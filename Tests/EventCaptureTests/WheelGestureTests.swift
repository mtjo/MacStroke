// issue #75：「希望分别添加右键 + 滚轮上滚和滚轮下滚的触发手势」。
//
// 这一手有两半，取证也分两半：
//
// 1. 读数与节流（`WheelGestureParser` / `WheelGestureGate`）—— 纯逻辑，直接喂构造好的
//    读数逐条钉；另外用真的 `CGEvent` 滚轮事件验一遍符号约定与「行→点」退让，
//    因为那一半是这台机器上的 CG 字段行为，不是我们的算式。
// 2. 状态机（`CanvasManager`）—— 走 `UnmatchedGestureTests` 同一套路子：直接调
//    `eventCapture(_:didScrollWith:)`，从外面看三样东西：上膛收膛的调用序列、
//    这一发该不该吞（返回值）、抬手时前台应用到底收到了几发合成事件
//    （`syntheticEventSink`）。判据一个都不取自被测对象自己声明的状态。
//
// 真那条 CGEventTap 需要辅助功能授权，命令行测试进程里没有，所以这里验的是
// 「窗口什么时候开、什么时候收、事件该不该拦」这套判定，不是 tap 本身能不能建。
// tap 落地由装机清单里那一步实测（按住右键滚一格，日志出现 armed/fired）。
import XCTest
import AppKit
import CoreGraphics
@testable import EventCapture
@testable import GestureEngine

final class WheelGestureTests: XCTestCase {

    private final class FixedDelegate: CanvasManagerDelegate {
        var matches = false
        private(set) var completeStrokeCalls = 0

        @discardableResult
        func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String) -> Bool {
            completeStrokeCalls += 1
            return matches
        }
    }

    private var delegate: FixedDelegate!
    private var manager: CanvasManager!
    private var capture: EventCapture!
    private var armedLog: [Bool] = []
    private var firedDirections: [WheelGestureDirection] = []
    private var postedButtons: [CGEventType] = []

    /// 一次触发所需的间隔之上（`WheelGestureGate.minimumInterval` = 0.09）。
    private static let notch: TimeInterval = 0.2

    override func setUp() {
        super.setUp()
        delegate = FixedDelegate()
        manager = CanvasManager()
        capture = EventCapture()
        manager.delegate = delegate
        capture.delegate = manager
        capture.wheelDelegate = manager
        armedLog = []
        firedDirections = []
        postedButtons = []
        manager.isWheelGestureEnabled = { true }
        manager.wheelCaptureArmer = { [weak self] armed in self?.armedLog.append(armed) }
        manager.onWheelGesture = { [weak self] direction in
            self?.firedDirections.append(direction)
            return true
        }
        manager.syntheticEventSink = { [weak self] event, _ in
            self?.postedButtons.append(event.type)
        }
    }

    override func tearDown() {
        manager.syntheticEventSink = nil
        manager.cancelStroke()
        capture.stop()
        delegate = nil
        manager = nil
        capture = nil
        super.tearDown()
    }

    // MARK: - 符号约定：正号 = 上滚

    /// 用真 CGEvent 验，而不是只验我们的算式：这条约定的来源是长截图那边
    /// 「要向下滚得把 wheel1 取负再投」（`ScreenshotScrollCapture.postScroll`），
    /// 搞反了就是「上滚切下一页」，而用户在偏好里怎么调都调不回来。
    func testRealWheelEventSignMeansUp() {
        let up = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                         wheel1: 3, wheel2: 0, wheel3: 0)
        let down = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                           wheel1: -3, wheel2: 0, wheel3: 0)
        XCTAssertEqual(WheelGestureParser.reading(from: up!)?.direction, .up)
        XCTAssertEqual(WheelGestureParser.reading(from: down!)?.direction, .down)
        XCTAssertEqual(WheelGestureParser.reading(from: up!)?.lines, 3)
    }

    /// 触控板那种「只有点增量」的事件，CG 自己会把它归一成「格」：本机实测
    /// （/tmp/wheelprobe/probe.swift）`units: .pixel, wheel1: -40` 出来的三个字段是
    /// 整数行 -4、定点行 -4.0、点 -40 —— 第 2、3 档的量纲不同，别当成同一个数。
    /// 这里钉的是「我们的读法跟 CG 的归一结果一致」，即 40 点读成 4 格。
    func testPixelConstructorNormalisesIntoLines() {
        let trackpad = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: -40, wheel2: 0, wheel3: 0)!
        XCTAssertEqual(trackpad.getIntegerValueField(.scrollWheelEventDeltaAxis1), -4,
                       "前提：CG 已把 40 点归成 4 格（自证这条实测还成立）")
        let reading = WheelGestureParser.reading(from: trackpad)
        XCTAssertEqual(reading?.lines, -4, "读到的格数要与 CG 的归一一致：40 点 = 4 格")
        XCTAssertEqual(reading?.direction, .down)
    }

    /// 惯性滚动的碎步：整数行是 0，只有定点行（带小数的格）。只认整数行就会把这些发
    /// 全读成「没动」，触控板上「按住右键两指一推」什么也不发生。
    func testFractionalLinesWithoutIntegerLinesAreRead() throws {
        let event = zeroDeltaEvent()
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0,
                       "前提：整数行这一档是 0")
        let reading = WheelGestureParser.reading(from: event)
        XCTAssertEqual(try XCTUnwrap(reading?.lines), 0.3, accuracy: 0.0001,
                       "定点行本身就是「格」，不能再折")
        XCTAssertEqual(reading?.direction, .up)
    }

    /// 最后一档兜底：点增量要除以 10 才回到「格」。不折的话门槛（1 格）在点量纲上等于
    /// 第一发就够，两指一推的几十发瞬间刷满 —— 声音直接拉满 / 连翻八页。
    func testPointDeltaIsScaledIntoLines() {
        let event = zeroDeltaEvent()
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -40)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0, "前提：整数行是 0")
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), 0, accuracy: 0.0001,
                       "前提：定点行也是 0，这才是在测第三档")
        XCTAssertEqual(WheelGestureParser.lineDelta(of: event), -4, accuracy: 0.0001,
                       "40 点 = 4 格：与上一条 CG 自己归一的结果对齐")
    }

    /// 横向滚轮（触控板两指左右推）不是这个触发。
    func testHorizontalOnlyWheelIsNotAReading() {
        let sideways = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: 0, wheel2: 3, wheel3: 0)
        XCTAssertNil(WheelGestureParser.reading(from: sideways!),
                     "轴 1 不动就不是这个触发，硬读成「上滚」会把横向滚动也吞掉")
    }

    func testZeroLinesHasNoDirection() {
        XCTAssertNil(WheelGestureParser.reading(from: zeroDeltaEvent()),
                     "读不出格数就返回 nil：调用方据此把事件原样交回前台应用")
    }

    /// 时间戳那一档退让。远程控制、长截图那些**注入**的滚轮事件 `timestamp` 压根没填，
    /// 读出来是 0；同一个窗口里两发都 0 的话，`WheelGestureGate` 从第二次起
    /// 「差值 < 最小间隔」恒成立，节流会把后续触发一口吞干净 —— 症状是「只切得动一次」，
    /// 比读错方向难查得多（而且只在注入源上出现，用鼠标手拨永远试不出来）。
    /// 这里只钉「退让确实生效」：拿到的是当前时刻（>0、与本机开机时长同量级），不是那个 0。
    func testInjectedEventsFallBackToTheLiveClock() {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: 1, wheel2: 0, wheel3: 0)!
        XCTAssertEqual(event.timestamp, 0, "前提：合成事件的 timestamp 没填（填了这条就不在测退让）")
        let now = WheelGestureParser.seconds(of: event)
        let uptime = ProcessInfo.processInfo.systemUptime
        XCTAssertGreaterThan(now, 0, "读回 0 = 所有触发挤在同一瞬间，间隔闸会吃掉第二发")
        XCTAssertGreaterThan(now, uptime - 5, "读的得是开机起算的时钟，不然跟真事件的戳没法混用")
        XCTAssertLessThanOrEqual(now, uptime + 5)
    }

    // MARK: - 节流：一次拨动只算一次

    func testGateFiresOncePerNotch() {
        var gate = WheelGestureGate()
        XCTAssertTrue(gate.accept(reading(lines: 1, at: 0)))
        XCTAssertTrue(gate.accept(reading(lines: -1, at: Self.notch)), "隔得够久的第二格该再算一次")
    }

    func testGateFoldsAFloodIntoSeparateTriggers() {
        // 高分辨率滚轮 / 触控板惯性：一整格滚动被拆成 4 发碎增量、每 10ms 一发
        // → 30 发就是 7.5 格、跨 0.3 秒。
        // 取 0.25 而不是 0.1：0.1 在二进制里加十次是 0.99999…，门槛会差一发，
        // 这条判据就变成在测浮点累加而不是测闸门。
        var gate = WheelGestureGate()
        var fired: [Int] = []
        for step in 0..<30 {
            if gate.accept(reading(lines: 0.25, at: Double(step) * 0.01)) { fired.append(step) }
        }
        XCTAssertEqual(fired, [3, 12, 21],
            "0.3 秒内 30 发碎增量只能算三下：照单全收就是切一次滚轮翻页八次 / 音量直接拉满")
    }

    /// 另一头：鼠标逐格硬砸（每发都是完整一格）时，门槛挡不住，靠的是 90ms 间隔闸。
    /// 0.3 秒里 30 发 → 4 次。没有这道闸，快速滚动会把「音量 +1 档」变成一路拉满。
    func testGateCapsNotchByNotchFloodingAtTheThrottleInterval() {
        var gate = WheelGestureGate()
        var fired = 0
        for step in 0..<30 {
            if gate.accept(reading(lines: 1, at: Double(step) * 0.01)) { fired += 1 }
        }
        XCTAssertEqual(fired, 4, "第一发立刻算一次，之后每 90ms 最多一次")
    }

    func testGateDoesNotFireBelowOneNotch() {
        var gate = WheelGestureGate()
        XCTAssertFalse(gate.accept(reading(lines: 0.6, at: 0)))
        XCTAssertFalse(gate.accept(reading(lines: 0.3, at: Self.notch)),
                       "累计 0.9 格不够一档，一次都不能算")
        XCTAssertTrue(gate.accept(reading(lines: 0.2, at: Self.notch * 2)),
                      "补到 1.1 格才落这一次")
    }

    /// 反向先清账：上滚剩的半格不该把下滚的第一格吃掉（否则「来回滚一次都不动」）。
    func testGateClearsTheBalanceOnReversal() {
        var gate = WheelGestureGate()
        XCTAssertFalse(gate.accept(reading(lines: 0.6, at: 0)))
        XCTAssertFalse(gate.accept(reading(lines: -0.6, at: Self.notch)),
                       "换方向时旧的 0.6 要作废，不能相抵成 0 再慢慢攒")
        XCTAssertTrue(gate.accept(reading(lines: -0.9, at: Self.notch * 2)))
    }

    func testGateResetDropsTheThrottle() {
        var gate = WheelGestureGate()
        XCTAssertTrue(gate.accept(reading(lines: 1, at: 0)))
        XCTAssertFalse(gate.accept(reading(lines: 1, at: 0.01)), "同一瞬间的第二格被间隔闸拦住")
        gate.reset()
        XCTAssertTrue(gate.accept(reading(lines: 1, at: 0.02)),
                      "新的窗口必须把上一段的 lastFired 也清掉，否则症状是「每次第一次按下都不灵」")
    }

    // MARK: - 窗口：只在按住起手键到松开之间上膛

    func testArmsOnTriggerDownAndDisarmsOnRelease() {
        pressTrigger()
        XCTAssertEqual(armedLog, [true], "起手键按下即上膛：这一刻之前来的滚轮都不该归它管")

        XCTAssertTrue(scrollUp())
        XCTAssertEqual(armedLog, [true], "触发过程中不许偷偷收膛")

        releaseTrigger()
        XCTAssertEqual(armedLog, [true, false], "抬手即收膛：常驻但不常开")
    }

    func testMasterSwitchOffNeverArms() {
        manager.isWheelGestureEnabled = { false }
        pressTrigger()
        releaseTrigger()
        XCTAssertTrue(armedLog.isEmpty, "关掉时连一次 tapEnable 往返都不该发")
    }

    /// 反向对照：没配总开关（闭包压根没挂上）也不上膛 —— 默认等于原版行为。
    func testMissingPreferenceClosureDoesNotArm() {
        manager.isWheelGestureEnabled = nil
        pressTrigger()
        XCTAssertTrue(armedLog.isEmpty)
        releaseTrigger()
    }

    /// 「绘制手势」录制态里滚轮掺进来会同时切标签页，那画面没法解释。
    func testNotArmedWhileDrawingARuleGesture() {
        manager.isRecordingGesture = true
        pressTrigger()
        XCTAssertTrue(armedLog.isEmpty, "录制态只该收轨迹，滚轮一律交回前台应用")
        releaseTrigger()
    }

    // MARK: - 拦不拦：没接住就一个事件都不吞

    func testWheelOutsideAWindowIsNotConsumed() {
        XCTAssertFalse(scrollUp(), "没按住起手键时的滚轮跟本功能无关")
        XCTAssertTrue(firedDirections.isEmpty)
    }

    func testUnboundDirectionLeavesTheScrollAlone() {
        manager.onWheelGesture = { _ in false }
        pressTrigger()
        XCTAssertFalse(scrollUp(),
                       "那一方向配的是「无」/ 动作没做成 —— 页面必须照常滚")
        XCTAssertTrue(firedDirections.isEmpty)
        // 抬手时没触发过滚轮 → 走原来的路径，把这次右键还给前台应用。
        XCTAssertEqual(releaseTrigger(), true)
        XCTAssertEqual(postedButtons, [.rightMouseDown, .rightMouseUp])
    }

    func testFiredDirectionSwallowsTheWheel() {
        pressTrigger()
        XCTAssertTrue(scrollUp())
        XCTAssertEqual(firedDirections, [.up])
        releaseTrigger()
    }

    func testTwoDirectionsAreIndependentTriggers() {
        // issue #75 要的就是「分别添加」：上下两档各走各的，互不顶替。
        pressTrigger()
        XCTAssertTrue(scrollDown())
        releaseTrigger()
        pressTrigger()
        XCTAssertTrue(scrollUp())
        releaseTrigger()
        XCTAssertEqual(firedDirections, [.down, .up])
    }

    /// issue #59 那条规矩在滚轮上同样成立：按住该让位的修饰键时不触发。
    func testSuppressedModifierLetsTheWheelThrough() {
        manager.suppressedModifiers = { [.command] }
        pressTrigger()
        XCTAssertFalse(scrollUp(modifiers: [.command]),
                       "按住 ⌘ 滚轮本来就另有用途（多数浏览器 = 横向滚），这里不能抢")
        XCTAssertTrue(firedDirections.isEmpty)
        releaseTrigger()
    }

    // MARK: - 抬手：触发过就不再匹配、也不再回放

    /// 这条是本功能最容易漏的一手：切完标签页还凭空弹出右键菜单，正是 issue #73 里
    /// 用户抱怨的那种「我没要菜单」。
    func testReleaseAfterAFireDoesNotReplayTheClick() {
        pressTrigger()
        XCTAssertTrue(scrollUp())
        let consumed = releaseTrigger()

        XCTAssertTrue(consumed, "抬手那一下也要吞掉")
        XCTAssertTrue(postedButtons.isEmpty,
                      "不该有任何合成点击投给前台应用：\(postedButtons.map { $0.rawValue })")
        XCTAssertEqual(delegate.completeStrokeCalls, 0,
                       "触发过滚轮就不该再拿那半条弧线去匹配，否则一次滚轮叠两个动作")
    }

    /// 反向对照：没触发滚轮时，抬手照常走原来的回放路径（不能因为新分支把老行为改了）。
    func testReleaseWithoutAFireStillReplaysTheClick() {
        pressTrigger()
        let consumed = releaseTrigger()

        XCTAssertTrue(consumed)
        XCTAssertEqual(postedButtons, [.rightMouseDown, .rightMouseUp],
                       "纯单击仍然是那次右键：这功能不该让右键菜单凭空消失")
    }

    /// 触发了滚轮、但那之后又画了一段轨迹 —— 抬手时仍以「已经触发过」为准，
    /// 不匹配也不回放（一条弧线加一次滚轮是两个动作，只留用户明确要的那一次）。
    func testDrawingAfterAFireDoesNotReopenMatching() {
        pressTrigger()
        XCTAssertTrue(scrollUp())
        _ = send(.right, .moved, at: 40)
        releaseTrigger()

        XCTAssertEqual(delegate.completeStrokeCalls, 0)
        XCTAssertTrue(postedButtons.isEmpty)
    }

    /// 收膛必须跟着手势结束走：Synergy 瞬移取消那一手也得收，否则膛会一直开着，
    /// 之后每一发滚轮都被吞掉（症状 = 整个系统「滚不动了」）。
    func testSynergyCancellationAlsoDisarms() {
        // 起手点贴屏幕边缘，下一发瞬移到屏幕中央 —— 原版认的这种取消走 resetGestureState。
        let edge = NSScreen.main!.frame.minX + 5
        _ = send(.right, .down, at: edge)
        _ = send(.right, .moved, at: NSScreen.main!.frame.midX, y: NSScreen.main!.frame.midY)
        XCTAssertEqual(armedLog, [true, false], "取消这一手要把膛收掉")
        XCTAssertFalse(manager.capturing)
    }

    /// 上一段窗口触发过、下一段窗口必须重新算账（闸门与 wheelFired 都在复位里清）。
    func testSecondWindowStartsClean() {
        pressTrigger()
        XCTAssertTrue(scrollUp())
        releaseTrigger()

        pressTrigger()
        XCTAssertTrue(scrollUp(), "上一段的 lastFired / wheelFired 不该把这一次吃掉")
        releaseTrigger()
        XCTAssertEqual(firedDirections, [.up, .up])
    }

    /// 同一条复位，但卡着节流的时间轴走：上面那条每次 `fire` 之间隔 0.2 秒（比 90ms 的间隔闸宽），
    /// 所以**删掉复位里的 `wheelGate.reset()` 它也照绿** —— 真用户的下一次按下可不等 90ms：
    /// 松手、再按住、再滚一格，两格之间经常不到 0.1 秒，那一格要是被上一段的 `lastFired`
    /// 吃掉，症状就是「第二次按下没反应，得等一会儿才灵」。
    func testNewWindowIsNotThrottledByThePreviousOne() {
        pressTrigger()
        XCTAssertTrue(fireWheel(lines: 1, at: 100))
        releaseTrigger()

        pressTrigger()
        XCTAssertTrue(fireWheel(lines: 1, at: 100.02),
                      "窗口结束必须把闸门的账清掉：上一段 20ms 前的 lastFired 不该吃掉这一格")
        releaseTrigger()
        XCTAssertEqual(firedDirections, [.up, .up])
    }

    // MARK: - EventCapture 侧的膛态

    func testWheelStartsDisarmedAndDisarmIsIdempotent() {
        XCTAssertFalse(capture.isWheelCaptureArmed, "没按下起手键之前那条监听不该是开的")
        capture.setWheelCaptureArmed(false)
        XCTAssertFalse(capture.isWheelCaptureArmed, "收一把没开过的膛不该改状态、也不该建 tap")
    }

    // MARK: - 驱动

    private func pressTrigger() { _ = send(.right, .down, at: 100) }
    @discardableResult private func releaseTrigger() -> Bool { send(.right, .up, at: 100) }

    @discardableResult
    private func scrollUp(modifiers: Set<GestureModifier> = []) -> Bool { fire(.up, modifiers: modifiers) }
    @discardableResult
    private func scrollDown() -> Bool { fire(.down, modifiers: []) }

    private var clock: TimeInterval = 0

    @discardableResult
    private func fire(_ direction: WheelGestureDirection, modifiers: Set<GestureModifier>) -> Bool {
        clock += Self.notch
        return manager.eventCapture(capture, didScrollWith: WheelGestureReading(
            lines: direction == .up ? 1 : -1, timestamp: clock, modifiers: modifiers))
    }

    /// 自己带时间戳的那一发：`fire` 每次走 0.2 秒，卡不住 90ms 的间隔闸，
    /// 复位类判据要贴着时间轴走就得用它。
    @discardableResult
    private func fireWheel(lines: Double, at time: TimeInterval) -> Bool {
        manager.eventCapture(capture, didScrollWith: WheelGestureReading(lines: lines, timestamp: time))
    }

    @discardableResult
    private func send(_ button: MouseButton, _ phase: MousePhase, at coordinate: Double) -> Bool {
        send(button, phase, at: coordinate, y: coordinate)
    }

    @discardableResult
    private func send(_ button: MouseButton, _ phase: MousePhase, at x: Double, y: Double) -> Bool {
        manager.eventCapture(capture, didReceive: MouseEvent(
            point: GesturePoint(x: x, y: y), button: button, phase: phase))
    }

    private func reading(lines: Double, at timestamp: TimeInterval) -> WheelGestureReading {
        WheelGestureReading(lines: lines, timestamp: timestamp)
    }

    /// 一格没动的滚轮事件（三个字段全 0）。
    private func zeroDeltaEvent() -> CGEvent {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                wheel1: 0, wheel2: 0, wheel3: 0)!
    }
}
