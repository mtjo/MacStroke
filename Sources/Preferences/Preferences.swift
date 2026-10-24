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
import EventCapture
import RemoteControl
import ProximityLock
import SelectionPopup

/// User preferences model - mirrors the design doc's PreferencesModel.
public final class UserPreferences: ObservableObject {
    private let storage: PreferencesStorage

    // MARK: - General
    /// Master switch. Original: `static BOOL isEnabled` in AppDelegate — it is
    /// runtime state only, re-initialised to YES on every launch and never
    /// written to UserDefaults, so the checkbox always starts ticked.
    @Published public var isEnabled: Bool = true
    @Published public var showIconInStatusBar: Bool {
        didSet { storage.setBool(showIconInStatusBar, forKey: .showIconInStatusBar) }
    }
    @Published public var showUIInWhateverApp: Bool {
        didSet { storage.setBool(showUIInWhateverApp, forKey: .showUIInWhateverApp) }
    }
    @Published public var blockFilter: String {
        didSet { storage.setString(blockFilter, forKey: .blockFilter) }
    }
    @Published public var whiteListMode: Bool {
        didSet { storage.setBool(whiteListMode, forKey: .whiteListMode) }
    }
    @Published public var whiteList: String {
        didSet { storage.setString(whiteList, forKey: .whiteList) }
    }
    @Published public var language: String {
        didSet { storage.setString(language, forKey: .language); applyUserLanguage(language) }
    }
    @Published public var openPrefOnStartup: Bool {
        didSet { storage.setBool(openPrefOnStartup, forKey: .openPrefOnStartup) }
    }
    @Published public var mergeConsecutiveIdenticalGestures: Bool {
        didSet { storage.setBool(mergeConsecutiveIdenticalGestures, forKey: .mergeConsecutiveIdenticalGestures) }
    }
    @Published public var defaultLineColor: String {
        didSet { storage.setString(defaultLineColor, forKey: .defaultLineColor) }
    }
    @Published public var defaultNoteColor: String {
        didSet { storage.setString(defaultNoteColor, forKey: .defaultNoteColor) }
    }

    // MARK: - Gesture recognition
    @Published public var minSimilarityScore: Double {
        didSet { storage.setDouble(minSimilarityScore, forKey: .minSimilarityScore) }
    }
    @Published public var enableGestureMinScore: Bool {
        didSet { storage.setBool(enableGestureMinScore, forKey: .enableGestureMinScore) }
    }
    @Published public var showGestureNote: Bool {
        didSet { storage.setBool(showGestureNote, forKey: .showGestureNote) }
    }

    // MARK: - Gesture trigger button
    // 移植版扩展（issue #53）：原版只有右键，这里收成「一个起手键」，默认 1 = 右键。
    // 存 CoreGraphics 的按键编号，录成别的键就改用那个，永远只有一个键能起手。
    @Published public var gestureTriggerButton: Int {
        didSet { storage.setInt(gestureTriggerButton, forKey: .gestureTriggerButton) }
    }

    // MARK: - Gesture suppression modifiers
    // 移植版扩展（issue #59）：按住录到的修饰键组合时不起手，整段拖拽原样交给前台
    // App。开关默认关，值仍是一份 token 串（cmd/ctrl/shift/opt/fn）。
    @Published public var enableGestureSuppression: Bool {
        didSet { storage.setBool(enableGestureSuppression, forKey: .enableGestureSuppression) }
    }
    @Published public var gestureSuppressedModifiers: String {
        didSet { storage.setString(gestureSuppressedModifiers, forKey: .gestureSuppressedModifiers) }
    }

    // MARK: - 不匹配时不弹右键菜单
    // 移植版扩展（issue #73）：画完一条却没匹配上规则时，不把这次按键交回前台 App。
    // 默认关 = 原版行为（画错了还能弹出右键菜单）。判定只在 CanvasManager 里做，
    // 这里只负责存；App 层每事件现读，勾上立刻生效、不用重启。
    @Published public var swallowUnmatchedGesture: Bool {
        didSet { storage.setBool(swallowUnmatchedGesture, forKey: .swallowUnmatchedGesture) }
    }

    /// 修饰键录制框讲的是「keyCode=…, flags=…」，存的还是同一份 token 串，这里做转换：
    /// key code 恒为 0，只有 ⌘⌃⇧⌥fn 五个键位会被认下来。
    public func suppressedModifiersBinding() -> Binding<String> {
        Binding(
            get: { "keyCode=0, flags=\(Set(tokenList: self.gestureSuppressedModifiers).eventFlags)" },
            set: { raw in
                self.gestureSuppressedModifiers = Set(eventFlags: ShortcutRecorder.parse(raw)?.flags ?? 0).tokenList
            }
        )
    }

    // MARK: - Note/Toast
    @Published public var noteRetentionTime: Int {
        didSet { storage.setInt(noteRetentionTime, forKey: .noteRetentionTime) }
    }
    @Published public var notePosition: Int {
        didSet { storage.setInt(notePosition, forKey: .notePosition) }
    }
    @Published public var noteBackgroundAlpha: Double {
        didSet { storage.setDouble(noteBackgroundAlpha, forKey: .noteBackgroundAlpha) }
    }
    @Published public var noteFontName: String {
        didSet { storage.setString(noteFontName, forKey: .noteFontName) }
    }
    @Published public var noteFontSize: Double {
        didSet { storage.setDouble(noteFontSize, forKey: .noteFontSize) }
    }
    @Published public var showNoteIcon: Bool {
        didSet { storage.setBool(showNoteIcon, forKey: .showNoteIcon) }
    }

    @Published public var disableMousePath: Bool {
        didSet { storage.setBool(disableMousePath, forKey: .disableMousePath) }
    }
    @Published public var lineColorHex: String {
        didSet { storage.setString(lineColorHex, forKey: .lineColorHex) }
    }

    /// Computed Color wrapper for lineColorHex, used by ColorPicker.
    public var lineColor: Color {
        get { Color(hex: lineColorHex) }
        set { lineColorHex = newValue.hexString }
    }

    /// Computed Color wrapper for defaultNoteColor (original noteColor —
    /// the gesture note text color), used by ColorPicker.
    public var noteColor: Color {
        get { Color(hex: defaultNoteColor) }
        set { defaultNoteColor = newValue.hexString }
    }

    // MARK: - Right-click menu
    @Published public var enableRightClickMenu: Bool {
        didSet { storage.setBool(enableRightClickMenu, forKey: .enableRightClickMenu) }
    }
    @Published public var enableNewFile: Bool {
        didSet { storage.setBool(enableNewFile, forKey: .enableNewFile) }
    }
    @Published public var enableOpenInTerminal: Bool {
        didSet { storage.setBool(enableOpenInTerminal, forKey: .enableOpenInTerminal) }
    }
    @Published public var enableCopyFilePath: Bool {
        didSet { storage.setBool(enableCopyFilePath, forKey: .enableCopyFilePath) }
    }

    // MARK: - Clipboard
    @Published public var enableHistoryClipboard: Bool {
        didSet { storage.setBool(enableHistoryClipboard, forKey: .enableHistoryClipboard) }
    }
    @Published public var clipoardStroageLocal: Bool {
        didSet { storage.setBool(clipoardStroageLocal, forKey: .clipoardStroageLocal) }
    }
    @Published public var historyCilpboardListShortcut: String {
        didSet { storage.setString(historyCilpboardListShortcut, forKey: .historyCilpboardListShortcut) }
    }
    @Published public var enableLimitTop: Bool {
        didSet { storage.setBool(enableLimitTop, forKey: .enableLimitTop) }
    }
    @Published public var limitTop: Int {
        didSet { storage.setInt(limitTop, forKey: .limitTop) }
    }
    @Published public var enableLimitTotal: Bool {
        didSet { storage.setBool(enableLimitTotal, forKey: .enableLimitTotal) }
    }
    @Published public var limitTotal: Int {
        didSet { storage.setInt(limitTotal, forKey: .limitTotal) }
    }
    @Published public var enableLimitSaveDays: Bool {
        didSet { storage.setBool(enableLimitSaveDays, forKey: .enableLimitSaveDays) }
    }
    @Published public var limitSaveDays: Int {
        didSet { storage.setInt(limitSaveDays, forKey: .limitSaveDays) }
    }
    // MARK: - Right-click menu extras
    @Published public var userTerminal: String {
        didSet { storage.setString(userTerminal, forKey: .userTerminal) }
    }

    // MARK: - Updates
    @Published public var autoCheckUpdates: Bool {
        didSet { storage.setBool(autoCheckUpdates, forKey: .autoCheckUpdates) }
    }
    /// 自动检查的节奏（秒），存的是 Sparkle 自己的 SUScheduledCheckInterval，
    /// 改了 Sparkle 立刻按新节奏重排定时器。
    @Published public var updateCheckInterval: Double {
        didSet { storage.setDouble(updateCheckInterval, forKey: .updateCheckInterval) }
    }
    /// 发现新版时先用菜单栏红点 + 系统通知温和提醒，而不是直接把更新窗抢到前面。
    @Published public var enableUpdateReminder: Bool {
        didSet { storage.setBool(enableUpdateReminder, forKey: .enableUpdateReminder) }
    }
    /// 用户从没在偏好页选过节奏时的当前生效值：读 build_app.sh 写进 Info.plist 的
    /// SUScheduledCheckInterval（那个数字只在那里维护一份），Info.plist 缺这个键才
    /// 退回 Sparkle 自己的默认 86400（1 天）。
    public static let infoPlistUpdateCheckInterval: Double =
        (Bundle.main.infoDictionary?[StorageKey.updateCheckInterval.rawValue] as? NSNumber)?.doubleValue ?? 86400

    // MARK: - Remote control
    // 移植版扩展（超出原版）：手机小程序经局域网 TCP 远程点击。开关默认关，
    // 关着时不监听任何端口，行为与原版一致。
    @Published public var enableRemoteControl: Bool {
        didSet {
            storage.setBool(enableRemoteControl, forKey: .enableRemoteControl)
            if enableRemoteControl, remoteControlToken.isEmpty {
                // 开关刚打开时先备好配对码：服务一启动就要能校验，二维码也要能立刻显示。
                remoteControlToken = RemoteControlSettings.makeToken()
            }
            NotificationCenter.default.post(name: .macStrokeRemoteControlDidChange, object: nil)
        }
    }
    @Published public var remoteControlPort: Int {
        didSet {
            // A port the mini program may not reach would make the service
            // silently unusable, so an invalid edit is dropped instead of saved.
            guard RemoteControlSettings.isPortAllowed(remoteControlPort) else {
                remoteControlPort = oldValue
                lastRejectedPort = oldValue
                return
            }
            lastRejectedPort = nil
            storage.setInt(remoteControlPort, forKey: .remoteControlPort)
            NotificationCenter.default.post(name: .macStrokeRemoteControlDidChange, object: nil)
        }
    }
    /// The port the last rejected edit was trying to keep (drives the hint text).
    @Published public private(set) var lastRejectedPort: Int? = nil

    @Published public var remoteControlToken: String {
        didSet {
            storage.setString(remoteControlToken, forKey: .remoteControlToken)
            NotificationCenter.default.post(name: .macStrokeRemoteControlDidChange, object: nil)
        }
    }

    /// 换配对码等于把已配对的手机全部踢掉：旧码立刻失效，二维码要重新扫。
    public func regenerateRemoteToken() {
        remoteControlToken = RemoteControlSettings.makeToken()
    }

    // MARK: - Screenshot
    // 移植版扩展（超出原版）：截图出图之后怎么落地。会话开始时 ScreenshotController
    // 现读一份快照（ScreenshotSettings.current），所以这几个开关不需要发通知 ——
    // 改完下一张图就生效，正铺着的遮罩不受影响。
    @Published public var screenshotAutoSave: Bool {
        didSet { storage.setBool(screenshotAutoSave, forKey: .screenshotAutoSave) }
    }
    /// 空串 = 用户没选过保存位置，由 ScreenshotSettings 回退到桌面。
    @Published public var screenshotSaveDirectory: String {
        didSet { storage.setString(screenshotSaveDirectory, forKey: .screenshotSaveDirectory) }
    }
    /// 关掉就是纯手动画框：吸附靠的是窗口边界，边框不是窗口的场景（网页浮层、
    /// 分屏网格）吸上去反而是干扰。
    @Published public var screenshotSnapToWindows: Bool {
        didSet { storage.setBool(screenshotSnapToWindows, forKey: .screenshotSnapToWindows) }
    }
    /// 选区阶段跟光的放大镜。关掉就是纯靠光标尖卡边界（老手感）。
    @Published public var screenshotMagnifier: Bool {
        didSet { storage.setBool(screenshotMagnifier, forKey: .screenshotMagnifier) }
    }
    /// 放大倍率（一个屏幕像素放大成几点），存的是倍率本身而不是档位序号。
    @Published public var screenshotMagnification: Int {
        didSet { storage.setInt(screenshotMagnification, forKey: .screenshotMagnification) }
    }
    /// 选区落定后预先装在注解条上的工具序号；**-1 = 关闭**（什么都不装，选区内拖动仍是
    /// 平移整块）。开关和取值共用这一个键，所以偏好页只有一格下拉。
    @Published public var screenshotDefaultTool: Int {
        didSet { storage.setInt(screenshotDefaultTool, forKey: .screenshotDefaultTool) }
    }
    /// 截图的全局快捷键，「keyCode=X, flags=Y」，跟粘贴板那条同格式。改了就写库，
    /// App 层监听 UserDefaults 的变化重新挂监听，不需要这里发通知。
    @Published public var screenshotShortcut: String {
        didSet { storage.setString(screenshotShortcut, forKey: .screenshotShortcut) }
    }
    /// 「提取文字」专用快捷键（issue #74）：按下去遮罩直接停在提取文字那一档，
    /// 框住一段文字松手就出字，不进注解条。和上面那条同格式、同生效方式。
    @Published public var screenshotTextShortcut: String {
        didSet { storage.setString(screenshotTextShortcut, forKey: .screenshotTextShortcut) }
    }

    // MARK: - Screenshot / 录屏
    // 这三行管「录屏那一档出来的是什么」：帧率决定流畅度和文件大小的折中，时长上限
    // 防止忘了按停止把盘写满，带不带指针决定这段录像能不能当操作演示。
    // 和上面几项一样：会话开始时才取快照（ScreenshotSettings.current），改完下一场生效。
    /// 每秒帧数，存数值而不是档位序号（加档位不用迁移）。消费端会把它夹进 1…120。
    @Published public var screenshotRecordFrameRate: Int {
        didSet { storage.setInt(screenshotRecordFrameRate, forKey: .screenshotRecordFrameRate) }
    }
    /// 单次录屏最长秒数，撞顶自动停止并出片。
    @Published public var screenshotRecordMaxSeconds: Int {
        didSet { storage.setInt(screenshotRecordMaxSeconds, forKey: .screenshotRecordMaxSeconds) }
    }
    /// 鼠标指针要不要进画面。
    @Published public var screenshotRecordCursor: Bool {
        didSet { storage.setBool(screenshotRecordCursor, forKey: .screenshotRecordCursor) }
    }

    // MARK: - Screenshot / 长截图
    // 长截图没有「质量」可调，能调的是它走多快和走多久：步长是每次注入的滚动量，
    // 上限是接多少屏之后收场。两个都存数值，消费端各自夹紧。
    /// 每滚一次走多少**点**（不是像素，像素是它乘上 scale 之后的事）。
    @Published public var screenshotScrollStep: Int {
        didSet { storage.setInt(screenshotScrollStep, forKey: .screenshotScrollStep) }
    }
    /// 最多接「几屏」：按框住那块的高度计，撞顶就停。
    @Published public var screenshotScrollMaxScreens: Int {
        didSet { storage.setInt(screenshotScrollMaxScreens, forKey: .screenshotScrollMaxScreens) }
    }

    // MARK: - Proximity lock（蓝牙靠近锁屏）
    // 移植版扩展（超出原版）。和截图那几项不同：这一组改完要**立刻**生效 ——
    // 人已经走开了才想起阈值不对，等下次启动没有意义。所以每个 didSet 都发
    // `.macStrokeProximityLockDidChange`，App 侧收到就 `ProximityLockController.shared.apply()`。
    /// 总开关。没选设备时即使打开也不算武装（`ProximityLockSettings.isArmed`）。
    @Published public var enableProximityLock: Bool {
        didSet {
            storage.setBool(enableProximityLock, forKey: .enableProximityLock)
            postProximityChange()
        }
    }
    /// 盯的那台设备的 BLE 广播标识（CBPeripheral.identifier 的 UUID 串）。
    /// 只由 `selectProximityDevice(id:name:)` 写，界面上是只读的。
    @Published public private(set) var proximityDeviceID: String
    @Published public private(set) var proximityDeviceName: String
    /// 均值 ≥ 这个值算「人在旁边」。
    @Published public var proximityUnlockRSSI: Int {
        didSet {
            guard proximityUnlockRSSI != oldValue else { return }
            guard ProximityLockSettings.isValidRSSI(unlock: proximityUnlockRSSI, lock: proximityLockRSSI) else {
                proximityUnlockRSSI = oldValue
                return
            }
            storage.setInt(proximityUnlockRSSI, forKey: .proximityUnlockRSSI)
            postProximityChange()
        }
    }
    /// 均值 ≤ 这个值（或者信号超时收不到广播）算「走开」。
    @Published public var proximityLockRSSI: Int {
        didSet {
            guard proximityLockRSSI != oldValue else { return }
            guard ProximityLockSettings.isValidRSSI(unlock: proximityUnlockRSSI, lock: proximityLockRSSI) else {
                proximityLockRSSI = oldValue
                return
            }
            storage.setInt(proximityLockRSSI, forKey: .proximityLockRSSI)
            postProximityChange()
        }
    }
    /// 判定为走开之后还要再撑这么多秒才锁屏。
    @Published public var proximityLockDelay: Int {
        didSet {
            storage.setInt(proximityLockDelay, forKey: .proximityLockDelay)
            postProximityChange()
        }
    }
    /// 这么久收不到一条广播就当设备消失（CoreBluetooth 永远不会主动说「它走了」）。
    @Published public var proximitySignalTimeout: Int {
        didSet {
            storage.setInt(proximitySignalTimeout, forKey: .proximitySignalTimeout)
            postProximityChange()
        }
    }
    /// 人回来时自动把存的登录密码打进锁屏密码框。默认关。
    @Published public var proximityAutoUnlock: Bool {
        didSet {
            storage.setBool(proximityAutoUnlock, forKey: .proximityAutoUnlock)
            postProximityChange()
        }
    }

    /// 扫描列表里点「选择」：id 和名字一起落盘（名字只是回显用，判定只看 id）。
    public func selectProximityDevice(id: String, name: String) {
        proximityDeviceID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        proximityDeviceName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        storage.setString(proximityDeviceID, forKey: .proximityDeviceID)
        storage.setString(proximityDeviceName, forKey: .proximityDeviceName)
        postProximityChange()
    }

    /// 「移除设备」：把选中的那台忘掉。id 清空后 `isArmed` 立刻为假，App 侧收到通知
    /// `apply()` 就 `stop()` 了 —— 不用界面上再去关总开关，也不用二次确认：
    /// 误点了重新扫一次、点「选择」就回来。
    public func forgetProximityDevice() {
        guard !proximityDeviceID.isEmpty || !proximityDeviceName.isEmpty else { return }
        proximityDeviceID = ""
        proximityDeviceName = ""
        storage.setString("", forKey: .proximityDeviceID)
        storage.setString("", forKey: .proximityDeviceName)
        postProximityChange()
    }

    private func postProximityChange() {
        NotificationCenter.default.post(name: .macStrokeProximityLockDidChange, object: nil)
    }

    // MARK: - Selection bubble（划词气泡）
    // 移植版扩展（超出原版）。这一组不发通知：App 侧走 `UserDefaults.didChangeNotification`
    // 比对快照（和截图那两条快捷键同一个路子），改完立刻起停监听，不需要偏好层主动喊。
    // 哪些 App 不弹不在这里再配一份名单，直接复用「过滤」页那套黑白名单语义。
    /// 总开关。关掉时监听整个卸掉 —— 不只是不弹，连左键的全局监听都不挂。
    @Published public var enableSelectionPopup: Bool {
        didSet { storage.setBool(enableSelectionPopup, forKey: .enableSelectionPopup) }
    }
    /// 手动唤出的全局快捷键，"keyCode=X, flags=Y"，同截图那两条的格式与生效方式。
    @Published public var selectionPopupShortcut: String {
        didSet { storage.setString(selectionPopupShortcut, forKey: .selectionPopupShortcut) }
    }
    /// 松手后隔多少毫秒去读选区。存数值，消费端夹进 50…1500。
    @Published public var selectionPopupReadDelay: Int {
        didSet { storage.setInt(selectionPopupReadDelay, forKey: .selectionPopupReadDelay) }
    }
    /// 触发方式一：划完字自动弹出。和总开关是两件事 —— 这条只关自动弹那一路，快捷键还在。
    @Published public var selectionPopupAutoPop: Bool {
        didSet { storage.setBool(selectionPopupAutoPop, forKey: .selectionPopupAutoPop) }
    }
    /// 触发方式二：手动快捷键那一路开不开。关掉它就不挂 ⌃⌘B，键位还给前台 App。
    @Published public var selectionPopupShortcutEnabled: Bool {
        didSet { storage.setBool(selectionPopupShortcutEnabled, forKey: .selectionPopupShortcutEnabled) }
    }
    // 气泡上四格各自的开关。四个独立属性而不是一个 Set：这一层的写法就是一个键一个属性，
    // 换成集合要自己管编解码，而偏好页那四行本来就是四个 TrailingSwitch。
    @Published public var selectionPopupActionCopy: Bool {
        didSet { storage.setBool(selectionPopupActionCopy, forKey: .selectionPopupActionCopy) }
    }
    @Published public var selectionPopupActionSearch: Bool {
        didSet { storage.setBool(selectionPopupActionSearch, forKey: .selectionPopupActionSearch) }
    }
    @Published public var selectionPopupActionTranslate: Bool {
        didSet { storage.setBool(selectionPopupActionTranslate, forKey: .selectionPopupActionTranslate) }
    }
    @Published public var selectionPopupActionSpeak: Bool {
        didSet { storage.setBool(selectionPopupActionSpeak, forKey: .selectionPopupActionSpeak) }
    }
    /// 「无障碍读不到时替用户按一次 ⌘C」那一手开不开。
    /// 单独一颗而不是并进上面那一组：它动的是用户的粘贴板（虽然用完原样放回），
    /// 有人就是不想让任何程序碰他复制的东西 —— 这一条得能在界面上单独否决。
    @Published public var selectionPopupCopyFallback: Bool {
        didSet { storage.setBool(selectionPopupCopyFallback, forKey: .selectionPopupCopyFallback) }
    }
    /// 搜索那一格走哪一家 —— 存 `SelectionBubbleSearchEngine` 的 rawValue（"google"、"chatgpt"…）。
    /// 这一层只存**字符串**，不存枚举：和其它偏好键一样 `defaults read` 一眼读得懂，
    /// 而且枚举将来往中间加一家也不会把已存的值顶歪。认不出来的串由消费端那一份退回默认。
    @Published public var selectionPopupSearchEngine: String {
        didSet { storage.setString(selectionPopupSearchEngine, forKey: .selectionPopupSearchEngine) }
    }
    /// 自定义那一档的 URL 模板（可含 `{query}` 占位符）。空串 = 没配，
    /// 消费端会退回默认那一家（见 `SelectionBubbleSearchEngine.resolvedTemplate`）。
    @Published public var selectionPopupSearchCustomURL: String {
        didSet { storage.setString(selectionPopupSearchCustomURL, forKey: .selectionPopupSearchCustomURL) }
    }
    /// 打开那种「不吃 URL 预填」的网页 AI 之后，要不要再替用户按一次 ⌘V。默认关。
    /// 单独一颗、且不并进上面那一家：这一手投的是**按键**，落点是「此刻前台那个窗口」，
    /// 有人就是要自己按那一下。真值与闸都在 `SelectionBubbleSettings.searchAutoPaste` / `pasteGate`。
    @Published public var selectionPopupAutoPaste: Bool {
        didSet { storage.setBool(selectionPopupAutoPaste, forKey: .selectionPopupAutoPaste) }
    }

    // MARK: - Legacy
    @Published public var showToast: Bool {
        didSet { storage.setBool(showToast, forKey: .showToast) }
    }
    @Published public var clipboardHistoryLimit: Int {
        didSet { storage.setInt(clipboardHistoryLimit, forKey: .clipboardHistoryLimit) }
    }

    public init(storage: PreferencesStorage = PreferencesStorage()) {
        self.storage = storage
        self.showIconInStatusBar = storage.getBoolOptional(forKey: .showIconInStatusBar) ?? StorageDefaults.showIconInStatusBar
        self.showUIInWhateverApp = storage.getBoolOptional(forKey: .showUIInWhateverApp) ?? StorageDefaults.showUIInWhateverApp
        self.blockFilter = storage.getStringOptional(forKey: .blockFilter) ?? StorageDefaults.blockFilter
        self.whiteListMode = storage.getBoolOptional(forKey: .whiteListMode) ?? StorageDefaults.whiteListMode
        self.whiteList = storage.getStringOptional(forKey: .whiteList) ?? StorageDefaults.whiteList
        self.language = storage.getStringOptional(forKey: .language) ?? "en"
        self.openPrefOnStartup = storage.getBoolOptional(forKey: .openPrefOnStartup) ?? StorageDefaults.openPrefOnStartup
        self.mergeConsecutiveIdenticalGestures = storage.getBoolOptional(forKey: .mergeConsecutiveIdenticalGestures) ?? StorageDefaults.mergeConsecutiveIdenticalGestures
        self.defaultLineColor = storage.getStringOptional(forKey: .defaultLineColor) ?? StorageDefaults.defaultLineColor
        self.defaultNoteColor = storage.getStringOptional(forKey: .defaultNoteColor) ?? StorageDefaults.defaultNoteColor
        self.minSimilarityScore = storage.getDoubleOptional(forKey: .minSimilarityScore) ?? StorageDefaults.minSimilarityScore
        self.enableGestureMinScore = storage.getBoolOptional(forKey: .enableGestureMinScore) ?? StorageDefaults.enableGestureMinScore
        self.showGestureNote = storage.getBoolOptional(forKey: .showGestureNote) ?? StorageDefaults.showGestureNote
        self.gestureTriggerButton = storage.getIntOptional(forKey: .gestureTriggerButton) ?? StorageDefaults.gestureTriggerButton
        self.enableGestureSuppression = storage.getBoolOptional(forKey: .enableGestureSuppression) ?? StorageDefaults.enableGestureSuppression
        self.gestureSuppressedModifiers = storage.getStringOptional(forKey: .gestureSuppressedModifiers) ?? StorageDefaults.gestureSuppressedModifiers
        self.swallowUnmatchedGesture = storage.getBoolOptional(forKey: .swallowUnmatchedGesture) ?? StorageDefaults.swallowUnmatchedGesture
        self.noteRetentionTime = storage.getIntOptional(forKey: .noteRetentionTime) ?? StorageDefaults.noteRetentionTime
        self.notePosition = storage.getIntOptional(forKey: .notePosition) ?? StorageDefaults.notePosition
        self.noteBackgroundAlpha = storage.getDoubleOptional(forKey: .noteBackgroundAlpha) ?? StorageDefaults.noteBackgroundAlpha
        self.noteFontName = storage.getStringOptional(forKey: .noteFontName) ?? StorageDefaults.noteFontName
        self.noteFontSize = storage.getDoubleOptional(forKey: .noteFontSize) ?? StorageDefaults.noteFontSize
        self.showNoteIcon = storage.getBoolOptional(forKey: .showNoteIcon) ?? StorageDefaults.showNoteIcon
        self.disableMousePath = storage.getBoolOptional(forKey: .disableMousePath) ?? StorageDefaults.disableMousePath
        // 存量 "#0000FFFF"（ARGB 写法蓝色）按 RRGGBBAA 解析是透明色，归一化为 "#0000FF"。
        let storedLineColor = storage.getStringOptional(forKey: .lineColorHex) ?? StorageDefaults.lineColorHex
        self.lineColorHex = storedLineColor.caseInsensitiveCompare("#0000FFFF") == .orderedSame ? "#0000FF" : storedLineColor
        self.enableRightClickMenu = storage.getBoolOptional(forKey: .enableRightClickMenu) ?? StorageDefaults.enableRightClickMenu
        self.enableNewFile = storage.getBoolOptional(forKey: .enableNewFile) ?? StorageDefaults.enableNewFile
        self.enableOpenInTerminal = storage.getBoolOptional(forKey: .enableOpenInTerminal) ?? StorageDefaults.enableOpenInTerminal
        self.enableCopyFilePath = storage.getBoolOptional(forKey: .enableCopyFilePath) ?? StorageDefaults.enableCopyFilePath
        self.enableHistoryClipboard = storage.getBoolOptional(forKey: .enableHistoryClipboard) ?? true
        self.clipoardStroageLocal = storage.getBoolOptional(forKey: .clipoardStroageLocal) ?? StorageDefaults.clipoardStroageLocal
        self.historyCilpboardListShortcut = storage.getStringOptional(forKey: .historyCilpboardListShortcut) ?? StorageDefaults.historyCilpboardListShortcut
        self.enableLimitTop = storage.getBoolOptional(forKey: .enableLimitTop) ?? StorageDefaults.enableLimitTop
        self.limitTop = storage.getIntOptional(forKey: .limitTop) ?? StorageDefaults.limitTop
        self.enableLimitTotal = storage.getBoolOptional(forKey: .enableLimitTotal) ?? StorageDefaults.enableLimitTotal
        self.limitTotal = storage.getIntOptional(forKey: .limitTotal) ?? StorageDefaults.limitTotal
        self.enableLimitSaveDays = storage.getBoolOptional(forKey: .enableLimitSaveDays) ?? StorageDefaults.enableLimitSaveDays
        self.limitSaveDays = storage.getIntOptional(forKey: .limitSaveDays) ?? StorageDefaults.limitSaveDays
        self.userTerminal = storage.getStringOptional(forKey: .userTerminal) ?? StorageDefaults.userTerminal
        self.autoCheckUpdates = storage.getBoolOptional(forKey: .autoCheckUpdates) ?? StorageDefaults.autoCheckUpdates
        self.updateCheckInterval = storage.getDoubleOptional(forKey: .updateCheckInterval)
            ?? UserPreferences.infoPlistUpdateCheckInterval
        self.enableUpdateReminder = storage.getBoolOptional(forKey: .enableUpdateReminder) ?? StorageDefaults.enableUpdateReminder
        self.enableRemoteControl = storage.getBoolOptional(forKey: .enableRemoteControl) ?? StorageDefaults.enableRemoteControl
        // 端口走同一份校验：导入进来的旧 plist 里可能是微信黑名单端口，落到默认值才连得上。
        let storedRemotePort = storage.getIntOptional(forKey: .remoteControlPort) ?? StorageDefaults.remoteControlPort
        self.remoteControlPort = RemoteControlSettings.isPortAllowed(storedRemotePort)
            ? storedRemotePort : StorageDefaults.remoteControlPort
        self.remoteControlToken = storage.getStringOptional(forKey: .remoteControlToken) ?? StorageDefaults.remoteControlToken
        self.screenshotAutoSave = storage.getBoolOptional(forKey: .screenshotAutoSave) ?? StorageDefaults.screenshotAutoSave
        self.screenshotSaveDirectory = storage.getStringOptional(forKey: .screenshotSaveDirectory) ?? StorageDefaults.screenshotSaveDirectory
        self.screenshotSnapToWindows = storage.getBoolOptional(forKey: .screenshotSnapToWindows) ?? StorageDefaults.screenshotSnapToWindows
        self.screenshotMagnifier = storage.getBoolOptional(forKey: .screenshotMagnifier) ?? StorageDefaults.screenshotMagnifier
        self.screenshotMagnification = storage.getIntOptional(forKey: .screenshotMagnification) ?? StorageDefaults.screenshotMagnification
        self.screenshotDefaultTool = storage.getIntOptional(forKey: .screenshotDefaultTool) ?? StorageDefaults.screenshotDefaultTool
        self.screenshotShortcut = storage.getStringOptional(forKey: .screenshotShortcut) ?? StorageDefaults.screenshotShortcut
        self.screenshotTextShortcut = storage.getStringOptional(forKey: .screenshotTextShortcut) ?? StorageDefaults.screenshotTextShortcut
        self.screenshotRecordFrameRate = storage.getIntOptional(forKey: .screenshotRecordFrameRate) ?? StorageDefaults.screenshotRecordFrameRate
        self.screenshotRecordMaxSeconds = storage.getIntOptional(forKey: .screenshotRecordMaxSeconds) ?? StorageDefaults.screenshotRecordMaxSeconds
        self.screenshotRecordCursor = storage.getBoolOptional(forKey: .screenshotRecordCursor) ?? StorageDefaults.screenshotRecordCursor
        self.screenshotScrollStep = storage.getIntOptional(forKey: .screenshotScrollStep) ?? StorageDefaults.screenshotScrollStep
        self.screenshotScrollMaxScreens = storage.getIntOptional(forKey: .screenshotScrollMaxScreens) ?? StorageDefaults.screenshotScrollMaxScreens
        // 靠近锁屏这一组从 ProximityLockSettings.current 读，不直接读键：这样界面显示的
        // 阈值和控制器实际用的那一对必然是同一对（存量 plist 里写坏的值在读的时候就整对
        // 退回默认，界面上也就看得出被退回过，而不是显示一个用不上的数）。
        let proximity = ProximityLockSettings.current(from: storage)
        self.enableProximityLock = proximity.enabled
        self.proximityDeviceID = proximity.deviceID
        self.proximityDeviceName = proximity.deviceName
        self.proximityUnlockRSSI = proximity.unlockRSSI
        self.proximityLockRSSI = proximity.lockRSSI
        self.proximityLockDelay = Int(proximity.lockDelay)
        self.proximitySignalTimeout = Int(proximity.signalTimeout)
        self.proximityAutoUnlock = proximity.autoUnlock
        // 划词气泡这一组跟靠近锁屏同一个路子：从 SelectionBubbleSettings.current 读，不逐键读。
        // 延迟要过一遍模块的阈值校验，四格开关要看过滤后的结果 —— 界面显示的必须就是消费端
        // 实际用的那一份，否则存着 999999 或全关的 plist 时，页面上是一组用不上的数。
        let bubble = SelectionBubbleSettings.current(from: storage)
        self.enableSelectionPopup = bubble.enabled
        self.selectionPopupShortcut = bubble.shortcut
        self.selectionPopupReadDelay = bubble.readDelayMilliseconds
        self.selectionPopupAutoPop = bubble.autoPop
        self.selectionPopupShortcutEnabled = bubble.shortcutEnabled
        self.selectionPopupActionCopy = bubble.actions.contains(.copy)
        self.selectionPopupActionSearch = bubble.actions.contains(.search)
        self.selectionPopupActionTranslate = bubble.actions.contains(.translate)
        self.selectionPopupActionSpeak = bubble.actions.contains(.speak)
        self.selectionPopupCopyFallback = bubble.copyFallbackEnabled
        // 下拉显示的是**消费端实际认下来**的那一家：存了个认不出的 id（手改过 plist、
        // 从旧版本带过来）时，页面显示退回的默认家，而不是显示一条下拉里根本没有的串 ——
        // 后者会画成空白，看上去像「页面坏了」，而实际是偏好坏了。
        self.selectionPopupSearchEngine = bubble.searchEngine.rawValue
        self.selectionPopupSearchCustomURL = bubble.searchCustomURL
        self.selectionPopupAutoPaste = bubble.autoPasteAfterOpen
        self.showToast = storage.getBoolOptional(forKey: .showToast) ?? StorageDefaults.showToast
        self.clipboardHistoryLimit = storage.getIntOptional(forKey: .clipboardHistoryLimit) ?? StorageDefaults.clipboardHistoryLimit
    }

    /// Save current preferences to storage immediately.
    public func save() {
        storage.synchronize()
    }

    /// Reset preferences the way the original `resetDefaults:` does — iterate the
    /// keys of `DefaultPreferences.plist` and write each back to UserDefaults.
    /// Keys that plist does not carry are therefore left alone: language, the
    /// black/white filter lists and mode, the login item, the minimum-points
    /// threshold, the mouse-path switch, update settings and the master switch.
    public func resetToDefaults() {
        storage.setBool(StorageDefaults.showIconInStatusBar, forKey: .showIconInStatusBar)
        storage.setBool(StorageDefaults.showUIInWhateverApp, forKey: .showUIInWhateverApp)
        storage.setBool(StorageDefaults.openPrefOnStartup, forKey: .openPrefOnStartup)
        storage.setBool(StorageDefaults.mergeConsecutiveIdenticalGestures, forKey: .mergeConsecutiveIdenticalGestures)
        storage.setString(StorageDefaults.defaultLineColor, forKey: .defaultLineColor)
        storage.setString(StorageDefaults.defaultNoteColor, forKey: .defaultNoteColor)
        storage.setDouble(StorageDefaults.minSimilarityScore, forKey: .minSimilarityScore)
        storage.setBool(StorageDefaults.enableGestureMinScore, forKey: .enableGestureMinScore)
        storage.setBool(StorageDefaults.showGestureNote, forKey: .showGestureNote)
        // 原版没有这几个键，但「恢复默认」要把手势的起手键让回右键、修饰键让位关掉，
        // 才是用户期待的结果（否则重置后还在用录进去的键，界面却显示为默认值）。
        storage.setInt(StorageDefaults.gestureTriggerButton, forKey: .gestureTriggerButton)
        storage.setBool(StorageDefaults.enableGestureSuppression, forKey: .enableGestureSuppression)
        storage.setString(StorageDefaults.gestureSuppressedModifiers, forKey: .gestureSuppressedModifiers)
        storage.setBool(StorageDefaults.swallowUnmatchedGesture, forKey: .swallowUnmatchedGesture)
        storage.setInt(StorageDefaults.noteRetentionTime, forKey: .noteRetentionTime)
        storage.setInt(StorageDefaults.notePosition, forKey: .notePosition)
        storage.setDouble(StorageDefaults.noteBackgroundAlpha, forKey: .noteBackgroundAlpha)
        storage.setString(StorageDefaults.noteFontName, forKey: .noteFontName)
        storage.setDouble(StorageDefaults.noteFontSize, forKey: .noteFontSize)
        storage.setBool(StorageDefaults.showNoteIcon, forKey: .showNoteIcon)
        // Original MGOptionsDefine resetColors: re-derive the live colors from
        // the defaultLineColor / defaultNoteColor strings.
        storage.setString(StorageDefaults.defaultLineColor, forKey: .lineColorHex)
        storage.setBool(StorageDefaults.enableRightClickMenu, forKey: .enableRightClickMenu)
        storage.setBool(StorageDefaults.enableNewFile, forKey: .enableNewFile)
        storage.setBool(StorageDefaults.enableOpenInTerminal, forKey: .enableOpenInTerminal)
        storage.setBool(StorageDefaults.enableCopyFilePath, forKey: .enableCopyFilePath)
        storage.setString(StorageDefaults.userTerminal, forKey: .userTerminal)
        storage.setBool(StorageDefaults.enableHistoryClipboard, forKey: .enableHistoryClipboard)
        storage.setBool(StorageDefaults.clipoardStroageLocal, forKey: .clipoardStroageLocal)
        storage.setString(StorageDefaults.historyCilpboardListShortcut, forKey: .historyCilpboardListShortcut)
        storage.setBool(StorageDefaults.enableLimitTop, forKey: .enableLimitTop)
        storage.setInt(StorageDefaults.limitTop, forKey: .limitTop)
        storage.setBool(StorageDefaults.enableLimitTotal, forKey: .enableLimitTotal)
        storage.setInt(StorageDefaults.limitTotal, forKey: .limitTotal)
        storage.setBool(StorageDefaults.enableLimitSaveDays, forKey: .enableLimitSaveDays)
        storage.setInt(StorageDefaults.limitSaveDays, forKey: .limitSaveDays)
        storage.synchronize()
        reloadResetValues()
    }

    /// The original refreshes its bound controls automatically through the
    /// shared `NSUserDefaultsController`; SwiftUI holds its own copies, so push
    /// the just-written defaults back into the published properties.
    private func reloadResetValues() {
        showIconInStatusBar = storage.getBool(forKey: .showIconInStatusBar)
        showUIInWhateverApp = storage.getBool(forKey: .showUIInWhateverApp)
        openPrefOnStartup = storage.getBool(forKey: .openPrefOnStartup)
        mergeConsecutiveIdenticalGestures = storage.getBool(forKey: .mergeConsecutiveIdenticalGestures)
        defaultLineColor = storage.getString(forKey: .defaultLineColor) ?? StorageDefaults.defaultLineColor
        defaultNoteColor = storage.getString(forKey: .defaultNoteColor) ?? StorageDefaults.defaultNoteColor
        minSimilarityScore = storage.getDouble(forKey: .minSimilarityScore)
        enableGestureMinScore = storage.getBool(forKey: .enableGestureMinScore)
        showGestureNote = storage.getBool(forKey: .showGestureNote)
        gestureTriggerButton = storage.getInt(forKey: .gestureTriggerButton)
        enableGestureSuppression = storage.getBool(forKey: .enableGestureSuppression)
        gestureSuppressedModifiers = storage.getString(forKey: .gestureSuppressedModifiers) ?? StorageDefaults.gestureSuppressedModifiers
        swallowUnmatchedGesture = storage.getBool(forKey: .swallowUnmatchedGesture)
        noteRetentionTime = storage.getInt(forKey: .noteRetentionTime)
        notePosition = storage.getInt(forKey: .notePosition)
        noteBackgroundAlpha = storage.getDouble(forKey: .noteBackgroundAlpha)
        noteFontName = storage.getString(forKey: .noteFontName) ?? StorageDefaults.noteFontName
        noteFontSize = storage.getDouble(forKey: .noteFontSize)
        showNoteIcon = storage.getBool(forKey: .showNoteIcon)
        lineColorHex = storage.getString(forKey: .lineColorHex) ?? StorageDefaults.defaultLineColor
        enableRightClickMenu = storage.getBool(forKey: .enableRightClickMenu)
        enableNewFile = storage.getBool(forKey: .enableNewFile)
        enableOpenInTerminal = storage.getBool(forKey: .enableOpenInTerminal)
        enableCopyFilePath = storage.getBool(forKey: .enableCopyFilePath)
        userTerminal = storage.getString(forKey: .userTerminal) ?? StorageDefaults.userTerminal
        enableHistoryClipboard = storage.getBool(forKey: .enableHistoryClipboard)
        clipoardStroageLocal = storage.getBool(forKey: .clipoardStroageLocal)
        historyCilpboardListShortcut = storage.getString(forKey: .historyCilpboardListShortcut) ?? StorageDefaults.historyCilpboardListShortcut
        enableLimitTop = storage.getBool(forKey: .enableLimitTop)
        limitTop = storage.getInt(forKey: .limitTop)
        enableLimitTotal = storage.getBool(forKey: .enableLimitTotal)
        limitTotal = storage.getInt(forKey: .limitTotal)
        enableLimitSaveDays = storage.getBool(forKey: .enableLimitSaveDays)
        limitSaveDays = storage.getInt(forKey: .limitSaveDays)
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3: // RGB
            (r, g, b) = ((int >> 8) & 0xFF, (int >> 4) & 0xFF, int & 0xFF)
        case 6: // RRGGBB
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8: // RRGGBBAA
            (r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }

    /// Returns a hex string representation of the color (e.g. "#FF0000").
    var hexString: String {
        let cgColor = NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        cgColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "#%02lX%02lX%02lX",
            lround(r * 255),
            lround(g * 255),
            lround(b * 255)
        )
    }
}

// MARK: - AppKit bridge for SwiftUI preferences window.
public final class PreferencesWindowController: NSWindowController {
    private let viewModel: UserPreferences
    private var languageObserver: NSObjectProtocol?

    public init(viewModel: UserPreferences, initialTab: PreferencesTab = .general) {
        self.viewModel = viewModel
        super.init(window: nil)

        let hostingController = NSHostingController(
            rootView: PreferencesView(viewModel: viewModel, initialTab: initialTab)
        )
        hostingController.title = L("MacStroke Preferences")
        self.contentViewController = hostingController

        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window?.contentView = hostingController.view
        self.window?.center()
        self.window?.title = L("MacStroke Preferences")

        languageObserver = NotificationCenter.default.addObserver(
            forName: .languageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.window?.title = L("MacStroke Preferences")
        }
    }

    deinit {
        if let observer = languageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}