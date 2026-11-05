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

    /// 红叉与 ⌘W 必须只结束模态、**不**关掉窗口。
    ///
    /// 这里连着两场真机事故：
    /// - 2026-11-03 上午：关窗走 AppKit 动画，模态一停 `pick()` 返回、面板（窗口唯一
    ///   持有者）释放，动画的 display link 拍到已释放窗口 → `EXC_BAD_ACCESS`；
    /// - 同日下午：只拦 `performClose` 不够 —— 红叉的 action 实测是私有的 `_close:`，
    ///   窗口照关、模态永挂，整个 App 的点击与键盘都被吃掉。
    ///
    /// 所以判据必须走**真实按钮**：`performClick` 之后窗口仍在、choice 为 nil；
    /// 只测 `performClose` 会把后半场放过去。
    @MainActor
    func testCloseOnlyEndsTheModalSessionAndKeepsTheWindow() throws {
        let panel = PresetGesturePickerPanel()
        let window = panel.makeWindow(entries: [])
        XCTAssertFalse(window.isReleasedWhenClosed,
                       "窗口仍按关闭即释放：ARC 这边一松手就是重复释放")
        XCTAssertEqual(window.animationBehavior, .none,
                       "窗口还允许关窗动画：模态结束后动画可能还在跑")
        // 挪到屏外再显示，别让用例闪一下窗口。
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible)

        // ⌘W 那条：菜单发 performClose。
        window.performClose(nil)
        XCTAssertNil(panel.choice, "⌘W 没有当成「取消」")
        XCTAssertTrue(window.isVisible, "⌘W 把窗口关掉了：模态会话会永远挂着")

        // 红叉那条：真实按钮（action 是 _close:，绕过 performClose）。
        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton),
                                        "没有红叉：这一条判据压根没跑")
        closeButton.performClick(nil)
        XCTAssertNil(panel.choice, "红叉没有当成「取消」")
        XCTAssertTrue(window.isVisible,
                      "红叉把窗口关掉了：模态会话会永远挂着，整个 App 收不到点击和键盘")
        window.orderOut(nil)
    }
}
