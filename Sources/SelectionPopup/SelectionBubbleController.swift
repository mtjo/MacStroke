//
//  SelectionBubbleController.swift
//  MacStroke
//
//  划词气泡这条链路的总装：只读监听 → 判定 → 后台读选区 → 弹胶囊 → 格子做事。
//
//  **为什么不动 EventCapture 那棵 HID 树**（issue #43/#68 划的死线是「识别执行和时间不要
//  受到影响」），四条理由记在这儿，免得下一个改的人手一抖就把它接进去：
//  1. 那棵树是 `.cghidEventTap` + `.defaultTap`，往里加 `.leftMouseDragged` 就是让**每一次**
//     拖动都多走一遍我们的回调，还多一份「该不该吞」的判断。
//  2. 这里的监听是 `addGlobalMonitorForEvents`，按构造只读：拿不到事件、更吞不掉事件，
//     不可能影响任何一条既有的投递路径。
//  3. 那棵树的回调跑在主运行循环上，无障碍读取哪怕只堵 100ms 都会拖到手势；这里读取一律丢后台。
//  4. `pointerDown` 那一大棵判定树（约六百行）在 `swift test` 里跑不起来，判定的测试进不来。
//
//  还有一条顺带的好处：手势按住期间左键是被 HID 回调吞掉的（`CanvasManager` 里
//  「gesture 进行中吞左键」那支），吞掉的事件压根不会派发到任何 App，全局监听也就看不见 ——
//  画手势时不该冒气泡，这一条是白拿的。这句是推断，装机清单第 6 条用日志确认，不是已实测结论。
//
//  接缝（`settingsProvider` / `readerFactory` / `frontmostApp` / `isSelfApp` / `cursorLocation` /
//  `monitorRegistration` / `isTrustedForGlobalEvents` / `presenter`）不是为了好看：`swift test` 这个进程里既没有辅助功能授权、
//  也没有别人的 App、更没有一顶 NSApplication 撑着开窗口，所以「该不该弹」「弹在哪」「什么时候作废」
//  三件事必须能在不开窗、不收真事件的情况下验。真窗口那一段（`showPanel`）只能装机时看日志确认，
//  这一条不假装测过。
//

import AVFoundation
import AppKit
import ApplicationServices
import Storage

/// 松手那一刻「字在谁那儿」：只要包名和进程号这两样。
///
/// 不用 `NSRunningApplication` 本身是因为它对没在跑的 pid 直接返回 nil —— 测试造不出一台
/// 「假装是别的应用」的对象，判定就只能挂在真机上。值类型一份，测试里想摆谁摆谁。
struct FrontApp: Equatable {
    var bundleID: String?
    var pid: pid_t
}

public final class SelectionBubbleController {
    public static let shared = SelectionBubbleController()

    // MARK: 接缝

    /// 偏好的来源。默认读标准域（App 真跑起来就是它），测试给一个隔离 suite —— 别把
    /// `enableSelectionPopup = true` 写进 App 自己的域里，那是用户看到的开关。
    var settingsProvider: () -> SelectionBubbleSettings = { SelectionBubbleSettings.current() }
    /// 读选中文字的实现。真实现是 `AXSelectedTextReader`，测试塞一个固定返回值的假对象。
    ///
    /// 第二个参数是**松手那一点的坐标**，不是可选的装饰：焦点元素是容器那一档（Chrome 的
    /// `AXWebArea`、信息里的正文）要靠「读鼠标点命中的元素」补救，而 reader 自己没有鼠标位置 ——
    /// 它是后台线程上现读的，读回来时指针早就飘走了。坐标只能从事件那一路带进来。
    /// 快捷键那一路没有拖动，给 nil。
    ///
    /// 第三个参数是「无障碍读不到时的最后一手」（代按 ⌘C），偏好不允许时给 nil。
    /// 它做成参数而不是让 reader 自己 new 一个，有两个原因：这一手上不上是**偏好**决定的，
    /// 而偏好只有控制器手上有快照；而它真跑起来要动用户的粘贴板，测试里绝不能碰那一份，
    /// 只能由用例决定递什么假对象进去（或者干脆递 nil，钉「开关关掉时压根不递」）。
    var readerFactory: (AXSelectedTextReader.Scope, CGPoint?, SelectionCopyReading?) -> SelectionTextReading = { scope, anchor, copyFallback in
        let reader = AXSelectedTextReader(scope: scope, anchor: anchor)
        reader.copyFallback = copyFallback
        return reader
    }
    /// 「代按 ⌘C」那一路的实现。单开一个口子是为了让用例能递一个不碰真粘贴板的假对象，
    /// 而不是因为这一手可以换东西用：真实现只有一个 `SelectionCopyReader`。
    var copyReaderFactory: () -> SelectionCopyReading = { SelectionCopyReader() }
    /// 前台 App 的黑白名单判定。App 层注入 `BlackWhiteFilter`，本模块因此不依赖 RuleEngine。
    public var isAppAllowed: (String) -> Bool = { _ in true }
    /// 「这台机器上有没有辅助功能授权」。单独开一个口子是因为 `swift test` 那个进程**不一定**有：
    /// 没有授权时下面那句真监听照样能挂上、只是一辈子不回调，于是「开关打开 ⇒ 挂监听」这一条
    /// 在测试里恒真、什么都咬不住。判定留在真调用上，测试只换这个开关。
    var isTrustedForGlobalEvents: () -> Bool = { AXIsProcessTrusted() }
    /// 当前前台 App。测试换成一个可控的替身，就能验「切了 App 之后那次读取作废」。
    var frontmostApp: () -> FrontApp? = {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontApp(bundleID: app.bundleIdentifier, pid: app.processIdentifier)
    }
    /// 「前台是不是我们自己在跑」。单独开一个口子：`swift test` 那个进程本身就是别的 App，
    /// 真判定不改这一句的话，测试里每次「认出自己」都恒真，一条也测不出来。
    var isSelfApp: (FrontApp) -> Bool = { $0.pid == NSRunningApplication.current.processIdentifier }
    /// 抛上屏。真实现开一扇浮窗，测试只记「弹了、弹在哪、弹的哪段字」。
    var presenter: (String, CGPoint) -> Void = { text, anchor in
        SelectionBubbleController.shared.showPanel(text, at: anchor)
    }

    /// 此刻的光标在哪（AppKit 坐标，原点主屏左下角）。
    /// 单独开一个口子是因为「全局监听的每一笔都要记位置」，而真光标在这台机器上是碰巧停在
    /// 哪儿就哪儿 —— 不换掉它，「按下→拖三笔→松手」这一整串在 `swift test` 里演不出来。
    var cursorLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// 挂监听这件事本身，默认就是那句真 API。测试换成一个记录用的假实现，顺手把回调拿到手：
    /// 真事件要辅助功能授权 + 另一个 App 在前台，两样在测试进程里都没有，
    /// 于是「鼠标到底走了几步」只能靠假光标 + 假事件喂进 `handle`。
    var monitorRegistration: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any? = { mask, handler in
        NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }
    /// 拆监听。和上面那一对开的，测试里不真去动系统的那张表。
    var monitorRemoval: (Any) -> Void = { NSEvent.removeMonitor($0) }
    /// 挂「前台换人」那一条通知。默认走工作区的那个通知中心。
    /// 这一对也要接缝：真通知会在用例跑的这半秒里因为人真的切了 App 而 firing，
    /// 把一条本来该绿的用例弄红 —— 那种红和代码无关，查起来最费时间。
    var appSwitchRegistration: (@escaping () -> Void) -> Any? = { fire in
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { _ in fire() }
    }
    /// 拆「前台换人」那条通知。拿的是 `addObserver(forName:)` 返回的那张凭据。
    var appSwitchRemoval: (Any) -> Void = {
        NSWorkspace.shared.notificationCenter.removeObserver($0)
    }

    /// 只读监听收的事件。写成常量是给取证的：这一档里**不能**出现滚轮、中键、右键，
    /// 也不能因为「顺手」多收一个事件类型。
    static let monitorMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]

    /// 松手时按着这三个键就别弹：⌥ 是列选/单词扩展，⇧ 是扩展选区，⌘ 是多选。
    /// ⌃ 不在里面 —— 那些控件里 ⌃ 拖动没有第二含义，拦它只会少弹。
    static let blockedModifiers: NSEvent.ModifierFlags = [.option, .shift, .command]

    // MARK: 状态

    private var monitor: Any?
    /// 「前台换人」那条通知的凭据（`addObserver(forName:)` 给回来的那一种）。
    private var appSwitchToken: Any?
    var settings = SelectionBubbleSettings(enabled: false,
                                           shortcut: StorageDefaults.selectionPopupShortcut,
                                           readDelay: TimeInterval(StorageDefaults.selectionPopupReadDelay) / 1_000)
    private var drag: DragSample?
    /// 一次「等着读」的序号：按下、切 App、关掉功能都会让它过期，
    /// 后台读回来的那一句就不许再往屏幕上抛。
    private var pendingToken = 0
    private var autoHideTimer: Timer?
    private var panel: SelectionBubblePanel?
    private var bubbleView: SelectionBubbleView?
    private let speech = AVSpeechSynthesizer()

    /// 左键那三档只读监听此刻挂没挂。**不等价于「功能开着」**：只用手唤出时它是关的。
    public private(set) var isMonitoring = false

    /// 此刻屏幕上有没有气泡。
    public var isBubbleVisible: Bool { panel?.isVisible == true }

    /// 「开浏览器」这一手的接缝。真值是 `NSWorkspace.shared.open`；用例里换成一个把 URL 记下来的
    /// 闭包，于是「选了必应就该开必应、选了豆包就该先复制再开」这两条能当场咬住 ——
    /// 浏览器一开就收不回来，那种判据没法写成用例。
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// 「写粘贴板」这一手的接缝，同上。真值动的是用户那份，所以**测试入口里默认换成记录的**，
    /// 用例忘了换的最坏结果是「粘贴板没动」，不会是「跑个单测把用户刚复制的东西顶掉了」。
    var pasteboardWrite: (String) -> Void = { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        NSLog("%@", "[SelectionBubble] 复制\(ok ? "成功" : "失败")：\(text.count) 个字符")
    }

    /// 「投一次 ⌘V」这一手的接缝，同上面那两条：真值是投到 session 层（见
    /// `SelectionCopyReader.postPasteKeysToSession` 那段注释 —— 不穿我们自己的 HID tap）。
    /// 测试入口默认**返回 false 且不投**：忘了换假件的最坏结果是「这一手没上场」。
    var postPasteKeys: () -> Bool = { SelectionCopyReader.postPasteKeysToSession() }

    /// 读粘贴板上此刻那一句（只读）。给「投之前核一句：还是不是我刚写进去的那句」那道闸用。
    /// 真值动的是系统那一份，测试入口默认给 nil —— 于是默认判「不是同一句」，不投。
    var pasteboardString: () -> String? = { NSPasteboard.general.string(forType: .string) }

    /// 「等多久再贴」这件事本身也要接缝。第五轮 M110/M111 那种「只能留给装机」的判据，
    /// 就是因为没有这一层：`asyncAfter` 在用例里等不到。测试入口默认**立刻执行**，
    /// 于是「先开页、后贴」这个次序能当场写成一条断言，用例里也能自己留着稍后手动放行。
    var pasteScheduler: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 我们自己的包名，给「到点时前台是不是我们自己」那道闸。
    /// 测试入口给 nil：那种情况下闸门按「不是我们」放行，只有用例显式设了值才能演出自激那一档。
    var ourBundleID: String? = Bundle.main.bundleIdentifier

    private init() {}

    /// 测试入口：每个用例要一个干净的控制器（单例的状态会串到下一个用例里去）。
    init(readerFactory: @escaping (AXSelectedTextReader.Scope, CGPoint?, SelectionCopyReading?) -> SelectionTextReading,
         frontmostApp: @escaping () -> FrontApp? = { nil },
         isAppAllowed: @escaping (String) -> Bool = { _ in true },
         settings: SelectionBubbleSettings? = nil) {
        self.readerFactory = readerFactory
        self.frontmostApp = frontmostApp
        self.isAppAllowed = isAppAllowed
        if let settings { self.settings = settings }
        // 假控制器默认不开真窗：上屏这一手由用例自己换成一个记录用的闭包。
        self.presenter = { _, _ in }
        // 也默认不带「代按 ⌘C」：这一个口子碰的是真粘贴板，测试里想验这一手必须自己递一个假的进来，
        // 漏递的话最坏结果只是「这一手没上场」，绝不会是「用例把用户刚复制的东西顶掉了」。
        self.copyReaderFactory = { InertCopyReader() }
        // 这两条同理：浏览器和粘贴板都不该在单测里真动。默认换成记账的，用例读那两本账下判据。
        self.openURL = { _ in }
        self.pasteboardWrite = { _ in }
        // 「自动贴那一次 ⌘V」的三条接缝同上，默认值一律选**最不打扰系统**的那一档：
        // 不投键（false）、读不到粘贴板（nil → 闸门判「不是同一句」，不投）、
        // 包名不认（自激那一档只有用例显式设值才演得出来）。
        // 唯独排期默认**立刻执行** —— 延时本身不是被测对象，而「先开页、后贴」这个次序必须
        // 能在一条断言里看出来；要演「那 1.2 秒里偏好变了」的用例自己把闭包接下来稍后放行。
        self.postPasteKeys = { false }
        self.pasteboardString = { nil }
        self.pasteScheduler = { _, work in work() }
        self.ourBundleID = nil
    }

    /// 什么都不做的「最后一手」：被问到也只回答「这一手没做成」，不碰粘贴板、不投键。
    /// 测试控制器默认用它 —— 用例没显式换接缝的时候，最坏结果只是「这一手没上场」，
    /// 绝不会是「跑个单测把用户刚复制的东西顶掉了」。
    private final class InertCopyReader: SelectionCopyReading {
        func read(from pid: pid_t?) -> SelectedTextResult { .unavailable(.copyBlocked) }
    }

    deinit { stop() }

    // MARK: 生命周期

    /// 读一遍偏好，决定挂监听还是拆监听。总开关一改变的是「监听存不存在」，
    /// 不是「监听着但什么都不弹」—— 关掉要关到根上。「划完字自动弹出」那一条自己关掉也是
    /// 同一句话（见 `refreshMouseMonitor`），因为那个监听只做这一件事。
    public func apply() {
        let snapshot = settingsProvider()
        settings = snapshot
        apply(settings: snapshot)
    }

    /// 已经读过一遍偏好的那一支：App 层的 `UserDefaults` 变化回调里手上一份快照，
    /// 直接递进来比再读一次省事，也免得两次读之间值又变了。测试也从这里喂。
    func apply(settings snapshot: SelectionBubbleSettings) {
        settings = snapshot
        guard snapshot.enabled else {
            stop()
            return
        }
        startIfNeeded()
    }

    private func startIfNeeded() {
        // 「前台换人」那条通知和左键监听不是一回事：手动唤出的气泡也要靠它收掉，
        // 所以总开关开着期间它一直挂着，不因为「这次不监听鼠标」被一起拆了。
        startAppSwitchObserver()
        refreshMouseMonitor()
    }

    /// 左键的只读监听**只服务「划完字自动弹出」这一条**。这一条自己关掉时把它整个拆掉，
    /// 而不是留着继续收每一次单击 —— 「监听在跑但什么都不做」正是总开关那条注释里
    /// 说的最难查的坏，而且多挂一份全局鼠标回调就多一份对系统其它部分的干扰。
    /// 快捷键那一路不吃这个监听，拆掉它不影响 ⌃⌘B。
    private func refreshMouseMonitor() {
        guard settings.autoPop else {
            stopMouseMonitor()
            return
        }
        guard !isMonitoring else { return }
        // 全局监听要辅助功能授权才收得到别人的事件。MacStroke 启动时已经过那道门
        // （`main.swift` 的 `AXIsProcessTrustedWithOptions`），这里只补一句日志。
        guard isTrustedForGlobalEvents() else {
            NSLog("%@", "[SelectionBubble] 没有辅助功能授权，收不到别的应用的鼠标事件，先不挂监听")
            return
        }
        monitor = monitorRegistration(Self.monitorMask) { [weak self] event in
            self?.handle(event)
        }
        isMonitoring = monitor != nil
        NSLog("%@", "[SelectionBubble] 开始监听划词（延迟 \(Int(settings.readDelay * 1000))ms）")
    }

    private func startAppSwitchObserver() {
        guard appSwitchToken == nil else { return }
        appSwitchToken = appSwitchRegistration { [weak self] in self?.noteAppSwitch() }
    }

    /// 只拆左键监听（偏好页把「自动弹出」那一条关掉时走这里，气泡和通知都不动）。
    private func stopMouseMonitor() {
        guard let monitor else { return }
        // 拆监听这一刻手上可能正有一次「等延迟读完」的自动划词：把它作废，否则表现是
        // 「开关一关，正好有一发读回来了，气泡照样弹出来」。
        pendingToken += 1
        monitorRemoval(monitor)
        self.monitor = nil
        isMonitoring = false
        NSLog("%@", "[SelectionBubble] 已停止划词监听")
    }

    /// 拆干净：监听、待读的这一次、气泡、还在念的话，四样一起收。
    public func stop() {
        let wasRunning = isMonitoring || panel != nil
        pendingToken += 1
        stopMouseMonitor()
        if let appSwitchToken {
            appSwitchRemoval(appSwitchToken)
            self.appSwitchToken = nil
        }
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        bubbleView = nil
        panel?.orderOut(nil)
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        isMonitoring = false
        // 我们替哪些 App 开了无障碍接口，关掉功能时一并请它们关掉：那些树是我们让它建的，
        // 那档 CPU 是我们让它吃的，功能没了还留着就是白留。详见 `releaseRequestedAccessibility`。
        AXSelectedTextReader.releaseRequestedAccessibility()
        // 只在真的拆过东西时喊一声：stop() 也被 deinit 和「开关本来就是关」那条路反复叫，
        // 每次都写一行日志会让人以为功能曾经开过。
        if wasRunning { NSLog("%@", "[SelectionBubble] 已停止监听") }
    }

    // MARK: 事件

    private func handle(_ event: NSEvent) {
        // 位置取的是**光标此刻**在哪，不取 `event.locationInWindow`：全局监听送来的事件
        // 没有窗口（`window == nil`），那套坐标在不同系统版本上的解释不一致，
        // 而 `cursorLocation` 就是这一笔事件对应的屏幕位置（同一轮运行循环里读到的）。
        let here = cursorLocation()
        switch event.type {
        case .leftMouseDown:
            // 点到别处就算「这次不要了」：先把气泡收掉，再开始记新的一划。
            pendingToken += 1
            dismiss()
            drag = DragSample(start: here, end: here, dragEvents: 0)
        case .leftMouseDragged:
            guard var sample = drag else { return }
            sample.dragEvents += 1
            sample.end = here
            drag = sample
        case .leftMouseUp:
            defer { drag = nil }
            guard var sample = drag else { return }
            sample.end = here
            evaluate(drag: sample, modifiers: event.modifierFlags)
        default:
            break
        }
    }

    /// 「这一次松手要不要去读选区」。internal 是给测试的：真事件要辅助功能授权加上别的 App
    /// 在前台，`swift test` 里两样都没有，判定的四条边界只能从这一句直接喂进去。
    func evaluate(drag sample: DragSample, modifiers: NSEvent.ModifierFlags) {
        switch SelectionTrigger.decide(drag: sample, modifiers: modifiers,
                                       blockedModifiers: Self.blockedModifiers) {
        case .skip(.singleClick), .skip(.tooShort):
            // 系统里每一次点东西都有一次单击，这两种一条日志都不打：控制台会被刷满，
            // 而 `[SelectionBubble]` 那份日志是留给装机看链路用的。
            break
        case .skip(.modifierHeld):
            NSLog("%@", "[SelectionBubble] 按住修饰键，这次划词不弹")
        case .arm(let anchor):
            // 「划完字自动弹出」这一条自己关掉了：那是不想每次划词都被放一枚气泡出来的人，
            // 不是整个功能关了（整个关了就压根收不到这一句）。不打日志的话，控制台会被
            // 每一次单击刷满 —— 这里只在真的完成了一次划词时才走到这一步，可以打。
            guard settings.popsOnSelection else {
                NSLog("%@", "[SelectionBubble] \(settings.autoPop ? "格子全关，不弹" : "自动弹出这一条没开，不弹")")
                return
            }
            guard let app = frontmostApp(), let bundleID = app.bundleID else {
                NSLog("%@", "[SelectionBubble] 认不出前台应用，不弹")
                return
            }
            // 自己人不算：在偏好页里划一段字也弹一条，等于盖住正要改的那个框。
            guard !isSelfApp(app) else {
                NSLog("%@", "[SelectionBubble] 前台是 MacStroke 自己，不弹")
                return
            }
            guard isAppAllowed(bundleID) else {
                NSLog("%@", "[SelectionBubble] \(bundleID) 在过滤名单里，不弹")
                return
            }
            scheduleRead(anchor: anchor, pid: app.pid)
        }
    }

    /// 到点了先去后台读，读回来的那一句再回主线程抛上屏。
    private func scheduleRead(anchor: CGPoint, pid: pid_t) {
        let token = pendingToken + 1
        pendingToken = token
        let delay = settings.readDelay
        let reader = readerFactory(.application(pid), anchor, makeCopyFallback())
        NSLog("%@", "[SelectionBubble] 划词到位（\(Int(anchor.x)), \(Int(anchor.y))），\(Int(delay * 1000))ms 后读选区")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.readNow(token: token, anchor: anchor, pid: pid, reader: reader)
        }
    }

    /// 这一趟带不带「代按 ⌘C」那一手，全看 `canUseCopyFallback`（那颗开关、格子还剩没剩、
    /// 以及**那条拆环的闸**：用户把气泡快捷键录成单纯 ⌘C 时这一手压根不能上场，否则
    /// 「按下 → 读不到 → 代按 ⌘C → 监听又命中」就是转圈动他的粘贴板）。
    /// 被那道闸挡掉时要说一句：界面上开关明明还开着、却一次都不生效，
    /// 没有日志的话这就是一条查不出来的坏。
    private func makeCopyFallback() -> SelectionCopyReading? {
        guard settings.canUseCopyFallback else {
            if settings.copyFallbackEnabled, SelectionBubbleSettings.isPlainCommandC(settings.shortcut) {
                NSLog("%@", "[SelectionBubble] 气泡快捷键就是 ⌘C，代按那一手不能上场（不然会自己触发自己）")
            }
            return nil
        }
        return copyReaderFactory()
    }

    private func readNow(token: Int, anchor: CGPoint, pid: pid_t, reader: SelectionTextReading) {
        guard pendingToken == token else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = reader.read()
            DispatchQueue.main.async {
                // 读期间可能又按下、切了 App、或者把功能整个关了 —— 三种都算这一次作废。
                // 切 App 那条尤其要在意：字是刚才那个 App 的，气泡却会跟着指针弹到新那个头上。
                guard self.pendingToken == token, let front = self.frontmostApp(), front.pid == pid else { return }
                // 失败那两句要把「在哪个 App 里读不上来」带出来。同一句「取不到焦点元素」
                // 在 Chrome 里是没开无障碍、在信息里是桥接层不给属性，两种修法；日志只报原因
                // 不报是谁，用户回「Chrome 不弹、TextEdit 弹」时就没法按 App 分档统计。
                let subject = "\(front.bundleID ?? "未知包名") pid=\(pid)"
                self.didRead(result, anchor: anchor, subject: subject, reader: reader)
            }
        }
    }

    /// 读回来之后要不要弹。`subject` 是「这次读的是谁」，只进日志：装机时按 App 分档统计
    /// 就靠那一句，两条唤出路径（自动划词 / 快捷键）也靠它分得开。
    ///
    /// `reader` 也只进日志，但它是**成功那一行**才需要的：装机时问「现在到底哪些软件里有效果」，
    /// 答案只能从「读到了」这一行统计出来 —— 上一版只有失败行带 App 名，成功行是
    /// 「弹气泡：9 个字符，位置 …」，谁都不认识，那一句没法按 App 归账。
    /// 来源（App 焦点 / 系统级 / 鼠标点命中的元素）也要一起报：它决定下一次该修哪一手。
    private func didRead(_ result: SelectedTextResult, anchor: CGPoint, subject: String,
                         reader: SelectionTextReading) {
        switch SelectionTrigger.decide(text: result) {
        case .skip(.nothingSelected):
            NSLog("%@", "[SelectionBubble] 没有选中内容（\(result.logReason)），不弹 —— \(subject)")
        case .skip(.readFailed):
            NSLog("%@", "[SelectionBubble] 读选区失败（\(result.logReason)），不弹 —— \(subject)")
        case .skip(.tooLong(let count)):
            NSLog("%@", "[SelectionBubble] 选中 \(count) 个字符，超过 \(SelectionBubbleSettings.maximumCharacters) 不弹 —— \(subject)")
        case .show(let text):
            NSLog("%@", Self.successLogLine(text: text, subject: subject,
                                            answeredFrom: reader.answeredFrom))
            presenter(text, anchor)
        }
    }

    /// 「读到了」那一行的正文，抽成纯函数。
    ///
    /// 为什么要抽：`NSLog` 在 `swift test` 里拿不到，而这一版要修的正是「装机时能不能按 App
    /// 统计出谁有效」—— 上一版成功那行写的是「弹气泡：9 个字符，位置 …」，没有 App 名，
    /// 用户问「现在什么软件里才有效果」时日志答不上来。把这句话留在 `showPanel` 里就永远验不到，
    /// 丢掉 `—— \(subject)` 也没人红。
    static func successLogLine(text: String, subject: String,
                               answeredFrom: AXSelectedTextReader.Scope?) -> String {
        "[SelectionBubble] 读到了：\(text.count) 个字符 —— \(subject)（\(answeredFrom?.logLabel ?? "来源未记")）"
    }

    // MARK: 手动唤出

    /// 快捷键那一条：不靠拖动，直接把当前焦点上的选中文字读出来弹一条。
    /// 键盘选字（⌥⇧→ 那一类）不产生左键事件，只有这一条能叫出气泡。
    public func showForCurrentSelection() {
        showSelection(at: cursorLocation())
    }

    /// 内部共用：`.systemWide` 那条读的是「当前焦点上的元素」，不认是谁的 App，
    /// 所以也不做「切了 App 就作废」那一条 —— 按下这条键的时候本来就是当前焦点。
    func showSelection(at anchor: CGPoint) {
        // 总开关关掉 = 整件事不存在；格子全关 = 读上来也没地方摆。这两种都连读都不读。
        // 注意这里**不看** `autoPop`：快捷键那一路和自动弹那一路各关各的。
        guard settings.enabled, settings.hasCells else { return }
        let reader = readerFactory(.systemWide, anchor, makeCopyFallback())
        pendingToken += 1
        let token = pendingToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = reader.read()
            DispatchQueue.main.async {
                guard self.pendingToken == token else { return }
                // 快捷键那一条读的是系统级焦点，落在谁身上只有「此刻前台是谁」这一个说法，
                // 所以这里现取，不用按下那一刻的快照（那一句压根没有）。
                let front = self.frontmostApp()
                let subject = front.map { "\($0.bundleID ?? "未知包名") pid=\($0.pid)（快捷键）" } ?? "系统级焦点（快捷键）"
                self.didRead(result, anchor: anchor, subject: subject, reader: reader)
            }
        }
    }

    // MARK: 真窗口

    /// 这一段在 `swift test` 里跑不到（没有 NSApplication 撑着开面板不可靠），
    /// 装机时按 `[SelectionBubble] 弹气泡` 那行日志核对位置与字符数。
    private func showPanel(_ text: String, at anchor: CGPoint) {
        let items = SelectionBubbleItem.items(for: settings.actions)
        guard !items.isEmpty else {
            NSLog("%@", "[SelectionBubble] 四格全关着，没地方摆，不弹")
            return
        }
        guard let screen = screen(for: anchor) else {
            NSLog("%@", "[SelectionBubble] 鼠标点不在任何屏幕上，不弹")
            return
        }
        let panel = ensurePanel(cellCount: items.count)
        let view = SelectionBubbleView(items: items)
        view.onAction = { [weak self] id in self?.perform(id, on: text) }
        panel.contentView = view
        bubbleView = view
        let frame = SelectionBubbleLayout.panelFrame(anchor: anchor, cellCount: items.count,
                                                     visible: screen.visibleFrame)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: SelectionBubbleSettings.autoHideAfter,
                                             repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        let ids = items.map(\.id).joined(separator: ",")
        NSLog("%@", "[SelectionBubble] 弹气泡：\(text.count) 个字符，格子 \(ids)，位置 \(frame)")
    }

    private func ensurePanel(cellCount: Int) -> SelectionBubblePanel {
        if let panel { return panel }
        // 初始尺寸按当下这几格算；每次弹之前都会重新 setFrame，所以真正决定大小的是那一句。
        let made = SelectionBubblePanel(cellCount: cellCount)
        panel = made
        return made
    }

    /// 气泡该摆在哪块屏上：鼠标点落在哪块就是哪块。多屏时这一条决定 visibleFrame 用谁的，
    /// 用错了就把气泡弹到另一台显示器的菜单栏底下。
    private func screen(for point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// 收气泡。`public` 是给 App 层和测试的：功能关掉、截图遮罩起来时都要能喊一声。
    public func dismiss() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        bubbleView = nil
        panel?.orderOut(nil)
    }

    // MARK: 应用切换

    /// 人已经去别的 App 了：刚才那一划的字作废，正在弹的那条也收掉。
    /// 单拆一句是给测试的 —— 真通知要等工作区换一个进程，用例里改一个 pid 就够了。
    func noteAppSwitch() {
        pendingToken += 1
        dismiss()
    }

    // MARK: 四格

    func perform(_ id: String, on text: String) {
        // 先收气泡再做事：复制那条要让粘贴板监听看见新内容，搜索/翻译要开浏览器，
        // 无论哪一样，气泡留在屏幕上都只是挡字。
        dismiss()
        switch id {
        case "copy":
            write(text)
        case "search":
            search(text)
        case "translate":
            open(Self.translateURL(text))
        case "speak":
            speak(text)
        default:
            NSLog("%@", "[SelectionBubble] 不认识的格子：\(id)")
        }
    }

    /// 写粘贴板。真那一手就三行，`SelectionBubbleSearchEngine` 那两家「页面不吃 URL 预填」的
    /// 也靠它兜底。**动的是用户那份**，所以它走 `pasteboardWrite` 那个接缝：测试入口里默认是
    /// 一本假账，用例忘了换的最坏结果是「没写进去」，不会是「跑单测把用户刚复制的东西顶掉了」。
    private func write(_ text: String) {
        pasteboardWrite(text)
    }

    // MARK: 搜索（走哪一家由偏好说了算）

    /// 搜索那一格的全部决定都在这三行：**用哪条模板**（`settings.searchTarget`，纯函数在
    /// `SelectionBubbleSearchEngine.resolvedTemplate`）＋ **要不要先把字放进粘贴板**。
    ///
    /// 为什么要「先复制」这一手：ChatGPT 那类页面的提问框**没有官方承诺的 URL 预填**，
    /// 参数名各家也在变（社区里同一个 `?q=` 时灵时不灵）。这一格点下去的结果如果只是
    /// 「浏览器开了、字没进去、也没人替他复制」，等于白跑一趟；复制那一下只多一条正常入库的
    /// 粘贴板历史，换来的是「页面打开后 ⌘V 就能问」。真能预填的那几家不复制 ——
    /// 结果页压根用不着粘贴板，多写一次只是弄脏用户刚复制的东西。
    private func search(_ text: String) {
        let target = settings.searchTarget
        NSLog("%@", Self.searchLogLine(engine: settings.searchEngine,
                                       template: target.template,
                                       copiesTextFirst: target.copiesTextFirst))
        if target.copiesTextFirst { write(text) }
        open(SelectionBubbleLinks.searchURL(text, template: target.template))
        // 排在 `open` **之后**：这一手是给「刚被打开的那一页」补的，先贴再开就成了
        // 「往此刻前台那个窗口贴一句莫名其妙的话」。能不能排由 `searchAutoPaste` 那四个条件说了算
        // （真能 URL 预填的那六家压根没写粘贴板，那就没有「贴我们刚复制的那句」这回事）。
        if settings.searchAutoPaste { schedulePaste(of: text) }
    }

    /// 排一次「打开之后再替用户按 ⌘V」。抽出来是因为延时那一档在测试里要能自己放行。
    private func schedulePaste(of text: String) {
        pasteScheduler(SelectionBubbleSettings.autoPasteDelay) { [weak self] in
            self?.pasteIfStillSafe(text)
        }
    }

    /// 到点那一刻的两道闸 + 投键。**判据取「现在」而不是「点下去那一刻」**：这一秒多里
    /// 用户可能又复制了别的东西、也可能已经切走了 App，那时候贴出去的是他没打算填的内容。
    ///
    /// 顺序也是定好的：粘贴板先。贴错内容（把别人刚复制的东西打进一个他没准备的框）
    /// 比贴错窗口（贴进我们自己的菜单栏面板，什么也不会发生）更坏，所以先把它挡住。
    private func pasteIfStillSafe(_ text: String) {
        // 那 1.2 秒里偏好可能已经变了（关掉这一格、改了引擎、甚至关了总开关）—— 用当下的快照再判一次。
        guard settings.searchAutoPaste else {
            NSLog("%@", "[SelectionBubble] 自动贴没做：等的时候这一手已经关了")
            return
        }
        let gate = SelectionBubbleSettings.pasteGate(
            pasteboardStillHoldsOurText: pasteboardString() == text,
            frontIsOurOwnApp: ourBundleID != nil && frontmostApp()?.bundleID == ourBundleID)
        NSLog("%@", Self.autoPasteLogLine(gate: gate, text: text))
        guard gate == .inject else { return }
        let posted = postPasteKeys()
        NSLog("%@", "[SelectionBubble] 自动贴\(posted ? "：已投出 ⌘V" : "：投失败（事件造不出来）")")
    }

    /// 「自动贴这一趟到底做了什么/为什么没做」那一行的正文，抽成纯函数（抽的理由同
    /// `searchLogLine`：`NSLog` 在用例里拿不到，而装机时「点了 AI 却没见字进去」全靠这一句分锅）。
    ///
    /// 三条各说清一件不同的事：投了（谁都能看懂）、粘贴板被人换掉了（这时**不贴是对的**）、
    /// 前台是我们自己（同样是**不贴是对的**）。把后两条写成一句「没贴」就分不出
    /// 是闸在做对的事，还是这一手压根没上场。
    static func autoPasteLogLine(gate: SelectionBubbleSettings.PasteGate,
                                 text: String) -> String {
        switch gate {
        case .inject:
            return "[SelectionBubble] 自动贴：投一次 ⌘V（粘贴板还是那句 \(text.count) 个字符，前台不是我们自己）"
        case .pasteboardChanged:
            return "[SelectionBubble] 自动贴没做：粘贴板里已经不是刚复制的那 \(text.count) 个字符 —— 这时候贴出去的是别人的东西"
        case .frontIsOurs:
            return "[SelectionBubble] 自动贴没做：前台是我们自己的窗口，那一下 ⌘V 不该打进这里"
        }
    }

    /// 「搜索走哪一家」那一行的正文，抽成纯函数（抽的理由和 `successLogLine` 同一个：
    /// `NSLog` 在用例里拿不到，而这一句是装机清单判断「到底开了哪条网址、动没动粘贴板」的凭据，
    /// 写错方向没人会红）。
    ///
    /// 一句里要说清**三件互相独立**的事，少一件就归错因：
    ///  - `engine`：**偏好里选的那一家**（用户配的东西）；
    ///  - `template`：**实际用的那条模板**。选了自定义却还没填成网址时，前者是 `custom`、
    ///    后者是退回那一家 —— 只印前半句就会读成「开的是我自己写的那条」，而这正是最难查的那种错配；
    ///  - 查询有没有拼进 URL、有没有替用户写粘贴板 —— 这两件对 `chatgpt` / `copilot` /
    ///    `perplexity` **同时成立**（模板带占位符，而 `kind == .ai` 又要求复制），
    ///    所以不能像上一版那样只按 `copiesTextFirst` 二选一，那样对那三家是说反的。
    static func searchLogLine(engine: SelectionBubbleSearchEngine,
                              template: String, copiesTextFirst: Bool) -> String {
        let prefill = SelectionBubbleLinks.prefillsQuery(template)
        let how: String
        switch (prefill, copiesTextFirst) {
        case (true, true): how = "查询拼进 URL，同时把这段字放进粘贴板备着 ⌘V"
        case (true, false): how = "查询拼进 URL，不碰粘贴板"
        case (false, true): how = "这一页不吃 URL 预填：已放进粘贴板，打开后 ⌘V"
        case (false, false): how = "只打开这一页，不碰粘贴板"
        }
        return "[SelectionBubble] 搜索走 \(engine.rawValue) → \(template) —— \(how)"
    }

    // MARK: 朗读

    /// 朗读用系统自带的合成器：不装东西、不要网络、不要密钥。
    /// 再点一次是把上一段掐掉念新的（气泡收得比念完快，所以不做「暂停/继续」那种状态）。
    private func speak(_ text: String) {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.voice = AVSpeechSynthesisVoice(language: Self.speechLanguage())
            ?? AVSpeechSynthesisVoice(language: "en-US")
        speech.speak(utterance)
        NSLog("%@", "[SelectionBubble] 朗读 \(text.count) 个字符，音色 \(utterance.voice?.identifier ?? "系统默认")")
    }

    /// 取的是「这段字大概是什么语言」—— 选中的文字我们读得到，但没有语言码，
    /// 只能跟着系统语言走。中英混排时念不准，这一档一期就这样。
    private static func speechLanguage() -> String {
        SelectionBubbleLinks.targetLanguage(from: Locale.current)
    }

    /// 上屏那一句走 `openURL` 接缝（真值是 `NSWorkspace.shared.open`）。浏览器一开就收不回来，
    /// 所以用例里换成记录用的闭包，**这一层才谈得上「选了必应就该开必应」这种断言**。
    private func open(_ url: URL?) {
        guard let url else {
            NSLog("%@", "[SelectionBubble] 拼不出链接，这一格没做事")
            return
        }
        NSLog("%@", "[SelectionBubble] 打开 \(url.absoluteString.prefix(80))")
        openURL(url)
    }

    /// 拆出来给测试：链接拼装是纯函数，浏览器那一开就收不回来。
    /// 搜索那一格**不再有对应的静态入口** —— 它的模板来自偏好（`settings.searchTarget`），
    /// 写死一条在这里就等于在控制器里私藏一份 Google，正是那张表要消灭的东西。
    static func translateURL(_ text: String) -> URL? {
        SelectionBubbleLinks.translateURL(text, targetLanguage: SelectionBubbleLinks.targetLanguage())
    }
}

/// 浮窗的档位。全部写成常量、由面板初始化时逐项照抄，是因为 `swift test` 里开不出真窗口，
/// 「不许抢焦点、不许盖满全屏、不许进录屏」这三条只能钉在值上（M37 就是来钉的）。
enum SelectionBubbleWindowConfig {
    /// 不激活、无边框：一激活就把焦点从那个文本 App 抢走，用户下一次⌘C 就打到我们头上了。
    static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    /// `.floating` 而不是 `CGShieldingWindowLevel`：那层是用来盖住整屏的（截图遮罩用的），
    /// 气泡只要浮在内容上面就够。
    static let level: NSWindow.Level = .floating
    /// 不进录屏、不进屏幕共享：划的可能是密码框旁边那段字。
    static let sharingType: NSWindow.SharingType = .none
    /// 全屏 App 的那一屏也要能弹出来，不然在 Safari 全屏读文档这条功能就是哑的。
    static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    static let isOpaque = false
    static let hidesOnDeactivate = false
}

/// 气泡那扇窗。
final class SelectionBubblePanel: NSPanel {
    init(cellCount: Int) {
        super.init(contentRect: NSRect(origin: .zero, size: SelectionBubbleLayout.capsuleSize(cellCount: cellCount)),
                   styleMask: SelectionBubbleWindowConfig.styleMask,
                   backing: .buffered,
                   defer: false)
        isOpaque = SelectionBubbleWindowConfig.isOpaque
        backgroundColor = .clear
        hasShadow = true
        level = SelectionBubbleWindowConfig.level
        sharingType = SelectionBubbleWindowConfig.sharingType
        hidesOnDeactivate = SelectionBubbleWindowConfig.hidesOnDeactivate
        isFloatingPanel = true
        worksWhenModal = true
        collectionBehavior = SelectionBubbleWindowConfig.collectionBehavior
        // 内容视图每次弹之前重建（格子要绑的是那一段字），这里不设。
        setAccessibilityLabel("Selection Bubble")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
