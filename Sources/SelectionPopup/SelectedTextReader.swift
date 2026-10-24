//
//  SelectedTextReader.swift
//  MacStroke
//
//  用 macOS 无障碍接口读「当前选中的文字」。
//
//  为什么只有这一条路：别的做法都被更硬的条件挡住了 —— 借剪贴板（先⌘C再读回来）要往真实
//  登录会话里注键、还会污染用户的粘贴板；`AccessibilitySharedContent` 是 macOS 15 才有，
//  我们的部署门槛是 13；Vision 认的是屏幕像素里的字，那是截图那条线已经在做的事
//  （`ScreenshotOCR.swift`）；`NSServices` 要用户主动从菜单里点，不是自动弹。
//  无障碍读取只要辅助功能授权，而 MacStroke 本来就要求它（`main.swift` 里那道
//  `AXIsProcessTrustedWithOptions` 的门），所以这一步不多要任何权限。
//
//  五类已知读不出来的情况，在这里分类而不是笼统返回 nil，因为界面上「不弹」是同一个动作，
//  日志里必须看得出为什么：
//  1. 安全输入 / 密码框（Secure Input）→ 读回来是空，属于正常，按「选区为空」记。
//  2. Chromium / Electron 那一类：没启用无障碍接口前压根不暴露选区 → 见 `requestAccessibility`。
//  3. SwiftUI 的 TextField / TextEditor：历史上这一属性就是不实现 → 记 unsupported，不重试开接口。
//  4. 焦点元素拿到了、但它是**容器**（Chrome 的 `AXWebArea`、表格里那一行 `AXRow`）：
//     选区在它的子树里，容器自己不应 `kAXSelectedTextAttribute`。这一类改读「鼠标松手那个点
//     命中的元素」并往父级上溯（`readAtPoint`）—— 装机第一轮 Chrome 与信息全卡在这一档。
//  5. **邮件正文那一类**（WebKit 自己绘制的正文视图）：上面那四手全走完也拿不到字。
//     装机第五轮拿真探针把它的树扒了个遍（1494 格）：`AXSelectedText` / `AXSelectedTextRange` /
//     `AXSelectedTextRanges` / `AXMarkedTextRange` / `AXSelectedChildren` 五样对 `AXWebArea`
//     全报 -25212，祖先报 -25205，没有一格带 `AXSelected`，唯一答 code=0 的那格（窗口往下第 6 层
//     的 `AXTextArea`）返回**空串** —— 选区在容器的**下面**，往上溯多少层都碰不到。
//     这一类是这条链的**终点**：再往上加层数只是拿超时换概率，出路是代按一次 ⌘C
//     （`SelectionCopyReader`，四道闸写在那份文件头）。
//
//  **别在主线程调 `read()`**：`AXUIElementCopyAttributeValue` 是同步往返到目标进程的调用，
//  对方卡住时这边一起卡。手势的 HID 回调跑在主运行循环上，主线程一堵「识别执行和时间」就受
//  影响 —— 那是这条功能划的死线。控制器把它丢到后台队列，读完再回主线程弹气泡。
//  最后那一手代按 ⌘C 同样只在这条后台队列上跑（它要等对方写粘贴板，最坏 `pollTimeout`）。
//

import AppKit
import ApplicationServices

/// 一次读取的结果。三种情况要分开：有字、真没选东西、读不到。
public enum SelectedTextResult: Equatable {
    case text(String)
    /// 无障碍接口答上来了，但选区是空的（没选中，或者落在安全输入/密码框里）。
    case nothingSelected
    /// 压根没答上来，带原因。
    case unavailable(Unavailable)

    public enum Unavailable: Equatable {
        /// 这个 App 没把无障碍接口打开（-25211）。Chromium 那一类在写
        /// `AXManualAccessibility` 之前就是这一档。
        case accessibilityNotEnabled
        /// 焦点元素取不到：没有焦点元素，或者那个元素已经作废。
        case noFocusedElement
        /// 焦点元素在，但它没有「选中文字」这个属性（-25205：SwiftUI 的文本框、自绘控件）。
        case selectedTextUnsupported
        /// 焦点元素在、属性也在，但它**当前没有选区值**（-25212 = kAXErrorNoValue）。
        /// 装机第一轮 Chrome 与信息就是这个外观：焦点给的是容器（`AXWebArea`、`AXRow`），
        /// 选区在子树里的某个孩子身上，容器自己不应这一属性。和上一条是两种病 ——
        /// 上一条修不了，这一条可以靠「读鼠标点命中的元素」绕过去。
        case noSelectedTextValue
        /// 鼠标点那个位置压根没命中被划 App 的元素（命中的是我们自己的气泡，或别的覆盖层）。
        case noElementUnderCursor
        /// 调用超时：目标 App 没在这个时间内答话。
        case timedOut
        /// 其余错误码原样留着，装机取证时按码分类。
        case apiError(Int)

        // 下面四档**只有代按 ⌘C 那一路会报**（`SelectionCopyReader`），无障碍那几手永远不产生它们。
        // 为什么不并成一档「这一手没做成」：这四件事的修法完全不同 ——
        // 换人是时序问题、被闸挡掉是设计如此、没动是「压根没选中东西」、没有文本是「复制来的是图片」。
        // 装机按 App 统计时把它们混成一句，就会得出「这一手在某些 App 里不灵」这种没用的结论。
        /// 目标进程不在前台（或就是我们自己）：键不能投给别人，这一手压根没开始。
        case copyTargetNotFrontmost
        /// 这一手被自己的安全闸挡掉了（粘贴板当前是文件 / 已经有一路在动粘贴板 /
        /// 哨兵写不上 / 键投不出去）。具体哪一条进日志，见 `SelectionCopyReader` 里那四句 `NSLog`。
        case copyBlocked
        /// 投了 ⌘C，粘贴板在 `pollTimeout` 内一次都没变。**多半是压根没选中东西**——
        /// 多数控件在无选区时 ⌘C 什么都不做，所以这一档不弹是正确答案。
        case copyNothingCopied
        /// 粘贴板变了，但里面没有可用的文本（图片、文件、或者只有富文本而没有纯文本档）。
        case copyNotText

        /// 进日志的那一句话。失败原因放在这一层而不是结果层，是因为「代按那一手」拿到的是
        /// 无障碍那一次的失败原因（`copyHand` 要拿它归因），结果层再拆一遍就是两份会漂移的表。
        public var logReason: String {
            switch self {
            case .accessibilityNotEnabled:
                return "该 App 未启用无障碍接口"
            case .noFocusedElement:
                return "取不到焦点元素"
            case .selectedTextUnsupported:
                return "该控件没有选中文字属性"
            case .noSelectedTextValue:
                return "焦点元素当前没有选区（选区可能在它的子树里）"
            case .noElementUnderCursor:
                return "鼠标点没命中这个 App 的元素"
            case .timedOut:
                return "无障碍调用超时"
            case .apiError(let code):
                return "无障碍调用失败 code=\(code)"
            case .copyTargetNotFrontmost:
                return "前台已换人（或就是我们自己），没有代按"
            case .copyBlocked:
                return "代按这一手被安全闸挡掉"
            case .copyNothingCopied:
                return "代按 ⌘C 后粘贴板没动"
            case .copyNotText:
                return "代按 ⌘C 拿回来的不是文字"
            }
        }
    }

    /// 进日志的那一句话。
    public var logReason: String {
        switch self {
        case .text(let value):
            return "读到 \(value.count) 个字符"
        case .nothingSelected:
            return "选区为空"
        case .unavailable(let reason):
            return reason.logReason
        }
    }

    /// 只有 `.text` 这一支拿得到字符串，判定层要用。
    public var string: String? {
        if case let .text(value) = self { return value }
        return nil
    }
}

/// 「读选中文字」这件事的接缝：真实现走无障碍，测试实现直接给一个结果。
public protocol SelectionTextReading {
    func read() -> SelectedTextResult
    /// 这一趟最终从哪一档来源读到的字（只进日志，装机按 App 统计「读得到吗」要用它）。
    /// 假件不实现就是 nil，日志里那句会写「来源未记」。
    var answeredFrom: AXSelectedTextReader.Scope? { get }
}

public extension SelectionTextReading {
    var answeredFrom: AXSelectedTextReader.Scope? { nil }
}

/// 真实现：无障碍接口。
///
/// 三种来源：
/// - `.application(pid)`：某个具体 App 的焦点元素。松手自动弹走这条 —— 我们要的就是
///   「刚才被划的那一下属于谁」。
/// - `.systemWide`：整个系统当前关注的元素。手动快捷键走这条 —— 按下去的时候不关心是谁，
///   当前焦点上有字就读出来（键盘选字 ⌥⇧→ 那类根本不产生左键事件，只有这条路能叫出气泡）。
/// - `.atPoint(pid, point)`：焦点元素是容器那一档的补救（见文件头第 4 条）。
/// - `.viaCopy(pid)`：**不是无障碍来源**，字是代按 ⌘C 从粘贴板拿回来的（见 `SelectionCopyReader`）。
///   它只作为「这一趟最终是从哪儿拿到字的」那一格记进日志，没人拿它去调 `AXUIElementCopyAttributeValue`。
public final class AXSelectedTextReader: SelectionTextReading {
    /// `Equatable` 是给取证的：用例要核对「自动弹那一支读的是哪个进程、快捷键那一支读的是不是
    /// 整个系统」，比不出来就只能断言「读过一次」，等于没核对来源。
    public enum Scope: Equatable {
        case application(pid_t)
        case systemWide
        /// 鼠标点那一带的元素树：从 `AXUIElementCopyElementAtPosition` 命中的那个元素出发，
        /// 沿 `kAXParentAttribute` 往上找真正持有选区的元素。第一个必须是 `pid` 自己的，
        /// 否则打到的可能是我们那枚还没收掉的气泡。
        case atPoint(pid_t, CGPoint)
        /// 代按 ⌘C 那一路。pid 可空：快捷键那一条读系统级焦点时压根没有「是谁」这一个说法，
        /// 键投给当下前台，日志里也就只能说「从粘贴板拿的」，不必编一个进程号出来。
        case viaCopy(pid_t?)

        /// 只给日志用：装机按 App 统计「读得到读不到」时要说清楚是哪一档来源中的。
        var logLabel: String {
            switch self {
            case .application: return "App 焦点元素"
            case .systemWide: return "系统级焦点元素"
            case .atPoint: return "鼠标点命中的元素"
            case .viaCopy: return "代按 ⌘C 取回"
            }
        }
    }

    /// 一次调用里出错的位置。同一个错误码在两处含义不同：焦点元素那一读失败是「这个 App
    /// 现在没焦点对象」，选中文字那一读失败是「这个控件不给选区」。
    private enum Stage { case focusedElement, selectedText }

    private let scope: Scope
    /// 松手那一点的屏幕坐标（AppKit 那套「左下原点」），`.atPoint` 那一手要用。
    /// nil 表示这一趟没有坐标 —— 快捷键那一条读的是系统级焦点，本来就不靠鼠标位置。
    private let anchor: CGPoint?
    /// internal 而不是 private：取证要核对「默认超时确实来自那个偏好常量」。
    /// 两处各写一个 0.6 的话，改偏好那一档时这里会静默地不跟着变。
    let timeout: TimeInterval
    /// 这一趟真读到字的那一档来源，只给日志用（`SelectionTextReading.answeredFrom`）。
    /// 记在 reader 上而不是返回值里：`SelectedTextResult` 是判据的核心，加一个字段要动的
    /// 地方比这多得多，而这条只是诊断。
    public private(set) var answeredFrom: Scope?
    /// 接缝：读一个来源的选区。真实现走 `readReal`，测试给一个按脚本答复的假对象。
    /// 为什么非抽不可：失败之后**按什么次序补救**（先请开接口再重读那一棵，还是换系统级那一份）
    /// 是这一段唯一的逻辑，而它在 `swift test` 里靠真 App 一次也演不出来 —— 那要有辅助功能授权、
    /// 要有个真在前台并且真选中了什么的进程。次序写错（比如 Chrome 那条：第一条开关被拒之后
    /// 就不试第二条）从界面上看和「这个 App 就是不弹」一模一样。
    var readSourceOverride: ((Scope) -> SelectedTextResult)?
    /// 接缝：往某个进程的某个属性上写 `true`，返回有没有写上。真实现是 `writeEnableAttribute`。
    var enableOverride: ((pid_t, String) -> Bool)?

    /// 接缝：无障碍**全部落空**之后的最后一手 —— 代按 ⌘C 从粘贴板取词。
    /// nil（默认）就是不上这一手：测试里那些「按脚本答复」的假读取不受影响，
    /// 真机上由控制器按偏好决定要不要递一个进来（`SelectionBubbleSettings.canUseCopyFallback`）。
    /// 为什么挂在 reader 上而不是控制器上：「哪一档失败值得走到这一手」是这条链的判据，
    /// 和上面那三手同一个性质 —— 挪到控制器就要把 `Unavailable` 那八档再抄一遍出去，
    /// 而抄的那一份在 `swift test` 里咬不住任何东西。
    var copyFallback: SelectionCopyReading?

    public init(scope: Scope, anchor: CGPoint? = nil,
                timeout: TimeInterval = SelectionBubbleSettings.messagingTimeout) {
        self.scope = scope
        self.anchor = anchor
        self.timeout = timeout
    }

    public func read() -> SelectedTextResult {
        switch scope {
        case .systemWide:
            // 快捷键那一条没有**无障碍**补救：它读的就是系统级那一份，再往系统级读一遍还是同一个元素。
            // 但这一路照样能上最后一手 —— 键盘选字（⌥⇧→ 那一类）在邮件里同样读不到，
            // 而那正是代按 ⌘C 唯一干得动的地方。pid 给 nil：按下时不认是谁，键投给当下前台。
            let ax = read(from: .systemWide)
            guard case let .unavailable(reason) = ax, Self.shouldCopyInstead(reason) else { return ax }
            return copyHand(after: ax, reason: reason, pid: nil)
        case .atPoint:
            // `.atPoint` 只作为**补救的那一手**出现（由下面 `.application` 那一支发出来），
            // 没人拿它当初始 scope。真有人这么建一个 reader 时也照样读一次，别 fatalError。
            return read(from: scope)
        case .viaCopy:
            // 同上，而且这一档更不该被当初始 scope：它是「这一趟从哪儿拿到字」那一格，
            // 不是一处**读的来源**。`readReal(from:)` 里它直接返回失败，不会去调任何 AX 属性。
            // 写开这一支的唯一理由是别让人绕过链子凭空建一个 `.viaCopy` 的 reader 然后崩在这儿。
            return read(from: scope)
        case .application(let pid):
            let ax = readViaAccessibility(pid: pid)
            guard case let .unavailable(reason) = ax, Self.shouldCopyInstead(reason) else { return ax }
            return copyHand(after: ax, reason: reason, pid: pid)
        }
    }

    /// 无障碍那几手：首读 + 上场的那一手补救。原样从 `read()` 里搬出来，
    /// 搬的目的只有一个 —— 让「代按那一手」在**链子外面**接，而不是在预算里再挤一格。
    /// 这一手不是跨进程往返，不该占 `maximumReadAttemptsOnTheFailurePath` 那一格，
    /// 也不该改动那两条钉住回数的判据。
    private func readViaAccessibility(pid: pid_t) -> SelectedTextResult {
        // 失败这条路上每一格预算 = 一次跨进程往返，扣完就不许再往下试。
        // 首读占一格，后面每补救一手占一格，所以「最坏等多少超时」只有下面那个数说了算。
        var budget = Self.maximumReadAttemptsOnTheFailurePath
        let first = read(&budget, from: .application(pid))
        guard case .unavailable(let reason) = first, Self.shouldAskAgain(reason) else {
            return first
        }
        // 补救按「便宜且不打扰对方」排在前面，而且**只上场一手**：
        // 1) 请对方开无障碍接口，开成了就立刻再读一遍这一棵（Chromium 那一类靠这一步）；
        // 2) 焦点元素是容器那一档：改读「鼠标松手那个点命中的元素」并往父级上溯
        //    （Chrome 的 AXWebArea、信息的正文都是这个外观，装机第一轮全卡在这）；
        // 3) 换「整个系统当前关注的元素」再读一次（有的桥接层在 App 元素上不答焦点，
        //    系统级那一份却有）。
        // 读到的是后台线程，而且走到这里本来就没打算弹，慢一点不伤手感；伤手感的是
        // 「弹出来的那一档」，那一档只有第一次读，见 `testWorstCaseLatencyStaysUnderASinglePerceptibleBeat`。
        if Self.shouldRequestAccessibility(reason), requestAccessibility(pid: pid) {
            guard budget > 0 else { return first }
            let second = read(&budget, from: .application(pid))
            if !isFailure(second) { return second }
            // 开接口这件事是**异步**的：对方收到开关后要现建一棵树，这一笔肯定来不及。
            // 装机日志实测过（Electron：写成功那一句立刻重读还是失败，6 秒后下一次划词才成）。
            // 所以这里不假装能救回这一次划词，只把「下一次再来」说清楚，并且**不再**去读系统级：
            // 对方连树都还没建，换一份来源读到的还是那句「没有焦点元素」，白排一次队。
            NSLog("%@", "[SelectionBubble] pid=\(pid) 的无障碍树还在建，这一次划词不弹；下一次划词再读")
            return second
        }
        if Self.shouldProbeUnderTheCursor(reason), let anchor {
            guard budget > 0 else { return first }
            let probe = read(&budget, from: .atPoint(pid, anchor))
            if !isFailure(probe) { return probe }
            // 上溯到顶也没人答选区：报**第一次**的错。装机要统计的是「在这个 App 里划词
            // 为什么不弹」，而第一次那一句带着焦点元素的 role，比「鼠标点没命中」有信息量。
            NSLog("%@", "[SelectionBubble] pid=\(pid) 鼠标点那一棵也没答出选区，报焦点那一次的错")
            return first
        }
        guard budget > 0, Self.shouldRetrySystemWide(reason) else { return first }
        let viaSystem = read(&budget, from: .systemWide)
        // 系统级那一份读到了就用它。读不到还是报 App 那一次的错：两次的失败原因可能不同，
        // 而装机要按第一次归因 —— 我们要修的是「在这个 App 里划词」，不是「在系统级元素上读」。
        return isFailure(viaSystem) ? first : viaSystem
    }

    /// 最后一手上场。`ax` 是无障碍那一次报出来的结果，`reason` 是它的失败原因。
    ///
    /// 拿不到字时**仍然报无障碍那一次的错**，和上面「按第一次归因」同一条规矩：
    /// 装机统计的是「在这个 App 里划词为什么不弹」，而这一手失败的原因（没响应 / 不是文本）
    /// 是我们自己那条腿的外观，不是那个 App 的。两句都进日志，缺一句就没法分清
    /// 「这一手压根没上场」和「上场了但白跑」。
    private func copyHand(after ax: SelectedTextResult, reason: SelectedTextResult.Unavailable,
                          pid: pid_t?) -> SelectedTextResult {
        guard let copyFallback else { return ax }
        let viaCopy = copyFallback.read(from: pid)
        if case .text = viaCopy {
            answeredFrom = .viaCopy(pid)
            return viaCopy
        }
        if case .nothingSelected = viaCopy {
            // 对方答了「这一回 ⌘C 什么也没复制」= 压根没选中东西。这是**一个答复**，
            // 比「这个控件不给选区」有用：装机时这一档该归「没选东西」，不是「这个 App 读不到」。
            return viaCopy
        }
        NSLog("%@", "[SelectionBubble] 代按 ⌘C 这一手也没拿到字（\(viaCopy.logReason)），仍按无障碍那一次归因：\(reason.logReason)")
        return ax
    }

    /// 一次划词最多做几回跨进程读取：首读 1，加上**上场的那一手补救** 1。
    /// 两手上不了两次台 —— 请开接口写成功了就只重读那一棵，两笔开关都被拒才换系统级那一份。
    /// 这个数字是**代码在用的**（`read(_:from:)` 每读一次扣一格，扣完不再往下试），不是注释：
    /// 有人要往里加一手，光加调用不加格数是加不动的；而格数跟着加的话，乘上 `messagingTimeout`
    /// 有多久，`testWorstCaseLatencyStaysUnderASinglePerceptibleBeat` 钉的就是那个乘积，
    /// `testTheRecoveryStopsAtTheDocumentedNumberOfReads` 钉的是读到的回数。
    static let maximumReadAttemptsOnTheFailurePath = 2

    private func read(_ budget: inout Int, from source: Scope) -> SelectedTextResult {
        budget -= 1
        return read(from: source)
    }

    private func read(from source: Scope) -> SelectedTextResult {
        let result = readSourceOverride?(source) ?? readReal(from: source)
        // 只有真读到字才记来源：`.nothingSelected` 与失败都继续往下走补救，记了会指错地方。
        if case .text = result { answeredFrom = source }
        return result
    }

    private func isFailure(_ result: SelectedTextResult) -> Bool {
        if case .unavailable = result { return true }
        return false
    }

    // MARK: - 内部

    /// 真读一次：按来源建元素、上消息超时、走两步。
    ///
    /// 消息超时对整棵元素树生效，先设再读：不设的话一个卡住的 App 能把后台线程一直
    /// 挂着 —— 无障碍调用没有「读不到就返回」这一说，只有超时。
    private func readReal(from source: Scope) -> SelectedTextResult {
        switch source {
        case .application(let pid):
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, Float(timeout))
            return readVia(focusedSource: element)
        case .systemWide:
            let element = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(element, Float(timeout))
            return readVia(focusedSource: element)
        case .atPoint(let pid, let point):
            return readAtPoint(pid: pid, appKitAnchor: point)
        case .viaCopy:
            // 这一档**不从无障碍读**：字是 `copyHand` 直接拿回来的，记进 `answeredFrom` 只为日志归因。
            // 真有人把它当来源来读时按「读不到」收尾，别 fatalError —— 同 `.atPoint` 那一条的规矩。
            return .unavailable(.noSelectedTextValue)
        }
    }

    /// 这一档失败值不值得再补救一次。`timedOut` 不在里面：对方压根没答话，
    /// 再问两次还是白等，而且第二次的等待会把这一笔拖到用户已经忘了自己划过字。
    /// 代按那四档也不在里面 —— 它们不是「无障碍读不到」，而是「已经走完无障碍去读粘贴板」的结果，
    /// 拿它们回来再走一遍链子就是自问自答。
    static func shouldAskAgain(_ reason: SelectedTextResult.Unavailable) -> Bool {
        switch reason {
        case .accessibilityNotEnabled, .noFocusedElement,
             .selectedTextUnsupported, .noSelectedTextValue: return true
        case .timedOut, .apiError, .noElementUnderCursor,
             .copyTargetNotFrontmost, .copyBlocked, .copyNothingCopied, .copyNotText: return false
        }
    }

    /// 无障碍那几手都落空之后，值不值得再代按一次 ⌘C。
    ///
    /// 这一条**必须**和上面几条各判一次，因为它动的不是同一个东西：前面那些只是往对方身上
    /// 问一句（问不到就算了），这一手要往用户的粘贴板上写两次、还要投一次真键盘事件。
    /// 所以只有「问遍了确实问不到」才配得上它。
    ///
    /// 排除 `timedOut` 和 `apiError`：前者是对方压根没答话（进程卡住），这时候投 ⌘C 过去
    /// 只会让那一手也一起卡住，还白占住用户的粘贴板；后者是没归过类的错误码，
    /// 按「不认识的错就不做有副作用的事」这条通用规矩挡掉。
    /// `noElementUnderCursor` 反而在里面：鼠标点没命中东西不代表那个 App 读不到字，
    /// 覆盖层（我们自己的气泡、别的软件的浮窗）挡住 hit test 是常事。
    static func shouldCopyInstead(_ reason: SelectedTextResult.Unavailable) -> Bool {
        switch reason {
        case .accessibilityNotEnabled, .noFocusedElement, .selectedTextUnsupported,
             .noSelectedTextValue, .noElementUnderCursor: return true
        case .timedOut, .apiError, .copyTargetNotFrontmost, .copyBlocked,
             .copyNothingCopied, .copyNotText: return false
        }
    }

    /// 值不值得去请对方开无障碍接口。「控件不支持选中文字」不在里面：那个控件是拿到手的，
    /// 开接口不会给它凭空长出一个属性。
    static func shouldRequestAccessibility(_ reason: SelectedTextResult.Unavailable) -> Bool {
        reason == .accessibilityNotEnabled || reason == .noFocusedElement
    }

    /// 值不值得改读「鼠标松手那个点命中的元素」。就那一档：焦点元素拿到了、接口也开着，
    /// 但它是个容器（Chrome 的 `AXWebArea`、表格里的 `AXRow`），选区在它子树里的某个孩子上。
    /// 装机第一轮 Chrome 与信息每次划词都停在这里，而旧代码在这一档**什么都不做**就直接返回。
    /// `noElementUnderCursor` 不在里面：那一手本身就是探测，再探测一次还是打不中。
    static func shouldProbeUnderTheCursor(_ reason: SelectedTextResult.Unavailable) -> Bool {
        reason == .selectedTextUnsupported || reason == .noSelectedTextValue
    }

    /// 值不值得换 `AXUIElementCreateSystemWide()` 再读一次。和上一条同一个集合，单开一个函数
    /// 是因为它们各自会被改：接口那一条要按 App 类别收窄，系统级那一条是按错误档收窄。
    static func shouldRetrySystemWide(_ reason: SelectedTextResult.Unavailable) -> Bool {
        shouldRequestAccessibility(reason)
    }

    /// 两步：焦点元素 → 它的选中文字。每步的错误码就地分类，不留「最近一次错误码」这种
    /// 成员变量：调用点是两条顺序读，靠状态传错误码会在中途插一笔时串线。
    private func readVia(focusedSource: AXUIElement) -> SelectedTextResult {
        var elementValue: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(focusedSource,
                                                  kAXFocusedUIElementAttribute as CFString,
                                                  &elementValue)
        guard error == .success, let raw = elementValue,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return .unavailable(Self.classify(Int(error.rawValue), stage: .focusedElement))
        }
        let focused = raw as! AXUIElement

        var textValue: CFTypeRef?
        error = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &textValue)
        guard error == .success, let text = textValue else {
            let reason = Self.classify(Int(error.rawValue), stage: .selectedText)
            // 「焦点元素拿到了，但它不给选区」是信息（Catalyst）那一类的外观，和「压根没焦点元素」
            // 是两种病。多读一个 role 才知道该往哪边修：报 AXTextArea 却不给选区和报 AXGroup
            // 是两个结论，前者是这套桥接层没接通、后者是焦点压根不在文本控件上。
            // 只在失败这一支读，成功的路径不多花一次跨进程往返。
            if Self.shouldProbeUnderTheCursor(reason) {
                NSLog("%@", "[SelectionBubble] \(scopeTag) 焦点元素 role=\(role(of: focused)) 不给选中文字（code=\(Int(error.rawValue))）")
            }
            return .unavailable(reason)
        }
        let string = Self.string(from: text) ?? ""
        return string.isEmpty ? .nothingSelected : .text(string)
    }

    /// 第三手（`.atPoint`）：从「鼠标松手那一点」命中一个元素，然后沿父级往上找真正持有选区的那一格。
    ///
    /// 为什么要往上走：Web 正文里 hit test 打中的常常是最深那格（`AXStaticText`、`AXGroup`），
    /// 它自己不应 `kAXSelectedTextAttribute`，真正管选区的是祖先 `AXWebArea`。只读命中那一格等于白读。
    ///
    /// 为什么要验 pid：命中是按**屏幕位置**算的，压在那一行的可能是我们自己那枚还没收掉的气泡，
    /// 读它会念出 MacStroke 的字；也可能是系统别的覆盖层。
    ///
    /// 这一手用**短超时**（`hitTestProbeTimeout`）：它是白捡的补救，慢就不等，免得把「不弹」
    /// 拖成「划完词卡半天」。整条失败路的最坏耗时由 `worstCaseWaitSeconds` 统一算，取证的延迟判据钉它。
    ///
    /// **邮件（`com.apple.mail`）这一手量过是无效的**，别再朝这个方向加层数：从邮件窗口沿
    /// `AXChildren` 往下扒 260 格，唯一答得出 `kAXSelectedTextAttribute`（code=0）的一格是
    /// `…/AXScrollArea/AXGroup/AXGroup/AXTextArea`（窗口往下第 6 格），而它的**每一格祖先**这一属性报
    /// -25205（不支持）、兄弟 `AXStaticText` 报 -25212。也就是说邮件的选区在容器的**下面**，
    /// 往上走多少格都碰不到。顺带两条同轮实测：正文归邮件自己的 pid，不归 `WebContent` 助手
    /// （助手那头的 App 元素给 0 个孩子），所以第 0 格那道 pid 闸不是邮件的堵点；把邮件的
    /// `AXEnhancedUserInterface` 真写成 1，树一点没变（那根杠杆修好了 Chrome，对邮件无效）。
    /// 见 `docs/selection-popup-plan.md` §12。
    private func readAtPoint(pid: pid_t, appKitAnchor: CGPoint) -> SelectedTextResult {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Float(Self.hitTestProbeTimeout))
        let point = Self.cgPoint(appKit: appKitAnchor)
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard hitError == .success, let rawHit = hit else {
            NSLog("%@", "[SelectionBubble] pid=\(pid) 鼠标点 (\(Int(point.x)), \(Int(point.y))) 没命中元素（code=\(Int(hitError.rawValue))）")
            return .unavailable(.noElementUnderCursor)
        }
        var element = rawHit
        var sawEmptySelection = false
        for level in 0..<Self.maximumElementsProbedAtThePoint {
            // 超时是**按对象**记的（头文件：给某个对象设的超时只对它自己生效，别的对象即使相等也不认），
            // 而命中这一格和它的每一格父级都是新对象 —— 只在 systemWide 上设一次不够，每格都得设。
            // 不设的表现不是「读不到」，是「对方卡住时这一手跟着卡」，那 1.8s 的账就白算了。
            AXUIElementSetMessagingTimeout(element, Float(Self.hitTestProbeTimeout))
            if level == 0, let owner = Self.pid(of: element), owner != pid {
                NSLog("%@", "[SelectionBubble] 鼠标点打到的是 pid=\(owner)，不是 pid=\(pid)；这一手不读别人的元素")
                return .unavailable(.noElementUnderCursor)
            }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
               let value {
                let string = Self.string(from: value) ?? ""
                if !string.isEmpty { return .text(string) }
                // 答了、但是空的：这一格确实「没选东西」。继续往上问，最后一格还是空就按「选区为空」记。
                sawEmptySelection = true
            }
            guard level + 1 < Self.maximumElementsProbedAtThePoint else { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let rawParent = parent, CFGetTypeID(rawParent) == AXUIElementGetTypeID() else {
                break   // 走到根了：按已经拿到的信息收尾
            }
            element = rawParent as! AXUIElement
        }
        return sawEmptySelection ? .nothingSelected : .unavailable(.noSelectedTextValue)
    }

    /// 命中元素属于哪个进程。拿不到就返回 nil：调用方按「没验上」放行（宁可少一次归因，
    /// 也不要把能读到的选区挡掉 —— 拿不到 pid 的只有极少数桥接层）。
    static func pid(of element: AXUIElement) -> pid_t? {
        var value: pid_t = 0
        guard AXUIElementGetPid(element, &value) == .success, value > 0 else { return nil }
        return value
    }

    /// AppKit 的鼠标坐标原点在**主屏左下角**，`AXUIElementCopyElementAtPosition` 要的是 CG 那套
    /// 以主屏**左上角**为原点、y 往下的坐标，所以要按主屏高度翻一下。副屏跟着这套全局坐标走：
    /// 在主屏左边/右边/下面都是同一个翻法（下面那块会得到 y > 主屏高，正是 CG 那一侧的下方）。
    /// **没验过**的是「物理上摆在主屏上面」那块 —— 那一块翻出来是负 y，真机上有没有第二块屏这么摆
    /// 得装机才知道；本轮的多屏判据只能保证一块屏的情形。
    /// 高度做成参数是为了取证：翻转写反表现成「永远打不中」，而那在测试里没法用真坐标验。
    /// **只有 `NSEvent.mouseLocation` 这一个来源要翻**：`AXPosition`/`AXSize` 和
    /// `CGWindowListCopyWindowInfo` 的 bounds 本来就是左上原点，跟 CG 同一套。取证脚本里
    /// 拿 AX 读回来的坐标再去翻一次，打到的全是上下镜像处的别人家窗口（本轮就这么错过两次，
    /// 差点据此写成「邮件命中不了」）。
    static func cgPoint(appKit anchor: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: anchor.x, y: primaryHeight - anchor.y)
    }

    private static func cgPoint(appKit anchor: CGPoint) -> CGPoint {
        cgPoint(appKit: anchor, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    /// 鼠标点那一手最多往上走几格（**含命中的那一格**）。装机第一轮的外观是
    /// `AXStaticText` → `AXGroup` → `AXWebArea`，三格够到管选区的那一层；再多就是拿超时换概率。
    static let maximumElementsProbedAtThePoint = 3

    /// 这一手的消息超时。**故意比主读短**：主读是整个功能成败，这一手只是补救的一手，
    /// 对方慢就放弃，不能把「不弹」拖成「划完词卡半天」。
    static let hitTestProbeTimeout: TimeInterval = 0.2

    /// 失败那一条路上最坏要等多久（秒）：首读一笔 `timeout`，再加上**上场的那一手**。
    /// 三手各自的上限不同，取最大的那个：重读那一棵 = 1 笔、换系统级 = 1 笔、
    /// 鼠标点那一手 = 1 次命中 + 每格一次选区读 + 每格一次父级读，全按短超时。
    /// 这是给延迟判据用的（`testWorstCaseLatencyStaysUnderASinglePerceptibleBeat`），
    /// 那两个常量谁被改大了都会在这里先红。
    ///
    /// `includesCopyHand` 那一段是**代按 ⌘C**：它占的是「等对方把字写进粘贴板」那一笔
    /// （`SelectionCopyReader.pollTimeoutCeiling`），不是跨进程往返，所以不进上面那个预算。
    /// 默认按「上这一手」算 —— 生产里它是开的，判据要钉的是用户实际会等到的那个数。
    /// 注意这一手只在「本来就不弹」那条路上：它把最坏那一档从 1.8 抬到 2.15，
    /// 换来的是「这一档在邮件那类 App 里真能弹出东西」。**弹出来的那一档**仍然是
    /// 「读取延迟 + 一次消息超时」，那条判据（1 秒内）一个字没动。
    static func worstCaseWaitSeconds(timeout: TimeInterval = SelectionBubbleSettings.messagingTimeout,
                                     includesCopyHand: Bool = true) -> TimeInterval {
        let oneMoreFocusedRead = timeout
        let cursorProbeCalls = 1 + maximumElementsProbedAtThePoint + (maximumElementsProbedAtThePoint - 1)
        let cursorProbe = Double(cursorProbeCalls) * hitTestProbeTimeout
        let copyHand = includesCopyHand ? SelectionCopyReader.pollTimeoutCeiling : 0
        return timeout + max(oneMoreFocusedRead, cursorProbe) + copyHand
    }

    /// 这一次读的是谁的元素，进日志用。
    private var scopeTag: String {
        switch scope {
        case .application(let pid): return "pid=\(pid)"
        case .systemWide: return "系统级焦点"
        case .atPoint(let pid, _): return "pid=\(pid) 鼠标点"
        case .viaCopy(let pid): return pid.map { "pid=\($0) 粘贴板" } ?? "粘贴板"
        }
    }

    /// 焦点元素的 `AXRole`。读不到就报读不到 —— 这是给人看的诊断，不当判据用。
    private func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let role = value as? String else { return "?" }
        return role
    }

    /// 错误码 → 原因。码的含义见 HIServices/AXError.h。
    /// 挑出来的这几个是装机时真会碰到的：-25211 = 对方没开无障碍（Chromium），
    /// -25204 = 超时（CannotComplete），-25205 = 没这个属性（AttributeUnsupported），
    /// -25208 = 没实现（NotImplemented），-25212 = **属性在但当前没值**（NoValue），
    /// -25202 = 焦点元素已经作废（InvalidUIElement，切 App 那一瞬最容易撞上）。
    ///
    /// -25205 与 -25212 必须分开：前者是「这控件压根不给你选区」（SwiftUI 文本框那一类，修不了），
    /// 后者是「这元素此刻没有选区」——装机第一轮 Chrome 与信息全是 -25212，焦点给的是容器，
    /// 选区在子树里。旧代码把两个码并成一句「该控件不支持选中文字属性」，归因直接指错方向。
    static func classify(_ code: Int, focusedElementStage: Bool) -> SelectedTextResult.Unavailable {
        switch code {
        case -25211: return .accessibilityNotEnabled
        case -25204: return .timedOut
        case -25205, -25208:
            return focusedElementStage ? .noFocusedElement : .selectedTextUnsupported
        case -25212:
            return focusedElementStage ? .noFocusedElement : .noSelectedTextValue
        case -25202: return .noFocusedElement
        default: return .apiError(code)
        }
    }

    private static func classify(_ code: Int, stage: Stage) -> SelectedTextResult.Unavailable {
        classify(code, focusedElementStage: stage == .focusedElement)
    }

    /// `kAXSelectedTextAttribute` 的返回值有两种写法：纯文本控件给 CFString，富文本控件
    /// （TextEdit 那一类）给 NSAttributedString。两种都要认，否则富文本里划词永远不弹。
    ///
    /// 富文本那一种是**直接给了个 CFAttributedString**，不是包在 `AXValue` 里 ——
    /// `AXValueGetValue` 只认点/尺寸/CFRange/仿射矩阵/元素/数组那六种（没有 `.attrString` 这一档），
    /// 照那条路走会一句都编译不过。所以按 CFTypeID 分派，和 CFString 那一支同一写法。
    ///
    /// `internal` 是给取证的：这一支不碰任何进程，纯类型分派，真调用反而验不到它（`swift test`
    /// 里那台机器恰好选中了什么，全凭运气）。桥接行为本机实测：`CFAttributedStringCreate` 出来的
    /// 东西 `CFGetTypeID` 命中、`as! NSAttributedString` 拿得到 `.string`，`NSNumber` 落 nil。
    static func string(from value: CFTypeRef) -> String? {
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            return (value as! CFString) as String
        }
        if typeID == CFAttributedStringGetTypeID() {
            return (value as! NSAttributedString).string
        }
        return nil
    }

    /// 请目标 App 打开无障碍接口。**这一笔有代价**：对方从此开始维护自己的无障碍树
    /// （Chromium 尤其明显，CPU 会吃掉一档），而且要等那个 App 退出才回落。所以每个进程
    /// 每个属性一生只提醒一遍，且只在第一次读失败时试。
    ///
    /// 两个属性名都要试，因为**装机实测它们各管一拨**（本机 2026-10-21）：
    /// - `AXManualAccessibility`：Electron 那一类吃它（写返回 0）；Chrome 155 和信息**直接 -25205 拒收**。
    /// - `AXEnhancedUserInterface`：VoiceOver 用的那一条老通道，Chrome 155 和信息吃它（读得到现值、写返回 0）。
    /// 只写前一条的话，在 Chrome 里就是「请求失败 → 永远取不到焦点元素」，这正是「很多软件里没效果」
    /// 的头一条真因；旧代码还把 pid 记进「已经试过了」那份名单，于是连第二条都没机会试。
    ///
    /// 返回「有没有真的把某个开关翻上去」。翻上了才值得立刻重读那一棵；两个都被拒就退回失败。
    private func requestAccessibility(pid: pid_t) -> Bool {
        for name in Self.accessibilityAttributes {
            // 名单按（进程 × 属性）记：第一条被拒不能把第二条的机会一起挡掉。
            guard Self.markAttempt(pid: pid, attribute: name) else { continue }
            guard enableOverride?(pid, name) ?? Self.write(pid, attribute: name, value: true,
                                                           timeout: timeout, why: "划词读不上来，请对方开接口") else {
                continue
            }
            Self.recordEnabledByUs(pid: pid, attribute: name)
            return true
        }
        return false
    }

    /// 真写一次开关。**开和关共用这一句**：两处各写一遍的话，很容易改成「开的时候用新属性名、
    /// 关的时候还在写旧的那个」，对方那棵无障碍树就永远留着了。
    ///
    /// 值必须是 CFBoolean：写 Swift `true` 会桥成 NSNumber，Chromium 那边认不下来。
    /// 苹果也没把这两个属性名导进 Swift 的符号表（10.10 前后加的常量），所以写字面量。
    @discardableResult
    static func write(_ pid: pid_t, attribute: String, value: Bool,
                      timeout: TimeInterval, why: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
        let error = AXUIElementSetAttributeValue(app, attribute as CFString,
                                                 value ? kCFBooleanTrue : kCFBooleanFalse)
        NSLog("%@", "[SelectionBubble] \(why)：pid=\(pid) 的 \(attribute) 写 \(value) result=\(error.rawValue)"
              + (value ? "（开接口会让对方开始维护无障碍树，代价是一档 CPU；每个进程每个属性只试一次）" : "（对方不再维护那棵无障碍树）"))
        return error == .success
    }

    /// 试过的两个开关属性，按「谁的代价小」排：`AXManualAccessibility` 只是请对方开接口，
    /// `AXEnhancedUserInterface` 是让对方以为屏幕上正有个辅助工具在跑（焦点行为都可能跟着变）。
    /// 前者被拒才退到后者。internal 是给取证的：顺序换一下，Chrome 那条就白走一遍贵的通道。
    static let accessibilityAttributes = ["AXManualAccessibility", "AXEnhancedUserInterface"]

    /// 记一次「已经对这个进程的这个名字写过开关」。
    /// 每个**属性**各一份名单，不是每个进程一份 —— 这是旧代码的坑：Chrome 拒收第一条之后
    /// pid 就永久进了名单，第二条再也没有机会被写。
    /// 返回 false 表示这一对（pid × 属性）以前试过了，别再往人家元素树上写。
    static func markAttempt(pid: pid_t, attribute: String) -> Bool {
        didAttemptLock.lock()
        defer { didAttemptLock.unlock() }
        if didAttempt[attribute, default: []].contains(pid) { return false }
        didAttempt[attribute, default: []].insert(pid)
        return true
    }

    /// 我们亲手翻上去的开关，连同翻的是哪一个属性。回落时要按同一个名字关回去，
    /// 关错名字等于没关。
    private static func recordEnabledByUs(pid: pid_t, attribute: String) {
        enabledByUsLock.lock()
        defer { enabledByUsLock.unlock() }
        enabledByUs[pid] = attribute
    }

    /// 把**我们自己**翻上去的开关再翻下来：总开关一关，功能整条链路就没了，
    /// 让别人家继续白维护一棵无障碍树、白吃一档 CPU 说不过去。
    ///
    /// 只关 `enabledByUs` 里那一档，且只关我们翻的那个属性名 —— 别的辅助工具（VoiceOver）
    /// 本来就开着的那一份动不得。而这一条能成立的前提是：走到 `requestAccessibility` 意味着
    /// App 元素上的焦点读是失败的，那正是「还没人开过接口」的样子；有人开过的话第一次读就中了，
    /// 压根到不了这一步。
    ///
    /// 每个属性名单同时清空：功能重新打开后要重新请各家开接口，旧名单会把新一次的机会挡掉。
    public static func releaseRequestedAccessibility() {
        didAttemptLock.lock()
        didAttempt.removeAll()
        didAttemptLock.unlock()
        enabledByUsLock.lock()
        let ours = enabledByUs
        enabledByUs.removeAll()
        enabledByUsLock.unlock()
        guard !ours.isEmpty else { return }
        for (pid, attribute) in ours {
            guard NSRunningApplication(processIdentifier: pid) != nil else { continue }
            Self.write(pid, attribute: attribute, value: false,
                       timeout: SelectionBubbleSettings.messagingTimeout, why: "关掉划词功能")
        }
    }

    /// 试过的（属性名 → 进程号集合）。静态是因为同一个 App 在同一场会话里反复划词很常见，
    /// 每笔都往它元素树上写一遍属性说不过去。
    private static var didAttempt: [String: Set<pid_t>] = [:]
    private static var didAttemptLock = NSLock()
    /// 我们把哪个进程的哪个属性从 false 翻成了 true。
    private static var enabledByUs: [pid_t: String] = [:]
    private static var enabledByUsLock = NSLock()
}
