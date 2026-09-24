// 「模拟右键」用原版工具栏的 RightClick.png，那是一枚纯黑图形，在深色侧边栏上
// 完全看不见；只有当模板图渲染才会跟随行文字颜色。
import XCTest
import AppKit
@testable import Preferences

final class PreferencesSidebarIconTests: XCTestCase {
    func testResourceIconIsTurnedIntoATemplate() {
        let source = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        XCTAssertFalse(source.isTemplate)
        XCTAssertTrue(sidebarIconImage(source).isTemplate)
    }

    /// `NSImage(named:)` hands out a cached instance, so flipping its flag in place
    /// would leak into every other place that draws the same asset.
    func testSourceImageIsNotMutated() {
        let source = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        _ = sidebarIconImage(source)
        XCTAssertFalse(source.isTemplate)
    }
}
