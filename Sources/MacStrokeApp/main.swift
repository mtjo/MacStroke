//  main.swift
//  MacStroke
//
//  App entry point - starts the status bar app with global event capture.
//
//  Mirrors the original AppDelegate lifecycle:
//  - Single-instance check (second launch posts MacStrokeOpenPreferences and quits)
//  - First-launch initialization of default rules / right-click list
//  - Legacy blockFilter migration (BlackWhiteFilter.compatibleProcedure)
//  - Legacy rules migration (RuleStore.importLegacyRulesIfNeeded, issue #67)
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
import RemoteControl
import Screenshot
import SelectionPopup
import ProximityLock
import Sparkle

/// Notifications used between the preferences UI and the running capture chain.
public extension Notification.Name {
    /// Ask the AppDelegate to enter gesture-recording mode for the named rule
    /// (userInfo: ["ruleName": String]).
    static let macStrokeRecordGesture = Notification.Name("MacStrokeRecordGesture")
    /// Leave gesture-recording mode without storing anything.
    static let macStrokeCancelRecordGesture = Notification.Name("MacStrokeCancelRecordGesture")
    /// A screen-drawn stroke finished; userInfo carries ["ruleName": String,
    /// "points": [GesturePoint]] so an open rule editor can capture it too.
    static let macStrokeGestureDidRecord = Notification.Name("MacStrokeGestureDidRecord")
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
    /// 「右键 + 滚轮」触发后的那一下（切标签页 / 音量 / 自定义快捷键，issue #75）。
    /// 与规则动作用同一套投键出口（`ActionExecutor` 的 `.shortcut`），音量走 CoreAudio。
    private let wheelGestureExecutor = WheelGestureExecutor()
    private var ruleStore: RuleStore?
    private var preferencesWindow: PreferencesWindowController?
    private var historyClipboardWindow: HistoryClipboardListWindowController?
    private var clipboardHistoryManager: HistoryClipboardManager?
    private var shortcutMonitor: ShortcutMonitor?
    /// 截图的全局快捷键。单独一只 monitor：粘贴板那只的命中事件要透传给前台 App，
    /// 截图这条要吞掉（否则 ⌘⇧A 会同时触发前台 App 自己的绑定）。
    private var screenshotShortcutMonitor: ShortcutMonitor?
    /// 「提取文字」专用快捷键（issue #74）的监听。和上面那条各占一只 monitor：
    /// 两个组合默认只差一个修饰键（⌘⇧A / ⌥⇧A），共用一只就没法各挂各的动作。
    private var screenshotTextShortcutMonitor: ShortcutMonitor?
    private var monitoredScreenshotShortcut = ""
    private var monitoredScreenshotTextShortcut = ""
    /// 划词气泡的手动唤出快捷键（移植版新增，超出原版）。单独一只 monitor：和截图那两条
    /// 同一种挂法（命中即吞），所以总开关关掉时把它整个停掉 —— 按下去什么都不做、
    /// 还把这组键从前台 App 手里吞掉，是最难查的那种坏。
    private var selectionBubbleShortcutMonitor: ShortcutMonitor?
    /// 上一次递给划词气泡的偏好快照（总开关 + 两条触发 + 四格 + 延迟）。`UserDefaults` 的变化通知很密，
    /// 先比一遍再决定要不要重喂，免得用户改个无关偏好都把左键监听拆一次、挂一次。
    /// 整个结构体拿来比（它本来就 Equatable），不拼串：延迟和快捷键拼出一个同号不代表没变。
    private var selectionBubbleSnapshot: SelectionBubbleSettings?
    private let storage = PreferencesStorage()
    private var updaterController: SPUStandardUpdaterController?
    /// 发现新版提醒用的系统通知标记：点了只认这条，其它提示（脚本出错、偏好页确认
    /// 条）维持原来的「把 App 带到前台」行为。
    private static let updateNotificationMarker = "MacStrokeUpdateReminder"
    /// 自动检查发现、但还没被用户看到的更新：菜单栏图标加点并挂一条系统通知，
    /// 用户点了才把 Sparkle 的更新窗前置（见 extension AppDelegate: SPUStandardUserDriverDelegate）。
    private var pendingUpdate: SUAppcastItem?

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

        // Which button starts a gesture (issue #53). Read from UserDefaults per
        // event so re-recording it takes effect immediately, with no restart and
        // no event-tap rebuild. The default is the right button, the original's
        // only trigger; CanvasManager never lets the left button start one.
        canvas.isTriggerButtonAllowed = { [weak self] button in
            guard let self = self else { return false }
            let configured = self.storage.getIntOptional(forKey: .gestureTriggerButton)
                ?? StorageDefaults.gestureTriggerButton
            return button.cgNumber == configured
        }

        // Which modifiers must not start a gesture (issue #59). Same per-event
        // read, so the switch and the recorded modifiers apply to the very next
        // click. Off, or nothing recorded, means modifiers never interfere.
        canvas.suppressedModifiers = { [weak self] in
            guard let self = self,
                  self.storage.getBoolOptional(forKey: .enableGestureSuppression)
                    ?? StorageDefaults.enableGestureSuppression else { return [] }
            return Set(tokenList: self.storage.getStringOptional(forKey: .gestureSuppressedModifiers)
                ?? StorageDefaults.gestureSuppressedModifiers)
        }

        // 画完没匹配上时不再把这次右键交回应用（issue #73）。还是每事件现读，勾上立刻
        // 生效。关 = 原版行为；开之后也只吞「真的画了一条」的那种，纯右键单击照旧弹菜单。
        canvas.shouldSwallowUnmatchedGesture = { [weak self] in
            guard let self = self else { return false }
            return self.storage.getBoolOptional(forKey: .swallowUnmatchedGesture)
                ?? StorageDefaults.swallowUnmatchedGesture
        }

        // 按住起始键 + 滚轮上/下 = 两条独立触发（issue #75）。
        //
        // 三件套各读各的偏好，都是「下一次事件就生效」的口径：
        // - 总开关决定要不要给这段窗口上膛第二条 tap（关 = 压根不建、不发一次 tapEnable）；
        // - 方向 → 动作的查表在 RuleEngine 的 `WheelGesturePlan`，这里只做「读偏好 + 递进去」；
        // - 键值串只认 `ShortcutMonitor.parseShortcut` 那一份口径，解析完再递给纯函数
        //   （再抄一条正则就是第三处会漂移的解析，划词气泡那边已经吃过一次）。
        canvas.isWheelGestureEnabled = { [weak self] in
            guard let self = self else { return false }
            return self.storage.getBoolOptional(forKey: .wheelGestureEnabled)
                ?? StorageDefaults.wheelGestureEnabled
        }
        canvas.wheelCaptureArmer = { [weak self] armed in
            self?.eventCapture?.setWheelCaptureArmed(armed)
        }
        canvas.onWheelGesture = { [weak self] direction in
            guard let self = self else { return false }
            let up = direction == .up
            let kind = WheelGestureActionKind(preferenceValue: self.storage.getIntOptional(
                forKey: up ? .wheelGestureUpAction : .wheelGestureDownAction
            ) ?? (up ? StorageDefaults.wheelGestureUpAction : StorageDefaults.wheelGestureDownAction))
            let rawShortcut = self.storage.getStringOptional(
                forKey: up ? .wheelGestureUpShortcut : .wheelGestureDownShortcut
            ) ?? (up ? StorageDefaults.wheelGestureUpShortcut : StorageDefaults.wheelGestureDownShortcut)
            let custom = rawShortcut.isEmpty ? nil : ShortcutMonitor.parseShortcut(rawShortcut)
            return self.wheelGestureExecutor.fire(kind: kind, customShortcut: custom)
        }
        capture.wheelDelegate = canvas

        // Initialize rule store / engine. The pre-3.0 build archived its rules
        // in UserDefaults while this one keeps rules.json, so an upgraded
        // preferences domain has to be read across before anything else touches
        // the rules (issue #67). `RuleStore.shared` seeds the presets when
        // rules.json is missing, so the import recognises an untouched preset
        // list and replaces it rather than treating it as the user's own work.
        ruleStore = RuleStore.shared
        ruleStore?.importLegacyRulesIfNeeded()
        ruleEngine = RuleEngine()

        if capture.start() {
            eventCapture = capture
            canvasManager = canvas
            NSLog("%@", "[AppDelegate] Event capture started")
        } else {
            NSLog("%@", "[AppDelegate] Failed to start event capture - check accessibility permissions")
        }

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
        // 发现新版的提醒靠这条系统通知，点了才知道（见 NSUserNotificationCenterDelegate）。
        NSUserNotificationCenter.default.delegate = self

        // Init Finder right-click menu (distributed notifications + pluginkit).
        initRightClickMenu()

        // Init clipboard history monitoring + global shortcut.
        initHistoryClipboard()

        // 截图的全局快捷键 + 默认手势规则（移植版新增，超出原版）。
        initScreenshotTriggers()

        // LAN remote control (偏好页「远程控制」)。默认关着，关掉时一个端口都不监听，
        // 行为和原版一致。
        RemoteControlServer.shared.apply()

        NotificationCenter.default.addObserver(
            self, selector: #selector(remoteControlSettingsDidChange),
            name: .macStrokeRemoteControlDidChange, object: nil)

        // 蓝牙靠近锁屏（偏好页「靠近锁屏」）。默认关着，而且没选设备就等于没开 ——
        // 关着的时候一个 CBCentralManager 都不构造，所以系统蓝牙授权框不会在启动时弹。
        ProximityLockController.shared.apply()
        // 「这台机器正被人用着」的判定挂在 App 层：判定状态机不该知道谁在忙。
        // 远程控制接管（手机在点这台 Mac）和截图遮罩摊开（人正在框选）时不锁屏，
        // 否则手表搁在桌上信号一晃就把这场操作打断。
        ProximityLockController.shared.isExternallyBusy = {
            !RemoteControlServer.shared.peers.isEmpty || ScreenshotController.shared.isActive
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(proximityLockSettingsDidChange),
            name: .macStrokeProximityLockDidChange, object: nil)

        // 划词气泡（偏好页「划词气泡」，移植版新增）。默认关着 —— 关掉时连左键的只读监听
        // 都不挂，行为和原版一致。哪些应用不弹复用「过滤」页那套黑白名单：判定从这儿注进去，
        // SelectionPopup 因此不依赖 RuleEngine，也不用再配一份名单。
        SelectionBubbleController.shared.isAppAllowed = { bundleID in
            // 截图遮罩摊开时不弹：那会儿左键是在框选区，不是在划字，气泡浮上去正好挡住选区。
            !ScreenshotController.shared.isActive
                && BlackWhiteFilter.shared.shouldHookMouseEventForApp(bundleID)
        }
        applySelectionBubblePreferences()

        // 截图。模块自己不开窗也不弹提示，两件事都回调到 App 层做：
        // 遮罩摊开期间必须挂起手势捕获（否则轨迹层跟选区抢同一只鼠标），
        // 复制完用用户已经调好的提示气泡参数回一句，不然遮罩一收用户分不清
        // 是复制了还是取消了。
        ScreenshotController.shared.onActiveStateChanged = { [weak self] active in
            self?.canvasManager?.isSuspended = active
            if active {
                self?.canvasManager?.cancelStroke()
                // 遮罩摊开前先把可能正浮着的气泡收掉：它浮在遮罩上面挡选区，而遮罩自己
                // 收不掉它（气泡那扇窗不吃键盘，只能点别处）。
                SelectionBubbleController.shared.dismiss()
            }
        }
        ScreenshotController.shared.onOutcome = { outcome in
            switch outcome {
            case .copied(let width, let height):
                Self.showScreenshotFeedback("\(L("Screenshot copied")) \(width)×\(height)")
            case .saved(let file):
                Self.showScreenshotFeedback("\(L("Screenshot saved")) \(file)")
            case .copiedAndSaved(let width, let height, let file):
                Self.showScreenshotFeedback("\(L("Screenshot copied")) \(width)×\(height)\n"
                                            + "\(L("Screenshot saved")) \(file)")
            case .saveFailed(let reason):
                Self.showScreenshotFeedback("\(L("Screenshot save failed")) \(reason)")
            case .textCopied(let lines):
                Self.showScreenshotFeedback("\(L("Screenshot text copied")) \(lines) \(L("Screenshot lines"))")
            case .textNotFound:
                Self.showScreenshotFeedback(L("Screenshot text not found"))
            case .textFailed(let reason):
                Self.showScreenshotFeedback("\(L("Screenshot text failed")) \(reason)")
            case .videoSaved(let file, let seconds):
                Self.showScreenshotFeedback("\(L("Screenshot video saved")) "
                                            + "\(ScreenshotController.duration(seconds)) · \(file)")
            case .captureFailed(let reason):
                Self.showScreenshotFeedback("\(L("Screenshot capture failed")) \(reason)")
            }
        }

        // Distributed notification from a second app instance.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(openPreferencesFromNotification),
            name: Notification.Name("MacStrokeOpenPreferences"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // Open the clipboard history list (preferences Clipboard tab).
        // In-process like the other preference commands: a distributed
        // notification would also reach a second MacStroke on this machine.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openHistoryClipboardFromNotification),
            name: .macStrokeShowHistoryClipboard,
            object: nil
        )

        // Check for updates (About tab button).
        NotificationCenter.default.addObserver(
            self, selector: #selector(checkForUpdatesFromNotification),
            name: .macStrokeCheckForUpdates, object: nil)

        // About tab update-setting checkboxes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateSettingsDidChange(_:)),
            name: .macStrokeUpdateSettingsDidChange, object: nil)

        // About tab "restore skipped versions".
        NotificationCenter.default.addObserver(
            self, selector: #selector(restoreSkippedUpdate(_:)),
            name: .macStrokeRestoreSkippedUpdate, object: nil)

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
            _ = RuleStore.shared // creates rules.json with the 15 default rules
            defaults.synchronize()
        }
    }

    // MARK: - Right-click menu / FinderSync

    private func initRightClickMenu() {
        RightClickMenuManager.shared.reinitFinderSyncExtension()
    }

    // MARK: - Clipboard history

    private func initHistoryClipboard() {
        restartHistoryClipboard()

        // Persist the default ⌘⌥V shortcut on first run so the preference
        // exists for every reader (original DefaultPreferences.plist value).
        if storage.getStringOptional(forKey: .historyCilpboardListShortcut) == nil {
            storage.setString(StorageDefaults.historyCilpboardListShortcut,
                              forKey: .historyCilpboardListShortcut)
        }

        // Global shortcut for the clipboard history list
        // (original: SRShortcutAction + SRGlobalShortcutMonitor, default ⌘⌥V).
        let shortcutString = storage.getStringOptional(forKey: .historyCilpboardListShortcut)
            ?? StorageDefaults.historyCilpboardListShortcut
        monitoredShortcutString = shortcutString
        startMonitoringHistoryShortcut(shortcutString)

        // Re-arm the shortcut whenever the preference changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification, object: nil)
    }

    /// Rebuild the clipboard manager and its pasteboard watcher (original:
    /// `onToggleClipboard` / `onChangeStroageLocalction` call
    /// `initHistoryClipboard` again), so enabling the feature or switching the
    /// storage backend takes effect without restarting the app.
    private func restartHistoryClipboard() {
        clipboardHistoryManager?.stopHistoryClipboard()
        let manager = HistoryClipboardManager()
        _ = manager.enableHistoryClipboard()
        clipboardHistoryManager = manager
        clipboardConfigSnapshot = historyClipboardConfigKey()
    }

    private func historyClipboardConfigKey() -> String {
        let enabled = storage.getBoolOptional(forKey: .enableHistoryClipboard)
            ?? StorageDefaults.enableHistoryClipboard
        let local = storage.getBoolOptional(forKey: .clipoardStroageLocal)
            ?? StorageDefaults.clipoardStroageLocal
        return "\(enabled),\(local)"
    }

    private var clipboardConfigSnapshot = ""

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

    /// 远程控制开关/端口/配对码变了：重启监听或关掉服务。
    @objc private func remoteControlSettingsDidChange(_ notification: Notification) {
        RemoteControlServer.shared.apply()
    }

    /// 靠近锁屏的开关/设备/阈值变了：重新武装或停下来。设置没变时 apply 不重启扫描，
    /// 所以「人在不在旁边」的判定不会被打回未知（用户改个无关项不用重新等一轮）。
    @objc private func proximityLockSettingsDidChange(_ notification: Notification) {
        ProximityLockController.shared.apply()
    }

    @objc private func userDefaultsDidChange(_ notification: Notification) {
        // Clipboard storage switches need a fresh manager (original does the
        // same by calling initHistoryClipboard from the toggle handlers).
        if historyClipboardConfigKey() != clipboardConfigSnapshot {
            DispatchQueue.main.async { [weak self] in
                self?.restartHistoryClipboard()
            }
        }

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

        // 截图的快捷键同理：录完下一个键就是新键，不用重启。两条一起比，
        // 谁变了都只重挂那一只（rebind 内部按串判等）。
        let screenshotShortcut = storedShortcut(forKey: .screenshotShortcut,
                                                fallback: StorageDefaults.screenshotShortcut)
        let screenshotTextShortcut = storedShortcut(forKey: .screenshotTextShortcut,
                                                   fallback: StorageDefaults.screenshotTextShortcut)
        if screenshotShortcut != monitoredScreenshotShortcut
            || screenshotTextShortcut != monitoredScreenshotTextShortcut {
            monitoredScreenshotShortcut = screenshotShortcut
            monitoredScreenshotTextShortcut = screenshotTextShortcut
            DispatchQueue.main.async { [weak self] in
                self?.applyScreenshotShortcuts()
            }
        }

        // 划词气泡的偏好合成一份快照比一次（开关、两条触发、四格、延迟）：比的是整个结构体，
        // 新增字段自动进比较，不用每加一栏就回来补一句。开关与触发变了要拆/挂监听，
        // 手动键变了要重挂 monitor，其余只需重喂快照 —— 都走同一个入口。
        if SelectionBubbleSettings.current() != selectionBubbleSnapshot {
            DispatchQueue.main.async { [weak self] in
                self?.applySelectionBubblePreferences()
            }
        }
    }
    private var monitoredShortcutString = ""

    /// Show the clipboard history list window (original: showHistoryCilpboardList:).
    /// The original closes any previous window and loads a fresh controller on
    /// every call, so the list always reflects the current storage backend.
    @objc func showHistoryClipboard(_ sender: Any?) {
        guard (storage.getBoolOptional(forKey: .enableHistoryClipboard) ?? true) else { return }
        historyClipboardWindow?.window?.close()
        let controller = HistoryClipboardListWindowController(manager: clipboardHistoryManager)
        historyClipboardWindow = controller
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.level = NSWindow.Level(rawValue: 21)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Screenshot

    /// 截图的三个外部入口：全局快捷键（默认 ⌘⇧A）、提取文字专用快捷键（默认 ⌥⇧A，
    /// issue #74）与手势规则（默认画 S）。两条快捷键各挂一只 monitor；手势那条规则是老
    /// 用户升级后才缺的，这里补一次。
    private func initScreenshotTriggers() {
        monitoredScreenshotShortcut = storedShortcut(forKey: .screenshotShortcut,
                                                     fallback: StorageDefaults.screenshotShortcut)
        monitoredScreenshotTextShortcut = storedShortcut(forKey: .screenshotTextShortcut,
                                                         fallback: StorageDefaults.screenshotTextShortcut)
        applyScreenshotShortcuts()
        if ruleStore?.installScreenshotRuleIfNeeded() == true {
            NotificationCenter.default.post(name: .macStrokeRuleStoreDidChange, object: nil)
        }
    }

    private func storedShortcut(forKey key: StorageKey, fallback: String) -> String {
        storage.getStringOptional(forKey: key) ?? fallback
    }

    /// 偏好页录完下一个键就是新键，不用重启 App：两条快捷键一起过一遍。
    private func applyScreenshotShortcuts() {
        screenshotShortcutMonitor = Self.rebind(screenshotShortcutMonitor,
                                                storedShortcut(forKey: .screenshotShortcut,
                                                               fallback: StorageDefaults.screenshotShortcut)) {
            ScreenshotController.shared.toggle()
        }
        screenshotTextShortcutMonitor = Self.rebind(screenshotTextShortcutMonitor,
                                                    storedShortcut(forKey: .screenshotTextShortcut,
                                                                   fallback: StorageDefaults.screenshotTextShortcut)) {
            ScreenshotController.shared.toggleText()
        }
    }

    /// 解析不出来的串（包括偏好页上点了叉、写成空串）走「停掉监听」那支：
    /// `"keyCode=0, flags=0"` 是「裸按 A」，绝不能当成一个真键去挂全局吞键的监听。
    private static func rebind(_ monitor: ShortcutMonitor?, _ shortcutString: String,
                               action: @escaping () -> Void) -> ShortcutMonitor? {
        guard let parsed = ShortcutMonitor.parseShortcut(shortcutString) else {
            monitor?.stop()
            return nil
        }
        guard let monitor else {
            let fresh = ShortcutMonitor()
            // 命中即吞：截图键不该再被前台 App 当成自己的快捷键执行一遍。
            fresh.consumesMatchedEvent = true
            fresh.onShortcutDetected = action
            fresh.keyCode = parsed.0
            fresh.flags = parsed.1
            _ = fresh.start()
            return fresh
        }
        monitor.keyCode = parsed.0
        monitor.flags = parsed.1
        _ = monitor.start()
        return monitor
    }

    /// 弹出截图选区遮罩（状态栏菜单「截图/录屏」、快捷键和手势都走这里）。
    /// 遮罩已经摊开时再触发一次等于取消。
    @objc func toggleScreenshot(_ sender: Any?) {
        ScreenshotController.shared.toggle()
    }

    /// 截图出图后的反馈：遮罩一收屏幕就恢复原样，不响一声用户分不清是复制了、
    /// 存盘了还是取消了。气泡参数沿用用户自己调好的提示设置。
    static func showScreenshotFeedback(_ message: String) {
        let preferences = UserPreferences()
        let pos = ToastPosition(rawValue: preferences.notePosition) ?? .center
        ToastManager.shared.show(Toast(message: message,
                                       duration: TimeInterval(preferences.noteRetentionTime),
                                       position: pos))
    }

    // MARK: - Selection bubble（划词气泡）

    /// 划词气泡的外部入口都在这里落地：整份快照喂给控制器（左键监听挂不挂、四格有哪些、
    /// 延迟多少，都由模块自己从快照里判），手动唤出那只快捷键单独一只 monitor。
    /// App 层只认「快照换没换」，不逐键判断 —— 页面上多一栏就得回来加一条比较。
    ///
    /// 快捷键那只 monitor 跟着总开关走，判定在 `SelectionBubbleSettings.monitorShortcut` 里
    /// （关着时它给空串 → rebind 停掉监听）：功能关着却把 ⌃⌘B 从前台 App 手里吞掉、按下还
    /// 什么都不做，是最难查的那种坏。
    private func applySelectionBubblePreferences() {
        let current = SelectionBubbleSettings.current()
        selectionBubbleSnapshot = current
        // apply() 内部自己再读一遍偏好（模块不认 App 层那个 storage 实例），值与上面一致。
        SelectionBubbleController.shared.apply()
        selectionBubbleShortcutMonitor = Self.rebind(
            selectionBubbleShortcutMonitor, current.monitorShortcut
        ) {
            SelectionBubbleController.shared.showForCurrentSelection()
        }
    }

    // MARK: - Gesture recording (Draw Gesture flow)

    @objc private func recordGesture(_ notification: Notification) {
        guard let ruleName = notification.userInfo?["ruleName"] as? String else { return }
        // The rule editor keeps the drawn path in its own form state and only
        // writes it on Save, so a cancelled edit must not touch the store.
        let deferStoreUpdate = (notification.userInfo?["deferStoreUpdate"] as? Bool) ?? false
        pendingRecordRuleName = ruleName
        canvasManager?.isRecordingGesture = true
        canvasManager?.onGestureRecorded = { [weak self] points in
            guard let self = self, let name = self.pendingRecordRuleName else { return }
            var stroke = Stroke(capacity: points.count)
            for p in points { stroke.addPoint(p) }
            let template = GestureTemplate(from: stroke, name: "Recorded")
            NotificationCenter.default.post(
                name: .macStrokeGestureDidRecord,
                object: nil,
                userInfo: ["ruleName": name, "points": stroke.points])
            if !deferStoreUpdate, let store = self.ruleStore, let old = store.rule(named: name) {
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
                    filterType: old.filterType,
                    spareActions: old.spareActions
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gestureTriggerRecordingDidChange(_:)),
            name: .gestureTriggerRecordingDidChange,
            object: nil
        )
    }

    /// While the preferences window is capturing which mouse button to bind,
    /// stop treating presses as gestures — otherwise the trial press of an
    /// already-enabled trigger button gets eaten as the start of a stroke.
    @objc private func gestureTriggerRecordingDidChange(_ notification: Notification) {
        let recording = (notification.object as? Bool) ?? false
        canvasManager?.isSuspended = recording
        if recording {
            canvasManager?.cancelStroke()
        }
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
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        // 启动时什么都不回写。这两个键本来就是 Sparkle 自己的键
        // （SUEnableAutomaticChecks / SUAutomaticallyUpdate），SPUUpdaterSettings 会按
        // 「用户默认值 > Info.plist」自己读；开机就赋值等于把「用户从未设置」变成
        // 「已显式写死」，以后改默认值或 Info.plist 都不生效。
        self.updaterController = controller
        NSLog("%@", "[AppDelegate] Sparkle updater initialized")
    }

    /// About tab update controls → apply to the live Sparkle updater.
    @objc func updateSettingsDidChange(_ notification: Notification) {
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyChecksForUpdates = storage.getBoolOptional(forKey: .autoCheckUpdates) ?? StorageDefaults.autoCheckUpdates
        // 自动下载：只有用户动过那个开关才回写。给 updater 赋值会连带把键写进用户
        // 默认域，无条件写就等于把「从没设过」钉成「显式 false」。
        if UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") != nil {
            updater.automaticallyDownloadsUpdates = UserDefaults.standard.bool(forKey: "SUAutomaticallyUpdate")
        }
        // 节奏必须走这个 setter：它才会通知 SPUUpdater 重排定时器，只写 UserDefaults
        // 的话新值要到下一次检查时才生效。0 在 Sparkle 里是「关掉自动检查」的老语义，
        // 所以只在用户真的选过（键存在）时才写。
        if let interval = storage.getDoubleOptional(forKey: .updateCheckInterval), interval > 0 {
            updater.updateCheckInterval = interval
        }
    }

    /// About tab「恢复提醒」：用户在更新窗点过「跳过这个版本」后，Sparkle 把版本号写进
    /// 那三个键（普通/大版本/大版本的小更新各一个），之后**只有自动检查**会永远跳过那一版
    /// （`SUAppcastDriver` 里 `background ? skippedUpdateForHost : nil`，手动「立即检查更新」
    /// 从来不受影响）。清记录本身是一瞬间的事，问题全在「清完没有任何东西会变」：
    /// `resetUpdateCycle` 只重排定时器、不补检查，唯一的反馈是一条可能被勿扰压掉的系统通知，
    /// 于是用户只能判断成「点了没反应」。所以这里三件事一起做：
    /// 1. 清完把清掉了哪几版回传给偏好页，页面上那行当场从版本号变回「无」（按钮同时转灰）；
    /// 2. 重置检查节奏，顺带清掉温和提醒的计时（`resetTimeSinceOpportuneUpdateNotice`）；
    /// 3. 开着自动检查时当场补一次后台检查 —— 这正是「恢复提醒」四个字要发生的事，
    ///    红点和通知当场回来，不用等下一个 12 小时。自动检查关着就不补（那是用户明确
    ///    不要后台检查），页面提示改用上面那行「立即检查更新」。
    @objc func restoreSkippedUpdate(_ notification: Notification) {
        let cleared = SparkleSkippedVersions.clear()
        let rechecking = !cleared.isEmpty && updaterController?.updater.automaticallyChecksForUpdates == true
        NotificationCenter.default.post(
            name: .macStrokeSkippedUpdateDidChange,
            object: nil,
            userInfo: ["cleared": cleared, "rechecking": rechecking])
        guard !cleared.isEmpty else {
            // 本来就没有跳过记录：不能报「已清除」，那等于把没发生过的事说成发生过。
            NSLog("%@", "[AppDelegate] Restore skipped updates: nothing was skipped")
            return
        }
        guard let updater = updaterController?.updater else {
            NSLog("%@", "[AppDelegate] Restore skipped updates: cleared \(cleared) but no updater to re-arm")
            return
        }
        updater.resetUpdateCycle()
        NSLog("%@", "[AppDelegate] Cleared skipped update records: \(cleared)")
        if rechecking {
            updater.checkForUpdatesInBackground()
        }
        postMacStrokeToast(L("Skipped update records have been cleared."))
    }

    /// 与偏好模块同一套提示通道（那边内部用的 NSUserNotification，这里不能跨模块调）。
    private func postMacStrokeToast(_ text: String) {
        let toast = NSUserNotification()
        toast.title = "MacStroke"
        toast.informativeText = text
        toast.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(toast)
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
        // Original MainMenu.xib status menu (Aae-oF-AsY): Preferences + Quit only.
        // 剪贴板 / 截图/录屏 / 远程控制 / 检查更新 是移植版自加的入口：剪贴板直接弹出历史面板（状态栏
        // 菜单不会把本 App 变成前台，所以面板照样能把焦点还给用户原来那个应用），
        // 截图摊开遮罩自己抢焦点（模式条上还带滚动截图/录屏两档），远程控制只能落到偏好页，检查更新走 Sparkle 的用户主动检查（一定带焦点）。
        let menu = NSMenu(title: "MacStroke")
        // 温和提醒留下的红点：点了这一项才把已经发现的更新窗拉到前面。
        if let pending = pendingUpdate {
            menu.addItem(withTitle: "\(L("Update Available")) \(pending.displayVersionString)",
                         action: #selector(showPendingUpdate(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: L("Preferences"), action: #selector(togglePreferences), keyEquivalent: "")
        menu.addItem(withTitle: L("Clipboard"), action: #selector(showHistoryClipboard(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Screenshot or record"), action: #selector(toggleScreenshot(_:)), keyEquivalent: "")
        statusMenuItem(to: menu, titleKey: "Remote Control", tab: .remoteControl)
        menu.addItem(withTitle: L("Check for Updates"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    private func statusMenuItem(to menu: NSMenu, titleKey: String, tab: PreferencesTab) {
        menu.addItem(withTitle: L(titleKey),
                     action: #selector(openPreferencesTab(_:)),
                     keyEquivalent: "").representedObject = tab.rawValue
    }

    /// 状态栏菜单：打开偏好窗口并停在指定页。
    @objc func openPreferencesTab(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let tab = PreferencesTab(rawValue: key) else { return }
        showPreferences(tab)
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

    // MARK: - 发现新版的温和提醒（菜单栏红点 + 系统通知）

    /// 红点叠在 button 的标题上：图标是模板图（要跟菜单栏深浅色走），把点画进图里
    /// 会让整张图标变成非模板，深色菜单栏下图标就看不见了。
    private func setUpdateBadge(_ on: Bool) {
        guard let button = statusItem?.button else { return }
        if on {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: "●", attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.systemFont(ofSize: 9),
            ])
        } else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    private func rememberPendingUpdate(_ update: SUAppcastItem) {
        pendingUpdate = update
        setUpdateBadge(true)
        statusItem?.menu = statusMenu()

        let toast = NSUserNotification()
        toast.title = "MacStroke"
        toast.informativeText = newVersionText(update)
        toast.soundName = NSUserNotificationDefaultSoundName
        toast.hasActionButton = true
        toast.actionButtonTitle = L("View Update")
        toast.userInfo = [Self.updateNotificationMarker: ""]
        NSUserNotificationCenter.default.deliver(toast)
        NSLog("%@", "[AppDelegate] Pending update reminder: \(update.displayVersionString)")
    }

    private func forgetPendingUpdate() {
        guard pendingUpdate != nil else { return }
        pendingUpdate = nil
        setUpdateBadge(false)
        statusItem?.menu = statusMenu()
    }

    private func newVersionText(_ update: SUAppcastItem) -> String {
        "\(L("Update Available")) \(update.displayVersionString)"
    }

    /// 菜单里的「发现新版本 x.y.z」和点通知都走这里：交给 Sparkle 的 checkForUpdates，
    /// 它看到更新窗已经存在（driver.showingUpdate）就直接 showUpdateInFocus 把它前置，
    /// 不会再跑一次网络检查。
    @objc func showPendingUpdate(_ sender: Any?) {
        forgetPendingUpdate()
        updaterController?.checkForUpdates(sender)
    }

    @objc func togglePreferences() {
        showPreferences(nil)
    }

    /// Show the preferences window. A tab means "open/stay on that page": a
    /// freshly built window gets it as its initial page, an already visible one
    /// is told to switch (its view is long since subscribed to the notification).
    private func showPreferences(_ tab: PreferencesTab?) {
        // If we already have a preferences window that is visible, just bring it to front
        if let existing = preferencesWindow,
           existing.window?.isVisible == true {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let tab {
                NotificationCenter.default.post(name: .macStrokeShowPreferencesTab, object: tab.rawValue)
            }
            return
        }
        let viewModel = UserPreferences()
        let controller = PreferencesWindowController(viewModel: viewModel, initialTab: tab ?? .general)
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
    func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String,
                       releasePoint: CGPoint) -> Bool {
        guard let ruleStore = ruleStore else { return false }

        let settings = strokeTargetSettings
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // 功能没开时连窗口表都不抓：老路径一次 CGWindowList 都不花，抬手响应不变
        // （识别与响应时间是这条功能的死线，见 issue #43/#68）。
        let windows = settings.needsWindowProbe ? CursorWindowProbe.onScreenWindows() : []
        let (attribution, reason) = CursorTarget.attribute(at: releasePoint, windows: windows,
                                                           frontPID: frontPID,
                                                           ownPID: ProcessInfo.processInfo.processIdentifier,
                                                           settings: settings,
                                                           isAppAllowed: {
                                                               BlackWhiteFilter.shared.shouldHookMouseEventForApp($0)
                                                           })
        if reason.isWorthLogging {
            NSLog("%@", "[StrokeTarget] \(reason.rawValue)（抬手点 \(Int(releasePoint.x)),\(Int(releasePoint.y))；"
                + "前台 \(bundleID.isEmpty ? "?" : bundleID)；匹配用 \(CursorTarget.ruleBundleID(attribution, frontBundle: bundleID))）")
        }

        // Match the stroke against all rules, keeping the best-scoring one
        // (mirrors the original setActionIndex, including the global
        // enableGestureMinScore / minScore gate handled inside the engine).
        // 开关关着时 ruleBundle == bundleID == 老行为那一家。
        guard let (rule, score) = ruleStore.match(stroke: stroke,
                                                  bundleID: CursorTarget.ruleBundleID(attribution, frontBundle: bundleID)) else {
            return false
        }
        NSLog("%@", "[AppDelegate] Rule matched: \(rule.name) (score: \(score))")

        let route = StrokeRouter.route(attribution: attribution, reason: reason,
                                       frontPID: frontPID, frontBundle: bundleID,
                                       settings: settings,
                                       needsFocus: rule.action.needsCursorAppFocus)

        // Execute the action — 需要的话先挪焦点，投完按 `restoreToPID` 安排还焦。
        let executor = ActionExecutor()
        executor.onScreenshotRequested = { ScreenshotController.shared.toggle() }
        StrokeRouter.execute(route, focus: SystemFocusControl.shared, action: {
            executor.execute(rule.action, for: rule)
        }, log: { line in
            NSLog("%@", "[StrokeTarget] \(line)")
        })

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

    /// issue #22 那两条偏好，每次抬手现读（口径同别的模块：偏好现读，不缓存，
    /// 用户在偏好页里改完立刻生效，不用重启也不用重新打开手势）。
    private var strokeTargetSettings: StrokeTargetSettings {
        StrokeTargetSettings(
            enabled: storage.getBoolOptional(forKey: .strokeTargetsCursorWindow)
                ?? StorageDefaults.strokeTargetsCursorWindow,
            restoresFocus: storage.getBoolOptional(forKey: .strokeTargetRestoresFocus)
                ?? StorageDefaults.strokeTargetRestoresFocus
        )
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

// MARK: - Sparkle scheduled update presentation

extension AppDelegate: SPUStandardUserDriverDelegate {
    /// MacStroke 是菜单栏 App。Sparkle 对「自动检查发现的更新」默认排在别的程序后面
    /// （SPUStandardUserDriverDelegate 文档 background app + immediateFocus=NO 那条），
    /// 用户就是据此报「发了新版却没弹更新窗」；反过来无条件抢焦点又太打扰。这里认领
    /// 提醒职责：先只在菜单栏点个红点、发一条系统通知，用户点了才把更新窗前置。
    @objc var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 偏好页「有新版本时提醒我」。每次现读，改完立刻生效，不用重启。
    fileprivate var updateReminderEnabled: Bool {
        storage.getBoolOptional(forKey: .enableUpdateReminder) ?? StorageDefaults.enableUpdateReminder
    }

    /// 返回 NO = 「这一版由我温和提醒」，Sparkle 就不去把更新窗排到后面。
    /// immediateFocus 是 Sparkle 自己判断的时机（刚启动、或系统空闲很久），那种场合
    /// 弹窗不扰人，交回给它；关键版本（发版时 CRITICAL=1 打的 <sparkle:criticalUpdate/>）
    /// 也不进温和通道，它就是要马上被看到；用户关掉提醒开关时同样走 Sparkle 自己的路。
    @objc func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        return immediateFocus || update.isCriticalUpdate || !updateReminderEnabled
    }

    @objc func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        rememberPendingUpdate(update)
    }

    /// 用户已经给了注意力（把更新窗带到前面、安装、跳过都算）：红点和菜单项该收了。
    @objc func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        forgetPendingUpdate()
    }

    @objc func standardUserDriverWillFinishUpdateSession() {
        forgetPendingUpdate()
    }
}

// MARK: - 系统通知点击

extension AppDelegate: NSUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        guard notification.userInfo?[Self.updateNotificationMarker] != nil else {
            // 其它提示沿用没设 delegate 时的默认行为：把 App 带到前台。
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        showPendingUpdate(nil)
    }
}

MacStrokeApp.main()
