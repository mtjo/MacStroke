//
//  ScreenshotWindowProbeTests.swift
//
//  吸附这件事错了不会报错，只会「亮框圈歪了」——副屏上尤其难肉眼核对，所以把
//  两套全局坐标的换算钉成数字断言。
//

import AppKit
import XCTest

@testable import Screenshot

final class ScreenshotWindowProbeTests: XCTestCase {
    /// 主屏上：y 只要把「离主屏顶」平移成「离本屏顶」，主屏两者相等 → 不变。
    func testViewRectOnMainScreenIsPureTranslation() {
        let main = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 100, y: 50, width: 300, height: 200)
        XCTAssertEqual(ScreenshotWindowProbe.viewRect(fromGlobalBounds: window, screenFrame: main, mainTop: 1080),
                       CGRect(x: 100, y: 50, width: 300, height: 200))
    }

    /// 副屏在主屏**上方**（frame.origin.y = 1080，即 AppKit 里 y 1080..2160 那一条）：
    /// 主屏顶下方的窗离副屏顶更远，所以 y 要加上一个屏高。
    func testViewRectForScreenAboveMain() {
        let above = NSRect(x: 0, y: 1080, width: 1920, height: 1080)
        // 主屏顶往下 50 的窗：对副屏来说是它顶下方 1130 处 → 已经在副屏之外。
        let window = CGRect(x: 100, y: 50, width: 300, height: 200)
        let rect = ScreenshotWindowProbe.viewRect(fromGlobalBounds: window, screenFrame: above, mainTop: 1080)
        XCTAssertEqual(rect, CGRect(x: 100, y: 1130, width: 300, height: 200))
        XCTAssertFalse(CGRect(origin: .zero, size: above.size).intersects(rect),
                       "主屏上的窗不该被算进副屏的吸附表里")

        // 真正在副屏上的窗：CG 给的 y 是负的（主屏顶之上 100）。
        let inSecond = CGRect(x: 100, y: -100, width: 300, height: 200)
        XCTAssertEqual(ScreenshotWindowProbe.viewRect(fromGlobalBounds: inSecond, screenFrame: above, mainTop: 1080),
                       CGRect(x: 100, y: 980, width: 300, height: 200),
                       "副屏上的窗口必须落在副屏自己的坐标里，而不是沿用主屏的 y")
    }

    /// 副屏在右边：x 去掉屏偏移，y 只补主屏高度差。
    func testViewRectForScreenRightOfMain() {
        let right = NSRect(x: 1920, y: 0, width: 1440, height: 900)
        let window = CGRect(x: 2000, y: 120, width: 400, height: 300)
        XCTAssertEqual(ScreenshotWindowProbe.viewRect(fromGlobalBounds: window, screenFrame: right, mainTop: 1080),
                       CGRect(x: 80, y: 120 + 900 - 1080, width: 400, height: 300))
    }

    /// 重叠窗口取最前台那个（列表顺序就是前后顺序，第一条命中即答案）。
    func testContainingPicksFrontmost() {
        let candidates = [CGRect(x: 0, y: 0, width: 800, height: 600),
                          CGRect(x: 100, y: 100, width: 300, height: 200)]
        XCTAssertEqual(ScreenshotWindowProbe.rect(containing: CGPoint(x: 150, y: 150), in: candidates),
                       candidates[0])
        // 但窗口外不该硬吸附。
        XCTAssertNil(ScreenshotWindowProbe.rect(containing: CGPoint(x: 900, y: 900), in: candidates))
        XCTAssertNil(ScreenshotWindowProbe.rect(containing: CGPoint(x: 5, y: 5), in: []))
    }

    /// 筛选条件的取证：喂一张合成的窗口表，把四类该掉的都摆出来。
    /// 真桌面上「那个位置刚好有个别人的窗」会让这类断言变成误报，所以过滤逻辑
    /// 走可注入的纯函数，只有抓取那一层留给真桌面烟测。
    func testCandidateRectsDropUnsnappableWindows() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        func window(_ bounds: CGRect, layer: Int = 0, alpha: Double = 1, own: Bool = false) -> ScreenshotProbeWindow {
            ScreenshotProbeWindow(globalBounds: bounds, layer: layer, alpha: alpha, isOwnProcess: own)
        }
        let windows = [
            window(CGRect(x: 0, y: 0, width: 1920, height: 1080), layer: 20),               // 程序坞：整屏大小的壳
            window(CGRect(x: 1000, y: 0, width: 60, height: 24), layer: 25),                // 菜单栏项
            window(CGRect(x: 100, y: 100, width: 400, height: 300)),                        // 正常窗
            window(CGRect(x: 200, y: 200, width: 400, height: 300), own: true),             // 自家窗
            window(CGRect(x: 300, y: 300, width: 400, height: 300), layer: -1),             // 桌面层
            window(CGRect(x: 400, y: 400, width: 400, height: 300), alpha: 0.5),            // 半透明
            window(CGRect(x: 500, y: 500, width: 4, height: 300)),                          // 太小
            window(CGRect(x: 3000, y: 100, width: 400, height: 300)),                       // 本屏之外
            window(CGRect(x: 0, y: 0, width: 1920, height: 1080)),                          // 真最大化窗：该留
        ]
        let rects = ScreenshotWindowProbe.candidateRects(windows: windows, screenFrame: screen, mainTop: 1080)
        XCTAssertEqual(rects, [CGRect(x: 100, y: 100, width: 400, height: 300),
                               CGRect(x: 0, y: 0, width: 1920, height: 1080)],
                       "只有普通窗该留下；自家/桌面层/半透明/太小/屏外，以及整屏大的非普通窗（程序坞、菜单栏）都要被滤掉")
        // 顺序即前后：第一条命中就是最前台那个，不能被整屏那条抢走。
        XCTAssertEqual(ScreenshotWindowProbe.rect(containing: CGPoint(x: 150, y: 150), in: rects),
                       CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    /// 真桌面烟测：这条链只能问 WindowServer，验「问得到、且给的矩形都在本屏内」。
    /// 不吸附的判据在上面那条合成用例里，这里不重复下断言。
    func testRealDesktopListIsUsable() throws {
        guard let screen = ScreenshotGrabber.targetScreen() else { throw XCTSkip("没有可用屏幕") }
        let rects = ScreenshotWindowProbe.candidateRects(screenFrame: screen.frame)
        XCTAssertFalse(rects.isEmpty, "真桌面上不可能一个可吸附窗都没有")
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.width, 8)
            XCTAssertGreaterThanOrEqual(rect.height, 8)
            XCTAssertTrue(rect.intersects(CGRect(origin: .zero, size: screen.frame.size)))
        }
    }
}
