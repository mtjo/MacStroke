//
//  PreferencesView.swift
//  MacStroke
//
//  SwiftUI-based preferences UI for MacStroke.
//

import SwiftUI
import AppKit
import Storage

/// Preferences window content.
public struct PreferencesView: View {
    @ObservedObject var viewModel: UserPreferences

    public init(viewModel: UserPreferences) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("General").font(.headline)
                    Toggle("Enable MacStroke", isOn: $viewModel.isEnabled)
                    Toggle("Show icon in status bar", isOn: $viewModel.showIconInStatusBar)
                    Toggle("Launch at login", isOn: $viewModel.launchAtLogin)
                    Toggle("Show UI in any application", isOn: $viewModel.showUIInWhateverApp)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Blocklist & Allowlist").font(.headline)
                    TextField("Blocked bundle IDs (one per line)", text: $viewModel.blockFilter)
                        .lineLimit(3...6)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Allowlist mode (inverse of blocklist)", isOn: $viewModel.whiteListMode)
                    TextField("Allowed bundle IDs (one per line)", text: $viewModel.whiteList)
                        .lineLimit(3...6)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Gesture Recognition").font(.headline)
                    Stepper(value: $viewModel.minimumPoints, in: 5...100) {
                        Text("Minimum Gesture Points: \(viewModel.minimumPoints)")
                    }
                    Stepper(value: $viewModel.minSimilarityScore, in: 0...100, step: 1) {
                        Text("Minimum Similarity Score: \(Int(viewModel.minSimilarityScore))%")
                    }
                    Toggle("Require similarity threshold", isOn: $viewModel.enableGestureMinScore)
                    Toggle("Show notification on gesture match", isOn: $viewModel.showGestureNote)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Notification Style").font(.headline)
                    Stepper(value: $viewModel.noteRetentionTime, in: 1...10) {
                        Text("Notification Duration: \(viewModel.noteRetentionTime)s")
                    }
                    Picker("Notification Position", selection: $viewModel.notePosition) {
                        Text("Mouse Position").tag(0)
                        Text("Screen Center").tag(1)
                        Text("Top Right").tag(2)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Background Alpha")
                        Slider(value: $viewModel.noteBackgroundAlpha, in: 0.1...1.0, step: 0.1)
                        Text("\(Int(viewModel.noteBackgroundAlpha * 100))%")
                            .frame(width: 42)
                    }
                    HStack {
                        Text("Font Size")
                        Slider(value: $viewModel.noteFontSize, in: 10...24, step: 1)
                        Text("\(Int(viewModel.noteFontSize))pt")
                            .frame(width: 42)
                    }
                    Toggle("Show icon in notification", isOn: $viewModel.showNoteIcon)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Mouse Path").font(.headline)
                    Toggle("Disable mouse path drawing", isOn: $viewModel.disableMousePath)
                    HStack {
                        Text("Line Width")
                        Slider(value: $viewModel.lineWidth, in: 1...10, step: 1)
                        Text("\(Int(viewModel.lineWidth))pt")
                            .frame(width: 42)
                    }
                    HStack {
                        Text("Line Color")
                        TextField("#0000FFFF", text: $viewModel.lineColorHex)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Right-click Menu").font(.headline)
                    Toggle("Enable Finder right-click menu", isOn: $viewModel.enableRightClickMenu)
                    Toggle("New File", isOn: $viewModel.enableNewFile)
                    Toggle("Open in Terminal", isOn: $viewModel.enableOpenInTerminal)
                    Toggle("Copy File Path", isOn: $viewModel.enableCopyFilePath)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Clipboard").font(.headline)
                    Stepper(value: $viewModel.clipboardLimitTop, in: 1...100) {
                        Text("Clipboard History Limit: \(viewModel.clipboardLimitTop)")
                    }
                    Stepper(value: $viewModel.clipboardLimitTotal, in: 1...1000) {
                        Text("Total Clipboard History: \(viewModel.clipboardLimitTotal)")
                    }
                    Stepper(value: $viewModel.clipboardSaveDays, in: 1...30) {
                        Text("Keep Clipboard History for: \(viewModel.clipboardSaveDays) day(s)")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Updates").font(.headline)
                    Toggle("Automatically check for updates", isOn: $viewModel.autoCheckUpdates)
                }

                HStack(spacing: 16) {
                    Button("Reset to Defaults", role: .destructive) {
                        viewModel.resetToDefaults()
                    }
                    Button("Save") {
                        viewModel.save()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 420, height: 560)
    }
}

// MARK: - Preferences View Helpers
private extension UserDefaults {
    func string(forKey key: StorageKey) -> String? {
        object(forKey: key.rawValue) as? String
    }
}

private extension UserDefaults {
    func setString(_ value: String, forKey key: StorageKey) {
        set(value, forKey: key.rawValue)
    }
}

