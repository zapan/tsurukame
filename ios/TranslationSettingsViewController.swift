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

import UIKit

class TranslationSettingsViewController: UITableViewController {
  private var model: MutableTableModel!
  private var services: TKMServices!
  private var progressObservation: NSKeyValueObservation?

  init(services: TKMServices) {
    self.services = services
    super.init(style: .grouped)
    title = "Translations"
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    rerender()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    rerender()
  }

  private func rerender() {
    model = MutableTableModel(tableView: tableView)

    // Section: Enable/Disable Translations
    model.add(section: "Translation", footer: """
    Automatically translate mnemonics, explanations, and context sentences to your preferred \
    language using DeepL. This requires a DeepL API key (free tier available at deepl.com/pro-api).

    Free tier: 500,000 characters/month
    Estimated: ~1,000 subjects per month with free tier
    """)

    let enabledSwitch = SwitchModelItem(style: .default,
                                        title: "Enable Translations",
                                        subtitle: nil,
                                        on: Settings.translationsEnabled,
                                        switchHandler: { [weak self] sender in
                                          Settings.translationsEnabled = sender.isOn
                                          self?.rerender()
                                        })
    model.add(enabledSwitch)

    // Show rest of settings only if enabled
    if Settings.translationsEnabled {
      // Section: DeepL API Configuration
      model.add(section: "DeepL API Configuration", footer: """
      Get a free API key at deepl.com/pro-api. The free tier includes 500,000 characters per \
      month, which is enough to translate about 1,000 subjects.
      """)

      let apiKeyText = Settings.deeplApiKey.isEmpty ? "" : "••••••••"
      let apiKeyItem = BasicModelItem(style: .value1,
                                      title: "API Key",
                                      subtitle: apiKeyText.isEmpty ? "Not configured" : apiKeyText,
                                      accessoryType: .disclosureIndicator,
                                      tapHandler: { [weak self] in
                                        self?.editApiKey()
                                      })
      model.add(apiKeyItem)

      model.add(BasicModelItem(style: .default,
                               title: "Get Free API Key →",
                               subtitle: "deepl.com/pro-api",
                               accessoryType: .none,
                               tapHandler: {
                                 if let url = URL(string: "https://www.deepl.com/pro-api") {
                                   UIApplication.shared.open(url)
                                 }
                               }))

      // Section: Language Selection
      model.add(section: "Target Language")

      model.add(BasicModelItem(style: .value1,
                               title: "Translation Language",
                               subtitle: Settings.translationLanguage.displayName,
                               accessoryType: .disclosureIndicator,
                               tapHandler: { [weak self] in
                                 self?.showLanguageSelection()
                               }))

      // Section: Download Options
      model.add(section: "Download Options")

      let autoDownloadSwitch = SwitchModelItem(style: .default,
                                               title: "Auto-download translations",
                                               subtitle: "Download translations during normal sync",
                                               on: Settings.translationAutoDownload,
                                               switchHandler: { [weak self] sender in
                                                 Settings.translationAutoDownload = sender.isOn
                                                 self?.rerender()
                                               })
      model.add(autoDownloadSwitch)

      let cellularSwitch = SwitchModelItem(style: .default,
                                           title: "Download over cellular",
                                           subtitle: nil,
                                           on: Settings.translationCellular,
                                           switchHandler: { sender in
                                             Settings.translationCellular = sender.isOn
                                           })
      cellularSwitch.isEnabled = Settings.translationAutoDownload
      model.add(cellularSwitch)

      // Section: Progress
      let (total, translated) = services.localCachingClient.getTranslationProgress()
      let percentage = total > 0 ? Int((Double(translated) / Double(total)) * 100) : 0

      model.add(section: "Translation Progress")

      model.add(BasicModelItem(style: .value1,
                               title: "Translated subjects",
                               subtitle: "\(translated) of \(total) (\(percentage)%)",
                               accessoryType: .none,
                               tapHandler: nil))

      // Show download button if not everything is translated
      if translated < total, !Settings.deeplApiKey.isEmpty {
        model.add(BasicModelItem(style: .default,
                                 title: "Download Translations Now",
                                 subtitle: "Translate all subjects up to your current level",
                                 accessoryType: .disclosureIndicator,
                                 tapHandler: { [weak self] in
                                   self?.startManualTranslation()
                                 }))
      }

      // Section: Management
      if translated > 0 {
        model.add(section: "Maintenance")

        model.add(BasicModelItem(style: .default,
                                 title: "Repair Reading Tags",
                                 subtitle: "Fix reading tags in existing translations",
                                 accessoryType: .disclosureIndicator,
                                 tapHandler: { [weak self] in
                                   self?.repairReadingTags()
                                 }))

        model.add(BasicModelItem(style: .default,
                                 title: "Clear All Translations",
                                 subtitle: nil,
                                 accessoryType: .none,
                                 tapHandler: { [weak self] in
                                   self?.confirmClearTranslations()
                                 }))
      }
    }

    model.reloadTable()
  }

  // MARK: - Actions

  private func editApiKey() {
    let alert = UIAlertController(title: "DeepL API Key",
                                  message: "Enter your DeepL API authentication key",
                                  preferredStyle: .alert)

    alert.addTextField { textField in
      textField.placeholder = "Enter API key"
      textField.text = Settings.deeplApiKey
      textField.autocapitalizationType = .none
      textField.autocorrectionType = .no
    }

    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
      if let apiKey = alert.textFields?.first?.text {
        Settings.deeplApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self?.rerender()
      }
    })

    present(alert, animated: true)
  }

  private func showLanguageSelection() {
    let vc = SettingChoiceListViewController(setting: Settings.$translationLanguage,
                                             title: "Translation Language")
    vc.addChoicesFromEnum()
    navigationController?.pushViewController(vc, animated: true)
  }

  private func startManualTranslation() {
    NSLog("[TR] startManualTranslation!")
    guard !Settings.deeplApiKey.isEmpty else {
      showError(message: "Please configure your DeepL API key first.")
      return
    }

    let userLevel = services.localCachingClient.getUserInfo()?.level ?? 1
    let maxLevel = services.localCachingClient.maxLevelGrantedBySubscription
    
    let levelSelector = LevelSelectorViewController(
      currentLevel: userLevel,
      maxLevel: Int32(maxLevel),
      onSelect: { [weak self] selectedLevel in
        self?.performManualTranslation(upToLevel: selectedLevel)
      }
    )
    
    present(levelSelector, animated: true)
  }

  private func performManualTranslation(upToLevel: Int32) {
    NSLog("[TR] performManualTranslation: \(upToLevel)")
    
    // Show progress HUD
    let hud = UIAlertController(title: "Downloading Translations", 
                                message: "0 / 0", 
                                preferredStyle: .alert)
    present(hud, animated: true)
    
    let progress = Progress(totalUnitCount: 100)

    // Update progress message
    progressObservation = progress
      .observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
        DispatchQueue.main.async {
          let percentage = Int(progress.fractionCompleted * 100)
          let completed = progress.completedUnitCount
          let total = progress.totalUnitCount
          hud.message = "\(completed) / \(total) subjects (\(percentage)%)"
        }
      }

    // Perform download
    services.localCachingClient.downloadTranslations(upToLevel: Int32(upToLevel), progress: progress)
      .done { [weak self] in
        guard let self = self else { return }
        self.progressObservation?.invalidate()
        
        hud.dismiss(animated: true) {
          self.rerender()
          
          let successAlert = UIAlertController(title: "Success",
                                               message: "Translations downloaded successfully!",
                                               preferredStyle: .alert)
          successAlert.addAction(UIAlertAction(title: "OK", style: .default))
          self.present(successAlert, animated: true)
        }
      }
      .catch { [weak self] error in
        guard let self = self else { return }
        self.progressObservation?.invalidate()
        
        hud.dismiss(animated: true) {
          self.rerender()
          self.showError(message: "Translation failed: \(error.localizedDescription)")
        }
      }
  }

  private func confirmClearTranslations() {
    let alert = UIAlertController(title: "Clear All Translations",
                                  message: "This will delete all downloaded translations for \(Settings.translationLanguage.description). " +
                                    "Are you sure? You can re-download them later.",
                                  preferredStyle: .alert)

    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
      self?.clearTranslations()
    })

    present(alert, animated: true)
  }

  private func clearTranslations() {
    services.localCachingClient.clearTranslations(targetLang: Settings.translationLanguage)
    rerender()

    let alert = UIAlertController(title: "Cleared",
                                  message: "All translations have been deleted.",
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  private func showError(message: String) {
    let alert = UIAlertController(title: "Error",
                                  message: message,
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  private func repairReadingTags() {
    let alert = UIAlertController(title: "Repair Reading Tags",
                                  message: "This will fix reading tags in translations that were broken by DeepL. " +
                                    "The tag <reading> will contain romaji instead of the translated word.",
                                  preferredStyle: .alert)

    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Repair", style: .default) { [weak self] _ in
      self?.performRepair()
    })

    present(alert, animated: true)
  }

  private func performRepair() {
    // Show progress HUD
    let hud = UIAlertController(title: "Repairing...", message: "0 / 0", preferredStyle: .alert)
    present(hud, animated: true)

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }

      self.services.localCachingClient.repairReadingTagsInTranslations(
        targetLang: Settings.translationLanguage.rawValue
      ) { current, total in
        DispatchQueue.main.async {
          hud.message = "\(current) / \(total)"
        }
      }

      DispatchQueue.main.async {
        hud.dismiss(animated: true) {
          self.rerender()

          let successAlert = UIAlertController(title: "Complete",
                                               message: "Reading tags have been repaired successfully!",
                                               preferredStyle: .alert)
          successAlert.addAction(UIAlertAction(title: "OK", style: .default))
          self.present(successAlert, animated: true)
        }
      }
    }
  }
}
