//
//  ScreenshotTriggerTests.swift
//
//  截图触发方式的偏好侧取证（移植版新增，超出原版）。核心风险是 keyCode 0：
//  A 的 Carbon 键码就是 0，而旧代码一路把 0 当「没设过」的空值用，所以 ⌘⇧A 这个
//  默认值很容易被当成没挂快捷键 —— 界面显示 ⌘⇧A、实际按键没反应，用户只会以为功能坏了。
//  这里把「默认串 → 解析 → 显示器上那行字」三段对齐，外加规则表第 5 类动作的下标。
//

import AppKit
import EventCapture
import RuleEngine
import Storage
import XCTest

@testable import Preferences

final class ScreenshotTriggerTests: XCTestCase {

    // MARK: - 默认快捷键

    func testDefaultShortcutIsCommandShiftA() throws {
        let parsed = try XCTUnwrap(ShortcutMonitor.parseShortcut(StorageDefaults.screenshotShortcut))
        XCTAssertEqual(parsed.0, 0, "A 的键码就是 0：默认值不能因为「0 像空值」被丢掉")
        XCTAssertEqual(parsed.1, 0x100000 | 0x20000, "默认修饰键是 ⌘⇧")
    }

    func testFreshMonitorCarriesNoShortcut() {
        // keyCode 用 Optional 区分「没设」和「设成 0 号键」。
        let monitor = ShortcutMonitor()
        XCTAssertNil(monitor.keyCode)
        XCTAssertEqual(monitor.flags, 0)
    }

    // MARK: - 录制框显示

    func testRecorderDisplaysTheStoredDefaultAndRoundTrips() {
        let view = ShortcutRecorderView()
        let parsed = ShortcutRecorder.parse(StorageDefaults.screenshotShortcut)
        view.keyCode = parsed?.keyCode ?? 999
        view.flags = parsed?.flags ?? 999

        let shown = view.displayString
        XCTAssertTrue(shown.contains("⌘"), "显示要带 command 符号：\(shown)")
        XCTAssertTrue(shown.contains("⇧"), "显示要带 shift 符号：\(shown)")
        // 键名字面按当前键盘布局翻译，只断言它没被当成空值省掉。
        XCTAssertEqual(shown.count, 3, "⌘⇧ 之后还得跟上一个键名：\(shown)")
        // 显示出来的串还得能被写回口径解析回去（录制框提交的是 "keyCode=…, flags=…"）。
        let committed = "keyCode=\(view.keyCode), flags=\(view.flags)"
        XCTAssertEqual(ShortcutRecorder.parse(committed)?.keyCode, 0)
        XCTAssertEqual(ShortcutRecorder.parse(committed)?.flags, 0x100000 | 0x20000)
    }

    func testZeroZeroStillMeansUnsetInTheRecorder() {
        let view = ShortcutRecorderView()
        XCTAssertEqual(view.keyCode, 0)
        XCTAssertEqual(view.flags, 0)
        // 只有「无修饰键 + 0 号键」才是空；单看 keyCode==0 不能判空。
        view.flags = 0x20000
        XCTAssertFalse(view.keyCode == 0 && view.flags == 0)
    }

    // MARK: - 规则表里的第 5 类动作

    func testScreenshotIsTheFifthActionTypeInTheRulesTable() throws {
        let titles = RulesTable.Coordinator.typeTitles
        XCTAssertEqual(titles.count, 5, "动作类型下拉要正好 5 项：截图是新增的第 5 项")
        XCTAssertEqual(titles.last, L("Screenshot"))
        XCTAssertEqual(RulesTable.Coordinator.typeIndex(for: .screenshot), 4,
                       "下标要和持久化的 actionType 对齐，否则切类型会写错格子")
        XCTAssertEqual(RulesTable.Coordinator.typeIndex(for: .shortcut(keyCode: 1, flags: 0)), 0)
        XCTAssertEqual(RulesTable.Coordinator.typeIndex(for: .applescript("id")), 1)
        XCTAssertEqual(RulesTable.Coordinator.typeIndex(for: .text("t")), 2)
        XCTAssertEqual(RulesTable.Coordinator.typeIndex(for: .password("p")), 3)
    }
}
