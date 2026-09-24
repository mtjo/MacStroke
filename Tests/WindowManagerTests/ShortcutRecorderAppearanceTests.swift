// 快捷键输入框曾在 macOS 26/27 的浅色偏好设置页里整块渲染成黑色。两层原因：
// ① 背景色以 layer.backgroundColor = NSColor.controlBackgroundColor.cgColor 的形式在
//    init 时冻结，CGColor 不带动态语义，视图还没进窗口就先建好，就把深色底色带进浅色窗口；
//    → 改成 draw(_:) 里现取现画。
// ② 仍然发黑，因为 SwiftUI 给 NSViewRepresentable 的那套 appearance 跟的是「系统设置」，
//    跟页面本身用的配色无关（实测：页面浅色、host 是 DarkAqua，连窗口的 effectiveAppearance
//    都会被 NSHostingView 带偏）。动态色在深色 appearance 下解析，自然还是黑的。
//    → ShortcutRecorder 把 @Environment(\.colorScheme) 换算成 drawAppearance 交给视图，
//    draw 里按它取色；下面两个 *HostedBySwiftUI* 用例就是把窗口 appearance 故意设成页面
//    配色的一方来复现这条路径。
import XCTest
import AppKit
import SwiftUI
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

    /// The path the user actually sees: the recorder inside the SwiftUI preferences
    /// page. SwiftUI gives the representable an appearance of its own (it tracks the
    /// system setting), so the page's own colour scheme has to reach the view.
    func testLightSchemePageKeepsLightBackgroundWhenHostedBySwiftUI() throws {
        let color = try renderHostedRecorder(pageScheme: .light)
        XCTAssertGreaterThan(color.redComponent, 0.8, "SwiftUI-hosted recorder is dark on a light page: \(color)")
        XCTAssertGreaterThan(color.greenComponent, 0.8)
        XCTAssertGreaterThan(color.blueComponent, 0.8)
    }

    func testDarkSchemePageKeepsDarkBackgroundWhenHostedBySwiftUI() throws {
        let color = try renderHostedRecorder(pageScheme: .dark)
        XCTAssertLessThan(color.redComponent, 0.5, "SwiftUI-hosted recorder stayed light on a dark page: \(color)")
        XCTAssertLessThan(color.greenComponent, 0.5)
        XCTAssertLessThan(color.blueComponent, 0.5)
    }

    /// Samples the recorder while it is wrapped by `ShortcutRecorder` and hosted by
    /// an `NSHostingView` whose own appearance is the opposite of the page scheme —
    /// the mismatch that made the box black on macOS 26/27.
    private func renderHostedRecorder(pageScheme scheme: ColorScheme) throws -> NSColor {
        let host = NSHostingView(rootView: ShortcutRecorder(text: .constant("keyCode=9, flags=1048832"))
            .frame(width: 200, height: 28)
            .environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .aqua : .darkAqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 60)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // x=60 sits inside the recorder box (it starts at x=30) and clear of the
        // centred shortcut text.
        let color = try XCTUnwrap(rep.colorAt(x: 60, y: 30))
        return try XCTUnwrap(color.usingColorSpace(.deviceRGB))
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
