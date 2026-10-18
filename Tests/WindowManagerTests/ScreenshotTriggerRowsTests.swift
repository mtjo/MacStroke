//
//  ScreenshotTriggerRowsTests.swift
//
//  截图页「触发方式」那一段的取证（issue #74 新增）。这一页把两个录制框铺在同一个
//  section 里，判据只能取「SwiftUI 真的把代表视图装进了视图树、而且各自带着库里那对键值」：
//  少一行、两行绑到同一个 @Published、或者第二条读错了键，界面上看是一模样的两行字，
//  按下去才有区别 —— 而那一段只能在装好的 App 里真按，单测能钉住的是绑定。
//

import AppKit
import SwiftUI
import XCTest
import Storage

@testable import Preferences

final class ScreenshotTriggerRowsTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.ScreenshotTriggerRows"

    override func setUp() {
        super.setUp()
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func isolatedSuite() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    /// 截图那条 + 提取文字那条：两个框都要真的装进页面，并且显示的是各自的默认组合。
    func testTriggerSectionCarriesBothRecordersWithTheirOwnDefaults() throws {
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
        let host = NSHostingView(rootView: ScreenshotTabView(viewModel: prefs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        host.layoutSubtreeIfNeeded()

        let recorders = collectShortcutRecorders(in: host)
        XCTAssertEqual(recorders.count, 2, "触发方式那一节该有两只录制框（截图、提取文字）")
        let shown = Set(recorders.map { "\($0.keyCode):\($0.flags)" })
        XCTAssertEqual(shown, ["0:1179648", "0:655360"],
                       "两只框显示的就该是库里的默认组合 ⌘⇧A 与 ⌥⇧A")
    }

    /// 代表视图藏在 SwiftUI 自己的宿主层下面，层数随系统版本变，所以按类型递归找而不是数下标。
    private func collectShortcutRecorders(in view: NSView) -> [ShortcutRecorderView] {
        var found: [ShortcutRecorderView] = []
        for sub in view.subviews {
            if let recorder = sub as? ShortcutRecorderView { found.append(recorder) }
            found.append(contentsOf: collectShortcutRecorders(in: sub))
        }
        return found
    }
}
