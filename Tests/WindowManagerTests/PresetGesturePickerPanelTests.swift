// The "Draw Gesture!" dialog must offer every preset the original combo box
// listed (8 arrows + 4 corners and 26 letters, each with a reversed twin), now
// as clickable thumbnails on a single page instead of a text menu.
import XCTest
import AppKit
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
final class PresetGesturePickerPanelTests: XCTestCase {
    @MainActor
    func testSinglePageShowsEveryPreset() throws {
        let entries = GestureTemplateProvider.shared.presetPickerEntries
        XCTAssertEqual(entries.count, 68)

        let window = PresetGesturePickerPanel().makeWindow(entries: entries)
        let content = try XCTUnwrap(window.contentView)
        let grid = try XCTUnwrap(
            content.subviews.first { $0.identifier?.rawValue == "PresetGestureGrid" }
        )
        XCTAssertEqual(grid.subviews.count, entries.count)
        XCTAssertEqual(Set(grid.subviews.compactMap { $0.accessibilityLabel() }),
                       Set(entries.map(\.name)))
        // No scrolling: the whole grid sits inside the window's content view.
        XCTAssertTrue(content.bounds.contains(grid.frame),
                      "grid \(grid.frame) does not fit content \(content.bounds)")
    }
}
