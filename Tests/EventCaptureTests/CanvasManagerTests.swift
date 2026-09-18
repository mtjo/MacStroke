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
}
