// The preset gestures come in forward/reverse twins that share one static shape,
// so the hover replay is what tells them apart. These pin the truncation the
// animation draws with, and that a thumbnail is hover-tracking at all.
import XCTest
import AppKit
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
final class GestureReplayTests: XCTestCase {
    private let line: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]

    func testFullProgressKeepsTheStaticThumbnailUnchanged() {
        XCTAssertEqual(GestureStrokeRenderer.visiblePolyline(line, progress: 1), line)
    }

    func testPartialProgressStopsOnAnInterpolatedPoint() {
        // Two segments total: half way is the end of the first one.
        XCTAssertEqual(GestureStrokeRenderer.visiblePolyline(line, progress: 0.5),
                       [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])
        XCTAssertEqual(GestureStrokeRenderer.visiblePolyline(line, progress: 0.25),
                       [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0)])
        XCTAssertEqual(GestureStrokeRenderer.visiblePolyline(line, progress: 0),
                       [CGPoint(x: 0, y: 0)])
    }

    func testProgressIsClamped() {
        XCTAssertEqual(GestureStrokeRenderer.visiblePolyline(line, progress: -1).count, 1)
        XCTAssertEqual(GestureStrokeRenderer.visiblePolyline(line, progress: 3), line)
    }

    func testReplayRunsAndEndsStatic() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let animator = GestureReplayAnimator(view: view)
        XCTAssertEqual(animator.progress, 1, "an idle thumbnail shows the finished stroke")
        animator.start()
        XCTAssertEqual(animator.progress, 0)
        animator.stop()
        XCTAssertEqual(animator.progress, 1)
    }

    func testRuleTableThumbnailTracksTheMouse() {
        let thumb = GestureThumbView(frame: NSRect(x: 0, y: 0, width: 84, height: 84))
        thumb.points = line
        thumb.updateTrackingAreas()
        assertHoverTracking(thumb)
    }

    func testPickerCellsTrackTheMouse() throws {
        let entries = GestureTemplateProvider.shared.presetPickerEntries
        let window = PresetGesturePickerPanel().makeWindow(entries: entries)
        let grid = try XCTUnwrap(window.contentView?.subviews.first {
            $0.identifier?.rawValue == "PresetGestureGrid"
        })
        for cell in grid.subviews {
            assertHoverTracking(cell, label: cell.accessibilityLabel())
        }
    }

    /// A tooltip also installs a tracking area, so the owner has to be the view
    /// itself for `mouseEntered(with:)` to reach it.
    private func assertHoverTracking(_ view: NSView, label: String? = nil,
                                     file: StaticString = #filePath, line: UInt = #line) {
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.contains {
            $0.owner === view && $0.options.contains(.mouseEnteredAndExited)
        }, "no hover tracking on \(label ?? String(describing: type(of: view)))",
                      file: file, line: line)
    }

    /// The reason the replay exists: a twin is the same polyline walked backwards.
    func testReversedTwinsDivergeOnlyWhileDrawing() throws {
        let entries = GestureTemplateProvider.shared.presetPickerEntries
        let forward = try XCTUnwrap(entries.first { $0.name == "T" }).stroke
            .points.map { CGPoint(x: $0.x, y: $0.y) }
        let reversed = try XCTUnwrap(entries.first { $0.name == "T Revered" }).stroke
            .points.map { CGPoint(x: $0.x, y: $0.y) }
        XCTAssertEqual(GestureStrokeRenderer.visiblePolyline(forward, progress: 1),
                       GestureStrokeRenderer.visiblePolyline(reversed, progress: 1).reversed())
        XCTAssertNotEqual(GestureStrokeRenderer.visiblePolyline(forward, progress: 0.3),
                          GestureStrokeRenderer.visiblePolyline(reversed, progress: 0.3))
    }
}
