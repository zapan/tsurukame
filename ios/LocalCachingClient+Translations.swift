// Copyright 2026 David Sansome
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import FMDB
import Foundation
import PromiseKit
import WaniKaniAPI

extension LocalCachingClient {
  // MARK: - Translation Getters

  /// Get translation for a specific subject and language
  func getTranslation(subjectId: Int64, targetLang: TranslationLanguage) -> TKMTranslatedSubject? {
    databaseQueue.inDatabase { db in
      let cursor = db.query("SELECT pb FROM translations WHERE subject_id = ? AND target_lang = ?",
                            args: [subjectId, targetLang.rawValue])
      if cursor.next() {
        return cursor.proto(forColumnIndex: 0)
      }
      return nil
    }
  }

  /// Get a subject with translation applied if available and enabled
  /// This is the main method to use throughout the app
  func getSubjectWithTranslation(id: Int64) -> TKMSubject? {
    // If translations are disabled, just return the original
    guard Settings.translationsEnabled else {
      return getSubject(id: id)
    }
    // Get the original subject
    guard let original = getSubject(id: id) else {
      return nil
    }
    return translateSubject(original: original)
  }

  func getSubjectWithTranslation(japanese: String, type: TKMSubject.TypeEnum) -> TKMSubject? {
    // If translations are disabled, just return the original
    guard Settings.translationsEnabled else {
      return getSubject(japanese: japanese, type: type)
    }
    // Get the original subject
    guard let original = getSubject(japanese: japanese, type: type) else {
      return nil
    }
    return translateSubject(original: original)
  }

  func translateSubject(original: TKMSubject) -> TKMSubject {
    // If translations are disabled, just return the original
    guard Settings.translationsEnabled else {
      return original
    }

    // Try to get translation
    guard let translation = getTranslation(subjectId: original.id, targetLang: Settings.translationLanguage) else {
      // No translation available, return original
      return original
    }

    // Verify the translation is still valid (content hasn't changed)
    let service = TranslationService(apiKey: Settings.deeplApiKey)
    let currentHash = service.contentHash(subject: original)

    if translation.originalHash != currentHash {
      // Content has changed, translation is outdated
      // Mark for re-translation and return original
      NSLog("[TR] Translation outdated for subject \(original.id), marking for re-translation")
      markForRetranslation(subjectId: original.id, targetLang: Settings.translationLanguage)
      return original
    }

    // Merge original with translation
    return mergeSubjectWithTranslation(original: original, translation: translation)
  }

  // MARK: - Translation Storage

  /// Save a translation to the database
  func saveTranslation(translation: TKMTranslatedSubject) {
    databaseQueue.inTransaction { db in
      do {
        let pbData = try translation.serializedData()
        db.mustExecuteUpdate("""
                             REPLACE INTO translations
                               (subject_id, target_lang, original_hash, pb, created_at, updated_at)
                             VALUES (?, ?, ?, ?, ?, ?)
                             """,
                             args: [
                               translation.subjectID,
                               translation.targetLang,
                               translation.originalHash,
                               pbData,
                               translation.createdAt,
                               translation.updatedAt,
                             ])
      } catch {
        NSLog("[TR] Error saving translation for subject \(translation.subjectID): \(error)")
      }
    }
  }

  /// Delete translation for a specific subject and language
  func markForRetranslation(subjectId: Int64, targetLang: TranslationLanguage) {
    databaseQueue.inTransaction { db in
      db.mustExecuteUpdate("DELETE FROM translations WHERE subject_id = ? AND target_lang = ?",
                           args: [subjectId, targetLang.rawValue])
    }
  }

  /// Delete all translations for a specific language
  func clearTranslations(targetLang: TranslationLanguage) {
    databaseQueue.inTransaction { db in
      db.mustExecuteUpdate("DELETE FROM translations WHERE target_lang = ?",
                           args: [targetLang.rawValue])
    }
  }

  /// Delete all translations (all languages)
  func clearAllTranslations() {
    databaseQueue.inTransaction { db in
      db.mustExecuteUpdate("DELETE FROM translations")
    }
  }

  // MARK: - Translation Progress

  /// Get subjects that need translation
  func getUntranslatedSubjects(targetLang: TranslationLanguage,
                               limit: Int = 100,
                               maxLevel: Int32? = nil) -> [TKMSubject] {
    databaseQueue.inDatabase { db in
      var query = """
        SELECT s.pb
        FROM subjects s
        LEFT JOIN translations t
          ON s.id = t.subject_id AND t.target_lang = ?
        WHERE t.id IS NULL
      """

      var args: [Any] = [targetLang.rawValue]

      if let maxLevel = maxLevel {
        query += " AND s.level <= ?"
        args.append(maxLevel)
      }

      query += " ORDER BY s.level, s.id LIMIT ?"
      args.append(limit)

      let cursor = db.query(query, args: args)

      var results = [TKMSubject]()
      while cursor.next() {
        if let subject: TKMSubject = cursor.proto(forColumnIndex: 0) {
          results.append(subject)
        }
      }
      return results
    }
  }

  /// Get subjects that have outdated translations (hash doesn't match)
  func getOutdatedTranslations(targetLang: TranslationLanguage, limit: Int = 100) -> [Int64] {
    // This requires checking hashes, which is expensive
    // We'll return subject IDs that need re-translation
    databaseQueue.inDatabase { db in
      let cursor = db.query("""
                            SELECT t.subject_id, t.original_hash, s.pb
                            FROM translations t
                            JOIN subjects s ON t.subject_id = s.id
                            WHERE t.target_lang = ?
                            LIMIT ?
                            """,
                            args: [targetLang.rawValue, limit * 2] // Get more to check
      )

      var outdated: [Int64] = []
      let service = TranslationService(apiKey: Settings.deeplApiKey)

      while cursor.next(), outdated.count < limit {
        let subjectId = cursor.longLongInt(forColumnIndex: 0)
        let storedHash = cursor.string(forColumnIndex: 1) ?? ""

        if let subject: TKMSubject = cursor.proto(forColumnIndex: 2) {
          let currentHash = service.contentHash(subject: subject)
          if storedHash != currentHash {
            outdated.append(subjectId)
          }
        }
      }

      return outdated
    }
  }

  /// Get translation progress statistics
  func getTranslationProgress(targetLang: TranslationLanguage? = nil)
    -> (total: Int, translated: Int) {
    let lang = targetLang ?? Settings.translationLanguage

    return databaseQueue.inDatabase { db in
      let totalCursor = db.query("SELECT COUNT(*) FROM subjects")
      let total = totalCursor.next() ? Int(totalCursor.int(forColumnIndex: 0)) : 0

      let translatedCursor = db.query("SELECT COUNT(*) FROM translations WHERE target_lang = ?",
                                      args: [lang.rawValue])
      let translated = translatedCursor.next() ? Int(translatedCursor.int(forColumnIndex: 0)) : 0

      return (total, translated)
    }
  }

  // MARK: - Translation Sync

  /// Start translation sync process
  func startTranslationSync(progress: Progress) -> Promise<Void> {
    NSLog("[TR] startTranslationSync...")
    guard Settings.translationsEnabled,
          !Settings.deeplApiKey.isEmpty,
          reachability.isReachable() else {
      progress.totalUnitCount = 1
      progress.completedUnitCount = 1
      return Promise.value(())
    }

    // Check if we should use cellular
    if !Settings.translationCellular, !reachability.isReachableViaWiFi() {
      NSLog("[TR] Skipping translation sync: cellular disabled and not on WiFi")
      progress.totalUnitCount = 1
      progress.completedUnitCount = 1
      return Promise.value(())
    }

    let service = TranslationService(apiKey: Settings.deeplApiKey)
    let targetLang = Settings.translationLanguage

    return firstly {
      // First, update any outdated translations
      self.syncOutdatedTranslations(service: service, targetLang: targetLang, progress: progress)
    }.then { _ in
      // Then, translate new subjects
      self.syncNewTranslations(service: service, targetLang: targetLang, progress: progress)
    }
  }

  private func syncOutdatedTranslations(service: TranslationService,
                                        targetLang: TranslationLanguage,
                                        progress _: Progress) -> Promise<Void> {
    let outdatedIds = getOutdatedTranslations(targetLang: targetLang, limit: 50)

    guard !outdatedIds.isEmpty else {
      return Promise.value(())
    }

    NSLog("[TR] Re-translating \(outdatedIds.count) outdated subjects")

    // Delete outdated translations
    for subjectId in outdatedIds {
      markForRetranslation(subjectId: subjectId, targetLang: targetLang)
    }

    // Get the subjects and translate them
    let subjects = outdatedIds.compactMap { getSubject(id: $0) }
    return translateSubjectsBatch(subjects: subjects, service: service, targetLang: targetLang)
  }

  private func syncNewTranslations(service: TranslationService,
                                   targetLang: TranslationLanguage,
                                   progress _: Progress) -> Promise<Void> {
    // Only translate up to user's current level + 1 (for upcoming lessons)
    let userLevel = getUserInfo()?.level ?? 1
    let maxLevel = min(userLevel + 1, 60)

    let untranslated = getUntranslatedSubjects(targetLang: targetLang,
                                               limit: 20, // Translate 20 subjects per sync
                                               maxLevel: maxLevel)

    guard !untranslated.isEmpty else {
      return Promise.value(())
    }

    NSLog("[TR] Translating \(untranslated.count) new subjects (up to level \(maxLevel))")

    return translateSubjectsBatch(subjects: untranslated,
                                  service: service,
                                  targetLang: targetLang)
  }

  private func translateSubjectsBatch(subjects: [TKMSubject],
                                      service: TranslationService,
                                      targetLang: TranslationLanguage) -> Promise<Void> {
    // Translate subjects one by one (could be optimized with batching)
    var promises: [Promise<Void>] = []

    for subject in subjects {
      let promise = service.translateSubject(subject: subject, targetLang: targetLang)
        .done { translatedSubject in
          self.saveTranslation(translation: translatedSubject)
        }
        .recover { error -> Promise<Void> in
          NSLog("[TR] Error translating subject \(subject.id): \(error)")
          // Don't fail the entire batch if one translation fails, return a resolved void promise
          return .value(())
        }
      promises.append(promise)
    }

    return when(fulfilled: promises)
  }

  // MARK: - Manual Translation Trigger

  /// Manually trigger translation of subjects up to a specific level
  func downloadTranslations(upToLevel: Int32, progress: Progress) -> Promise<Void> {
    guard Settings.translationsEnabled,
          !Settings.deeplApiKey.isEmpty else {
      return Promise(error: TranslationError.apiKeyInvalid)
    }

    let service = TranslationService(apiKey: Settings.deeplApiKey)
    let targetLang = Settings.translationLanguage

    let untranslated = getUntranslatedSubjects(targetLang: targetLang,
                                               limit: 1000, // Get many for manual download
                                               maxLevel: upToLevel)

    progress.totalUnitCount = Int64(untranslated.count)

    guard !untranslated.isEmpty else {
      progress.completedUnitCount = progress.totalUnitCount
      return Promise.value(())
    }

    NSLog("[TR] Manually downloading translations for \(untranslated.count) subjects")

    // Translate in batches of 10
    let batchSize = 10
    var batchPromises: [Promise<Void>] = []

    for i in stride(from: 0, to: untranslated.count, by: batchSize) {
      let end = min(i + batchSize, untranslated.count)
      let batch = Array(untranslated[i ..< end])

      let batchPromise = translateSubjectsBatch(subjects: batch,
                                                service: service,
                                                targetLang: targetLang).done {
        progress.completedUnitCount += Int64(batch.count)
      }

      batchPromises.append(batchPromise)
    }

    return when(fulfilled: batchPromises)
  }

  // MARK: - Helper Methods

  private func mergeSubjectWithTranslation(original: TKMSubject,
                                           translation: TKMTranslatedSubject) -> TKMSubject {
    var merged = original

    // Merge Radical translations
    if merged.hasRadical {
      if !translation.radicalMnemonic.isEmpty {
        merged.radical.mnemonic = translation.radicalMnemonic
      }
      if !translation.radicalDeprecatedMnemonic.isEmpty {
        merged.radical.deprecatedMnemonic = translation.radicalDeprecatedMnemonic
      }
    }

    // Merge Kanji translations
    if merged.hasKanji {
      if !translation.kanjiMeaningMnemonic.isEmpty {
        merged.kanji.meaningMnemonic = translation.kanjiMeaningMnemonic
      }
      if !translation.kanjiMeaningHint.isEmpty {
        merged.kanji.meaningHint = translation.kanjiMeaningHint
      }
      if !translation.kanjiReadingMnemonic.isEmpty {
        merged.kanji.readingMnemonic = translation.kanjiReadingMnemonic
      }
      if !translation.kanjiReadingHint.isEmpty {
        merged.kanji.readingHint = translation.kanjiReadingHint
      }
    }

    // Merge Vocabulary translations
    if merged.hasVocabulary {
      if !translation.vocabularyMeaningExplanation.isEmpty {
        merged.vocabulary.meaningExplanation = translation.vocabularyMeaningExplanation
      }
      if !translation.vocabularyReadingExplanation.isEmpty {
        merged.vocabulary.readingExplanation = translation.vocabularyReadingExplanation
      }

      // Merge context sentences
      if !translation.vocabularySentenceEnglish.isEmpty,
         translation.vocabularySentenceEnglish.count == merged.vocabulary.sentences.count {
        for (index, translatedEnglish) in translation.vocabularySentenceEnglish.enumerated() {
          if index < merged.vocabulary.sentences.count {
            merged.vocabulary.sentences[index].english = translatedEnglish
          }
        }
      }
    }

    return merged
  }
}

// MARK: - Translation Migration/Repair

extension LocalCachingClient {
  /// Fix reading tags in existing translations that use the old fallback format
  /// This updates translations where reading tags were broken by translation
  public func repairReadingTagsInTranslations(targetLang: String,
                                             progressCallback: ((Int, Int) -> Void)? = nil) {
    databaseQueue.inDatabase { db in
      // Get all subjects with translations for the target language
      let cursor = db.query("""
        SELECT t.subject_id, t.target_lang, t.pb, s.pb as subject_pb
        FROM translations t
        JOIN subjects s ON t.subject_id = s.id
        WHERE t.target_lang = ?
      """, args: [targetLang])

      var subjectsToFix: [(subjectId: Int64, translation: TKMTranslatedSubject,
                          subject: TKMSubject)] = []

      while cursor.next() {
        guard let translationData = cursor.data(forColumn: "pb"),
              let subjectData = cursor.data(forColumn: "subject_pb"),
              let translation = try? TKMTranslatedSubject(serializedData: translationData),
              let subject = try? TKMSubject(serializedData: subjectData) else {
          continue
        }

        // Only process if it has reading mnemonics/explanations that use English fallback
        if translation.readingMnemonicUsesEnglish || translation.readingExplanationUsesEnglish {
          subjectsToFix.append((subjectId: translation.subjectID,
                               translation: translation,
                               subject: subject))
        }
      }

      NSLog("[TR] Found %d translations to repair", subjectsToFix.count)

      // Process each translation
      for (index, item) in subjectsToFix.enumerated() {
        var updated = item.translation
        var needsUpdate = false

        // Log subject info
        let subjectType = item.subject.hasKanji ? "KANJI" : "VOCAB"
        let subjectName = item.subject.japanese
        NSLog("[TR] [REPAIR] Processing %@ #%d: %@ (ID: %d)", 
              subjectType, index + 1, subjectName, item.subjectId)

        // Fix kanji reading_mnemonic
        if item.subject.hasKanji && updated.readingMnemonicUsesEnglish {
          if let primaryReading = item.subject.readings.first(where: { $0.isPrimary })?.reading {
            let englishText = item.subject.kanji.readingMnemonic
            let spanishText = updated.kanjiReadingMnemonic
            
            let fixed = self.fixReadingTags(englishText: englishText,
                                           spanishText: spanishText,
                                           reading: primaryReading)
            
            if fixed != spanishText {
              NSLog("[TR] [REPAIR] KANJI reading_mnemonic for '%@' (reading: %@)", 
                    subjectName, primaryReading)
              NSLog("[TR] [REPAIR] BEFORE: %@", spanishText)
              NSLog("[TR] [REPAIR] AFTER:  %@", fixed)
              
              updated.kanjiReadingMnemonic = fixed
              updated.updatedAt = Int32(Date().timeIntervalSince1970)
              needsUpdate = true
            } else {
              NSLog("[TR] [REPAIR] No changes needed for KANJI reading_mnemonic")
            }
          }
        }

        // Fix vocabulary reading_explanation
        if item.subject.hasVocabulary && updated.readingExplanationUsesEnglish {
          if let primaryReading = item.subject.readings.first(where: { $0.isPrimary })?.reading {
            let englishText = item.subject.vocabulary.readingExplanation
            let spanishText = updated.vocabularyReadingExplanation
            
            let fixed = self.fixReadingTags(englishText: englishText,
                                           spanishText: spanishText,
                                           reading: primaryReading)
            
            if fixed != spanishText {
              NSLog("[TR] [REPAIR] VOCAB reading_explanation for '%@' (reading: %@)", 
                    subjectName, primaryReading)
              NSLog("[TR] [REPAIR] BEFORE: %@", spanishText)
              NSLog("[TR] [REPAIR] AFTER:  %@", fixed)
              
              updated.vocabularyReadingExplanation = fixed
              updated.updatedAt = Int32(Date().timeIntervalSince1970)
              needsUpdate = true
            } else {
              NSLog("[TR] [REPAIR] No changes needed for VOCAB reading_explanation")
            }
          }
        }

        // Update database if changes were made
        if needsUpdate {
          guard let updatedData = try? updated.serializedData() else { continue }

          db.mustExecuteUpdate("""
            UPDATE translations
            SET pb = ?, updated_at = ?
            WHERE subject_id = ? AND target_lang = ?
          """, args: [updatedData, updated.updatedAt, item.subjectId, targetLang])
          
          NSLog("[TR] [REPAIR] ✅ Updated translation in database")
        } else {
          NSLog("[TR] [REPAIR] ⚠️  No updates needed for this subject")
        }

        // Report progress
        progressCallback?(index + 1, subjectsToFix.count)
      }

      NSLog("[TR] Repaired %d translations", subjectsToFix.count)
    }
  }

  private func fixReadingTags(englishText: String, spanishText: String, reading: String) -> String {
    // Extract the English keyword from the original text
    let englishKeyword = extractKeywordFromText(englishText, reading: reading)
    
    // Extract the Spanish keyword from the translated text
    let spanishKeyword = extractKeywordFromText(spanishText, reading: reading)
    
    // Apply the fix
    return fixReadingTagsInText(spanishText, 
                                reading: reading, 
                                englishKeyword: englishKeyword,
                                spanishKeyword: spanishKeyword)
  }
  
  private func extractKeywordFromText(_ text: String, reading: String) -> String? {
    // Pattern to find <reading>word</reading> followed by parentheses
    let pattern = "<reading>([^<]+)</reading>(?:\\s*\\([^)]*\\))+"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return nil
    }
    
    if let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       let readingWordRange = Range(match.range(at: 1), in: text),
       let matchRange = Range(match.range, in: text) {
      
      let readingWord = String(text[readingWordRange])
      let matchedText = String(text[matchRange])
      
      // Extract all content in parentheses
      let parenPattern = "\\(([^)]+)\\)"
      guard let parenRegex = try? NSRegularExpression(pattern: parenPattern) else {
        return readingWord // Fallback to word in <reading> tag
      }
      
      let parenMatches = parenRegex.matches(in: matchedText, 
                                           range: NSRange(matchedText.startIndex..., 
                                                         in: matchedText))
      
      // Get all words from parentheses, excluding the reading itself and romaji
      let romanReading = romanize(reading)
      var words: [String] = []
      for parenMatch in parenMatches {
        if let wordRange = Range(parenMatch.range(at: 1), in: matchedText) {
          let word = String(matchedText[wordRange])
          // Skip if it's the hiragana reading or romaji
          if word != reading && word != romanReading {
            words.append(word)
          }
        }
      }
      
      // Return the last non-hiragana/non-romaji word found (the actual keyword)
      // If no words found in parentheses, return the word from <reading> tag
      return words.last ?? readingWord
    }
    
    return nil
  }
  
  private func fixReadingTagsInText(_ text: String, 
                                    reading: String,
                                    englishKeyword: String?,
                                    spanishKeyword: String?) -> String {
    var result = text
    let romanReading = romanize(reading)

    // Pattern to match <reading>word</reading> followed by any number of (...)
    // This captures things like: <reading>hon</reading> (ほん) (hon) (hon) (perfeccionar)
    let escapedReading = NSRegularExpression.escapedPattern(for: reading)
    let pattern = "<reading>[^<]+</reading>(?:\\s*\\([^)]*\\))+"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return text
    }

    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

    // Process in reverse order to not affect indices
    for match in matches.reversed() {
      guard let fullRange = Range(match.range, in: text) else { continue }
      
      let matchedText = String(text[fullRange])
      
      // Verify this match contains our target reading
      if !matchedText.contains("(\(reading))") {
        continue
      }

      // Build the keyword part
      var keywordPart = ""
      if let englishKeyword = englishKeyword, let spanishKeyword = spanishKeyword {
        keywordPart = "\(englishKeyword), \(spanishKeyword)"
      } else if let spanishKeyword = spanishKeyword {
        keywordPart = spanishKeyword
      } else {
        continue // Skip if we don't have keywords
      }
      
      // Replacement: <reading>romaji</reading> (hiragana) (english, spanish)
      let replacement = "<reading>\(romanReading)</reading> (\(reading)) (\(keywordPart))"
      result.replaceSubrange(fullRange, with: replacement)
    }

    return result
  }

  private func romanize(_ japanese: String) -> String {
    let kanaToRoman: [String: String] = [
      "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
      "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
      "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
      "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
      "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
      "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
      "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
      "や": "ya", "ゆ": "yu", "よ": "yo",
      "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
      "わ": "wa", "を": "wo", "ん": "n",
      "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
      "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
      "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
      "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
      "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
      // Katakana
      "ア": "a", "イ": "i", "ウ": "u", "エ": "e", "オ": "o",
      "カ": "ka", "キ": "ki", "ク": "ku", "ケ": "ke", "コ": "ko",
      "サ": "sa", "シ": "shi", "ス": "su", "セ": "se", "ソ": "so",
      "タ": "ta", "チ": "chi", "ツ": "tsu", "テ": "te", "ト": "to",
      "ナ": "na", "ニ": "ni", "ヌ": "nu", "ネ": "ne", "ノ": "no",
      "ハ": "ha", "ヒ": "hi", "フ": "fu", "ヘ": "he", "ホ": "ho",
      "マ": "ma", "ミ": "mi", "ム": "mu", "メ": "me", "モ": "mo",
      "ヤ": "ya", "ユ": "yu", "ヨ": "yo",
      "ラ": "ra", "リ": "ri", "ル": "ru", "レ": "re", "ロ": "ro",
      "ワ": "wa", "ヲ": "wo", "ン": "n",
    ]

    var result = ""
    for char in japanese {
      if let roman = kanaToRoman[String(char)] {
        result += roman
      } else {
        result += String(char)
      }
    }

    return result
  }
}
