//
//  Storage.swift
//  MacStroke
//
//  Persistent storage for user preferences and rules.
//  Uses UserDefaults for simple key-value storage.
//

import Foundation

/// Storage keys used by the preferences module.
public enum StorageKey: String, CaseIterable {
    // General
    case showIconInStatusBar = "showIconInStatusBar"
    case showUIInWhateverApp = "showUIInWhateverApp"
    case blockFilter = "blockFilter"
    case whiteListMode = "filterIsInWhiteMode"
    case whiteList = "whiteList"
    case language = "language"
    case openPrefOnStartup = "openPrefOnStartup"
    case mergeConsecutiveIdenticalGestures = "mergeConsecutiveIdenticalGestures"
    case defaultLineColor = "defaultLineColor"
    case defaultNoteColor = "defaultNoteColor"

    // Gesture recognition
    case minSimilarityScore = "minScore"
    case enableGestureMinScore = "enableGestureMinScore"
    case showGestureNote = "showGestureNote"

    // Gesture trigger button
    // 移植版扩展（issue #53）：原版只监听右键，连 DefaultPreferences.plist 里都
    // 没有按键相关的键，所以键名是新造的，不需要对原版兼容。
    // 存 CoreGraphics 的按键编号（0 左、1 右、2 中、3 起为侧键/自定义键），
    // 默认 1 = 右键，即原版行为。
    case gestureTriggerButton = "gestureTriggerButton"

    // 移植版扩展（issue #59）：按住这些修饰键时不起手。同样没有原版键名，
    // 值是逗号分隔的 token（cmd/ctrl/shift/opt/fn），空串表示不因修饰键暂停。
    case enableGestureSuppression = "enableGestureSuppression"
    case gestureSuppressedModifiers = "gestureSuppressedModifiers"

    // 移植版扩展（issue #73）：手势画完却没匹配上时，不再把这次右键交回前台应用。
    // 原版是无论匹配没匹配都回放（画错了至少还能弹出右键菜单），所以默认关。
    case swallowUnmatchedGesture = "swallowUnmatchedGesture"

    // 移植版扩展（issue #75）：按住起始键（默认右键）+ 滚轮上/下 = 两个独立触发手势。
    // 原版没有这一手，所以键名全是新造的。总开关默认关 = 原版行为（滚轮永远只管滚页面）；
    // 两个方向的动作存的是 `WheelGestureActionKind` 的原始值（1 上一个标签页、2 下一个标签页，
    // 即「开了开关就先把 issue 里那件最想要的事做掉」）；只有选「自定义快捷键」时
    // 才读那两条快捷键串（格式同截图那几条：「keyCode=X, flags=Y」）。
    case wheelGestureEnabled = "wheelGestureEnabled"
    case wheelGestureUpAction = "wheelGestureUpAction"
    case wheelGestureDownAction = "wheelGestureDownAction"
    case wheelGestureUpShortcut = "wheelGestureUpShortcut"
    case wheelGestureDownShortcut = "wheelGestureDownShortcut"

    // Note/Toast
    case noteRetentionTime = "noteRetetionTime"
    case notePosition = "notePostion"
    case noteBackgroundAlpha = "noteBackgroundAlpha"
    case noteFontName = "noteFontName"
    case noteFontSize = "noteFontSize"
    case showNoteIcon = "showNoteIcon"

    // Drawing
    case disableMousePath = "disableMousePath"
    case lineColorHex = "lineColorHex"
    case lineWidth = "lineWidth"

    // Right-click menu
    // The rawValues are the original key names: the FinderSync payload is built
    // from `newFile`/`openInTerminal`/`copyFilePath`, so the UI has to write the
    // same keys (the Swift enum cases keep the longer names for readability).
    case enableRightClickMenu = "enableRightClickMenu"
    case enableNewFile = "newFile"
    case enableOpenInTerminal = "openInTerminal"
    case enableCopyFilePath = "copyFilePath"

    // Clipboard
    case enableHistoryClipboard = "enableHistoryClipboard"
    case clipoardStroageLocal = "clipoardStroageLocal"
    case historyCilpboardListShortcut = "historyCilpboardListShortcut"
    case enableLimitTotal = "enableLimitTotal"
    case limitTotal = "limitTotal"
    case enableLimitTop = "enableLimitTop"
    case limitTop = "limitTop"
    case enableLimitSaveDays = "enableLimitSaveDays"
    case limitSaveDays = "limitSaveDays"
    case userTerminal = "userTerminal"

    // Updates
    /// 原版没有自己的键：偏好窗「自动检查更新」复选框绑
    /// SUUpdater.automaticallyChecksForUpdates，值落在 Sparkle 自己的
    /// SUEnableAutomaticChecks 上。移植版早期自造了 "autoCheckUpdates" 键，
    /// 写进去的旧值会永久压掉后改的默认值（老移植版用户升上来再也不自动检查），
    /// 所以改回 Sparkle 的键，旧键在 migrateLegacyPreferenceKeys 里清掉。
    case autoCheckUpdates = "SUEnableAutomaticChecks"

    /// 自动检查的节奏。也是 Sparkle 自己的键：SPUUpdaterSettings 监听这个键的默认值
    /// 变化并立刻按新节奏重排定时器，所以偏好页选完不用重启。Sparkle 的取值顺序是
    /// 「用户默认值 > Info.plist」，用户从没选过时仍走 build_app.sh 写进 Info.plist 的
    /// 默认值 —— 因此这个键故意不进 registerUserDefaultsDefaults()：注册域里的值会被
    /// Sparkle 当成「用户已显式设置」，以后改 Info.plist 就不生效了（同 autoCheckUpdates
    /// 踩过的坑）。
    case updateCheckInterval = "SUScheduledCheckInterval"

    /// 移植版扩展（超出原版）：自动检查发现新版时，改用「菜单栏图标加点 + 系统通知」
    /// 温和提醒，用户点一下才把更新窗前置。关掉就回到 Sparkle 自己的做法。
    case enableUpdateReminder = "enableUpdateReminder"

    // Remote control
    // 移植版扩展（超出原版）：手机小程序经局域网 TCP 远程点击。原版没有任何
    // 网络接口，所以三个键名都是新造的。开关默认关 —— 关掉时行为和原版一致，
    // 不会有多开放的端口。端口默认 8848，避开微信 TCP 的端口黑名单；
    // 配对码首次启用时生成，存成 6 位大写字母数字串。
    case enableRemoteControl = "enableRemoteControl"
    case remoteControlPort = "remoteControlPort"
    case remoteControlToken = "remoteControlToken"

    // Screenshot
    // 移植版扩展（超出原版）：截图出图后怎么落地。自动保存默认关 —— 关掉时和
    // 现在一样只在用户点「保存为文件」时弹面板。保存位置存绝对路径，空串表示
    // 「还没设过」，由 Screenshot 模块回退到桌面（跟 macOS 自带截图一致）。
    case screenshotAutoSave = "screenshotAutoSave"
    case screenshotSaveDirectory = "screenshotSaveDirectory"
    /// 拖选时是否吸附窗口边界。关掉就是纯手动画框，适合边框不是窗口的场景
    /// （网页里的浮层、分屏网格）。
    case screenshotSnapToWindows = "screenshotSnapToWindows"
    /// 截图的全局快捷键，跟粘贴板那条一样存成 "keyCode=X, flags=Y"。手势触发不在
    /// 这里，它是一条规则（规则表才是手势的存放处）。
    case screenshotShortcut = "screenshotShortcut"
    /// 「提取文字」专用的那一条（issue #74）。和上面那条分开存：一条开「截图并注解」，
    /// 这一条开「框住文字直接出字」，两个动作各留一个键位才有意义。
    case screenshotTextShortcut = "screenshotTextShortcut"
    /// 选区阶段跟着光标的放大镜（放大的像素 + 坐标 + 色值）。默认开：卡边界和取色
    /// 都靠它，不想要的人在这一页关掉。
    case screenshotMagnifier = "screenshotMagnifier"
    /// 一个屏幕像素放大成几点。存的是倍率本身（4/8/16），不是档位序号，
    /// 这样以后加档位不用迁移。
    case screenshotMagnification = "screenshotMagnification"
    /// 框选落定时预先装在注解条上的工具，存 `ScreenshotTool.rawValue`（0～6）。
    /// **-1 = 关闭**：进编辑态什么都不选，选区内按下拖动仍然是平移整块。开关和取值共用
    /// 这一个键，所以偏好页只有一格下拉，不铺「一个开关 + 一个下拉」。
    case screenshotDefaultTool = "screenshotDefaultTool"

    /// 录屏帧率（每秒帧数）。存的是数值而不是档位序号，以后加档位不用迁移。
    case screenshotRecordFrameRate = "screenshotRecordFrameRate"
    /// 单次录屏最长多少秒：撞顶自动停止并出片，防止忘了关把盘写满。
    case screenshotRecordMaxSeconds = "screenshotRecordMaxSeconds"
    /// 录屏要不要把鼠标指针录进去。做操作演示要开，录内容本身开着只会挡字。
    case screenshotRecordCursor = "screenshotRecordCursor"
    /// 长截图每滚一次走多少**点**（不是像素）。小步重合多、拼接认得稳；大步帧数少、
    /// 但一次跳过头就会认输收场。
    case screenshotScrollStep = "screenshotScrollStep"
    /// 长截图最多接多少「屏」：按框住的那块高度计。撞顶就停 —— 再长的 PNG 用户也打不开。
    case screenshotScrollMaxScreens = "screenshotScrollMaxScreens"

    // Proximity lock（蓝牙靠近锁屏）
    // 移植版扩展（超出原版）。总开关默认**关**：这一条会自动锁用户的屏幕，没点头之前
    // 一次都不该发生 —— 尤其是把 Mac 当远程机用的人，误锁等于把自己关在门外。
    case enableProximityLock = "enableProximityLock"
    /// 盯哪台设备。存 `CBPeripheral.identifier` 的 UUID 串：苹果设备（手表/手机）由
    /// macOS 把随机地址解析成公开地址，这个 UUID 跨扫描稳定；空串 = 还没选过设备，
    /// 此时即使总开关开着也不动（没有目标的「靠近」无从判定）。
    case proximityDeviceID = "proximityDeviceID"
    /// 只用于界面回显的设备名。真判定只认 ID —— 名字可以重复也可以改。
    case proximityDeviceName = "proximityDeviceName"
    /// 两个阈值做滞回：信号强过 unlockRSSI 算「回来了」，弱过 lockRSSI 算「走开了」。
    /// 只留一个阈值会在临界点上反复锁解（RSSI 本身就有几 dB 抖动）。
    case proximityUnlockRSSI = "proximityUnlockRSSI"
    case proximityLockRSSI = "proximityLockRSSI"
    /// 弱过阈值之后还要再等几秒才真锁：路过门口、蓝牙抖一下都不该锁屏。
    case proximityLockDelay = "proximityLockDelay"
    /// 多久没收到这台设备的广播就认定「信号丢了」。CoreBluetooth 不会告诉你设备走了，
    /// 只能靠最后见到它的时间超时。
    case proximitySignalTimeout = "proximitySignalTimeout"
    /// 回来后要不要自动解锁（把存进钥匙串的登录密码打进锁屏密码框）。**默认关**，
    /// 而且和上面的锁屏是两件事：只锁不解是完全可用的组合，反过来不成立。
    case proximityAutoUnlock = "proximityAutoUnlock"

    // Selection bubble（划词气泡）
    // 移植版扩展（超出原版）。总开关默认**关**：这一条是「每次划词后往屏幕上放一个
    // 浮窗」，属于没点头之前一次都不该发生的那类干扰，跟靠近锁屏同等待遇。
    // 键名跟 enableHistoryClipboard、enableProximityLock、enableRemoteControl 同前缀。
    case enableSelectionPopup = "enableSelectionPopup"
    /// 手动唤出气泡的那条键（默认 ⌃⌘B）。和「松手自动弹」是两条路：键盘选字
    /// （⌥⇧→ 那一类）压根不产生左键事件，只有这一条能把它叫出来。
    /// 格式同其它快捷键："keyCode=X, flags=Y"。
    case selectionPopupShortcut = "selectionPopupShortcut"
    /// 松手之后隔多少**毫秒**去读选区。读早了拿到的是旧值甚至 nil —— 目标 App 把选中
    /// 文字交给无障碍接口也要一个来回。浏览器、Electron 这类要调大一点。
    case selectionPopupReadDelay = "selectionPopupReadDelay"
    /// 「划完字自动弹出」这一条**触发方式**。它和总开关是两件事：总开关关掉是整个功能不挂
    /// 监听，这条关掉是只留快捷键那一路 —— 有人就是不想每次划词都被放一枚气泡出来。
    case selectionPopupAutoPop = "selectionPopupAutoPop"
    /// 手动唤出那一路要不要挂快捷键监听。和上面那条对称：只想留自动弹的人，不该被 ⌃B
    /// 占着键位（占着不做事是最难查的坏，见 SelectionBubbleSettings.monitorShortcut）。
    case selectionPopupShortcutEnabled = "selectionPopupShortcutEnabled"
    // 下面四个是「气泡上每一格」自己的开关。做成一格一键，是因为这四件事的出口完全不同：
    // 复制进剪贴板、搜索和翻译要开浏览器、朗读要出声。只要其中一两个是很正常的诉求，
    // 而四格固定摆出来时，不想被朗读打扰的人只能把整个功能关掉。
    case selectionPopupActionCopy = "selectionPopupActionCopy"
    case selectionPopupActionSearch = "selectionPopupActionSearch"
    case selectionPopupActionTranslate = "selectionPopupActionTranslate"
    case selectionPopupActionSpeak = "selectionPopupActionSpeak"
    /// 「无障碍读不到选区」时要不要**替用户按一次 ⌘C**，从粘贴板把字取回来（取完原样放回）。
    /// 邮件正文那一类（WebKit 自己绘制的视图）五样选区属性全不答，只有这一条路能拿到字；
    /// 代价是那不到一秒里我们动两次用户的粘贴板，所以给它自己一颗开关，不埋在总开关底下。
    case selectionPopupCopyFallback = "selectionPopupCopyFallback"
    /// 搜索那一格走哪一家（`SelectionBubbleSearchEngine` 的 rawValue）。写字符串而不是写整数：
    /// 偏好里存的是**能读懂的 id**，装机出问题时 `defaults read` 一眼能看出选了谁，
    /// 也避免「往枚举里插一家就把后面的序号全顶歪」这种坏。
    case selectionPopupSearchEngine = "selectionPopupSearchEngine"
    /// 自选那一条的 URL 模板，`{query}` 是占位符。**带占位符就走 URL 预填，不带就退成
    /// 「先把字复制进粘贴板再打开这一页」**（判定在 `SelectionBubbleLinks.prefillsQuery`）。
    /// 默认空串：空的时候按上面那一家走，不拿一个空模板去拼链接。
    case selectionPopupSearchCustomURL = "selectionPopupSearchCustomURL"
    /// 点开那种「不吃 URL 预填」的网页 AI 之后，要不要**再替用户按一次 ⌘V**，把那一段字送进
    /// 输入框。默认**关**：这一手会往「此刻前台那个窗口」投按键，页面没把光标落进输入框时
    /// 可能贴到地址栏，属于有代价的贴心，所以由用户自己开。判定与闸在
    /// `SelectionBubbleSettings.searchAutoPaste`（含「快捷键录成单纯 ⌘V 时压根不上场」那一条）。
    case selectionPopupAutoPaste = "selectionPopupAutoPaste"

    // Legacy (kept for compatibility)
    case showToast = "showToast"
    case clipboardHistoryLimit = "clipboardHistoryLimit"
}

/// A lightweight storage abstraction for user preferences.
public struct PreferencesStorage {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func getBool(forKey key: StorageKey) -> Bool {
        defaults.bool(forKey: key.rawValue)
    }

    public func getInt(forKey key: StorageKey) -> Int {
        defaults.integer(forKey: key.rawValue)
    }

    public func getDouble(forKey key: StorageKey) -> Double {
        defaults.double(forKey: key.rawValue)
    }

    /// Returns the boolean value for the given key, or nil if the key does not exist.
    public func getBoolOptional(forKey key: StorageKey) -> Bool? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.bool(forKey: key.rawValue)
    }

    /// Returns the integer value for the given key, or nil if the key does not exist.
    public func getIntOptional(forKey key: StorageKey) -> Int? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.integer(forKey: key.rawValue)
    }

    /// Returns the double value for the given key, or nil if the key does not exist.
    public func getDoubleOptional(forKey key: StorageKey) -> Double? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.double(forKey: key.rawValue)
    }

    public func setBool(_ value: Bool, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func setInt(_ value: Int, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func setDouble(_ value: Double, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func getString(forKey key: StorageKey) -> String? {
        defaults.string(forKey: key.rawValue)
    }

    public func getStringOptional(forKey key: StorageKey) -> String? {
        defaults.object(forKey: key.rawValue) as? String
    }

    public func setString(_ value: String, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func remove(_ key: StorageKey) {
        defaults.removeObject(forKey: key.rawValue)
    }

    public func synchronize() {
        defaults.synchronize()
    }
}

/// Default storage configuration values.
public enum StorageDefaults {
    // General
    public static let showIconInStatusBar: Bool = true
    public static let showUIInWhateverApp: Bool = false
    public static let blockFilter: String = ""
    public static let whiteListMode: Bool = false
    public static let whiteList: String = ""
    public static let language: String = "en"
    public static let openPrefOnStartup: Bool = true
    public static let mergeConsecutiveIdenticalGestures: Bool = false
    public static let defaultLineColor: String = "#0000ff"
    public static let defaultNoteColor: String = "#FFFFFF"

    // Gesture recognition
    public static let minSimilarityScore: Double = 85.0
    public static let enableGestureMinScore: Bool = true
    public static let showGestureNote: Bool = true

    // Gesture trigger button — the right button (CG number 1), i.e. exactly the
    // original's behaviour, until the user records another one.
    public static let gestureTriggerButton: Int = 1
    // Gesture suppression — off by default: modifiers never interfere, like the
    // original, which never looked at the flags a click arrived with.
    public static let enableGestureSuppression: Bool = false
    /// 空 = 没有录制过要避让的修饰键。
    public static let gestureSuppressedModifiers: String = ""
    // 不匹配时吞掉这次右键 —— 关，等于原版：画错了还把点击交回应用，右键菜单照常弹。
    // 只在「真的画了一条」的前提下才可能生效，纯右键单击永远照常回放（issue #73）。
    public static let swallowUnmatchedGesture: Bool = false

    // 右键 + 滚轮（issue #75）—— 总开关关，等于原版：滚轮只管滚页面，跟手势无关。
    // 那两个 1 / 2 是 `WheelGestureActionKind.tabPrevious` / `.tabNext`（RuleEngine 里的枚举，
    // 这一层够不到，所以写死数字并由 `StorageTests` 钉住对应关系）。
    public static let wheelGestureEnabled: Bool = false
    public static let wheelGestureUpAction: Int = 1
    public static let wheelGestureDownAction: Int = 2
    /// 只有动作档位是「自定义快捷键」时才读；空串 = 没录过键，等于不执行（见 `WheelGesturePlan`）。
    public static let wheelGestureUpShortcut: String = ""
    public static let wheelGestureDownShortcut: String = ""

    // Note/Toast
    public static let noteRetentionTime: Int = 1
    public static let notePosition: Int = 1              // 0鼠标 1屏幕中心 2右上...
    public static let noteBackgroundAlpha: Double = 0.5
    public static let noteFontName: String = "Monaco"
    public static let noteFontSize: Double = 40
    public static let showNoteIcon: Bool = true

    // Drawing
    public static let disableMousePath: Bool = false
    public static let lineColorHex: String = "#0000FF" // 蓝色（RRGGBB；旧默认值 "#0000FFFF" 是 ARGB 写法，会导致按 RRGGBBAA 解析成全透明）
    public static let lineWidth: Double = 4.0

    // Right-click menu
    public static let enableRightClickMenu: Bool = true
    public static let enableNewFile: Bool = true
    public static let enableOpenInTerminal: Bool = true
    public static let enableCopyFilePath: Bool = true

    // Clipboard
    public static let enableHistoryClipboard: Bool = true
    public static let clipoardStroageLocal: Bool = true
    /// Original SRShortcut default: keyCode 9 ("v") + modifierFlags 1572864 (⌘⌥).
    public static let historyCilpboardListShortcut: String = "keyCode=9, flags=1572864"
    public static let enableLimitTotal: Bool = false
    public static let limitTotal: Int = 200
    public static let enableLimitTop: Bool = true
    public static let limitTop: Int = 15
    public static let enableLimitSaveDays: Bool = true
    public static let limitSaveDays: Int = 7
    public static let userTerminal: String = "Terminal"

    // Updates
    // 原版默认为 true（复选框绑 SUUpdater.automaticallyChecksForUpdates，原版
    // Info.plist 里也没有 SUEnableAutomaticChecks，即走 Sparkle 的默认开）。
    // build_app.sh 生成的 Info.plist 同写 SUEnableAutomaticChecks=true，两处一致。
    public static let autoCheckUpdates: Bool = true

    /// 默认开：菜单栏 App 直接抢焦点太打扰，见 StorageKey.enableUpdateReminder。
    public static let enableUpdateReminder: Bool = true

    // Remote control
    public static let enableRemoteControl: Bool = false
    public static let remoteControlPort: Int = 8848
    /// 空串 = 还没生成过配对码（首次打开远程控制时由 RemoteControl 模块生成并落库）。
    public static let remoteControlToken: String = ""

    // Screenshot
    public static let screenshotAutoSave: Bool = false
    /// 空串 = 用户没选过，落盘位置由 ScreenshotSettings 现取桌面。
    public static let screenshotSaveDirectory: String = ""
    public static let screenshotSnapToWindows: Bool = true
    /// ⌘⇧A：A 的 Carbon 键码就是 0，修饰键 ⌘(0x100000)|⇧(0x20000)。
    public static let screenshotShortcut: String = "keyCode=0, flags=1179648"
    /// ⌥⇧A：键码同样是 0，修饰键 ⌥(0x80000)|⇧(0x20000)。
    /// 和上面那条只差一个修饰键，两下按法在手指上是相邻的，但位的组合不重叠，
    /// 监听器各判各的（issue #74 要的是一条能把「框住就出字」单独叫出来的键）。
    public static let screenshotTextShortcut: String = "keyCode=0, flags=655360"
    public static let screenshotMagnifier: Bool = true
    /// 8 倍：120pt 的取景窗里横排 15 个像素。Retina 上那是屏上约 7.5pt 见方的一小块，
    /// 再小就看不出像素格，再大就开始挡内容。
    public static let screenshotMagnification: Int = 8
    /// 默认**关**（-1）：进编辑态不预先装工具。装上是「少点一下格子」的偏好，
    /// 但代价是选区内拖动不再平移整块，这个交换不该由我们替所有人做。
    public static let screenshotDefaultTool: Int = -1

    /// 30 帧：再高对网页/文档滚动没意义，文件却大一截。
    public static let screenshotRecordFrameRate: Int = 30
    /// 10 分钟：区域录像多是操作演示，撞这个上限基本就是忘了按停止。
    public static let screenshotRecordMaxSeconds: Int = 600
    /// 默认带指针：录的是「怎么操作」，看不见鼠标就没意义。
    public static let screenshotRecordCursor: Bool = true
    /// 每次滚 100 点。步子小 → 相邻两帧重合长 → 拼接认得稳；步子大 → 帧数少，
    /// 但一次跳过头就认输收场。
    public static let screenshotScrollStep: Int = 100
    /// 长到 10 屏就该收：再长的 PNG 用户自己也打不开，白占内存。
    public static let screenshotScrollMaxScreens: Int = 10

    // Proximity lock
    public static let enableProximityLock: Bool = false
    /// 空串 = 还没选设备，功能不动。
    public static let proximityDeviceID: String = ""
    public static let proximityDeviceName: String = ""
    /// -60 dBm ≈ 同一张桌子上；-80 dBm ≈ 隔了一两堵墙或者已经走出房间。
    /// 这两个值是 BLEUnlock 长期实测下来的默认，起步就用它，用户再按自家户型调。
    public static let proximityUnlockRSSI: Int = -60
    public static let proximityLockRSSI: Int = -80
    /// 5 秒：够滤掉一次蓝牙抖动，又不至于让人已经走远还等着锁。
    public static let proximityLockDelay: Int = 5
    /// 60 秒：手表的广播间隔通常是秒级，一分钟一个包都没收到就是真不在附近了。
    public static let proximitySignalTimeout: Int = 60
    public static let proximityAutoUnlock: Bool = false

    // Selection bubble（划词气泡）
    /// 默认关：没在偏好页点头之前，一次气泡都不该弹出来。
    public static let enableSelectionPopup: Bool = false
    /// ⌃⌘B：B 的 Carbon 键码 11，修饰键 ⌃(0x40000)|⌘(0x100000) = 1310720。
    /// 避开 ⌘⇧A / ⌥⇧A（截图）、⌘⌥V（粘贴板），也避开系统占用的 ⌃⌘F/⌃⌘Space。
    public static let selectionPopupShortcut: String = "keyCode=11, flags=1310720"
    /// 250ms：按「无障碍接口要把选区算出来才交得出字」估的一档，装机取证后再定。
    /// 读到 nil 就静默不弹，所以这个数偏大只多等一下，偏小会漏弹。
    public static let selectionPopupReadDelay: Int = 250
    /// 两条触发方式默认都开：**开不开整个功能由总开关说**，这里只管「开着之后怎么叫出来」。
    /// 默认两条都给，用户第一次装好打开总开关时看到的是完整行为。
    public static let selectionPopupAutoPop: Bool = true
    public static let selectionPopupShortcutEnabled: Bool = true
    /// 四格默认全开（同上：过滤哪些格子是另一件事，不是「功能开不开」）。
    public static let selectionPopupActionCopy: Bool = true
    public static let selectionPopupActionSearch: Bool = true
    public static let selectionPopupActionTranslate: Bool = true
    public static let selectionPopupActionSpeak: Bool = true
    /// 「无障碍读不到时替用户按一次 ⌘C」—— 默认**开**。
    /// 开在这里的理由：邮件正文那一类压根没有第二条路能拿到字，默认关掉等于那一档直接没功能。
    /// 代价写在 `SelectionCopyReader` 文件头那四道闸里：只在读不到时动手、动手前后各还原一次、
    /// 粘贴板当前是文件时压根不动手。用户不认这条可以在偏好页那一颗开关上关掉。
    public static let selectionPopupCopyFallback: Bool = true
    /// 搜索那一格默认走 Google —— 与 3.2.3 之前写死那一家一致，升级完行为不许变。
    public static let selectionPopupSearchEngine: String = "google"
    /// 自选 URL 默认空：空就等于「没配」，实际用哪家由上面那一条决定（见 `searchTemplate` 的退回）。
    public static let selectionPopupSearchCustomURL: String = ""
    /// 「打开网页 AI 后再替用户按一次 ⌘V」—— 默认**关**。
    /// 关在这里的理由和上面那颗 ⌘C 相反：⌘C 那一手不做就是没功能，这一手不做只是多按一次键；
    /// 而它做的是「往此刻前台那个窗口投一次粘贴」，页面没把光标落进输入框时贴到的是地址栏。
    /// 想省事的人可以在偏好页那一颗开关上打开。
    public static let selectionPopupAutoPaste: Bool = false

    // Legacy (keep for compatibility)
    public static let showToast: Bool = true
    public static let clipboardHistoryLimit: Int = 50
}

/// Registers the default values for every preference key with UserDefaults
/// (the Swift counterpart of the original's
/// `registerDefaults: [DefaultPreferences.plist]`).
///
/// Must be called at app startup, **before** anything reads UserDefaults
/// directly (e.g. `HistoryClipboardManager`, `RuleEngine.match` reading
/// `minScore`) — `UserDefaults.bool`/`integer` return false/0 for keys that
/// were never written, which would otherwise disable the clipboard monitor
/// and the gesture score gate on a fresh install.
public func registerUserDefaultsDefaults() {
    let defaults: [String: Any] = [
        StorageKey.showIconInStatusBar.rawValue: StorageDefaults.showIconInStatusBar,
        StorageKey.showUIInWhateverApp.rawValue: StorageDefaults.showUIInWhateverApp,
        StorageKey.blockFilter.rawValue: StorageDefaults.blockFilter,
        StorageKey.whiteListMode.rawValue: StorageDefaults.whiteListMode,
        StorageKey.whiteList.rawValue: StorageDefaults.whiteList,
        StorageKey.language.rawValue: StorageDefaults.language,
        StorageKey.openPrefOnStartup.rawValue: StorageDefaults.openPrefOnStartup,
        StorageKey.mergeConsecutiveIdenticalGestures.rawValue: StorageDefaults.mergeConsecutiveIdenticalGestures,
        StorageKey.defaultLineColor.rawValue: StorageDefaults.defaultLineColor,
        StorageKey.defaultNoteColor.rawValue: StorageDefaults.defaultNoteColor,
        StorageKey.minSimilarityScore.rawValue: StorageDefaults.minSimilarityScore,
        StorageKey.enableGestureMinScore.rawValue: StorageDefaults.enableGestureMinScore,
        StorageKey.showGestureNote.rawValue: StorageDefaults.showGestureNote,
        StorageKey.gestureTriggerButton.rawValue: StorageDefaults.gestureTriggerButton,
        StorageKey.enableGestureSuppression.rawValue: StorageDefaults.enableGestureSuppression,
        StorageKey.gestureSuppressedModifiers.rawValue: StorageDefaults.gestureSuppressedModifiers,
        StorageKey.swallowUnmatchedGesture.rawValue: StorageDefaults.swallowUnmatchedGesture,
        StorageKey.wheelGestureEnabled.rawValue: StorageDefaults.wheelGestureEnabled,
        StorageKey.wheelGestureUpAction.rawValue: StorageDefaults.wheelGestureUpAction,
        StorageKey.wheelGestureDownAction.rawValue: StorageDefaults.wheelGestureDownAction,
        StorageKey.wheelGestureUpShortcut.rawValue: StorageDefaults.wheelGestureUpShortcut,
        StorageKey.wheelGestureDownShortcut.rawValue: StorageDefaults.wheelGestureDownShortcut,
        StorageKey.noteRetentionTime.rawValue: StorageDefaults.noteRetentionTime,
        StorageKey.notePosition.rawValue: StorageDefaults.notePosition,
        StorageKey.noteBackgroundAlpha.rawValue: StorageDefaults.noteBackgroundAlpha,
        StorageKey.noteFontName.rawValue: StorageDefaults.noteFontName,
        StorageKey.noteFontSize.rawValue: StorageDefaults.noteFontSize,
        StorageKey.showNoteIcon.rawValue: StorageDefaults.showNoteIcon,
        StorageKey.disableMousePath.rawValue: StorageDefaults.disableMousePath,
        StorageKey.lineColorHex.rawValue: StorageDefaults.lineColorHex,
        StorageKey.lineWidth.rawValue: StorageDefaults.lineWidth,
        StorageKey.enableRightClickMenu.rawValue: StorageDefaults.enableRightClickMenu,
        StorageKey.enableNewFile.rawValue: StorageDefaults.enableNewFile,
        StorageKey.enableOpenInTerminal.rawValue: StorageDefaults.enableOpenInTerminal,
        StorageKey.enableCopyFilePath.rawValue: StorageDefaults.enableCopyFilePath,
        StorageKey.enableHistoryClipboard.rawValue: StorageDefaults.enableHistoryClipboard,
        StorageKey.clipoardStroageLocal.rawValue: StorageDefaults.clipoardStroageLocal,
        StorageKey.historyCilpboardListShortcut.rawValue: StorageDefaults.historyCilpboardListShortcut,
        StorageKey.enableLimitTotal.rawValue: StorageDefaults.enableLimitTotal,
        StorageKey.limitTotal.rawValue: StorageDefaults.limitTotal,
        StorageKey.enableLimitTop.rawValue: StorageDefaults.enableLimitTop,
        StorageKey.limitTop.rawValue: StorageDefaults.limitTop,
        StorageKey.enableLimitSaveDays.rawValue: StorageDefaults.enableLimitSaveDays,
        StorageKey.limitSaveDays.rawValue: StorageDefaults.limitSaveDays,
        StorageKey.userTerminal.rawValue: StorageDefaults.userTerminal,
        StorageKey.autoCheckUpdates.rawValue: StorageDefaults.autoCheckUpdates,
        // SUScheduledCheckInterval 不在这里注册，理由见 StorageKey.updateCheckInterval。
        StorageKey.enableUpdateReminder.rawValue: StorageDefaults.enableUpdateReminder,
        StorageKey.enableRemoteControl.rawValue: StorageDefaults.enableRemoteControl,
        StorageKey.remoteControlPort.rawValue: StorageDefaults.remoteControlPort,
        StorageKey.remoteControlToken.rawValue: StorageDefaults.remoteControlToken,
        StorageKey.screenshotAutoSave.rawValue: StorageDefaults.screenshotAutoSave,
        StorageKey.screenshotSaveDirectory.rawValue: StorageDefaults.screenshotSaveDirectory,
        StorageKey.screenshotSnapToWindows.rawValue: StorageDefaults.screenshotSnapToWindows,
        StorageKey.screenshotShortcut.rawValue: StorageDefaults.screenshotShortcut,
        StorageKey.screenshotTextShortcut.rawValue: StorageDefaults.screenshotTextShortcut,
        StorageKey.screenshotMagnifier.rawValue: StorageDefaults.screenshotMagnifier,
        StorageKey.screenshotMagnification.rawValue: StorageDefaults.screenshotMagnification,
        StorageKey.screenshotDefaultTool.rawValue: StorageDefaults.screenshotDefaultTool,
        StorageKey.screenshotRecordFrameRate.rawValue: StorageDefaults.screenshotRecordFrameRate,
        StorageKey.screenshotRecordMaxSeconds.rawValue: StorageDefaults.screenshotRecordMaxSeconds,
        StorageKey.screenshotRecordCursor.rawValue: StorageDefaults.screenshotRecordCursor,
        StorageKey.screenshotScrollStep.rawValue: StorageDefaults.screenshotScrollStep,
        StorageKey.screenshotScrollMaxScreens.rawValue: StorageDefaults.screenshotScrollMaxScreens,
        StorageKey.enableProximityLock.rawValue: StorageDefaults.enableProximityLock,
        StorageKey.proximityDeviceID.rawValue: StorageDefaults.proximityDeviceID,
        StorageKey.proximityDeviceName.rawValue: StorageDefaults.proximityDeviceName,
        StorageKey.proximityUnlockRSSI.rawValue: StorageDefaults.proximityUnlockRSSI,
        StorageKey.proximityLockRSSI.rawValue: StorageDefaults.proximityLockRSSI,
        StorageKey.proximityLockDelay.rawValue: StorageDefaults.proximityLockDelay,
        StorageKey.proximitySignalTimeout.rawValue: StorageDefaults.proximitySignalTimeout,
        StorageKey.proximityAutoUnlock.rawValue: StorageDefaults.proximityAutoUnlock,
        StorageKey.enableSelectionPopup.rawValue: StorageDefaults.enableSelectionPopup,
        StorageKey.selectionPopupShortcut.rawValue: StorageDefaults.selectionPopupShortcut,
        StorageKey.selectionPopupReadDelay.rawValue: StorageDefaults.selectionPopupReadDelay,
        StorageKey.selectionPopupAutoPop.rawValue: StorageDefaults.selectionPopupAutoPop,
        StorageKey.selectionPopupShortcutEnabled.rawValue: StorageDefaults.selectionPopupShortcutEnabled,
        StorageKey.selectionPopupActionCopy.rawValue: StorageDefaults.selectionPopupActionCopy,
        StorageKey.selectionPopupActionSearch.rawValue: StorageDefaults.selectionPopupActionSearch,
        StorageKey.selectionPopupActionTranslate.rawValue: StorageDefaults.selectionPopupActionTranslate,
        StorageKey.selectionPopupActionSpeak.rawValue: StorageDefaults.selectionPopupActionSpeak,
        StorageKey.selectionPopupCopyFallback.rawValue: StorageDefaults.selectionPopupCopyFallback,
        StorageKey.selectionPopupSearchEngine.rawValue: StorageDefaults.selectionPopupSearchEngine,
        StorageKey.selectionPopupSearchCustomURL.rawValue: StorageDefaults.selectionPopupSearchCustomURL,
        StorageKey.selectionPopupAutoPaste.rawValue: StorageDefaults.selectionPopupAutoPaste,
        StorageKey.showToast.rawValue: StorageDefaults.showToast,
        StorageKey.clipboardHistoryLimit.rawValue: StorageDefaults.clipboardHistoryLimit,
    ]
    UserDefaults.standard.register(defaults: defaults)

    migrateLegacyPreferenceKeys()
}

/// One-time migration of early Swift-port key names to the original MacStroke
/// keys (the StorageKey rawValues now match the original, so re-registering
/// under the new name is enough; old values are moved only if actually written).
private func migrateLegacyPreferenceKeys() {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: "minSimilarityScore") != nil {
        if defaults.object(forKey: "minScore") == nil {
            defaults.set(defaults.double(forKey: "minSimilarityScore"), forKey: "minScore")
        }
        defaults.removeObject(forKey: "minSimilarityScore")
    }
    if defaults.object(forKey: "whiteListMode") != nil {
        if defaults.object(forKey: "filterIsInWhiteMode") == nil {
            defaults.set(defaults.bool(forKey: "whiteListMode"), forKey: "filterIsInWhiteMode")
        }
        defaults.removeObject(forKey: "whiteListMode")
    }
    for (legacy, key) in [("noteRetentionTime", "noteRetetionTime"), ("notePosition", "notePostion")] {
        if defaults.object(forKey: legacy) != nil {
            if defaults.object(forKey: key) == nil {
                defaults.set(defaults.integer(forKey: legacy), forKey: key)
            }
            defaults.removeObject(forKey: legacy)
        }
    }
    // Early Swift builds stored the Finder sub-switches under "enable…"; the
    // original (and the extension payload) use the short names.
    for (legacy, key) in [
        ("enableNewFile", "newFile"),
        ("enableOpenInTerminal", "openInTerminal"),
        ("enableCopyFilePath", "copyFilePath"),
    ] {
        if defaults.object(forKey: legacy) != nil {
            if defaults.object(forKey: key) == nil {
                defaults.set(defaults.bool(forKey: legacy), forKey: key)
            }
            defaults.removeObject(forKey: legacy)
        }
    }
    // "clipoardStroageRam" only ever exists as a dead registered default in the
    // original; early Swift builds read it as a live switch, so drop any value
    // they wrote. Storage backend is decided by "clipoardStroageLocal" alone.
    defaults.removeObject(forKey: "clipoardStroageRam")

    // 早期 Swift 构建把「自动检查更新」存在自造的 "autoCheckUpdates" 键下，并且
    // 在启动时把它回写进 Sparkle 的 SUEnableAutomaticChecks。两处都留着旧值的话，
    // 默认值改再多也压不回来，所以对跑过那些构建的机器各清一次（用户可在关于页重设）。
    if defaults.object(forKey: "autoCheckUpdates") != nil {
        defaults.removeObject(forKey: "autoCheckUpdates")
        defaults.removeObject(forKey: "SUEnableAutomaticChecks")
    }
}
