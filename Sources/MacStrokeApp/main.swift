//  main.swift
//  MacStroke
//
//  App entry point - starts the status bar app with global event capture.
//
//  Mirrors the original AppDelegate lifecycle:
//  - Single-instance check (second launch posts MacStrokeOpenPreferences and quits)
//  - First-launch initialization of default rules / right-click list
//  - Legacy blockFilter migration (BlackWhiteFilter.compatibleProcedure)
//  - openPrefOnStartup / applicationShouldHandleReopen open the preferences
//  - RightClickMenu (FinderSync extension communication) initialization
//  - Clipboard history monitoring + global shortcut to open the history list
//  - Event capture → CanvasManager → RuleEngine processing chain
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
import RightClickMenu
import WindowManager
import Sparkle

/// Notifications used between the preferences UI and the running capture chain.
public extension Notification.Name {
    /// Ask the AppDelegate to enter gesture-recording mode for the named rule
    /// (userInfo: ["ruleName": String]).
    static let macStrokeRecordGesture = Notification.Name("MacStrokeRecordGesture")
    /// Leave gesture-recording mode without storing anything.
    static let macStrokeCancelRecordGesture = Notification.Name("MacStrokeCancelRecordGesture")
}

struct MacStrokeApp {
    static func main() {
        // Set up the application
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Register default preference values before anything reads
        // UserDefaults (mirrors the original's registerDefaults: call with
        // DefaultPreferences.plist). Without this the clipboard monitor,
        // score gate, etc. read false/0 on a fresh install.
        registerUserDefaultsDefaults()

        // Apply the saved language preference before any localized UI is displayed.
        let storage = PreferencesStorage()
        if let savedLanguage = storage.getStringOptional(forKey: .language) {
            applyUserLanguage(savedLanguage)
        }

        // Only one instance may run at a time: if another instance is running,
        // ask it to open its preferences window and terminate this process.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "net.mtjo.MacStroke")
        if running.count > 1 {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("MacStrokeOpenPreferences"), object: nil, userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            app.run()
            return
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
    private var ruleStore: RuleStore?
    private var preferencesWindow: PreferencesWindowController?
    private var historyClipboardWindow: HistoryClipboardListWindowController?
    private var clipboardHistoryManager: HistoryClipboardManager?
    private var shortcutMonitor: ShortcutMonitor?
    private let storage = PreferencesStorage()
    private var updaterController: SPUStandardUpdaterController?

    func startCapture() {
        let capture = EventCapture()
        let canvas = CanvasManager()
        capture.delegate = canvas
        canvas.delegate = self

        // App-layer capture filter (original: BWFilter + showUIInWhateverApp +
        // appSuitedRule gate before the right-mouse-down is consumed).
        canvas.shouldCaptureGesture = { [weak self] bundleID in
            guard let self = self else { return false }
            guard BlackWhiteFilter.shared.shouldHookMouseEventForApp(bundleID) else { return false }
            if self.storage.getBoolOptional(forKey: .showUIInWhateverApp) ?? StorageDefaults.showUIInWhateverApp {
                return true
            }
            return self.ruleStore?.appSuitedRule(bundleID: bundleID) ?? false
        }

        // RightClicksList: apps that should receive a synthetic right click.
        canvas.needsRightClickMenu = { bundleID in
            RightClicksList.shared.needRightClick(byAppname: bundleID)
        }

        // Master enable switch.
        canvas.isEnabled = storage.getBoolOptional(forKey: .isEnabled) ?? StorageDefaults.isEnabled

        if capture.start() {
            eventCapture = capture
            canvasManager = canvas
            print("[AppDelegate] Event capture started")
        } else {
            print("[AppDelegate] Failed to start event capture - check accessibility permissions")
        }

        // Initialize rule store / engine
        ruleStore = RuleStore()
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

        initAppAtFirstLaunch()

        // Migrate legacy blockFilter rules into the black/white list.
        BlackWhiteFilter.shared.compatibleProcedureWithPreviousVersion()

        if storage.getBoolOptional(forKey: .openPrefOnStartup) ?? StorageDefaults.openPrefOnStartup {
            togglePreferences()
        }

        setupStatusBar()
        observeNotifications()

        // Init Finder right-click menu (distributed notifications + pluginkit).
        initRightClickMenu()

        // Init clipboard history monitoring + global shortcut.
        initHistoryClipboard()

        // Distributed notification from a second app instance.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(openPreferencesFromNotification),
            name: Notification.Name("MacStrokeOpenPreferences"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // Open the clipboard history list (from the preferences Clipboard tab
        // or the global shortcut).
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(openHistoryClipboardFromNotification),
            name: Notification.Name("MacStrokeOpenHistoryClipboard"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // Check for updates (About tab button).
        NotificationCenter.default.addObserver(
            self, selector: #selector(checkForUpdatesFromNotification),
            name: .macStrokeCheckForUpdates, object: nil)

        // About tab update-setting checkboxes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateSettingsDidChange(_:)),
            name: .macStrokeUpdateSettingsDidChange, object: nil)

        // Gesture-recording requests from the preferences UI.
        NotificationCenter.default.addObserver(
            self, selector: #selector(recordGesture(_:)),
            name: .macStrokeRecordGesture, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(cancelRecordGesture),
            name: .macStrokeCancelRecordGesture, object: nil)

        registerAppleScriptHandler()
    }

    /// AppleScript support (original: AppleScript.sdef + AppleScriptCommand):
    /// `tell application "MacStroke" to openPreferences` arrives as an
    /// 'stds'/'pref' Apple Event (sdef code stdspref).
    private func registerAppleScriptHandler() {
        let stds = Self.fourCharCode("stds")
        let pref = Self.fourCharCode("pref")
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenPreferencesEvent(_:reply:)),
            forEventClass: AEEventClass(stds),
            andEventID: AEEventID(pref)
        )
    }

    private static func fourCharCode(_ s: String) -> OSType {
        var out: OSType = 0
        for byte in s.utf8 { out = (out << 8) | OSType(byte) }
        return out
    }

    @objc private func handleOpenPreferencesEvent(
        _ event: NSAppleEventDescriptor,
        reply: NSAppleEventDescriptor
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.togglePreferences()
        }
    }

    /// Reopen (Dock icon click) shows the preferences window (original:
    /// applicationShouldHandleReopen).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePreferences()
        return false
    }

    // MARK: - First launch

    /// First launch initialization: seed the default rules and right-click
    /// list (the Swift version persists rules as rules.json, so an empty
    /// store is simply initialized with the defaults).
    private func initAppAtFirstLaunch() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "firstLaunch") {
            defaults.set(true, forKey: "firstLaunch")
            RightClicksList.shared.reInit()
            _ = RuleStore() // creates rules.json with the 15 default rules
            defaults.synchronize()
        }
    }

    // MARK: - Right-click menu / FinderSync

    private func initRightClickMenu() {
        RightClickMenuManager.shared.initFinderSyncExtension()
        RightClickMenuManager.shared.delayedEnableFinderExtension()
    }

    // MARK: - Clipboard history

    private func initHistoryClipboard() {
        let manager = HistoryClipboardManager()
        _ = manager.enableHistoryClipboard()
        clipboardHistoryManager = manager

        // Persist the default ^⇧V shortcut on first run so the preference
        // exists for every reader (original DefaultPreferences.plist value).
        if storage.getStringOptional(forKey: .historyCilpboardListShortcut) == nil {
            storage.setString(StorageDefaults.historyCilpboardListShortcut,
                              forKey: .historyCilpboardListShortcut)
        }

        // Global shortcut for the clipboard history list
        // (original: SRShortcutAction + SRGlobalShortcutMonitor, default ^⇧V).
        let shortcutString = storage.getStringOptional(forKey: .historyCilpboardListShortcut)
            ?? StorageDefaults.historyCilpboardListShortcut
        monitoredShortcutString = shortcutString
        startMonitoringHistoryShortcut(shortcutString)

        // Re-arm the shortcut whenever the preference changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification, object: nil)
    }

    private func startMonitoringHistoryShortcut(_ shortcutString: String) {
        guard let parsed = ShortcutMonitor.parseShortcut(shortcutString) else {
            shortcutMonitor?.stop()
            shortcutMonitor = nil
            return
        }
        if shortcutMonitor == nil {
            shortcutMonitor = ShortcutMonitor()
        }
        shortcutMonitor?.keyCode = parsed.0
        shortcutMonitor?.flags = parsed.1
        shortcutMonitor?.onShortcutDetected = { [weak self] in
            self?.showHistoryClipboard(nil)
        }
        _ = shortcutMonitor?.start()
    }

    @objc private func userDefaultsDidChange(_ notification: Notification) {
        let shortcutString = storage.getStringOptional(forKey: .historyCilpboardListShortcut)
            ?? StorageDefaults.historyCilpboardListShortcut
        // Only react to shortcut changes (cheap string compare).
        if shortcutMonitor?.isMonitoring == false || shortcutString != monitoredShortcutString {
            monitoredShortcutString = shortcutString
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let parsed = ShortcutMonitor.parseShortcut(shortcutString) {
                    self.shortcutMonitor?.keyCode = parsed.0
                    self.shortcutMonitor?.flags = parsed.1
                    self.shortcutMonitor?.onShortcutDetected = { [weak self] in
                        self?.showHistoryClipboard(nil)
                    }
                    _ = self.shortcutMonitor?.start()
                } else {
                    self.shortcutMonitor?.stop()
                }
            }
        }
    }
    private var monitoredShortcutString = ""

    /// Show the clipboard history list window (original: showHistoryCilpboardList:).
    @objc func showHistoryClipboard(_ sender: Any?) {
        guard (storage.getBoolOptional(forKey: .enableHistoryClipboard) ?? true) else { return }
        if historyClipboardWindow == nil {
            historyClipboardWindow = HistoryClipboardListWindowController()
        }
        historyClipboardWindow?.showWindow(nil)
    }

    // MARK: - Gesture recording (Draw Gesture flow)

    @objc private func recordGesture(_ notification: Notification) {
        guard let ruleName = notification.userInfo?["ruleName"] as? String else { return }
        pendingRecordRuleName = ruleName
        canvasManager?.isRecordingGesture = true
        canvasManager?.onGestureRecorded = { [weak self] points in
            guard let self = self, let name = self.pendingRecordRuleName else { return }
            var stroke = Stroke(capacity: points.count)
            for p in points { stroke.addPoint(p) }
            let template = GestureTemplate(from: stroke, name: "Recorded")
            if let store = self.ruleStore, let old = store.rule(named: name) {
                let newRule = Rule(
                    name: old.name,
                    description: old.description,
                    template: template,
                    minSimilarityScore: old.minSimilarityScore,
                    action: old.action,
                    note: old.note,
                    isEnabled: old.isEnabled,
                    triggerOnEveryMatch: old.triggerOnEveryMatch,
                    filter: old.filter,
                    filterType: old.filterType
                )
                store.update(newRule)
                // Notify the UI to refresh.
                NotificationCenter.default.post(name: .macStrokeRuleStoreDidChange, object: nil)
            }
            self.pendingRecordRuleName = nil
            self.canvasManager?.onGestureRecorded = nil
        }
    }

    @objc private func cancelRecordGesture() {
        pendingRecordRuleName = nil
        canvasManager?.isRecordingGesture = false
        canvasManager?.onGestureRecorded = nil
    }
    private var pendingRecordRuleName: String?

    // MARK: - Notifications

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

    @objc private func openPreferencesFromNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.togglePreferences()
        }
    }

    @objc private func openHistoryClipboardFromNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.showHistoryClipboard(nil)
        }
    }

    @objc private func checkForUpdatesFromNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.checkForUpdates(nil)
        }
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
        // Use SPUStandardUpdaterController for automatic update checking and UI.
        // Feed URL & DSA key come from Info.plist (SUFeedURL / SUPublicDSAKeyFile),
        // same appcast as the original MacStroke release.
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = storage.getBoolOptional(forKey: .autoCheckUpdates) ?? StorageDefaults.autoCheckUpdates
        controller.updater.automaticallyDownloadsUpdates = UserDefaults.standard.bool(forKey: "SUAutomaticallyUpdate")
        self.updaterController = controller
        print("[AppDelegate] Sparkle updater initialized")
    }

    /// About tab checkboxes → apply to the live Sparkle updater.
    @objc func updateSettingsDidChange(_ notification: Notification) {
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyChecksForUpdates = storage.getBoolOptional(forKey: .autoCheckUpdates) ?? StorageDefaults.autoCheckUpdates
        updater.automaticallyDownloadsUpdates = UserDefaults.standard.bool(forKey: "SUAutomaticallyUpdate")
    }

    /// Trigger a Sparkle update check (About tab "Check for Updates" button).
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
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
        menu.addItem(withTitle: L("Show History Clipboard"), action: #selector(showHistoryClipboard), keyEquivalent: "")
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
        // Update both the status icon and the actual capture behavior
        // (original: static isEnabled gates the event callback).
        canvasManager?.isEnabled = enabled
        guard let statusItem = statusItem else { return }
        guard let image = menuIcon(enabled: enabled) else { return }
        statusItem.button?.image = image
    }
}

extension AppDelegate: CanvasManagerDelegate {
    @discardableResult
    func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String) -> Bool {
        guard let ruleStore = ruleStore else { return false }

        // Match the stroke against all rules, keeping the best-scoring one
        // (mirrors the original setActionIndex, including the global
        // enableGestureMinScore / minScore gate handled inside the engine).
        guard let (rule, score) = ruleStore.match(stroke: stroke, bundleID: bundleID) else {
            return false
        }
        print("[AppDelegate] Rule matched: \(rule.name) (score: \(score))")

        // Execute the action
        let executor = ActionExecutor()
        executor.execute(rule.action, for: rule)

        // Show the note toast if enabled (original: showGestureNote key).
        let showGestureNote = storage.getBoolOptional(forKey: .showGestureNote) ?? StorageDefaults.showGestureNote
        if showGestureNote && !rule.note.isEmpty {
            let preferences = UserPreferences()
            let positionIndex = preferences.notePosition
            let pos = ToastPosition(rawValue: positionIndex) ?? ToastPosition.center
            let toast = Toast(
                message: rule.note,
                duration: TimeInterval(preferences.noteRetentionTime),
                position: pos
            )
            ToastManager.shared.show(toast)
        }

        return true
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
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }
}

MacStrokeApp.main()
