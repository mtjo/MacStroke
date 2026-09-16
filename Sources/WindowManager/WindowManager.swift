//
//  WindowManager.swift
//  MacStroke
//
//  Manages the status bar item and toast notifications.
//

import Foundation
import AppKit
import EventCapture
import Preferences

/// Manages the status bar item for the MacStroke app.
public final class WindowManager {
    public static let shared = WindowManager()

    private let statusBar = NSStatusBar.system
    private var statusItem: NSStatusItem?
    private var statusButton: NSButton?
    private var preferencesWindowController: PreferencesWindowController?

    private init() {}

    /// Create and show the status bar item.
    /// - Parameter buttonTitle: The text to display in the status bar
    /// - Returns: The created status bar item
    @discardableResult
    public func createStatusItem(with buttonTitle: String = "🖐") -> NSStatusItem {
        if let existing = statusItem {
            return existing
        }

        let item = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.title = buttonTitle
            button.target = self
            button.action = #selector(togglePreferences)
            statusButton = button
        }

        statusItem = item
        return item
    }

    /// Toggle the preferences window.
    @objc private func togglePreferences() {
        let viewModel = UserPreferences()
        let controller = PreferencesWindowController(viewModel: viewModel)
        controller.showWindow(nil)
        preferencesWindowController = controller
    }

    /// Hide the preferences window.
    public func hidePreferences() {
        preferencesWindowController?.close()
        preferencesWindowController = nil
    }
}