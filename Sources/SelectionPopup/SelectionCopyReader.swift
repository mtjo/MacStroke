//
//  SelectionCopyReader.swift
//  MacStroke
//
//  无障碍读不到选区时的最后一手：**替用户按一次 ⌘C**，从粘贴板里把那段字取回来，
//  取完立刻把粘贴板原样放回去。
//
//  为什么非要有这一手：装机第五轮拿真探针把邮件正文的无障碍树扒了个遍（1494 格，7.9 秒），
//  `AXSelectedText` / `AXSelectedTextRange` / `AXSelectedTextRanges` / `AXMarkedTextRange` /
//  `AXSelectedChildren` 五样对 `AXWebArea` 全报 -25212，往上的祖先报 -25205，整棵树里
//  唯一答 code=0 的一格是窗口往下第 6 层的 `AXTextArea`、返回**空串**，而它的每一格祖先都不应答；
//  兄弟 `AXStaticText` 报 -25212。也就是说**邮件的选区在容器的下面**，往上溯多少层都碰不到，
//  `AXEnhancedUserInterface`（把 Chrome 修好的那根杠杆）对邮件实测无效。
//  这一类控件（WebKit 自己写的正文视图）在无障碍侧就是拿不到字，除了「让它自己复制一次」没有第二条路。
//  用户选的正是这一条：静默代按 ⌘C。
//
//  四道闸，按「代价从小到大」排：
//  1. **只在失败那条路上**（见 `AXSelectedTextReader.shouldCopyInstead`）：无障碍读得到就绝不出手，
//     一次粘贴板都不碰。成功那一条的手感判据（1 秒内）不受这一手影响。
//  2. **不碰别人的粘贴板**：动手之前先抄下每一项的每一种类型，读完（**包括读失败**）用 `defer`
//     原样写回。哨兵写的是用户原来那份文本，所以就算他正好在这一秒里按了 ⌘V，贴出来还是他自己的东西。
//  3. **粘贴板上有文件 URL 就不做**（动手前与拿到结果后各判一次）。动手前那一次是护着用户：
//     `public.file-url` 那一档存的是资源描述符，用 `NSPasteboardItem` 逐类型回放**不保证**还能
//     贴出同一个文件，宁可少弹一次也不弄坏他刚才的文件复制。拿到后那一次是防假气泡：在 Finder 里
//     ⌘C 复制的是文件，把路径当「选中的文字」弹出来莫名其妙。
//  4. **不往自己身体里投键**：前台是 MacStroke 自己时不做。偏好页里正划着字按下 ⌃⌘B，
//     代按一次 ⌘C 会把那个框里的内容抄进粘贴板 —— 那是用户正在编辑的东西。
//     同一条闸还挡住「前台已经换人」：字是刚才那个 App 的，⌘C 却打到现在这个头上。
//
//  另外两件必须一起做的事：
//  - **给我们的粘贴板历史加闸门**（`HistoryClipboardManager.beginRecordingPause`）。不加的话
//    哨兵那一写、⌘C 那一写、还原那一写会被自家监听记成三条用户复制，历史里全是脏条目。
//  - **不自激**：我们投出去的 ⌘C 会进全局事件流，App 层那只快捷键监听（`ShortcutMonitor`）
//    也在收键。只要用户把气泡快捷键录成 **单纯 ⌘C**，就成环了：按下 → 读不到 → 代按 ⌘C →
//    监听又命中 → 又读不到……这条由 `SelectionBubbleSettings.canUseCopyFallback` 那句纯函数挡死，
//    比「加个冷却时间」准得多（冷却只把环变慢，没拆掉）。
//
//  **别在主线程调 `read(from:)`**：里面既有跨进程的键注入，也有轮询等待（最坏 `pollTimeout`）。
//  调用点是 `AXSelectedTextReader`，它已经跑在后台队列上，手势的 HID 回调不在那条队列上 ——
//  这是这条功能划的死线，见 `SelectionBubbleController` 文件头那四条理由。
//
//  接缝（`pasteboard` / `postCopyKeys` / `frontmostPID` / `ownPID` / `suppression` / `sleep`）
//  不是为了好看：`swift test` 这个进程里没有「另一个真在前台并且真选中了字」的 App，
//  而这一段被测的恰恰是**次序**（先抄后写、写哨兵再投键、投了才轮询、无论成败都还原）。
//  次序写错从界面上只看得到两件事：「邮件还是不弹」或者「我刚才复制的东西不见了」，
//  前者不伤人不后者伤。真注入那一段（`postCopyKeysToSession`）只能装机时看日志确认，不假装测过。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Storage

/// 一项粘贴板内容：类型 → 原始字节。够把「用户原来复制的是什么」原样搬回去，
/// 不需要懂任何一类的语义（文本、RTF、图片都按字节走）。
public typealias SelectionPasteboardContent = [NSPasteboard.PasteboardType: Data]

/// 粘贴板这件事的接缝：真实现是 `SystemPasteboard`，测试给一个按脚本答复的假对象。
///
/// 为什么不给一个 `NSPasteboard` 本身：`NSPasteboard.general` 是**用户那一份**，
/// 单测往里写一次就把他刚复制的东西顶掉了 —— 那是拿用户数据换覆盖率。
/// `SystemPasteboardTests` 那几条真调用只碰一个 `NSPasteboard(name:)` 自建实例。
public protocol SelectionPasteboarding: AnyObject {
    /// 粘贴板的变化序号：每一次有人写它都会变大。这一手成败全靠它，不靠内容比对。
    var changeCount: Int { get }
    /// 当前有没有文件 URL。动手前判它是为了「别把用户的文件复制弄坏」，动手后判是为了「别把路径当文字弹出来」。
    var holdsFileURLs: Bool { get }
    /// 当前那份纯文本；没有文本类型返回 nil。
    func text() -> String?
    /// 把每一项的每一种类型抄下来，供之后还原。
    func snapshot() -> [SelectionPasteboardContent]
    /// 清空并写一条哨兵。返回有没有写上。
    func writeSentinel(_ text: String) -> Bool
    /// 清空并还原这些内容。空数组表示「原本就是空的」，那时只清空。返回有没有写上。
    func restore(_ content: [SelectionPasteboardContent]) -> Bool
}

/// 「代按 ⌘C 取字」这件事的接缝，`AXSelectedTextReader` 认这一个协议就够。
public protocol SelectionCopyReading {
    /// `pid` 为 nil 表示「按当下前台那一档来」：快捷键那一路读的是系统级焦点，本来就不认是谁。
    func read(from pid: pid_t?) -> SelectedTextResult
}

/// 真实现。
public final class SelectionCopyReader: SelectionCopyReading {
    // MARK: 接缝

    /// 粘贴板。测试给一个假对象，就能把「先抄→写哨兵→投键→轮询→还原」这一串钉死。
    var pasteboard: SelectionPasteboarding = SystemPasteboard()
    /// 投一次 ⌘C。真实现是 `postCopyKeysToSession`；测试给一个「一投就让假粘贴板长出一个新值」的脚本。
    /// 返回有没有投出去。
    var postCopyKeys: () -> Bool = { SelectionCopyReader.postCopyKeysToSession() }
    /// 此刻谁在前台。测试里想摆谁摆谁 —— 真前台在这台机器上是碰巧是谁就是谁，
    /// 「切了 App 就不许再投键」这一条拿它当判据会做出「今天绿明天红」的用例。
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    /// 我们自己的进程号。单独开一个口子：`swift test` 那个进程本身就是「别的 App」，
    /// 直接用 `NSRunningApplication.current` 判的话，测试里「认出自己」恒真，一条也测不出来。
    var ownPID: () -> pid_t = { NSRunningApplication.current.processIdentifier }
    /// 粘贴板历史的闸门。默认接 Storage 那份引用计数实现（生产里监听实例不止一个）。
    var beginSuppression: () -> Void = { HistoryClipboardManager.beginRecordingPause() }
    var endSuppression: () -> Void = { HistoryClipboardManager.endRecordingPause() }
    /// 投完键之后怎么等。真实现是 `usleep`；测试给一个空转，
    /// 否则「对方压根没响应」那一档每跑一次就真等 `pollTimeout`，一百个用例就是白等几十秒。
    var sleep: (TimeInterval) -> Void = { usleep(UInt32($0 * 1_000_000)) }
    /// 这一手最坏等多久。判据（`worstCaseWaitSeconds`）和用例都从这里取，别两处各写一个数。
    var pollTimeout: TimeInterval = SelectionCopyReader.pollTimeoutCeiling

    // MARK: 阈值

    /// C 的 ANSI 虚拟键码（HIToolbox/Events.h：kVK_ANSI_C = 8）。
    static let copyKeyCode: UInt16 = 8
    /// V 的 ANSI 虚拟键码（kVK_ANSI_V = 9）。「打开网页 AI 后自动贴一次」投的是这一键，
    /// 而 `SelectionBubbleSettings.isPlainCommandV` 比的是同一个数 —— 两处必须一个来源，
    /// 否则改了投的那一键、拆环那一条就在比一把没人投的键（和 ⌘C 那对完全同理）。
    static let pasteKeyCode: UInt16 = 9

    /// 投完 ⌘C 最多等这么久。
    /// 依据是「一次复制的落地时间」：本地控件的 ⌘C 是同步写粘贴板的，几十毫秒量级；
    /// 等满还不写就是这一手白搭（对方把 ⌘C 绑去了别的事，或者压根没有选中东西）。
    /// 再长就会把「不弹」拖成「划完词卡半天」——注意这一手只在**本来就不弹**的那条路上，
    /// 所以慢一点只是让「也许能弹」多等一会儿，见 `AXSelectedTextReader.worstCaseWaitSeconds`。
    static let pollTimeoutCeiling: TimeInterval = 0.35

    /// 轮询间隔。20 毫秒 = 一次复制的两个数量级余量里再取一档， CPU 忽略不计。
    static let pollInterval: TimeInterval = 0.02

    /// 原来粘贴板没有文本时写进去的那串。它的用途只是「让 `changeCount` 先跳一格」，
    /// 所以内容无所谓；会露出来的唯一场景是用户恰好在这一秒里按了 ⌘V。
    static let sentinelMarker = "MacStrokeSelectionProbe"

    // MARK: 一次只跑一路

    /// 有没有正跑着的这一手。两路同时在动粘贴板会互相踩：后一手把前一手抄的快照当成新内容还原回去。
    /// 快速连划两下真能碰上（每一次松手都排一次读取，而这一手要等 `pollTimeout`）。
    private static let claimLock = NSLock()
    private static var copyHandInFlight = false

    /// 占位：没有人在跑就占住并返回 true。用**函数**而不是直接改属性，是为了「判 + 改」在一把锁里做完 ——
    /// 分开写就是两个线程都读到 false 然后都投一遍 ⌘C。
    static func claimCopyHand() -> Bool {
        claimLock.lock()
        defer { claimLock.unlock() }
        if copyHandInFlight { return false }
        copyHandInFlight = true
        return true
    }

    static func releaseCopyHand() {
        claimLock.lock()
        defer { claimLock.unlock() }
        copyHandInFlight = false
    }

    /// 测试复位用：用例之间不该共享上一个用例留下的「正在跑」。
    public static func resetCopyHandForTesting() { releaseCopyHand() }

    // MARK: - 主流程

    public func read(from pid: pid_t?) -> SelectedTextResult {
        let target = pid ?? frontmostPID()
        guard let targetPID = target else {
            NSLog("%@", "[SelectionBubble] 代按 ⌘C 跳过：认不出前台应用")
            return .unavailable(.copyTargetNotFrontmost)
        }
        // 闸 4（上半）：不打到自己身上。见文件头。
        guard targetPID != ownPID() else {
            NSLog("%@", "[SelectionBubble] 代按 ⌘C 跳过：前台是 MacStroke 自己，不能把正在编辑的框抄进粘贴板")
            return .unavailable(.copyTargetNotFrontmost)
        }
        // 闸 4（下半）：字是刚才那个 App 的，键不能打到现在这个头上。
        // 这一判和 `SelectionBubbleController.readNow` 那句「读回来时前台已经换人就作废」是同一件事，
        // 区别是这里在**投键之前**判 —— 投错了收不回来。
        guard frontmostPID() == targetPID else {
            NSLog("%@", "[SelectionBubble] 代按 ⌘C 跳过：前台已从 pid=\(targetPID) 换人")
            return .unavailable(.copyTargetNotFrontmost)
        }
        // 闸 3（上半）：护着用户的文件复制。见文件头。
        guard !pasteboard.holdsFileURLs else {
            NSLog("%@", "[SelectionBubble] 代按 ⌘C 跳过：粘贴板上现在是文件，回放不保证还能贴出同一个文件")
            return .unavailable(.copyBlocked)
        }
        // 两路同时在动粘贴板 = 互相踩，后一手直接放弃（不是失败，是不做）。
        guard Self.claimCopyHand() else {
            NSLog("%@", "[SelectionBubble] 代按 ⌘C 跳过：已经有一路在动粘贴板")
            return .unavailable(.copyBlocked)
        }
        defer { Self.releaseCopyHand() }

        let snapshot = pasteboard.snapshot()
        beginSuppression()
        // 闸 2：**无论走到哪一支都要还原**，包括「投了键没反应」「读回来没有文本」和
        // 将来有人往里加一句 `return`。写成 defer 是因为这一段的返回值有五条，
        // 五条各补一句还原迟早漏一条 —— 漏的那一条的表现是「用户刚才复制的东西没了」，
        // 那是这一手最坏的失败模式，比不弹严重得多。
        defer {
            if !pasteboard.restore(snapshot) {
                NSLog("%@", "[SelectionBubble] 粘贴板还原失败：这一手把原来复制的内容弄丢了")
            }
            endSuppression()
        }

        guard pasteboard.writeSentinel(Self.sentinelText(from: pasteboard.text())) else {
            NSLog("%@", "[SelectionBubble] 代按 ⌘C 跳过：哨兵写不上粘贴板")
            return .unavailable(.copyBlocked)
        }
        // 记下哨兵那一写的序号：之后的判据是「比它大」，也就是**必须有别人写过**。
        // 不先跳这一格的话，对方压根没响应时我们会把用户原来的内容当成「这次选中的字」读回来。
        let mark = pasteboard.changeCount

        guard postCopyKeys() else {
            NSLog("%@", "[SelectionBubble] 代按 ⌘C 跳过：键盘事件造不出来 / 投不出去")
            return .unavailable(.copyBlocked)
        }

        let deadline = Date().addingTimeInterval(pollTimeout)
        while pasteboard.changeCount <= mark {
            guard Date() < deadline else { break }
            sleep(Self.pollInterval)
        }
        guard pasteboard.changeCount > mark else {
            // 多半是「压根没选中东西」：多数控件在无选区时 ⌘C 什么都不做。这一条不弹是正确答案。
            NSLog("%@", "[SelectionBubble] 代按 ⌘C 之后粘贴板没动（\(Int(pollTimeout * 1000))ms 内）——按没选中东西处理")
            return .unavailable(.copyNothingCopied)
        }
        // 闸 3（下半）：复制来的是文件，不是字。别把路径当选中文字弹一枚气泡。
        guard !pasteboard.holdsFileURLs else {
            NSLog("%@", "[SelectionBubble] 代按 ⌘C 拿回来的是文件，不是文字，不弹")
            return .unavailable(.copyNotText)
        }
        guard let text = pasteboard.text() else {
            NSLog("%@", "[SelectionBubble] 代按 ⌘C 拿回来的粘贴板里没有文本类型，不弹")
            return .unavailable(.copyNotText)
        }
        let characters = text.count
        NSLog("%@", "[SelectionBubble] 代按 ⌘C 读到 \(characters) 个字符")
        return text.isEmpty ? .nothingSelected : .text(text)
    }

    /// 哨兵写什么：优先写**用户原来那份文本**。
    ///
    /// 这一手的目的不是「拿一段独特的文本去比对」—— 判据是 `changeCount` 而不是内容 ——
    /// 而是「让粘贴板在这一秒里仍然对用户有用」：万一他正好按了 ⌘V，贴出来还是他自己刚才复制的东西，
    /// 而不是一串调试标记。原来没有文本（图片 / 文件 / 空的）时才用那串标记。
    static func sentinelText(from previous: String?) -> String {
        guard let previous, !previous.isEmpty else { return sentinelMarker }
        return previous
    }
}

// MARK: - 真粘贴板

/// 真实现：`NSPasteboard.general`。
///
/// 逐类型回放这件事要说清楚边界：文本、RTF、图片这类**按字节搬回去是等价的**；
/// 「承诺式」类型（对方 App 到 ⌘V 那一刻才现算的那类，比如某些大图的延迟 TIFF）
/// 被 `data(forType:)` 一读就会**当场物化** —— 内容不失真，但物化要花时间的东西会花我们的时间。
/// 所以这一手只在后台队列上跑，而且上面那道文件 URL 的闸已经把最容易出问题的情形挡掉了。
public final class SystemPasteboard: SelectionPasteboarding {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public var holdsFileURLs: Bool { pasteboard.types?.contains(.fileURL) ?? false }

    public func text() -> String? { pasteboard.string(forType: .string) }

    public func snapshot() -> [SelectionPasteboardContent] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var content = SelectionPasteboardContent()
            for type in item.types {
                if let data = item.data(forType: type) { content[type] = data }
            }
            return content
        }
    }

    public func writeSentinel(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    public func restore(_ content: [SelectionPasteboardContent]) -> Bool {
        // 空快照 = 原来粘贴板就是空的：只清，别拿 `writeObjects([])` 去报错。
        guard !content.isEmpty else {
            pasteboard.clearContents()
            return true
        }
        let items: [NSPasteboardItem] = content.map { content in
            let item = NSPasteboardItem()
            for (type, data) in content { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }
}

// MARK: - 投键

public extension SelectionCopyReader {
    /// 往 **session 层**投一次 ⌘C（按下 + 抬起）。
    ///
    /// 为什么走 session 而不是 HID：本项目的既有结论 —— 投到 `.cghidEventTap` 要先穿过
    /// 我们自己那只 head-insert 的 HID tap，而那一刻回调还没返回，实测动作晚 120ms
    /// （`ActionExecutor` 同一段注释、issue #68）。走 session 还有一条更要紧的：
    /// 它**不经过**那棵 HID 树，所以「识别执行和时间不要受到影响」那条死线一点没动。
    ///
    /// 返回值只说「两个事件都造出来并投出去了」。对方吃不吃是另一件事，
    /// 由上面那次轮询来判（`copyNothingCopied`）。
    static func postCopyKeysToSession() -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: copyKeyCode, keyDown: true) else {
            return false
        }
        down.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: copyKeyCode, keyDown: false) else {
            // 按下已经投出去了，抬起必须补上：漏一次抬起在对方看来就是 ⌘C 一直按着。
            // 键码固定是 C，没有后续判断，所以这里不改成「投到 half 状态就不做」那种分支。
            return false
        }
        up.flags = .maskCommand
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// 往 **session 层**投一次 ⌘V（按下 + 抬起），给「打开网页 AI 后自动贴一次」用。
    ///
    /// 走 session 的理由和上面那一句一模一样：不穿过我们自己那只 head-insert 的 HID tap，
    /// 所以「识别执行与耗时不许受影响」那条死线没动。
    ///
    /// **这一手不需要 ⌘C 那套轮询与还原**：⌘C 是「投出去再把它取回来的东西读掉」，那是取词；
    /// ⌘V 只是把已经在那儿的一句交给前台，读不到结果也不需要重试。它要的是另一样东西 ——
    /// **投之前那道闸**（见 `SelectionBubbleSettings.pasteGate`），因为贴的目标是
    /// 「此刻前台那个窗口」，而我们没法确知网页已经把光标落进输入框了没有。
    static func postPasteKeysToSession() -> Bool {
        guard let events = pasteEvents() else { return false }
        events.down.post(tap: .cgSessionEventTap)
        // 同 ⌘C 那一句：按下已经投出去了就必须补抬起，不然前台看到的是 ⌘V 一直按着。
        events.up.post(tap: .cgSessionEventTap)
        return true
    }

    /// 那两下 ⌘V 的本体，抽出来是为了**能被单测咬住**：投到哪一层（session / HID）在测试进程里
    /// 看不见，但「投的是 V 这一键、带的修饰键只剩 ⌘、按下和抬起都在」这三件事可以。
    ///
    /// 为什么值得为它拆一层：写坏的方式恰好是另外几层看不到的那几种 —— 漏掉 `.maskCommand`
    /// 就成了往别人的输入框里打一个字母「v」；键码抄成 8（C）就成了再替用户复制一次，
    /// 把他刚复制的东西覆盖掉。这两样只会装在真机上暴露，而这里一条断言就能提前抓住。
    static func pasteEvents() -> (down: CGEvent, up: CGEvent)? {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: pasteKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: pasteKeyCode, keyDown: false)
        else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return (down, up)
    }
}
