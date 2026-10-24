//
//  SelectionBubbleSettings.swift
//  MacStroke
//
//  划词气泡的偏好快照 + 那几个不给偏好页铺控件的阈值。
//
//  照 ProximityLockSettings / ScreenshotSettings 的写法：读的时候重新校验并夹取，因为这几
//  个值也可能来自导入的偏好 plist，写坏的值不该让功能「静默地乱弹」。
//
//  这一份快照里有十三个数：总开关、两条触发方式（自动弹 / 手动快捷键）、快捷键串、读取延迟、
//  代按 ⌘C 那一手开不开、搜索走哪一家加那条自选 URL、打开网页 AI 后要不要再补一次 ⌘V，
//  外加四格各自的开关（收在 `actions` 里）。哪些 App 不弹不在这里 —— 直接
//  复用「过滤」页那套黑白名单（App 层把判定注进来）。位移下限、字数上限、自动收起这些是手感阈值，
//  用户只会感知「该弹的时候没弹」，给滑块只会多三行没人动的控件。
//

import CoreGraphics
import Foundation
import Storage

public struct SelectionBubbleSettings: Equatable {
    /// 总开关。关掉时监听整个卸掉 —— 不是「继续监听然后什么都不弹」。
    public var enabled: Bool
    /// 手动唤出的快捷键串，"keyCode=X, flags=Y"，由 App 层交给 ShortcutMonitor 解析。
    public var shortcut: String
    /// 松手之后隔多久去读选区（**秒**；落盘的是毫秒，这里换算成秒给消费端用）。
    public var readDelay: TimeInterval
    /// 触发方式一：划完字自动弹。
    public var autoPop: Bool
    /// 触发方式二：按快捷键手动唤出。
    public var shortcutEnabled: Bool
    /// 气泡上要摆的格子（已按 `SelectionBubbleAction.allCases` 排好）。空 = 没格子可摆，
    /// 那时候**两条触发方式都不该做事**：读一段字上来再弹一枚空格子，比不弹更让人莫名其妙。
    public var actions: [SelectionBubbleAction]
    /// 无障碍那几手全落空时，要不要**替用户按一次 ⌘C**把字从粘贴板取回来。
    /// 邮件正文那一类只有这一手能做到（见 `SelectedTextReader` 文件头第 5 条），
    /// 代价是那一秒里我们会动两次用户的粘贴板 —— 所以它有自己的一颗开关，
    /// 而不是藏在总开关底下：有人就是不想让任何程序碰他复制的东西。
    public var copyFallbackEnabled: Bool
    /// 「搜索」那一格走哪一家（含网页 AI）。默认 Google —— 与这一格写死那一家一致。
    public var searchEngine: SelectionBubbleSearchEngine
    /// 自选那一条的模板，只在 `searchEngine == .custom` 时参与拼链接。
    public var searchCustomURL: String
    /// 「打开那一页之后，再替用户按一次 ⌘V」。**默认关**，而且只对那种「先把字放进粘贴板」的
    /// 页面生效（见 `searchAutoPaste`）。
    ///
    /// 为什么这颗开关要单独存在、且不默认开：URL 预填是那些站点自己没承诺的东西（社区里同一个
    /// `?q=` 时灵时不灵，ChatGPT 压根不认），所以退成「替他复制 + 他自己 ⌘V」。这一手是把最后
    /// 那一下也替他按掉 —— 代价是**我们不知道网页此刻把光标落在哪儿**：输入框还没就绪时，
    /// 那次 ⌘V 会打到地址栏或页面上别的控件。所以它默认关、由用户自己开，
    /// 投之前还要过 `pasteGate` 那两道闸。
    public var autoPasteAfterOpen: Bool

    public init(enabled: Bool, shortcut: String, readDelay: TimeInterval,
                autoPop: Bool = true, shortcutEnabled: Bool = true,
                actions: [SelectionBubbleAction] = SelectionBubbleAction.allCases,
                copyFallbackEnabled: Bool = true,
                searchEngine: SelectionBubbleSearchEngine = .google,
                searchCustomURL: String = "",
                autoPasteAfterOpen: Bool = false) {
        self.enabled = enabled
        self.shortcut = shortcut
        self.readDelay = readDelay
        self.autoPop = autoPop
        self.shortcutEnabled = shortcutEnabled
        self.actions = actions
        self.copyFallbackEnabled = copyFallbackEnabled
        self.searchEngine = searchEngine
        self.searchCustomURL = searchCustomURL
        self.autoPasteAfterOpen = autoPasteAfterOpen
    }

    /// 读取延迟的有效区间。下限是「别让无障碍调用贴着一松手就来」，上限是「等到这里还没读
    /// 出来就当这个 App 读不到」——再长用户已经把鼠标挪走了。
    public static let readDelayRange: ClosedRange<TimeInterval> = 0.05 ... 1.5

    /// 至少拖过这么多**点**才算划词：单击、双击选词都拖不出这个距离，不该弹。
    public static let minimumTravel: CGFloat = 6

    /// 选中超过这么多字符就不弹。全选整篇文档时冒一条气泡只会挡字，而那么长一段既不是
    /// 「复制一下」的场景，也不是「朗读」的场景。
    public static let maximumCharacters = 2_000

    /// 没人理它的时候气泡自己待这么久。点别处、切 App 都会提前收，这一档只是兜底。
    public static let autoHideAfter: TimeInterval = 6

    /// 一次无障碍调用的超时。目标 App 卡住（或者压根没有无障碍接口）时，不能让后台线程
    /// 跟着无限等下去 —— 读不出来就是不弹，不值得挂在那儿。
    public static let messagingTimeout: TimeInterval = 0.6

    public static func current(from storage: PreferencesStorage = PreferencesStorage()) -> SelectionBubbleSettings {
        let storedMs = storage.getIntOptional(forKey: .selectionPopupReadDelay) ?? StorageDefaults.selectionPopupReadDelay
        return SelectionBubbleSettings(
            enabled: storage.getBoolOptional(forKey: .enableSelectionPopup) ?? StorageDefaults.enableSelectionPopup,
            shortcut: storage.getStringOptional(forKey: .selectionPopupShortcut) ?? StorageDefaults.selectionPopupShortcut,
            readDelay: clampedDelay(storedMs) / 1_000,
            autoPop: storage.getBoolOptional(forKey: .selectionPopupAutoPop) ?? StorageDefaults.selectionPopupAutoPop,
            shortcutEnabled: storage.getBoolOptional(forKey: .selectionPopupShortcutEnabled)
                ?? StorageDefaults.selectionPopupShortcutEnabled,
            actions: SelectionBubbleAction.enabled(in: storage),
            copyFallbackEnabled: storage.getBoolOptional(forKey: .selectionPopupCopyFallback)
                ?? StorageDefaults.selectionPopupCopyFallback,
            searchEngine: SelectionBubbleSearchEngine.current(in: storage),
            searchCustomURL: storage.getStringOptional(forKey: .selectionPopupSearchCustomURL)
                ?? StorageDefaults.selectionPopupSearchCustomURL,
            autoPasteAfterOpen: storage.getBoolOptional(forKey: .selectionPopupAutoPaste)
                ?? StorageDefaults.selectionPopupAutoPaste
        )
    }

    /// 「搜索」那一格此刻该用的模板，以及**要不要先把字放进粘贴板**。
    /// 判定全在 `SelectionBubbleSearchEngine.resolvedTemplate(customURL:)` 那一处纯函数里，
    /// 这里只是把它接到偏好快照上 —— 控制器读一次，别在两个地方各判一遍占位符。
    public var searchTarget: (template: String, copiesTextFirst: Bool) {
        searchEngine.resolvedTemplate(customURL: searchCustomURL)
    }

    /// 打开那一页**之后**要不要再排一次 ⌘V。这一句只管「排不排」，「到点了投不投」在
    /// `pasteGate` 那一道。
    ///
    /// 四个条件各挡一种真实的坏法：
    ///  - `enabled && hasCells`：功能整个关掉、或四格全关时，不该有任何按键进得了事件流；
    ///  - `autoPasteAfterOpen`：用户没点头就不碰他的键盘（默认关，见上面那颗字段）；
    ///  - `searchTarget.copiesTextFirst`：**只有那种「字是我们放进粘贴板的」页面才贴**。
    ///    真能 URL 预填的那六家压根没写粘贴板，这时候补一次 ⌘V 贴出去的是用户本来就复制
    ///    着的东西 —— 那不是贴心，那是把别人的内容打进一个他没打算填的框；
    ///  - `!isPlainCommandV(shortcut)`：拆环，和 ⌘C 那一手同一件事（见下面那一句的注释）。
    public var searchAutoPaste: Bool {
        enabled && hasCells && autoPasteAfterOpen
            && searchTarget.copiesTextFirst && !Self.isPlainCommandV(shortcut)
    }

    /// 到点之后那一刻的三档答复。写成枚举而不是两个 Bool，是因为**这两道闸会同时不过**，
    /// 而装机时要知道的是「为什么这次没贴」—— 一次只能报一个原因，所以顺序也在这句里定：
    /// 粘贴板先（那是「贴错东西」，比「贴到我们自己窗口」更坏）。
    public enum PasteGate: Equatable {
        case inject
        case pasteboardChanged
        case frontIsOurs
    }

    public static func pasteGate(pasteboardStillHoldsOurText: Bool,
                                 frontIsOurOwnApp: Bool) -> PasteGate {
        if !pasteboardStillHoldsOurText { return .pasteboardChanged }
        if frontIsOurOwnApp { return .frontIsOurs }
        return .inject
    }

    /// 「打开之后等多久再贴」。不给偏好页铺控件的理由同文件头那几条：这是一个手感阈值，
    /// 用户只会感知「那次 ⌘V 落没落进输入框」。取 1.2 秒是照装机实测的那类页面来的 ——
    /// 那些聊天页从被激活到把光标落进输入框，快的几百毫秒，慢的要在登录态里绕一圈；
    /// 再长就长成「点了放大镜半天没反应」的手感了。
    public static let autoPasteDelay: TimeInterval = 1.2

    /// 「这串快捷键就是单纯的 ⌘V 吗」—— `isPlainCommandC` 的同一件事，换个键码。
    ///
    /// 为什么必须有：气泡快捷键是那只 `ShortcutMonitor` 在收的，而我们投出去的这一下**就是**
    /// 不带别修饰键的 ⌘V，它会进全局事件流。用户要是把气泡快捷键录成单纯的 ⌘V，
    /// 就成了「点搜索 → 打开页面 → 自动 ⌘V → 监听命中 ⌘V → 又读选区 → 又点搜索…」，
    /// 而且每一圈都在动键盘和浏览器。那种配法下这一手压根不上场，而不是「上场但加冷却」——
    /// 冷却只把环变慢。默认那组 ⌃⌘B、还有粘贴板历史那组 ⌥⌘V 都不会命中（比的是全套标准修饰键）。
    public static func isPlainCommandV(_ shortcut: String) -> Bool {
        guard let (keyCode, flags) = Self.parse(shortcut) else { return false }
        return keyCode == SelectionCopyReader.pasteKeyCode && (flags & 0x1E_0000) == 0x10_0000
    }

    /// 递给偏好页那根滑杆的**毫秒**值。`readDelay` 是给消费端的秒，落盘和界面都是毫秒，
    /// 这个换算只此一处：两边各写一份 `* 1000` 迟早有人漏掉一位，界面上就显示 0。
    public var readDelayMilliseconds: Int { Int(readDelay * 1_000) }

    /// 毫秒进出：越界整值退回默认，而不是夹到边界。写坏的值（0、-5、999999）夹到边界会得到
    /// 一个界面上显示不出来的数，退回默认反而看得见、也解释得清。
    public static func clampedDelay(_ milliseconds: Int) -> TimeInterval {
        guard milliseconds >= Int(readDelayRange.lowerBound * 1_000),
              milliseconds <= Int(readDelayRange.upperBound * 1_000) else {
            return TimeInterval(StorageDefaults.selectionPopupReadDelay)
        }
        return TimeInterval(milliseconds)
    }

    /// 偏好页那根滑杆的刻度（毫秒）：上下限和默认值都从这个数出发，别让界面写死一份。
    public static var readDelayMillisecondsRange: ClosedRange<Int> {
        Int(readDelayRange.lowerBound * 1_000) ... Int(readDelayRange.upperBound * 1_000)
    }

    /// 滑杆步长（毫秒）。界面用这个数，测试也按这个数验收：默认值和上下限都必须是它的
    /// 整数倍，否则用户滑不到边界、也滑不回默认，而这两件事在界面上都解释不清。
    public static let readDelayStepMilliseconds = 50

    /// 递给 App 层挂快捷键那只 monitor 的串：**总开关关掉、或手动那一条自己关掉时给空串**。
    ///
    /// 规则为什么不写在 `main.swift` 那句三元里：App 层那个可执行 target 没有单测能咬进去，
    /// 而这一条恰好是「关到根上」的另一半 —— 功能关着却把 ⌃⌘B 从前台 App 手里吞掉、按下
    /// 什么都不做，是最难查的那种坏。放在这里，它就是一个有测试的纯函数。
    /// 空串走 `ShortcutMonitor.parseShortcut` 的那一支：解析不出来 = 停掉监听。
    public var monitorShortcut: String { enabled && shortcutEnabled ? shortcut : "" }

    /// 有没有格子可摆。四格全关时两条触发方式都只是白读一次选区，所以先在这儿拦住。
    public var hasCells: Bool { !actions.isEmpty }

    /// 鼠标划词那一路要不要做事。
    public var popsOnSelection: Bool { enabled && autoPop && hasCells }

    /// 快捷键那一路要不要做事。**不看 `autoPop`**：按下去的人就是想要一条气泡，跟
    /// 「不想每次划词都弹」并不冲突 —— 这两条能各关各的，正是要拆成两行的理由。
    public var popsOnShortcut: Bool { enabled && shortcutEnabled && hasCells }

    /// 这一趟能不能上「代按 ⌘C」那一手。
    ///
    /// `isPlainCommandC(shortcut)` 那一条**不是洁癖，是拆环**：我们投出去的那一下就是
    /// 不带别修饰键的 ⌘C，它会进全局事件流，而 App 层那只 `ShortcutMonitor` 也在收键。
    /// 用户要是把气泡快捷键录成单纯的 ⌘C，就成了「按下 → 读不到 → 代按 ⌘C → 监听又命中 →
    /// 又读不到 → 又代按」的死循环，而且每一圈都在动他的粘贴板。这一条判据把环从根上拆掉：
    /// **那种配法下这一手压根不上场**，而不是「上场但加个冷却」（冷却只把环变慢）。
    /// 其余配法（⌃⌘C / ⌥⌘C / 默认那组 ⌃⌘B）都不会命中，因为监听比的是**全套标准修饰键**。
    public var canUseCopyFallback: Bool {
        enabled && copyFallbackEnabled && hasCells && !Self.isPlainCommandC(shortcut)
    }

    /// 「这串快捷键就是单纯的 ⌘C 吗」。
    ///
    /// 修饰键只比标准那四位（`0x1E_0000`），和 `ShortcutMonitor.modifierMask` 同一套：
    /// 录制框会把左右键那些设备位一并存进来，严格相等会比出无数个「看起来一样但判不相等」。
    /// 键码是 8（kVK_ANSI_C），也正是 `SelectionCopyReader.copyKeyCode` 投的那一键 ——
    /// 两处必须同一个数，否则改了一处、环又回来了。
    /// 解析不出来（空串 / 坏值 / 没录）按**不是** ⌘C 处理：那种情况下监听压根没挂（见
    /// `monitorShortcut`），不可能自激。
    public static func isPlainCommandC(_ shortcut: String) -> Bool {
        guard let (keyCode, flags) = Self.parse(shortcut) else { return false }
        return keyCode == SelectionCopyReader.copyKeyCode && (flags & 0x1E_0000) == 0x10_0000
    }

    /// 从 "keyCode=8, flags=1048576" 里取那两个数。和 `ShortcutMonitor.parseShortcut` 同格式，
    /// 这里不复用它是因为 `SelectionPopup` 不依赖 `EventCapture`（那条依赖会为了一行解析拉整个模块）。
    private static func parse(_ shortcut: String) -> (UInt16, UInt)? {
        var keyCode: UInt16?
        var flags: UInt?
        for piece in shortcut.components(separatedBy: ",") {
            let parts = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let value = UInt64(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "keyCode": keyCode = UInt16(exactly: value)
            case "flags": flags = UInt(exactly: value)
            default: break
            }
        }
        guard let keyCode, let flags else { return nil }
        return (keyCode, flags)
    }
}
