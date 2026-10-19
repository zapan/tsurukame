// Copyright David Sansome
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

import CommonCrypto
import Foundation
import PromiseKit
import WaniKaniAPI

enum TranslationError: Error, LocalizedError {
  case apiKeyInvalid
  case quotaExceeded
  case networkError(Error)
  case invalidResponse
  case languageNotSupported
  case emptyText
  case tagPreservationFailed

  var errorDescription: String? {
    switch self {
    case .apiKeyInvalid:
      return "DeepL API key is invalid. Please check your configuration."
    case .quotaExceeded:
      return "DeepL translation quota exceeded. Please wait until next month or upgrade to Pro."
    case let .networkError(error):
      return "Network error: \(error.localizedDescription)"
    case .invalidResponse:
      return "Invalid response from DeepL API."
    case .languageNotSupported:
      return "Target language is not supported by DeepL."
    case .emptyText:
      return "Cannot translate empty text."
    case .tagPreservationFailed:
      return "Failed to preserve HTML tags in translation."
    }
  }
}

enum TranslationStrategy {
  case deepL // Direct DeepL translation (works well)
  case fallbackAnnotated // English + Spanish annotation (phonetics broken)
}

struct TranslationResult {
  let text: String
  let strategy: TranslationStrategy
  let usesEnglish: Bool // true if fallback was used
}

class TranslationService {
  private let apiKey: String
  private let useFreeAPI: Bool // true = api-free.deepl.com, false = api.deepl.com

  // Rate limiting
  private let requestQueue: OperationQueue
  private var lastRequestTime: Date = .distantPast
  private let minimumRequestInterval: TimeInterval = 0.5 // 2 requests/second max
  private let rateLimitQueue = DispatchQueue(label: "com.app.deepl.ratelimit")

  init(apiKey: String, useFreeAPI: Bool = true) {
    self.apiKey = apiKey
    self.useFreeAPI = useFreeAPI

    // Configure request queue for serial execution
    requestQueue = OperationQueue()
    requestQueue.maxConcurrentOperationCount = 1
    requestQueue.qualityOfService = .userInitiated
  }

  // MARK: - Public API

  /// Translate a single text with DeepL
  func translate(text: String, targetLang: TranslationLanguage) -> Promise<String> {
    guard !text.isEmpty else {
      return Promise(error: TranslationError.emptyText)
    }

    return translateBatch(texts: [text], targetLang: targetLang).map { results in
      guard let first = results.first else {
        throw TranslationError.invalidResponse
      }
      return first
    }
  }

  /// Translate multiple texts in a single API call (more efficient)
  /// DeepL allows up to 50 texts per request
  func translateBatch(texts: [String], targetLang: TranslationLanguage) -> Promise<[String]> {
    guard !texts.isEmpty else {
      return Promise.value([])
    }

    // Filter out empty texts but remember positions
    var textIndexMap: [Int: Int] = [:]
    var nonEmptyTexts: [String] = []
    for (index, text) in texts.enumerated() {
      if !text.isEmpty {
        textIndexMap[nonEmptyTexts.count] = index
        nonEmptyTexts.append(text)
      }
    }

    guard !nonEmptyTexts.isEmpty else {
      return Promise.value(Array(repeating: "", count: texts.count))
    }

    NSLog("[TR:API] 📤 Batch request: \(nonEmptyTexts.count) texts, \(nonEmptyTexts.reduce(0) { $0 + $1.count }) chars total")

    return firstly {
      self.waitForRateLimit()
    }.then { _ in
      self.performDeepLRequest(texts: nonEmptyTexts, targetLang: targetLang)
    }.map { translatedTexts in
      // Reconstruct full array with empty strings in original positions
      var result = Array(repeating: "", count: texts.count)
      for (translatedIndex, originalIndex) in textIndexMap {
        if translatedIndex < translatedTexts.count {
          result[originalIndex] = translatedTexts[translatedIndex]
        }
      }
      return result
    }
  }

  /// Translate text while preserving WaniKani markup tags
  func translateWithMarkup(text: String, targetLang: TranslationLanguage) -> Promise<String> {
    guard !text.isEmpty else {
      return Promise(error: TranslationError.emptyText)
    }

    // Extract tags and replace with placeholders
    let (plainText, tagMap) = extractTags(from: text)

    // Translate the text with placeholders
    return translate(text: plainText, targetLang: targetLang).map { translated in
      // Restore tags in the translated text
      self.restoreTags(in: translated, using: tagMap)
    }
  }

  /// Translate a reading mnemonic with phonetic preservation check
  func translateReadingMnemonic(text: String,
                                reading: String,
                                targetLang: TranslationLanguage) -> Promise<TranslationResult> {
    guard !text.isEmpty else {
      return Promise(error: TranslationError.emptyText)
    }

    // Attempt translation with markup preservation
    return translateWithMarkup(text: text, targetLang: targetLang).map { translated in
      // Check if phonetics are preserved
      if self.readingTagsPreserveFonetics(translatedText: translated, targetReading: reading) {
        // ✅ Translation works!
        return TranslationResult(text: translated,
                                 strategy: .deepL,
                                 usesEnglish: false)
      } else {
        // ❌ Translation breaks phonetics, fix it
        let fixed = self.fixReadingTags(translatedText: translated, targetReading: reading)
        return TranslationResult(text: fixed,
                                 strategy: .fallbackAnnotated,
                                 usesEnglish: true)
      }
    }
  }

  /// Translate a complete subject with all its fields (OPTIMIZED BATCH)
  func translateSubject(subject: TKMSubject,
                        targetLang: TranslationLanguage) -> Promise<TKMTranslatedSubject> {
    var result = TKMTranslatedSubject()
    result.subjectID = subject.id
    result.targetLang = targetLang.rawValue
    result.originalHash = contentHash(subject: subject)
    result.createdAt = Int32(Date().timeIntervalSince1970)
    result.updatedAt = Int32(Date().timeIntervalSince1970)
    result.translationVersion = 1

    // Collect all texts to translate with metadata about what they are
    var textsToTranslate: [String] = []
    var fieldMapping: [(fieldType: String, index: Int)] = []

    let subjectType = subject.hasRadical ? "Radical" : subject.hasKanji ? "Kanji" : "Vocabulary"
    NSLog(
      "[TR:Subject] 🔤 translateSubject() - ID: \(subject.id), Type: \(subjectType)"
    )

    // Collect Radical fields
    if subject.hasRadical {
      if !subject.radical.mnemonic.isEmpty {
        textsToTranslate.append(subject.radical.mnemonic)
        fieldMapping.append(("radical_mnemonic", textsToTranslate.count - 1))
      }
      if !subject.radical.deprecatedMnemonic.isEmpty {
        textsToTranslate.append(subject.radical.deprecatedMnemonic)
        fieldMapping.append(("radical_deprecated_mnemonic", textsToTranslate.count - 1))
      }
    }

    // Collect Kanji fields
    if subject.hasKanji {
      if !subject.kanji.meaningMnemonic.isEmpty {
        textsToTranslate.append(subject.kanji.meaningMnemonic)
        fieldMapping.append(("kanji_meaning_mnemonic", textsToTranslate.count - 1))
      }
      if !subject.kanji.meaningHint.isEmpty {
        textsToTranslate.append(subject.kanji.meaningHint)
        fieldMapping.append(("kanji_meaning_hint", textsToTranslate.count - 1))
      }
      if !subject.kanji.readingMnemonic.isEmpty {
        textsToTranslate.append(subject.kanji.readingMnemonic)
        fieldMapping.append(("kanji_reading_mnemonic", textsToTranslate.count - 1))
      }
      if !subject.kanji.readingHint.isEmpty {
        textsToTranslate.append(subject.kanji.readingHint)
        fieldMapping.append(("kanji_reading_hint", textsToTranslate.count - 1))
      }
    }

    // Collect Vocabulary fields
    if subject.hasVocabulary {
      if !subject.vocabulary.meaningExplanation.isEmpty {
        textsToTranslate.append(subject.vocabulary.meaningExplanation)
        fieldMapping.append(("vocab_meaning_explanation", textsToTranslate.count - 1))
      }
      if !subject.vocabulary.readingExplanation.isEmpty {
        textsToTranslate.append(subject.vocabulary.readingExplanation)
        fieldMapping.append(("vocab_reading_explanation", textsToTranslate.count - 1))
      }
      if !subject.vocabulary.sentences.isEmpty {
        let englishSentences = subject.vocabulary.sentences.map { $0.english }
        for (sentenceIndex, sentence) in englishSentences.enumerated() {
          textsToTranslate.append(sentence)
          fieldMapping.append(("vocab_sentence_\(sentenceIndex)", textsToTranslate.count - 1))
        }
      }
    }

    guard !textsToTranslate.isEmpty else {
      NSLog("[TR:Subject] ⚠️  No texts to translate for subject \(subject.id)")
      return Promise.value(result)
    }

    NSLog("[TR:Subject] 📊 Batching \(textsToTranslate.count) texts in single request")

    // Now translate ALL texts in a single batch
    return translateBatch(texts: textsToTranslate, targetLang: targetLang).then { translatedTexts
      -> Promise<TKMTranslatedSubject> in

      // Map results back to fields
      for (fieldType, index) in fieldMapping {
        guard index < translatedTexts.count else { continue }
        let translatedText = translatedTexts[index]

        switch fieldType {
        case "radical_mnemonic":
          result.radicalMnemonic = translatedText
        case "radical_deprecated_mnemonic":
          result.radicalDeprecatedMnemonic = translatedText
        case "kanji_meaning_mnemonic":
          result.kanjiMeaningMnemonic = translatedText
        case "kanji_meaning_hint":
          result.kanjiMeaningHint = translatedText
        case "kanji_reading_mnemonic":
          result.kanjiReadingMnemonic = translatedText
        case "kanji_reading_hint":
          result.kanjiReadingHint = translatedText
        case "vocab_meaning_explanation":
          result.vocabularyMeaningExplanation = translatedText
        case "vocab_reading_explanation":
          result.vocabularyReadingExplanation = translatedText
        default:
          if fieldType.hasPrefix("vocab_sentence_") {
            if result.vocabularySentenceEnglish.isEmpty {
              result.vocabularySentenceEnglish = Array(
                repeating: "", count: subject.vocabulary.sentences.count
              )
            }
            if let sentenceIndex = Int(fieldType.replacingOccurrences(of: "vocab_sentence_", with: ""))
            {
              result.vocabularySentenceEnglish[sentenceIndex] = translatedText
            }
          }
        }
      }

      return Promise.value(result)
    }
  }

  // MARK: - Content Hashing

  /// Calculate a hash of the translatable content in a subject
  /// Used to detect when WaniKani updates content and we need to re-translate
  func contentHash(subject: TKMSubject) -> String {
    var content = ""

    if subject.hasRadical {
      content += subject.radical.mnemonic
      content += subject.radical.deprecatedMnemonic
    }

    if subject.hasKanji {
      content += subject.kanji.meaningMnemonic
      content += subject.kanji.meaningHint
      content += subject.kanji.readingMnemonic
      content += subject.kanji.readingHint
    }

    if subject.hasVocabulary {
      content += subject.vocabulary.meaningExplanation
      content += subject.vocabulary.readingExplanation
      for sentence in subject.vocabulary.sentences {
        content += sentence.english
      }
    }

    return content.md5()
  }

  // MARK: - Private Helpers

  private func waitForRateLimit() -> Promise<Void> {
    Promise { seal in
      rateLimitQueue.async {
        let now = Date()
        let timeSinceLastRequest = now.timeIntervalSince(self.lastRequestTime)

        if timeSinceLastRequest < self.minimumRequestInterval {
          let delay = self.minimumRequestInterval - timeSinceLastRequest
          self.lastRequestTime = now.addingTimeInterval(delay)

          DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            seal.fulfill(())
          }
        } else {
          self.lastRequestTime = now
          seal.fulfill(())
        }
      }
    }
  }

  private func performDeepLRequest(texts: [String],
                                   targetLang: TranslationLanguage) -> Promise<[String]> {
    let baseURL = useFreeAPI
      ? "https://api-free.deepl.com/v2/translate"
      : "https://api.deepl.com/v2/translate"

    guard let url = URL(string: baseURL) else {
      return Promise(error: TranslationError.invalidResponse)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    // Build request body
    var bodyComponents: [String] = []
    for text in texts {
      let encodedText = text
        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
      bodyComponents.append("text=\(encodedText)")
    }
    bodyComponents.append("target_lang=\(targetLang.rawValue)")
    bodyComponents.append("tag_handling=html") // Preserve HTML-like tags
    bodyComponents.append("split_sentences=0") // Don't split sentences

    request.httpBody = bodyComponents.joined(separator: "&").data(using: .utf8)
    let requestBodySize = request.httpBody?.count ?? 0

    NSLog("[TR:API] 🚀 DeepL: \(texts.count) texts → \(requestBodySize) bytes")

    return Promise { seal in
      let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
          NSLog("[TR:API] ❌ Network error: \(error.localizedDescription)")
          seal.reject(TranslationError.networkError(error))
          return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
          NSLog("[TR:API] ❌ Invalid response type")
          seal.reject(TranslationError.invalidResponse)
          return
        }

        // Check for API errors
        switch httpResponse.statusCode {
        case 200:
          break // Success, continue to parsing
        case 403:
          NSLog("[TR:API] ❌ API Key Invalid (403)")
          seal.reject(TranslationError.apiKeyInvalid)
          return
        case 429:
          NSLog("[TR:API] ❌ Rate limited (429)")
          seal.reject(TranslationError.invalidResponse)
          return
        case 456:
          NSLog("[TR:API] ❌ Quota exceeded (456)")
          seal.reject(TranslationError.quotaExceeded)
          return
        default:
          NSLog("[TR:API] ❌ HTTP \(httpResponse.statusCode)")
          seal.reject(TranslationError.invalidResponse)
          return
        }

        guard let data = data else {
          NSLog("[TR:API] ❌ No data in response")
          seal.reject(TranslationError.invalidResponse)
          return
        }

        // Parse JSON response
        do {
          guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let translations = json["translations"] as? [[String: Any]] else {
            NSLog("[TR:API] ❌ Invalid JSON structure")
            seal.reject(TranslationError.invalidResponse)
            return
          }

          let translatedTexts = translations.compactMap { dict -> String? in
            dict["text"] as? String
          }

          guard translatedTexts.count == texts.count else {
            NSLog("[TR:API] ❌ Count mismatch: sent \(texts.count), got \(translatedTexts.count)")
            seal.reject(TranslationError.invalidResponse)
            return
          }

          NSLog("[TR:API] ✅ HTTP 200 - Received \(translatedTexts.count) translations")
          seal.fulfill(translatedTexts)
        } catch {
          NSLog("[TR:API] ❌ JSON parsing error: \(error.localizedDescription)")
          seal.reject(TranslationError.invalidResponse)
        }
      }

      task.resume()
    }
  }

  // MARK: - Tag Preservation

  private func extractTags(from text: String) -> (plainText: String, tagMap: [String: (tag: String,
                                                                                       content: String)]) {
    var result = text
    var tagMap: [String: (tag: String, content: String)] = [:]
    var tagCounter = 0

    // Regex to find tags: <TAG>content</TAG>
    let pattern = "<(radical|kanji|vocabulary|reading)>([^<]+)</\\1>"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return (text, [:])
    }

    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

    // Process in reverse order to not affect indices
    for match in matches.reversed() {
      guard let tagRange = Range(match.range(at: 1), in: text),
            let contentRange = Range(match.range(at: 2), in: text),
            let fullRange = Range(match.range, in: text) else { continue }

      let tag = String(text[tagRange])
      let content = String(text[contentRange])
      let placeholder = "{{TAG_\(tagCounter)_START}}\(content){{TAG_\(tagCounter)_END}}"

      tagMap["TAG_\(tagCounter)"] = (tag: tag, content: content)
      result.replaceSubrange(fullRange, with: placeholder)
      tagCounter += 1
    }

    return (result, tagMap)
  }

  private func restoreTags(in text: String,
                           using tagMap: [String: (tag: String, content: String)]) -> String {
    var result = text

    // Sort by key to process in consistent order
    let sortedKeys = tagMap.keys.sorted { key1, key2 in
      let num1 = Int(key1.replacingOccurrences(of: "TAG_", with: "")
        .replacingOccurrences(of: "_START", with: "")) ?? 0
      let num2 = Int(key2.replacingOccurrences(of: "TAG_", with: "")
        .replacingOccurrences(of: "_START", with: "")) ?? 0
      return num1 < num2
    }

    for key in sortedKeys {
      guard let value = tagMap[key] else { continue }

      let startPlaceholder = "{{\(key)_START}}"
      let endPlaceholder = "{{\(key)_END}}"

      // Find the translated content between placeholders
      guard let startRange = result.range(of: startPlaceholder),
            let endRange = result.range(of: endPlaceholder) else {
        // Placeholders not found - log warning but continue
        NSLog("[TR] Warning: Placeholders not found for key: \(key)")
        continue
      }

      // Verify valid range before creating it
      guard startRange.upperBound <= endRange.lowerBound else {
        NSLog("[TR] Error: Invalid range order for key: \(key). Start: \(startRange.upperBound), End: \(endRange.lowerBound)")
        continue
      }

      let contentRange = startRange.upperBound ..< endRange.lowerBound
      let translatedContent = String(result[contentRange])
      let fullRange = startRange.lowerBound ..< endRange.upperBound

      // Replace with the original tag
      let replacement = "<\(value.tag)>\(translatedContent)</\(value.tag)>"
      result.replaceSubrange(fullRange, with: replacement)
    }

    return result
  }

  // MARK: - Phonetic Preservation

  private func extractReadingWords(from text: String) -> [(word: String, fullMatch: String)] {
    let pattern = "<reading>([^<]+)</reading>"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return []
    }

    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

    return matches.compactMap { match in
      guard let wordRange = Range(match.range(at: 1), in: text),
            let fullRange = Range(match.range, in: text) else { return nil }
      return (word: String(text[wordRange]), fullMatch: String(text[fullRange]))
    }
  }

  private func readingTagsPreserveFonetics(translatedText: String,
                                           targetReading: String) -> Bool {
    let translatedWords = extractReadingWords(from: translatedText)

    guard !translatedWords.isEmpty else {
      return false
    }

    // Romanize the Japanese reading
    let romanReading = romanize(targetReading)
    let readingPrefix = String(romanReading.prefix(2)).lowercased()

    // Check each translated word
    for item in translatedWords {
      let transPrefix = String(item.word.prefix(2)).lowercased()

      // The translated word should start with the same sound
      if !transPrefix.starts(with: readingPrefix) {
        return false
      }
    }

    return true
  }

  /// Fix reading tags by replacing translated words with romaji and adding translation in
  /// parentheses
  private func fixReadingTags(translatedText: String, targetReading: String) -> String {
    var result = translatedText
    let romanReading = romanize(targetReading)

    let pattern = "<reading>([^<]+)</reading>\\s*\\(([^)]+)\\)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return translatedText
    }

    let matches = regex.matches(in: translatedText, range: NSRange(translatedText.startIndex...,
                                                                   in: translatedText))

    // Process in reverse order to not affect indices
    for match in matches.reversed() {
      guard let translatedWordRange = Range(match.range(at: 1), in: translatedText),
            let fullRange = Range(match.range, in: translatedText) else { continue }

      let translatedWord = String(translatedText[translatedWordRange])

      // Replacement: <reading>romaji</reading> (hiragana) (spanish_word)
      let replacement = "<reading>\(romanReading)</reading> (\(targetReading)) (\(translatedWord))"
      result.replaceSubrange(fullRange, with: replacement)
    }

    return result
  }

  private func romanize(_ japanese: String) -> String {
    // Simple romanization mapping for common kana
    // For a full implementation, you'd use a proper romanization library
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

// MARK: - String Extensions

extension String {
  func md5() -> String {
    guard let data = data(using: .utf8) else { return "" }
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))

    data.withUnsafeBytes { bytes in
      _ = CC_MD5(bytes.baseAddress, CC_LONG(data.count), &digest)
    }

    return digest.map { String(format: "%02hhx", $0) }.joined()
  }
}
