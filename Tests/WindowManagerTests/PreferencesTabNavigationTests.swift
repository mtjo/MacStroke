// 状态栏菜单入口的跳页取证：菜单用的键要能还原成偏好页；新建窗口按 initialTab 落在目标页；
// 已经开着的窗口靠通知切页。判据一律取侧栏高亮条（accent 填充）在竖直方向的位置，
// 不读任何页面自己声明的状态，也不用「和另一处同样的 bug 量出来的参照值」互证。
import XCTest
import AppKit
import SwiftUI
import Storage
@testable import Preferences

final class PreferencesTabNavigationTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.TabNavigation"

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    // MARK: - 菜单键与页的对应关系

    func testStatusMenuKeysMapOntoTheTabsTheyOpen() {
        // 状态栏菜单只把 rawValue 传过来（两个模块之间没有别的契约），键名一改入口就断。
        XCTAssertEqual(PreferencesTab.clipboard.rawValue, "clipboard")
        XCTAssertEqual(PreferencesTab.remoteControl.rawValue, "remoteControl")
        for tab in PreferencesTab.allCases {
            XCTAssertEqual(PreferencesTab(rawValue: tab.rawValue), tab,
                           "\(tab) 的键必须能原样还原")
        }
        XCTAssertNil(PreferencesTab(rawValue: "noSuchTab"))
    }

    // MARK: - 新建窗口停在请求的页

    func testFreshWindowOpensOnTheRequestedTab() throws {
        // 侧栏里 general → clipboard → remoteControl → screenshot → about 自上而下，高亮条必须逐级挪位。
        let ordered: [PreferencesTab] = [.general, .clipboard, .remoteControl, .screenshot, .about]
        var centers: [(String, CGFloat)] = []
        for tab in ordered {
            centers.append((tab.rawValue, try accentBandCenter(in: try hostPreferences(initialTab: tab))))
        }
        assertStrictlyMonotonic(centers)
    }

    // MARK: - 已开着的窗口靠通知切页

    func testNotificationMovesTheHighlightOfAnAlreadyOpenWindow() throws {
        let host = try hostPreferences(initialTab: .general)
        let general = try accentBandCenter(in: host)

        post(tabKey: PreferencesTab.clipboard.rawValue)
        spin()
        let clipboard = try accentBandCenter(in: host)
        XCTAssertNotEqual(clipboard, general, accuracy: 2, "通知没把已开着的窗口切到粘贴板页")

        post(tabKey: PreferencesTab.remoteControl.rawValue)
        spin()
        let remote = try accentBandCenter(in: host)
        XCTAssertNotEqual(remote, clipboard, accuracy: 2, "连续第二次切页没动")

        post(tabKey: "noSuchTab")
        spin()
        XCTAssertEqual(try accentBandCenter(in: host), remote, accuracy: 1,
                       "未知页面键不该改动当前页")

        post(tabKey: PreferencesTab.general.rawValue)
        spin()
        XCTAssertEqual(try accentBandCenter(in: host), general, accuracy: 1,
                       "切回常规页要回到原位置（说明判据量的是真状态，不是单向漂移）")
    }

    // MARK: - 测量

    private func post(tabKey: String) {
        NotificationCenter.default.post(name: .macStrokeShowPreferencesTab, object: tabKey)
    }

    private func spin() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }

    private func makePrefs() -> UserPreferences {
        UserPreferences(storage: PreferencesStorage(defaults: UserDefaults(suiteName: Self.suiteName)!))
    }

    private func hostPreferences(initialTab: PreferencesTab) throws -> NSHostingView<PreferencesView> {
        let host = NSHostingView(rootView: PreferencesView(viewModel: makePrefs(), initialTab: initialTab))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 660)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Vertical centre of the sidebar's accent-filled selection band, measured in a
    /// column inside the row but clear of its label (the sidebar is 216pt wide).
    private func accentBandCenter(in host: NSHostingView<PreferencesView>) throws -> CGFloat {
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let x = Int(190 * CGFloat(rep.pixelsWide) / host.bounds.width)
        let accent = try XCTUnwrap(NSColor.controlAccentColor.usingColorSpace(.deviceRGB))

        var ys: [Int] = []
        for y in 0..<rep.pixelsHigh {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if distance(color, accent) < 0.12 { ys.append(y) }
        }
        XCTAssertFalse(ys.isEmpty, "侧栏找不到高亮条，测量本身失效")
        return CGFloat(ys.reduce(0, +)) / CGFloat(ys.count)
    }

    private func assertStrictlyMonotonic(_ centers: [(String, CGFloat)],
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        let values = centers.map { $0.1 }
        for pair in zip(values, values.dropFirst()) {
            XCTAssertNotEqual(pair.0, pair.1, accuracy: 2,
                              "相邻两页的高亮位置相同，initialTab 没生效：\(centers)", file: file, line: line)
        }
        // 绘制坐标的 y 方向由 AppKit 决定，这里只要求随侧栏顺序严格单向。
        let ascending = zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
        let descending = zip(values, values.dropFirst()).allSatisfy { $0 > $1 }
        XCTAssertTrue(ascending || descending,
                      "高亮位置没有按侧栏顺序单向移动：\(centers)", file: file, line: line)
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        sqrt(pow(a.redComponent - b.redComponent, 2)
            + pow(a.greenComponent - b.greenComponent, 2)
            + pow(a.blueComponent - b.blueComponent, 2))
    }
}
