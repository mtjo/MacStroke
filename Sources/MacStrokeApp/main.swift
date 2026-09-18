//  main.swift
//  MacStroke
//
//  App entry point - starts the status bar app with global event capture.
//

import Foundation
import AppKit
import Cocoa
import CoreFoundation
import EventCapture
import GestureEngine
import RuleEngine
import Storage
import Preferences
import WindowManager
import Sparkle

struct MacStrokeApp {
    static func main() {
        // Set up the application
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Apply the saved language preference before any localized UI is displayed.
        let storage = PreferencesStorage()
        if let savedLanguage = storage.getStringOptional(forKey: .language) {
            applyUserLanguage(savedLanguage)
        }

        // Check accessibility permissions before starting
        AccessibilityHelper.checkAndRequestAccess()

        // Use the shared AppDelegate instance for consistent state
        let delegate = AppDelegate.shared
        app.delegate = delegate

        // Start event capture
        delegate.startCapture()

        // Run the application (applicationDidFinishLaunching is called automatically)
        app.run()
    }
}

/// Application delegate managing global event capture and preferences.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let shared = AppDelegate()

    private var statusItem: NSStatusItem?
    private var eventCapture: EventCapture?
    private var canvasManager: CanvasManager?
    private var ruleEngine: RuleEngine?
    private var preferencesWindow: PreferencesWindowController?
    private let storage = PreferencesStorage()
    private var updaterController: SPUStandardUpdaterController?

    func startCapture() {
        let capture = EventCapture()
        let canvas = CanvasManager()
        capture.delegate = canvas
        canvas.delegate = self

        if capture.start() {
            eventCapture = capture
            canvasManager = canvas
            print("[AppDelegate] Event capture started")
        } else {
            print("[AppDelegate] Failed to start event capture - check accessibility permissions")
        }

        // Initialize rule engine
        ruleEngine = RuleEngine()

        // Initialize Sparkle updater
        initSparkleUpdater()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sync the stored language preference with the process locale
        // so the UI uses the correct language immediately on launch.
        if let savedLanguage = storage.getStringOptional(forKey: .language) {
            applyUserLanguage(savedLanguage)
        }

        setupStatusBar()
        observeNotifications()
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(macStrokeEnabledDidChange(_:)),
            name: .macStrokeEnabledDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showIconInStatusBarDidChange(_:)),
            name: .showIconInStatusBarDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange(_:)),
            name: .languageDidChange,
            object: nil
        )
    }

    @objc private func languageDidChange(_ notification: Notification) {
        // Update status menu titles when the language changes
        if statusItem != nil {
            statusItem?.menu = statusMenu()
        }
        // Update the preferences window title if it's open
        if let window = preferencesWindow?.window {
            window.title = L("MacStroke Preferences")
        }
    }

    @objc func macStrokeEnabledDidChange(_ notification: Notification) {
        guard let enabled = notification.object as? Bool else { return }
        setEnabled(enabled)
    }

    @objc func showIconInStatusBarDidChange(_ notification: Notification) {
        guard let showIcon = notification.object as? Bool else { return }
        if showIcon {
            setupStatusBar()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func initSparkleUpdater() {
        // Use SPUStandardUpdaterController for automatic update checking and UI
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // Placeholder feed URL - replace with your actual appcast URL
        if let feedURL = URL(string: "https://example.com/updates/feed.xml") {
            controller.updater.setFeedURL(feedURL)
        }
        controller.updater.automaticallyChecksForUpdates = true
        // Optionally check for updates on launch (in background)
        controller.updater.checkForUpdates()
        self.updaterController = controller
        print("[AppDelegate] Sparkle updater initialized")
    }

    /// Create the status bar item on app launch if "Show icon in status bar" is enabled.
    private func setupStatusBar() {
        let showIcon = storage.getBoolOptional(forKey: .showIconInStatusBar) ?? StorageDefaults.showIconInStatusBar
        guard showIcon else { return }

        // Remove any existing status item before creating a new one
        if statusItem != nil {
            NSStatusBar.system.removeStatusItem(statusItem!)
            statusItem = nil
        }

        let statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = menuIcon(enabled: true)
        }
        statusItem?.menu = statusMenu()
        statusItem?.highlightMode = true
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu(title: "MacStroke")
        menu.addItem(withTitle: L("Preferences"), action: #selector(togglePreferences), keyEquivalent: "")
        menu.addItem(withTitle: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    private func menuIcon(enabled: Bool) -> NSImage? {
        let resourceName = enabled ? "menu_icon_16x16" : "menu_icon_disabled_16x16"
        let url = appResourceBundle().url(forResource: resourceName, withExtension: "png")
        guard let url else { return nil }
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    @objc func togglePreferences() {
        // If we already have a preferences window that is visible, just bring it to front
        if let existing = preferencesWindow,
           existing.window?.isVisible == true {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let viewModel = UserPreferences()
        let controller = PreferencesWindowController(viewModel: viewModel)
        // Set the window delegate so we can clear the reference on close
        controller.window?.delegate = self
        preferencesWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setEnabled(_ enabled: Bool) {
        guard let statusItem = statusItem else { return }
        guard let image = menuIcon(enabled: enabled) else { return }
        statusItem.button?.image = image
    }
}

extension AppDelegate: CanvasManagerDelegate {
    func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String) {
        // Match the stroke against rules
        if let (rule, score) = ruleEngine?.match(stroke: stroke, bundleID: bundleID) {
            print("[AppDelegate] Rule matched: \(rule.name) (score: \(score))")

            // Execute the action
            if ruleEngine?.executeAction(for: stroke) != nil {
                // Show toast with rule note
                if !rule.note.isEmpty {
                    let preferences = UserPreferences()
                    let positionIndex = preferences.notePosition
                    let pos = ToastPosition(rawValue: positionIndex) ?? ToastPosition.bottom
                    let toast = Toast(
                        message: rule.note,
                        duration: TimeInterval(preferences.noteRetentionTime),
                        position: pos
                    )
                    if preferences.showToast {
                        ToastManager.shared.show(toast)
                    }
                }
            }
        }
    }
}

/// Helper for accessibility permission checking and user guidance.
final class AccessibilityHelper {
    static func checkAndRequestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            // Show a modal alert to guide user to System Settings
            DispatchQueue.main.async {
                showAccessibilityAlert()
            }
        }
    }

    static func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = L("Needs Accessibility Permission")
        alert.informativeText = """
        \(L("MacStroke needs accessibility permission to capture global mouse events and recognize gestures."))

        \(L("Open System Settings"))

        \(L("Please restart the application after granting permission."))
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Later"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    static func openAccessibilitySettings() {
        if #available(macOS 13.0, *) {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        } else {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }
}

MacStrokeApp.main()