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

        func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String) {
            completedStrokes.append(stroke)
            completedBundleIDs.append(bundleID)
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

    func testCollectsStrokeFromMouseDownToMouseUp() {
        let start = MouseEvent(
            point: GesturePoint(x: 0, y: 0),
            button: .left,
            phase: .down
        )
        manager.eventCapture(capture, didReceive: start)

        for i in 1..<20 {
            let move = MouseEvent(
                point: GesturePoint(x: Double(i), y: Double(i)),
                button: .left,
                phase: .moved
            )
            manager.eventCapture(capture, didReceive: move)
        }

        let end = MouseEvent(
            point: GesturePoint(x: 20, y: 20),
            button: .left,
            phase: .up
        )
        manager.eventCapture(capture, didReceive: end)

        XCTAssertEqual(delegate.completedStrokes.count, 1)
        XCTAssertEqual(delegate.completedStrokes[0].count, 21)
        XCTAssertFalse(manager.capturing)
    }

    func testRequiresMinimumPoints() {
        let start = MouseEvent(
            point: GesturePoint(x: 0, y: 0),
            button: .left,
            phase: .down
        )
        manager.eventCapture(capture, didReceive: start)

        let move = MouseEvent(
            point: GesturePoint(x: 1, y: 1),
            button: .left,
            phase: .moved
        )
        manager.eventCapture(capture, didReceive: move)

        let end = MouseEvent(
            point: GesturePoint(x: 2, y: 2),
            button: .left,
            phase: .up
        )
        manager.eventCapture(capture, didReceive: end)

        XCTAssertTrue(delegate.completedStrokes.isEmpty)
        XCTAssertFalse(manager.capturing)
    }

    func testRightClickIsSupported() {
        let start = MouseEvent(
            point: GesturePoint(x: 0, y: 0),
            button: .right,
            phase: .down
        )
        manager.eventCapture(capture, didReceive: start)

        for i in 1..<10 {
            let move = MouseEvent(
                point: GesturePoint(x: Double(i), y: Double(i)),
                button: .right,
                phase: .moved
            )
            manager.eventCapture(capture, didReceive: move)
        }

        let end = MouseEvent(
            point: GesturePoint(x: 10, y: 10),
            button: .right,
            phase: .up
        )
        manager.eventCapture(capture, didReceive: end)

        XCTAssertEqual(delegate.completedStrokes.count, 1)
        XCTAssertEqual(delegate.completedStrokes[0].count, 11)
    }
}
