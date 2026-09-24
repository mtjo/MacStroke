// The "Draw Gesture!" dialog must offer every preset the original combo box
// listed (8 arrows + 4 corners and 26 letters, each with a reversed twin), now
// as clickable thumbnails instead of a text menu.
import XCTest
import AppKit
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
final class PresetGesturePickerPanelTests: XCTestCase {
    @MainActor
    func testGridShowsEveryPreset() throws {
        let entries = GestureTemplateProvider.shared.presetPickerEntries
        XCTAssertEqual(entries.count, 68)

        let window = PresetGesturePickerPanel().makeWindow(entries: entries)
        let grid = try XCTUnwrap(
            window.contentView?.subviews.compactMap { ($0 as? NSScrollView)?.documentView }.first
        )
        XCTAssertEqual(grid.subviews.count, entries.count)
        XCTAssertEqual(Set(grid.subviews.compactMap { $0.accessibilityLabel() }),
                       Set(entries.map(\.name)))
    }
}
