//
//  HistoryClipboardPanelFocusTests.swift
//  MacStroke
//
//  面板关闭后的焦点归属：必须还给「面板打开前那个 App」。
//  缺陷表现是开机第一次用快捷键打开粘贴板列表，选完一条或按 Esc 退出后跳到偏好设置
//  窗口 —— 因为 AppKit 在面板关闭时会把 key 转给本 App 下一个可见窗口，而开机时
//  openPrefOnStartup 默认让偏好窗口正好可见。
//  激活动作走可注入的替身，判据只读 NSWorkspace 的真实前台 App，不碰用户当前焦点。
//

import XCTest
import AppKit
@testable import Storage

@MainActor
final class HistoryClipboardPanelFocusTests: XCTestCase {

    private static let suiteName = "MacStrokeTests.ClipboardPanelFocus"

    private var activated: [NSRunningApplication] = []

    override func setUp() {
        super.setUp()
        activated = []
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 把测试面板藏出用户视线，只留它的窗口机制。
    /// 面板 init 里把 level 设成 21（浮在一切 App 之上）并且 `window.center()`，所以一跑回归
    /// 就是好几枚真窗口堆在桌面正中，看着像 App 自己弹的粘贴板弹窗（装机取证时用户就是这么问的）。
    /// 所以**开窗之前**先压回普通层级 + 整窗透明 + 点击穿透，但**不挪位置也不关窗**：字段编辑器、
    /// first responder、`isVisible` 这套判据全靠窗口真的有序在屏上。
    private func hideFromSight(_ controller: HistoryClipboardListWindowController) {
        guard let window = controller.window else { return }
        window.level = .normal
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    /// 一个确定在跑、又绝不是自己的 App：Finder。测试只比较它的身份，
    /// 真实的 activate 被替身换掉了，不会动用户的前台窗口。
    private func otherApplication() throws -> NSRunningApplication {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        return try XCTUnwrap(apps.first, "本机没有 Finder 可用，判据失去参照")
    }

    private func makePanel() -> HistoryClipboardListWindowController {
        let dir = "\(NSTemporaryDirectory())focus_\(UUID().uuidString)"
        let manager = HistoryClipboardManager(databasePath: "\(dir)/clip.db",
                                             userDefaults: UserDefaults(suiteName: Self.suiteName)!)
        _ = manager.insertLocalHistoryClipboard(content: "alpha one", isTop: false)
        let controller = HistoryClipboardListWindowController(manager: manager)
        hideFromSight(controller)
        controller.reload()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        pump(0.3)
        controller.activateApplication = { [weak self] app in
            self?.activated.append(app)
        }
        return controller
    }

    // MARK: - 记住打开前的 App

    func testPanelRecordsTheAppThatWasFrontmostWhenItOpened() throws {
        let expected = NSWorkspace.shared.frontmostApplication
        let controller = HistoryClipboardListWindowController(
            manager: HistoryClipboardManager(databasePath: "\(NSTemporaryDirectory())focus_\(UUID().uuidString)/clip.db",
                                             userDefaults: UserDefaults(suiteName: Self.suiteName)!)
        )
        guard let expected, expected.processIdentifier != NSRunningApplication.current.processIdentifier else {
            XCTAssertNil(controller.previouslyFrontmostApplication, "前台本来就是我们自己，没什么可交还")
            return
        }
        XCTAssertEqual(controller.previouslyFrontmostApplication?.processIdentifier, expected.processIdentifier)
    }

    // MARK: - 交还焦点

    func testClosingThePanelHandsFocusBackToThePreviousApp() throws {
        let previous = try otherApplication()
        let controller = makePanel()
        controller.previouslyFrontmostApplication = previous

        controller.window?.close()
        pump(0.3)

        XCTAssertEqual(activated.count, 1, "关面板必须交还一次焦点")
        XCTAssertEqual(activated.first?.processIdentifier, previous.processIdentifier)
    }

    func testClosingThePanelWithNothingToRestoreLeavesActivationAlone() throws {
        let controller = makePanel()
        controller.previouslyFrontmostApplication = nil

        controller.window?.close()
        pump(0.3)

        XCTAssertTrue(activated.isEmpty, "没有前置 App 时不能凭空激活任何东西")
    }

    func testOpeningThePanelDoesNotHandFocusAnywhereYet() throws {
        let controller = makePanel()
        controller.previouslyFrontmostApplication = try otherApplication()
        pump(0.3)

        XCTAssertTrue(activated.isEmpty, "交还只发生在关窗，开窗时面板自己要在前台")
    }

    // MARK: - 重复打开（调用方先关旧面板再建新面板）

    func testReopeningThePanelCancelsTheOldPanelsHandBack() throws {
        let previous = try otherApplication()
        let old = makePanel()
        old.previouslyFrontmostApplication = previous

        // 两个调用方（AppDelegate.showHistoryClipboard / WindowManager.showClipboardHistory）
        // 都是「先 close 旧面板，再 alloc 新面板」，逐字复刻这个顺序。
        old.window?.close()
        let fresh = makePanel()
        fresh.previouslyFrontmostApplication = previous
        pump(0.3)

        XCTAssertTrue(activated.isEmpty, "新面板还在屏幕上，旧面板的关窗回调不许把焦点踢走")

        fresh.window?.close()
        pump(0.3)

        XCTAssertEqual(activated.count, 1, "最后一次关窗仍然要交还")
        XCTAssertEqual(activated.first?.processIdentifier, previous.processIdentifier)
    }
}
