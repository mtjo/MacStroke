//
//  CanvasManagerTests
//  MacStroke
//

import XCTest
import AppKit
@testable import EventCapture
@testable import GestureEngine

final class CanvasManagerTests: XCTestCase {

    private final class RecordingDelegate: CanvasManagerDelegate {
        private(set) var completedStrokes: [Stroke] = []
        private(set) var completedBundleIDs: [String] = []
        private(set) var completedReleasePoints: [CGPoint] = []
        var matchResult = false

        @discardableResult
        func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String,
                           releasePoint: CGPoint) -> Bool {
            completedStrokes.append(stroke)
            completedBundleIDs.append(bundleID)
            completedReleasePoints.append(releasePoint)
            return matchResult
        }
    }

    private let delegate = RecordingDelegate()
    private lazy var manager = CanvasManager()
    private lazy var capture = EventCapture()

    override func setUp() {
        super.setUp()
        manager.delegate = delegate
        capture.delegate = manager
    }

    override func tearDown() {
        capture.stop()
        manager.cancelStroke()
        super.tearDown()
    }

    func testCollectsStrokeFromRightMouseDownToMouseUp() {
        let start = MouseEvent(
            point: GesturePoint(x: 0, y: 0),
            button: .right,
            phase: .down
        )
        let consumedDown = manager.eventCapture(capture, didReceive: start)
        XCTAssertTrue(consumedDown, "right-mouse-down that starts a gesture must be consumed")

        for i in 1..<20 {
            let move = MouseEvent(
                point: GesturePoint(x: Double(i), y: Double(i)),
                button: .right,
                phase: .moved
            )
            manager.eventCapture(capture, didReceive: move)
        }

        let end = MouseEvent(
            point: GesturePoint(x: 20, y: 20),
            button: .right,
            phase: .up
        )
        manager.eventCapture(capture, didReceive: end)

        XCTAssertEqual(delegate.completedStrokes.count, 1)
        XCTAssertEqual(delegate.completedStrokes[0].count, 21)
        XCTAssertFalse(manager.capturing)
    }

    func testLeftButtonDoesNotStartGesture() {
        let start = MouseEvent(
            point: GesturePoint(x: 0, y: 0),
            button: .left,
            phase: .down
        )
        let consumed = manager.eventCapture(capture, didReceive: start)
        XCTAssertFalse(consumed, "left-mouse-down must pass through")
        XCTAssertFalse(manager.capturing)

        for i in 1..<20 {
            let move = MouseEvent(
                point: GesturePoint(x: Double(i), y: Double(i)),
                button: .left,
                phase: .moved
            )
            manager.eventCapture(capture, didReceive: move)
        }

        let end = MouseEvent(
            point: GesturePoint(x: 2, y: 2),
            button: .left,
            phase: .up
        )
        manager.eventCapture(capture, didReceive: end)

        XCTAssertTrue(delegate.completedStrokes.isEmpty)
    }

    func testRequiresMinimumPoints() {
        let start = MouseEvent(
            point: GesturePoint(x: 0, y: 0),
            button: .right,
            phase: .down
        )
        manager.eventCapture(capture, didReceive: start)

        let move = MouseEvent(
            point: GesturePoint(x: 1, y: 1),
            button: .right,
            phase: .moved
        )
        manager.eventCapture(capture, didReceive: move)

        let end = MouseEvent(
            point: GesturePoint(x: 2, y: 2),
            button: .right,
            phase: .up
        )
        manager.eventCapture(capture, didReceive: end)

        // Fewer than the minimum points means a plain right click, not a gesture.
        XCTAssertTrue(delegate.completedStrokes.isEmpty)
        XCTAssertFalse(manager.capturing)
    }

    func testCaptureFilterBlocksGestureStart() {
        manager.shouldCaptureGesture = { _ in false }

        let start = MouseEvent(
            point: GesturePoint(x: 0, y: 0),
            button: .right,
            phase: .down
        )
        let consumed = manager.eventCapture(capture, didReceive: start)

        XCTAssertFalse(consumed, "blocked apps must receive the right click untouched")
        XCTAssertFalse(manager.capturing)
        XCTAssertTrue(delegate.completedStrokes.isEmpty)
    }

    func testDisabledManagerPassesEventsThrough() {
        manager.isEnabled = false

        let start = MouseEvent(
            point: GesturePoint(x: 0, y: 0),
            button: .right,
            phase: .down
        )
        let consumed = manager.eventCapture(capture, didReceive: start)

        XCTAssertFalse(consumed)
        XCTAssertFalse(manager.capturing)
    }

    func testRecordingModeDeliversPointsInsteadOfMatching() {
        manager.isRecordingGesture = true
        var recordedPoints: [GesturePoint] = []
        manager.onGestureRecorded = { recordedPoints = $0 }

        let start = MouseEvent(
            point: GesturePoint(x: 0, y: 0),
            button: .right,
            phase: .down
        )
        manager.eventCapture(capture, didReceive: start)

        for i in 1..<15 {
            let move = MouseEvent(
                point: GesturePoint(x: Double(i), y: Double(i)),
                button: .right,
                phase: .moved
            )
            manager.eventCapture(capture, didReceive: move)
        }

        let end = MouseEvent(
            point: GesturePoint(x: 15, y: 15),
            button: .right,
            phase: .up
        )
        manager.eventCapture(capture, didReceive: end)

        XCTAssertFalse(manager.isRecordingGesture, "recording mode ends after one gesture")
        XCTAssertEqual(recordedPoints.count, 16)
        XCTAssertTrue(delegate.completedStrokes.isEmpty, "recorded gestures are not matched")
    }

    // MARK: - 手势起手键（issue #53：中键 / 侧键 / 自定义键合成一个）

    /// 用同一个按键画一条足够长的轨迹（down + moves + up），返回是否至少吃掉了一个事件。
    @discardableResult
    private func drawStroke(with button: MouseButton, pointCount: Int = 20) -> Bool {
        var consumed = manager.eventCapture(
            capture,
            didReceive: MouseEvent(point: GesturePoint(x: 0, y: 0), button: button, phase: .down)
        )
        for i in 1..<pointCount {
            let handled = manager.eventCapture(
                capture,
                didReceive: MouseEvent(
                    point: GesturePoint(x: Double(i), y: Double(i)),
                    button: button,
                    phase: .moved
                )
            )
            consumed = consumed || handled
        }
        let handled = manager.eventCapture(
            capture,
            didReceive: MouseEvent(
                point: GesturePoint(x: Double(pointCount), y: Double(pointCount)),
                button: button,
                phase: .up
            )
        )
        return consumed || handled
    }

    func testMiddleButtonStartsGestureWhenRecorded() {
        manager.isTriggerButtonAllowed = { $0 == .middle }

        XCTAssertTrue(drawStroke(with: .middle))
        XCTAssertEqual(delegate.completedStrokes.count, 1, "中键起手应产出一条轨迹")
        XCTAssertFalse(manager.capturing)
    }

    func testMiddleButtonPassesThroughWhenNotRecorded() {
        // 反向对照：起手键是别的键时（默认右键），中键行为必须与原版一致 = 放行。
        manager.isTriggerButtonAllowed = { $0 == .right }

        XCTAssertFalse(drawStroke(with: .middle), "未录成起手键时中键事件必须原样放行")
        XCTAssertTrue(delegate.completedStrokes.isEmpty)
        XCTAssertFalse(manager.capturing)
    }

    func testRecordedButtonReplacesTheRightButton() {
        // 合并成单个起手键后（issue #53）偏好判定说了算：录成中键，右键就原样
        // 交还给前台 App，不会再起手。
        manager.isTriggerButtonAllowed = { $0 == .middle }

        XCTAssertFalse(drawStroke(with: .right), "右键已不是起手键")
        XCTAssertTrue(delegate.completedStrokes.isEmpty)

        XCTAssertTrue(drawStroke(with: .middle))
        XCTAssertEqual(delegate.completedStrokes.count, 1)
    }

    func testUnsetTriggerCheckLeavesRightButtonAsTheOnlyTrigger() {
        // 没接线 = 原版：只有右键起手。
        XCTAssertTrue(drawStroke(with: .right))
        XCTAssertFalse(drawStroke(with: .middle))
        XCTAssertEqual(delegate.completedStrokes.count, 1)
    }

    func testExtraButtonOnlyMatchesTheRecordedNumber() {
        // 复刻 AppDelegate 的判定：编号 5 被录为自定义触发键。
        manager.isTriggerButtonAllowed = { $0 == .extra(5) }

        XCTAssertFalse(drawStroke(with: .extra(3)), "未绑定的侧键必须放行")
        XCTAssertTrue(delegate.completedStrokes.isEmpty)

        XCTAssertTrue(drawStroke(with: .extra(5)))
        XCTAssertEqual(delegate.completedStrokes.count, 1, "绑定的按键应产出一条轨迹")
    }

    func testDragOfAnotherButtonDoesNotJoinActiveGesture() {
        // 起手键录成右键（默认），中键的拖动不该并进这趟手势。
        manager.isTriggerButtonAllowed = { $0 == .right }

        let down = manager.eventCapture(
            capture,
            didReceive: MouseEvent(point: GesturePoint(x: 0, y: 0), button: .right, phase: .down)
        )
        XCTAssertTrue(down)

        for i in 1...4 {
            let handled = manager.eventCapture(
                capture,
                didReceive: MouseEvent(
                    point: GesturePoint(x: Double(i), y: 200 + Double(i)),
                    button: .middle,
                    phase: .moved
                )
            )
            XCTAssertFalse(handled, "进行中手势是右键，中键拖动不该并进来也不该被吃掉")
        }

        for i in 1...12 {
            XCTAssertTrue(
                manager.eventCapture(
                    capture,
                    didReceive: MouseEvent(
                        point: GesturePoint(x: Double(i), y: Double(i)),
                        button: .right,
                        phase: .moved
                    )
                ),
                "右键自己的拖动必须收进轨迹"
            )
        }

        let up = manager.eventCapture(
            capture,
            didReceive: MouseEvent(point: GesturePoint(x: 13, y: 13), button: .right, phase: .up)
        )
        XCTAssertTrue(up)
        XCTAssertEqual(delegate.completedStrokes.count, 1)
        XCTAssertEqual(
            delegate.completedStrokes.first?.count, 14,
            "起点 + 12 个右键拖动 + 终点，不含中键那几个点"
        )
    }

    func testSuspendedWhileRecordingTriggerButton() {
        manager.isSuspended = true

        let consumed = manager.eventCapture(
            capture,
            didReceive: MouseEvent(point: GesturePoint(x: 0, y: 0), button: .right, phase: .down)
        )

        XCTAssertFalse(consumed, "录制按键期间的试按不能被当起手")
        XCTAssertFalse(manager.capturing)
    }

    // MARK: - Suppressing modifiers (issue #59)

    func testNoSuppressionHookKeepsOriginalBehaviourWithModifiers() {
        // 没接线 = 原版行为：按住任何修饰键，右键轨迹照样是手势。
        let consumed = manager.eventCapture(
            capture,
            didReceive: MouseEvent(
                point: GesturePoint(x: 0, y: 0),
                button: .right,
                phase: .down,
                modifiers: [.command, .shift]
            )
        )

        XCTAssertTrue(consumed)
        XCTAssertTrue(manager.capturing)
    }

    func testSuppressedModifierBlocksGestureStart() {
        manager.suppressedModifiers = { [.command] }

        let consumed = manager.eventCapture(
            capture,
            didReceive: MouseEvent(
                point: GesturePoint(x: 0, y: 0),
                button: .right,
                phase: .down,
                modifiers: [.command]
            )
        )

        XCTAssertFalse(consumed, "按住 ⌘ 时这次右键必须原样交给前台 App")
        XCTAssertFalse(manager.capturing)
        XCTAssertTrue(delegate.completedStrokes.isEmpty)
    }

    func testUnlistedModifierStillStartsGesture() {
        // 反向对照：只勾了 ⌘，按 ⇧ 不该有任何影响。
        manager.suppressedModifiers = { [.command] }

        let consumed = manager.eventCapture(
            capture,
            didReceive: MouseEvent(
                point: GesturePoint(x: 0, y: 0),
                button: .right,
                phase: .down,
                modifiers: [.shift]
            )
        )

        XCTAssertTrue(consumed)
        XCTAssertTrue(manager.capturing)
    }

    func testSuppressionAppliesToEveryTriggerButton() {
        manager.isTriggerButtonAllowed = { $0 == .middle }
        manager.suppressedModifiers = { [.option] }

        let consumed = manager.eventCapture(
            capture,
            didReceive: MouseEvent(
                point: GesturePoint(x: 0, y: 0),
                button: .middle,
                phase: .down,
                modifiers: [.option]
            )
        )

        XCTAssertFalse(consumed, "修饰键让位规则对中键/侧键一样成立")
        XCTAssertFalse(manager.capturing)
    }

    func testModifierPressedMidStrokeDoesNotCancelGesture() {
        // 只判起手那一刻：起手后中途按下勾选的修饰键，这趟轨迹照常识别。
        manager.suppressedModifiers = { [.command] }

        let start = manager.eventCapture(
            capture,
            didReceive: MouseEvent(point: GesturePoint(x: 0, y: 0), button: .right, phase: .down)
        )
        XCTAssertTrue(start)

        for i in 1..<13 {
            manager.eventCapture(
                capture,
                didReceive: MouseEvent(
                    point: GesturePoint(x: Double(i), y: Double(i)),
                    button: .right,
                    phase: .moved,
                    modifiers: [.command]
                )
            )
        }

        let up = manager.eventCapture(
            capture,
            didReceive: MouseEvent(
                point: GesturePoint(x: 13, y: 13),
                button: .right,
                phase: .up,
                modifiers: [.command]
            )
        )
        XCTAssertTrue(up)
        XCTAssertEqual(delegate.completedStrokes.count, 1)
    }

    func testModifierTokenListRoundTrip() {
        XCTAssertEqual(Set(tokenList: "cmd,shift"), [.command, .shift])
        XCTAssertEqual(Set(tokenList: ""), [])
        XCTAssertEqual(Set(tokenList: "cmd,unknown"), [.command], "认不出的 token 直接忽略")
        // 存出来的串固定按 allCases 顺序，勾选先后不会改变磁盘内容。
        XCTAssertEqual(Set([.option, .command, .function]).tokenList, "cmd,opt,fn")
    }

    func testModifierEventFlagsRoundTrip() {
        // 录制框报的是 device-independent flags，存的还是同一份 token 串。
        XCTAssertEqual(Set(eventFlags: 0x100000 | 0x20000).tokenList, "cmd,shift")
        XCTAssertEqual(Set(eventFlags: 0x800000).tokenList, "fn")
        XCTAssertEqual(Set([.command, .option]).eventFlags, 0x180000)
        // 反向对照：caps-lock 这类没建模的位一律丢掉，录到的快捷键里
        // key code 自带的 flags 混不进来。
        XCTAssertEqual(Set(eventFlags: 0x10000).tokenList, "")
        XCTAssertEqual(Set<GestureModifier>().eventFlags, 0)
    }

    // MARK: - 抬手点翻回窗口服务坐标（issue #22：命中判定必须和 kCGWindowBounds 同一把尺）

    func testReleasePointIsFlippedIntoWindowServerSpace() {
        // 字面数字钉公式：主屏 1080 高时，AppKit 的 y=200（离屏底 200）= 窗口服务的 y=880
        // （离屏顶 880）。这一手写坏在界面上和日志里都看不出名堂（只会归到
        // `noWindowUnderCursor` 那一档），所以只能这样钉。
        XCTAssertEqual(CanvasManager.windowServerReleasePoint(GesturePoint(x: 300, y: 200),
                                                             primaryHeight: 1080),
                       CGPoint(x: 300, y: 880))
        XCTAssertEqual(CanvasManager.windowServerReleasePoint(GesturePoint(x: 500, y: 1080),
                                                             primaryHeight: 1080),
                       CGPoint(x: 500, y: 0), "屏最顶上（AppKit 的 y=屏高）在窗口服务里是 0")
        XCTAssertEqual(CanvasManager.windowServerReleasePoint(GesturePoint(x: 500, y: 0),
                                                             primaryHeight: 1080),
                       CGPoint(x: 500, y: 1080), "屏最底下反过来")
        XCTAssertNotEqual(CanvasManager.windowServerReleasePoint(GesturePoint(x: 300, y: 200),
                                                                primaryHeight: 1080).x,
                          200, "x 压根不该动")
    }

    func testFlippingTheSamePointTwiceIsTheOriginalPoint() {
        // 轨迹点是**已经翻过**那一套（`EventCapture` 采集时翻的）。这一手要是被人在
        // 别处再套一次，点会原地跳回对称位置 —— 「上下颠倒」这种症状最难认，
        // 所以把「自逆」钉成判据：翻两次 = 没翻。
        // 用 Double 而不是 CGFloat 比较，免得 32/64 位下的表示差被当成红。
        let p = GesturePoint(x: 123, y: 456)
        let once = CanvasManager.windowServerReleasePoint(p, primaryHeight: 1080)
        XCTAssertEqual(once.x, 123)
        XCTAssertEqual(once.y, 624)
        let twice = CanvasManager.windowServerReleasePoint(GesturePoint(x: once.x, y: once.y),
                                                          primaryHeight: 1080)
        XCTAssertEqual(twice.x, p.x)
        XCTAssertEqual(twice.y, p.y)
    }

    func testTheDelegateReceivesTheFlippedReleasePoint() {
        // 走完整事件链，断**调用处确实用上了这一翻**（上一组用例钉的是公式本身）。
        // 期望值不取被测函数，取的是同一个屏高来源 —— 免得函数写错、期望也跟着错。
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let down = MouseEvent(point: GesturePoint(x: 0, y: 0), button: .right, phase: .down)
        _ = manager.eventCapture(capture, didReceive: down)
        for i in 1..<20 {
            _ = manager.eventCapture(capture,
                                     didReceive: MouseEvent(point: GesturePoint(x: Double(i),
                                                                                y: Double(i)),
                                                            button: .right, phase: .moved))
        }
        _ = manager.eventCapture(capture,
                                 didReceive: MouseEvent(point: GesturePoint(x: 20, y: 40),
                                                        button: .right, phase: .up))

        XCTAssertEqual(delegate.completedReleasePoints.count, 1)
        XCTAssertEqual(delegate.completedReleasePoints[0].x, 20)
        XCTAssertEqual(delegate.completedReleasePoints[0].y, Double(primaryHeight) - 40,
                       "翻没翻，看的是 delegate 收到的那个 y 是不是 primaryHeight - 40")
    }
}
