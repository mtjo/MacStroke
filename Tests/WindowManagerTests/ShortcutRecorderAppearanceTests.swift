// 快捷键输入框曾在 macOS 26 上整块渲染成黑色（内容看不见）。原因是背景色以
// layer.backgroundColor = NSColor.controlBackgroundColor.cgColor 的形式在 init 时
// 冻结：CGColor 不带动态语义，取色时用的是「当时所在的 appearance」，视图还没进
// 窗口就先建好，就把深色主题的底色带进了浅色窗口。
// 现在改成 draw(_:) 里现取现画，所以浅色窗口必须是浅色底、深色窗口必须是深色底。
import XCTest
import AppKit
@testable import Preferences

final class ShortcutRecorderAppearanceTests: XCTestCase {

    func testLightWindowKeepsLightBackgroundEvenWhenBuiltUnderDarkAppearance() throws {
        let color = try renderRecorder(windowAppearance: .aqua)
        XCTAssertGreaterThan(color.redComponent, 0.8, "recorder background came out dark in a light window: \(color)")
        XCTAssertGreaterThan(color.greenComponent, 0.8)
        XCTAssertGreaterThan(color.blueComponent, 0.8)
    }

    /// The reverse half of the previous assertion: proves the fix resolves the
    /// dynamic colour instead of hardcoding white.
    func testDarkWindowKeepsDarkBackground() throws {
        let color = try renderRecorder(windowAppearance: .darkAqua)
        XCTAssertLessThan(color.redComponent, 0.5, "recorder background stayed light inside a dark window: \(color)")
        XCTAssertLessThan(color.greenComponent, 0.5)
        XCTAssertLessThan(color.blueComponent, 0.5)
    }

    /// Builds the recorder while the *current* drawing appearance is dark — the
    /// situation that used to freeze a dark CGColor into the layer — then mounts
    /// it in a window with the given appearance and samples a background pixel.
    private func renderRecorder(windowAppearance name: NSAppearance.Name) throws -> NSColor {
        let dark = NSAppearance(named: .darkAqua)
        var built: ShortcutRecorderView?
        dark?.performAsCurrentDrawingAppearance { built = ShortcutRecorderView() }
        let view = try XCTUnwrap(built)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 150, height: 24),
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: name)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 150, height: 24)
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let color = try XCTUnwrap(rep.colorAt(x: 6, y: rep.pixelsHigh / 2))
        return try XCTUnwrap(color.usingColorSpace(.deviceRGB))
    }
}
