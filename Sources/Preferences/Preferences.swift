//
//  Preferences.swift
//  MacStroke
//
//  User preferences management with SwiftUI + AppKit hybrid UI.
//  Uses PreferencesStorage for persistence.
//

import Foundation
import AppKit
import SwiftUI
import Storage

/// User preferences model.
public final class UserPreferences: ObservableObject {
    private let storage: PreferencesStorage

    @Published public var isEnabled: Bool {
        didSet { storage.setBool(isEnabled, forKey: .isEnabled) }
    }

    @Published public var showToast: Bool {
        didSet { storage.setBool(showToast, forKey: .showToast) }
    }

    @Published public var launchAtLogin: Bool {
        didSet { storage.setBool(launchAtLogin, forKey: .launchAtLogin) }
    }

    @Published public var minimumPoints: Int {
        didSet { storage.setInt(minimumPoints, forKey: .minimumPoints) }
    }

    @Published public var minSimilarityScore: Double {
        didSet { storage.setDouble(minSimilarityScore, forKey: .minSimilarityScore) }
    }

    @Published public var clipboardHistoryLimit: Int {
        didSet { storage.setInt(clipboardHistoryLimit, forKey: .clipboardHistoryLimit) }
    }

    public init(storage: PreferencesStorage = PreferencesStorage()) {
        self.storage = storage
        self.isEnabled = storage.getBool(forKey: .isEnabled)
        self.showToast = storage.getBool(forKey: .showToast)
        self.launchAtLogin = storage.getBool(forKey: .launchAtLogin)
        self.minimumPoints = storage.getInt(forKey: .minimumPoints)
        self.minSimilarityScore = storage.getDouble(forKey: .minSimilarityScore)
        self.clipboardHistoryLimit = storage.getInt(forKey: .clipboardHistoryLimit)
    }

    /// Save current preferences to storage immediately.
    public func save() {
        storage.synchronize()
    }
}

/// AppKit bridge for presenting SwiftUI preferences as a preference pane.
public final class PreferencesWindowController: NSWindowController {
    private let viewModel: UserPreferences

    public init(viewModel: UserPreferences) {
        self.viewModel = viewModel
        super.init(window: nil)

        let hostingController = NSHostingController(
            rootView: PreferencesView(viewModel: viewModel)
        )
        hostingController.title = "MacStroke Preferences"
        self.contentViewController = hostingController

        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.window?.contentView = hostingController.view
        self.window?.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// SwiftUI preferences view.
public struct PreferencesView: View {
    @ObservedObject public var viewModel: UserPreferences

    public init(viewModel: UserPreferences) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 16) {
            Group {
                Toggle("Enable MacStroke", isOn: $viewModel.isEnabled)
                Toggle("Show Toast Notifications", isOn: $viewModel.showToast)
                Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)

                HStack {
                    Text("Minimum Points:")
                    TextField("10", value: $viewModel.minimumPoints, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                HStack {
                    Text("Min Similarity Score:")
                    TextField("30.0", value: $viewModel.minSimilarityScore, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                HStack {
                    Text("Clipboard History Limit:")
                    TextField("50", value: $viewModel.clipboardHistoryLimit, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }
            .padding()

            Button("Save") {
                viewModel.save()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}