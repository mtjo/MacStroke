//
//  HistoryClipboardPanelEscapeTests.swift
//  MacStroke
//
//  Esc 必须从历史粘贴板面板的任何焦点位置关闭窗口。
//

import XCTest
import AppKit
@testable import Storage

@MainActor
final class HistoryClipboardPanelEscapeTests: XCTestCase {

    private func firstView<T: NSView>(in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let found: T = firstView(in: sub) { return found }
        }
        return nil
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Escape 必须带上字符，否则 interpretKeyEvents 映射不出 cancelOperation:。
    private func escapeEvent() throws -> NSEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true))
        var unicode = Array("\u{1b}".utf16)
        down.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
        return try XCTUnwrap(NSEvent(cgEvent: down))
    }

    private func makePanel() throws -> (HistoryClipboardListWindowController, NSWindow) {
        let dir = "\(NSTemporaryDirectory())esc_test_\(UUID().uuidString)"
        let manager = HistoryClipboardManager(databasePath: "\(dir)/clip.db",
                                              userDefaults: isolatedDefaults())
        _ = manager.insertLocalHistoryClipboard(content: "hello world", isTop: false)
        _ = manager.insertLocalHistoryClipboard(content: "other text", isTop: false)
        let controller = HistoryClipboardListWindowController(manager: manager)
        controller.entries = manager.getHistoryClipboardList(firstPage: true)
        controller.showWindow(nil)
        pump(0.5)
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        pump(0.5)
        return (controller, window)
    }

    /// 随机 UUID 的 suite 会往 ~/Library/Preferences 里留下一堆 plist。
    private static let suiteName = "MacStrokeTests.ClipboardPanelEscape"

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    override func setUp() {
        super.setUp()
        isolatedDefaults().removePersistentDomain(forName: Self.suiteName)
    }

    func testEscapeInSearchFieldClosesPanel() throws {
        let (_, window) = try makePanel()
        let field: NSSearchField = try XCTUnwrap(firstView(in: window.contentView))
        window.makeFirstResponder(field)
        pump(0.4)
        let editor = try XCTUnwrap(field.currentEditor() ?? window.firstResponder as? NSTextView)

        try editor.interpretKeyEvents([escapeEvent()])
        pump(0.4)
        XCTAssertFalse(window.isVisible, "搜索框里的 Esc 直接关窗")
    }

    func testEscapeWithQueryTypedStillCloses() throws {
        let (controller, window) = try makePanel()
        let field: NSSearchField = try XCTUnwrap(firstView(in: window.contentView))
        window.makeFirstResponder(field)
        pump(0.4)
        let editor = try XCTUnwrap(field.currentEditor() ?? window.firstResponder as? NSTextView)

        field.stringValue = "hello"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification,
                                        object: field,
                                        userInfo: ["NSControl": field])
        pump(0.3)
        XCTAssertEqual(controller.displayedEntries.count, 1, "输入即时过滤")

        try editor.interpretKeyEvents([escapeEvent()])
        pump(0.4)
        XCTAssertFalse(window.isVisible, "有查询词时一次 Esc 就关窗")
    }

    func testEscapeInResultListClosesPanel() throws {
        let (_, window) = try makePanel()
        let table: NSTableView = try XCTUnwrap(firstView(in: window.contentView))
        window.makeFirstResponder(table)
        pump(0.4)
        XCTAssertTrue(window.firstResponder === table)

        // 走真实按键派发：点击行之后焦点在表格上，Esc 要沿响应链到达面板容器。
        window.sendEvent(try escapeEvent())
        pump(0.5)
        XCTAssertFalse(window.isVisible, "结果列表获得焦点时 Esc 同样关窗")
    }
}
