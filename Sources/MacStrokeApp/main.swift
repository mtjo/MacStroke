//
//  main.swift
//  MacStroke
//
//  App entry point - starts the status bar app with global event capture.
//

import Foundation
import AppKit
import EventCapture
import GestureEngine
import RuleEngine
import Storage
import Preferences

@main
struct MacStrokeApp {
    static func main() {
        // Set up the application
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

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
    }

    @objc func togglePreferences() {
        let viewModel = UserPreferences()
        let windowController = PreferencesWindowController(viewModel: viewModel)
        windowController.showWindow(nil)
        preferencesWindow = windowController
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventCapture?.stop()
    }
}

extension AppDelegate: CanvasManagerDelegate {
    func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke) {
        // Match the stroke against rules
        if let (rule, score) = ruleEngine?.match(stroke: stroke) {
            print("[AppDelegate] Rule matched: \(rule.name) (score: \(score))")
            // In a full implementation, execute the rule action here
        }
    }
}