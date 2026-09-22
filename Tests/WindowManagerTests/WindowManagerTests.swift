//
//  WindowManagerTests
//  MacStroke
//

import XCTest
@testable import WindowManager
@testable import Preferences
import Storage

final class WindowManagerTests: XCTestCase {

    func testWindowManagerSingleton() {
        let wm1 = WindowManager.shared
        let wm2 = WindowManager.shared
        XCTAssertTrue(wm1 === wm2)
    }

    func testUserPreferencesDefaults() {
        let prefs = isolatedPreferences()
        XCTAssertEqual(prefs.minSimilarityScore, StorageDefaults.minSimilarityScore)
        XCTAssertEqual(prefs.noteRetentionTime, StorageDefaults.noteRetentionTime)
    }

    /// 同一个 suite 里 save 之后重新构造，读回的应是刚写入的值。
    func testUserPreferencesSaveAndLoad() {
        let suite = isolatedSuite()
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: suite))
        prefs.minSimilarityScore = 66
        prefs.noteRetentionTime = 7
        prefs.save()

        let loadedPrefs = UserPreferences(storage: PreferencesStorage(defaults: suite))
        XCTAssertEqual(loadedPrefs.minSimilarityScore, 66)
        XCTAssertEqual(loadedPrefs.noteRetentionTime, 7)
    }

    /// 原版把总开关放在 AppDelegate 的 `static BOOL isEnabled`，每次启动都回到
    /// YES 且从不写 UserDefaults，所以偏好里的勾选状态不是持久状态。
    func testIsEnabledIsRuntimeOnly() {
        let prefs = isolatedPreferences()
        prefs.isEnabled = false
        prefs.save()
        XCTAssertTrue(isolatedPreferences().isEnabled)
    }

    /// 原版 `resetDefaults:` 只把 DefaultPreferences.plist 里的键写回 UserDefaults，
    /// 语言、黑白名单、登录项与总开关都不在 plist 中所以保持不变；写完后绑定控件
    /// 立即看到新值（SwiftUI 侧靠 reloadResetValues 回读）。
    func testResetToDefaultsKeepsUntouchedKeysAndRefreshesModel() {
        let storage = PreferencesStorage(defaults: isolatedSuite())
        // Seed through storage so the model picks the values up at init time
        // (assigning `language` afterwards would trigger a live language switch).
        storage.setString("zh-Hans", forKey: .language)
        storage.setString("com.example.blocked", forKey: .blockFilter)
        storage.setString("com.example.allowed", forKey: .whiteList)
        let prefs = UserPreferences(storage: storage)
        prefs.minSimilarityScore = 95
        prefs.noteFontSize = 18
        prefs.noteFontName = "Courier"
        prefs.lineColorHex = "#FF0000"
        prefs.showGestureNote = false

        prefs.resetToDefaults()

        XCTAssertEqual(prefs.language, "zh-Hans")
        XCTAssertEqual(prefs.blockFilter, "com.example.blocked")
        XCTAssertEqual(prefs.whiteList, "com.example.allowed")
        XCTAssertEqual(prefs.minSimilarityScore, StorageDefaults.minSimilarityScore)
        XCTAssertEqual(prefs.noteFontSize, StorageDefaults.noteFontSize)
        XCTAssertEqual(prefs.noteFontName, StorageDefaults.noteFontName)
        XCTAssertEqual(prefs.lineColorHex, StorageDefaults.defaultLineColor)
        XCTAssertTrue(prefs.showGestureNote)
    }

    /// 固定 suite 名并在用例前后各清一次：随机 UUID 会让每次跑测试都在
    /// ~/Library/Preferences 里留下一个新 plist。
    private static let suiteName = "MacStrokeTests.WindowManager"

    private func isolatedSuite() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    override func setUp() {
        super.setUp()
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func isolatedPreferences() -> UserPreferences {
        UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
    }

    // MARK: - Toast 位置

    /// 1920x1080，菜单栏 25pt、底部 Dock 70pt（即原版会把提示框整体顶高 95pt）
    private let testVisibleFrame = NSRect(x: 0, y: 70, width: 1920, height: 985)
    private let testBoxSize = NSSize(width: 320, height: 80)

    /// 把"距可视区顶部"的坐标换算成 AppKit 全局坐标，便于判断是否越界
    private func screenRect(for origin: NSPoint) -> NSRect {
        NSRect(x: testVisibleFrame.minX + origin.x,
               y: testVisibleFrame.maxY - origin.y - testBoxSize.height,
               width: testBoxSize.width, height: testBoxSize.height)
    }

    func testToastContainerOriginStaysInsideVisibleFrame() {
        let positions: [ToastPosition] = [.center, .rightTop, .rightBottom, .leftTop, .leftBottom, .mouse]
        for position in positions {
            let origin = ToastManager.containerOrigin(
                for: position, visibleFrame: testVisibleFrame,
                mouseLocation: NSPoint(x: 800, y: 30), containerSize: testBoxSize,
                edgeOffset: 50)
            XCTAssertTrue(testVisibleFrame.contains(screenRect(for: origin)),
                          "\(position) 位置的提示框超出可视区域: \(screenRect(for: origin))")
        }
    }

    func testToastContainerOriginCornerAnchors() {
        let leftTop = ToastManager.containerOrigin(
            for: .leftTop, visibleFrame: testVisibleFrame, mouseLocation: .zero,
            containerSize: testBoxSize, edgeOffset: 50)
        XCTAssertEqual(leftTop, NSPoint(x: 50, y: 50))

        let rightBottom = ToastManager.containerOrigin(
            for: .rightBottom, visibleFrame: testVisibleFrame, mouseLocation: .zero,
            containerSize: testBoxSize, edgeOffset: 50)
        XCTAssertEqual(rightBottom, NSPoint(x: 1920 - 50 - 320, y: 985 - 50 - 80))
    }

    func testToastContainerOriginAtMouseKeepsBoxAbovePointer() {
        // 全局坐标（左下原点）指针在 (800, 600) → 距可视区顶部 455
        let origin = ToastManager.containerOrigin(
            for: .mouse, visibleFrame: testVisibleFrame,
            mouseLocation: NSPoint(x: 800, y: 600),
            containerSize: testBoxSize, edgeOffset: 50)
        XCTAssertEqual(origin, NSPoint(x: 800, y: 455 - 80))

        // 指针落在 Dock 区域（可视区下方）时夹回可视区底部，仍完整可见
        let overDock = ToastManager.containerOrigin(
            for: .mouse, visibleFrame: testVisibleFrame,
            mouseLocation: NSPoint(x: 800, y: 30),
            containerSize: testBoxSize, edgeOffset: 50)
        XCTAssertTrue(testVisibleFrame.contains(screenRect(for: overDock)))
        XCTAssertEqual(overDock.y, 985 - 80)
    }
}