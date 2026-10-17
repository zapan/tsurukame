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

class LevelSelectorViewController: UIViewController {
  private let currentLevel: Int32
  private let maxLevel: Int32
  private let onSelect: (Int32) -> Void
  
  private var selectedLevel: Int32
  private let levelLabel = UILabel()
  private let stepper = UIStepper()
  
  init(currentLevel: Int32, maxLevel: Int32, onSelect: @escaping (Int32) -> Void) {
    self.currentLevel = currentLevel
    self.maxLevel = maxLevel
    self.selectedLevel = currentLevel
    self.onSelect = onSelect
    super.init(nibName: nil, bundle: nil)
    
    modalPresentationStyle = .formSheet
    preferredContentSize = CGSize(width: 300, height: 200)
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    view.backgroundColor = .systemBackground
    
    // Title
    let titleLabel = UILabel()
    titleLabel.text = "Download Translations"
    titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(titleLabel)
    
    // Message
    let messageLabel = UILabel()
    messageLabel.text = "Select up to which level to translate"
    messageLabel.font = .systemFont(ofSize: 13)
    messageLabel.textColor = .secondaryLabel
    messageLabel.textAlignment = .center
    messageLabel.numberOfLines = 0
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(messageLabel)
    
    // Level label
    levelLabel.text = "Level \(selectedLevel)"
    levelLabel.font = .systemFont(ofSize: 24, weight: .bold)
    levelLabel.textAlignment = .center
    levelLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(levelLabel)
    
    // Stepper
    stepper.minimumValue = 1
    stepper.maximumValue = Double(maxLevel)
    stepper.value = Double(selectedLevel)
    stepper.addTarget(self, action: #selector(stepperValueChanged), for: .valueChanged)
    stepper.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stepper)
    
    // Buttons
    let buttonStack = UIStackView()
    buttonStack.axis = .horizontal
    buttonStack.distribution = .fillEqually
    buttonStack.spacing = 12
    buttonStack.translatesAutoresizingMaskIntoConstraints = false
    
    let cancelButton = UIButton(type: .system)
    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    
    let downloadButton = UIButton(type: .system)
    downloadButton.setTitle("Download", for: .normal)
    downloadButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    downloadButton.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
    
    buttonStack.addArrangedSubview(cancelButton)
    buttonStack.addArrangedSubview(downloadButton)
    view.addSubview(buttonStack)
    
    // Constraints
    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
      titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      
      messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
      messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      
      levelLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      levelLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -10),
      
      stepper.topAnchor.constraint(equalTo: levelLabel.bottomAnchor, constant: 12),
      stepper.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      
      buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      buttonStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
      buttonStack.heightAnchor.constraint(equalToConstant: 44)
    ])
  }
  
  @objc private func stepperValueChanged() {
    selectedLevel = Int32(stepper.value)
    levelLabel.text = "Level \(selectedLevel)"
  }
  
  @objc private func cancelTapped() {
    dismiss(animated: true)
  }
  
  @objc private func downloadTapped() {
    dismiss(animated: true) {
      self.onSelect(self.selectedLevel)
    }
  }
}
