//
//  WindowManagerTests
//  MacStroke
//

import XCTest
@testable import WindowManager
@testable import Preferences

final class WindowManagerTests: XCTestCase {

    func testWindowManagerSingleton() {
        let wm1 = WindowManager.shared
        let wm2 = WindowManager.shared
        XCTAssertTrue(wm1 === wm2)
    }

    func testUserPreferencesDefaults() {
        let prefs = UserPreferences()
        XCTAssertNotNil(prefs)
        XCTAssertEqual(prefs.minimumPoints, 10)
        XCTAssertEqual(prefs.minSimilarityScore, 85.0)
    }

    func testUserPreferencesSaveAndLoad() {
        let prefs = UserPreferences()
        prefs.isEnabled = false
        prefs.minimumPoints = 15
        prefs.save()

        let loadedPrefs = UserPreferences()
        XCTAssertEqual(loadedPrefs.isEnabled, false)
        XCTAssertEqual(loadedPrefs.minimumPoints, 15)

        // Reset
        let resetPrefs = UserPreferences()
        resetPrefs.isEnabled = true
        resetPrefs.minimumPoints = 10
        resetPrefs.save()
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