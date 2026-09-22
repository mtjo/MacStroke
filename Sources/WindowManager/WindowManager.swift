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
import Storage

/// Manages the status bar item for the MacStroke app.
public final class WindowManager {
    public static let shared = WindowManager()

    private let statusBar = NSStatusBar.system
    private var statusItem: NSStatusItem?
    private var statusButton: NSButton?
    private var preferencesWindowController: PreferencesWindowController?
    private var clipboardListWindowController: HistoryClipboardListWindowController?
    private var shortcutMonitor: ShortcutMonitor?
    private var historyShortcutNeedsUpdate = true

    private init() {
        // Initialize clipboard history monitoring when WindowManager is created
        initializeClipboardHistory()
    }

    /// Initialize clipboard history and global shortcut monitoring.
    private func initializeClipboardHistory() {
        // Enable clipboard history monitoring if enabled in preferences
        let manager = HistoryClipboardManager()
        _ = manager.enableHistoryClipboard()

        // Start monitoring the global shortcut for clipboard history list
        startMonitoringHistoryShortcut()
    }

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
        if let existing = preferencesWindowController,
           existing.window?.isVisible == true {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = UserPreferences()
        let controller = PreferencesWindowController(viewModel: viewModel)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController = controller
    }

    /// Hide the preferences window.
    public func hidePreferences() {
        preferencesWindowController?.close()
        preferencesWindowController = nil
    }

    /// Show the clipboard history list window.
    /// The original closes the previous window and loads a fresh controller on
    /// every call, so the list always reflects the current storage backend.
    @objc public func showClipboardHistory() {
        clipboardListWindowController?.window?.close()
        let controller = HistoryClipboardListWindowController()
        clipboardListWindowController = controller
        controller.window?.center()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Update the global shortcut monitor based on current preferences.
    /// - Parameter shortcutString: Shortcut string in format "keyCode=X, flags=Y"
    public func updateGlobalShortcut(_ shortcutString: String) {
        let wasMonitoring = shortcutMonitor?.isMonitoring ?? false

        if shortcutMonitor == nil {
            shortcutMonitor = ShortcutMonitor()
        }

        if let parsed = ShortcutMonitor.parseShortcut(shortcutString) {
            shortcutMonitor?.keyCode = parsed.0
            shortcutMonitor?.flags = parsed.1
            if wasMonitoring {
                _ = shortcutMonitor?.start()
            }
        } else {
            if wasMonitoring {
                shortcutMonitor?.stop()
            }
        }
    }

    /// Start monitoring the clipboard history global shortcut.
    public func startMonitoringHistoryShortcut() {
        let defaults = UserDefaults.standard
        let shortcutString = defaults.string(forKey: "historyCilpboardListShortcut") ?? ""
        updateGlobalShortcut(shortcutString)

        // Setup observer for changes to the shortcut string
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(shortcutChanged),
                                               name: UserDefaults.didChangeNotification,
                                               object: nil)
    }

    @objc private func shortcutChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let defaults = UserDefaults.standard
            let shortcutString = defaults.string(forKey: "historyCilpboardListShortcut") ?? ""
            self.updateGlobalShortcut(shortcutString)
        }
    }
}