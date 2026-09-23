//
//  HistoryClipboardPanelInteractionTests.swift
//  MacStroke
//
//  历史粘贴板面板的键盘交互：输入即时过滤、× 清空、Esc 从任何焦点关窗。
//  一律走真实按键链路（interpretKeyEvents / sendEvent），手工发通知会漏掉
//  AppKit 不按预期回调的那类缺陷。
//

import XCTest
import AppKit
@testable import Storage

@MainActor
final class HistoryClipboardPanelInteractionTests: XCTestCase {

    private static let suiteName = "MacStrokeTests.ClipboardPanelInteraction"

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    override func setUp() {
        super.setUp()
        isolatedDefaults().removePersistentDomain(forName: Self.suiteName)
    }

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

    /// 合成的按键事件必须带上 unicode 字符，否则 interpretKeyEvents 映射不出
    /// cancelOperation: 等命令选择器。
    private func keyEvent(_ text: String, virtualKey: CGKeyCode) throws -> NSEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true))
        var unicode = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
        return try XCTUnwrap(NSEvent(cgEvent: down))
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "t": 17, "r": 15, "e": 14, "w": 13, "o": 31, "p": 35, "l": 37,
        "\u{1b}": 53,
    ]

    private func press(_ text: String, in editor: NSTextView) throws {
        guard let key = Self.keyCodes[text] else {
            XCTFail("no key code for \(text)")
            return
        }
        editor.interpretKeyEvents([try keyEvent(text, virtualKey: key)])
    }

    private func makePanel(contents: [String] = ["alpha one", "beta two", "alpha three"])
        throws -> (HistoryClipboardListWindowController, NSWindow, NSSearchField) {
        let dir = "\(NSTemporaryDirectory())panel_\(UUID().uuidString)"
        let manager = HistoryClipboardManager(databasePath: "\(dir)/clip.db", userDefaults: isolatedDefaults())
        for content in contents {
            _ = manager.insertLocalHistoryClipboard(content: content, isTop: false)
        }
        let controller = HistoryClipboardListWindowController(manager: manager)
        controller.reload()
        controller.showWindow(nil)
        pump(0.5)
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        let field: NSSearchField = try XCTUnwrap(firstView(in: window.contentView))
        window.makeFirstResponder(field)
        pump(0.5)
        return (controller, window, field)
    }

    private func editor(of field: NSSearchField, in window: NSWindow) throws -> NSTextView {
        try XCTUnwrap((field.currentEditor() as? NSTextView) ?? window.firstResponder as? NSTextView)
    }

    // MARK: - Search

    func testTypingFiltersTheResultList() throws {
        let (controller, window, field) = try makePanel()
        let editor = try editor(of: field, in: window)
        XCTAssertEqual(controller.displayedEntries.count, 3)

        for letter in "alpha" { try press(String(letter), in: editor) }
        pump(0.4)

        XCTAssertEqual(field.stringValue, "alpha")
        XCTAssertEqual(controller.query, "alpha", "输入必须同步到查询词")
        XCTAssertEqual(controller.displayedEntries.count, 2, "只剩含 alpha 的两条")
    }

    func testCancelButtonRestoresTheFullList() throws {
        let (controller, window, field) = try makePanel()
        let editor = try editor(of: field, in: window)
        for letter in "alpha" { try press(String(letter), in: editor) }
        pump(0.4)
        XCTAssertEqual(controller.displayedEntries.count, 2)

        (field.cell as? NSSearchFieldCell)?.cancelButtonCell?.performClick(nil)
        pump(0.4)

        XCTAssertEqual(controller.query, "", "× 是程序化改值，不发 textDidChange 通知")
        XCTAssertEqual(controller.displayedEntries.count, 3)
    }

    func testSearchMatchesPinnedRowsToo() throws {
        let dir = "\(NSTemporaryDirectory())panel_\(UUID().uuidString)"
        let manager = HistoryClipboardManager(databasePath: "\(dir)/clip.db", userDefaults: isolatedDefaults())
        _ = manager.addTop(content: "pinned target")
        _ = manager.insertLocalHistoryClipboard(content: "unrelated", isTop: false)
        _ = manager.insertLocalHistoryClipboard(content: "history target", isTop: false)
        let controller = HistoryClipboardListWindowController(manager: manager)
        controller.reload()
        controller.showWindow(nil)
        pump(0.5)
        let window = try XCTUnwrap(controller.window)
        let field: NSSearchField = try XCTUnwrap(firstView(in: window.contentView))
        window.makeFirstResponder(field)
        pump(0.5)

        for letter in "target" { try press(String(letter), in: try editor(of: field, in: window)) }
        pump(0.4)

        XCTAssertEqual(controller.displayedEntries.count, 2)
        XCTAssertTrue(controller.displayedEntries.contains { $0.isTop }, "置顶组也要能被搜到")
    }

    // MARK: - Escape

    func testEscapeInSearchFieldClosesPanel() throws {
        let (_, window, field) = try makePanel()
        try press("\u{1b}", in: try editor(of: field, in: window))
        pump(0.4)
        XCTAssertFalse(window.isVisible, "搜索框里的 Esc 直接关窗")
    }

    func testEscapeWithQueryTypedStillCloses() throws {
        let (controller, window, field) = try makePanel()
        let editor = try editor(of: field, in: window)
        for letter in "alpha" { try press(String(letter), in: editor) }
        pump(0.4)
        XCTAssertEqual(controller.displayedEntries.count, 2)

        try press("\u{1b}", in: editor)
        pump(0.4)
        XCTAssertFalse(window.isVisible, "有查询词时一次 Esc 就关窗")
    }

    func testEscapeInResultListClosesPanel() throws {
        let (_, window, _) = try makePanel()
        let table: NSTableView = try XCTUnwrap(firstView(in: window.contentView))
        window.makeFirstResponder(table)
        pump(0.4)
        XCTAssertTrue(window.firstResponder === table)

        // 点击行之后焦点在表格上，Esc 要沿响应链到达面板容器。
        window.sendEvent(try keyEvent("\u{1b}", virtualKey: 53))
        pump(0.5)
        XCTAssertFalse(window.isVisible, "结果列表获得焦点时 Esc 同样关窗")
    }
}
