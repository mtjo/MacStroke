//
//  CanvasManagerTests
//  MacStroke
//

import XCTest
@testable import EventCapture
@testable import GestureEngine

final class CanvasManagerTests: XCTestCase {

    private final class RecordingDelegate: CanvasManagerDelegate {
        private(set) var completedStrokes: [Stroke] = []
        private(set) var completedBundleIDs: [String] = []
        var matchResult = false

        @discardableResult
        func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String) -> Bool {
            completedStrokes.append(stroke)
            completedBundleIDs.append(bundleID)
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

    // MARK: - 额外触发按键（issue #53：中键 / 侧键 / 自定义键）

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

    func testMiddleButtonStartsGestureWhenEnabled() {
        manager.isTriggerButtonAllowed = { $0 == .middle }

        XCTAssertTrue(drawStroke(with: .middle))
        XCTAssertEqual(delegate.completedStrokes.count, 1, "中键起手应产出一条轨迹")
        XCTAssertFalse(manager.capturing)
    }

    func testMiddleButtonPassesThroughWhenDisabled() {
        // 反向对照：不勾任何额外按键时（默认状态），行为必须与原版一致。
        manager.isTriggerButtonAllowed = { _ in false }

        XCTAssertFalse(drawStroke(with: .middle), "关闭时中键事件必须原样放行")
        XCTAssertTrue(delegate.completedStrokes.isEmpty)
        XCTAssertFalse(manager.capturing)
    }

    func testRightButtonAlwaysStartsGestureRegardlessOfPreference() {
        // 右键是原版唯一的起手键，偏好判定不能把它关掉。
        manager.isTriggerButtonAllowed = { _ in false }

        XCTAssertTrue(drawStroke(with: .right))
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
        manager.isTriggerButtonAllowed = { $0 == .middle }

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
}
