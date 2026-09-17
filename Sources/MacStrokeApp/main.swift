//
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

@main
struct MacStrokeApp {
    static func main() {
        // Set up the application
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Check accessibility permissions before starting
        AccessibilityHelper.checkAndRequestAccess()

        // Create status bar item
        let statusBar = NSStatusBar.system
        let statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.title = "🖐"
            button.action = #selector(AppDelegate.togglePreferences)
            button.target = AppDelegate.shared
        }

        // Create app delegate
        let delegate = AppDelegate()
        app.delegate = delegate

        // Start event capture
        delegate.startCapture()

        // Run the application
        app.run()
    }
}

/// Application delegate managing global event capture and preferences.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

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

    @objc func togglePreferences() {
        let viewModel = UserPreferences()
        let windowController = PreferencesWindowController(viewModel: viewModel)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow = windowController
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventCapture?.stop()
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
                    let toast = Toast(message: rule.note, duration: 2.0)
                    ToastManager.shared.show(toast)
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
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = """
        MacStroke 需要辅助功能权限来捕获全局鼠标事件并识别手势。

        请点击"打开系统设置"，在"隐私与安全性" → "辅助功能"中勾选 MacStroke。

        授权后请重新启动应用。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

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
