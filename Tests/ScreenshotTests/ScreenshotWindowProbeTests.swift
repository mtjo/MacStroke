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
        func window(_ bounds: CGRect, layer: Int = 0, alpha: Double = 1,
                    pid: pid_t = 100, number: Int = 1) -> ScreenshotProbeWindow {
            ScreenshotProbeWindow(globalBounds: bounds, layer: layer, alpha: alpha,
                                  isOwnProcess: false, isCapturable: true,
                                  pid: pid, windowNumber: number)
        }
        let windows = [
            window(CGRect(x: 0, y: 0, width: 1920, height: 1080), layer: 20),               // 程序坞：整屏大小的壳
            window(CGRect(x: 1000, y: 0, width: 60, height: 24), layer: 25),                // 菜单栏项
            window(CGRect(x: 200, y: 200, width: 400, height: 300), layer: 21),             // 别家的浮窗：不吸
            window(CGRect(x: 100, y: 100, width: 400, height: 300)),                        // 正常窗
            window(CGRect(x: 300, y: 300, width: 400, height: 300), layer: -1),             // 桌面层
            window(CGRect(x: 400, y: 400, width: 400, height: 300), alpha: 0.5),            // 半透明
            window(CGRect(x: 500, y: 500, width: 4, height: 300)),                          // 太小
            window(CGRect(x: 3000, y: 100, width: 400, height: 300)),                       // 本屏之外
            window(CGRect(x: 0, y: 0, width: 1920, height: 1080)),                          // 真最大化窗：该留
        ]
        let rects = ScreenshotWindowProbe.candidateRects(windows: windows, screenFrame: screen, mainTop: 1080)
        XCTAssertEqual(rects, [CGRect(x: 100, y: 100, width: 400, height: 300),
                               CGRect(x: 0, y: 0, width: 1920, height: 1080)],
                       "别家只吸普通窗；桌面层/半透明/太小/屏外，以及整屏大的非普通窗（程序坞、菜单栏）都要被滤掉")
        // 顺序即前后：第一条命中就是最前台那个，不能被整屏那条抢走。
        XCTAssertEqual(ScreenshotWindowProbe.rect(containing: CGPoint(x: 150, y: 150), in: rects),
                       CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    /// 自家窗的吸附口径（2026-11-04 两场实测：「偏好设置不能智能框选」「历史粘贴板
    /// 弹窗也不吸附」）：
    /// - 能吸：偏好设置（layer 0）、贴图（3）、历史粘贴板（21）—— 只要有像素进得了
    ///   冻结帧，就该吸；
    /// - 不能吸：状态栏项（25）、Toast（101）超出菜单栏门槛；画布/遮罩/描边/气泡
    ///   虽然层级低，但 `sharingType = .none`，冻结帧里根本没有它们 —— 圈上去只会
    ///   截到它们背后那层画面。
    func testOwnWindowsSnapOnlyWhenTheyAppearInTheFrame() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        func own(_ bounds: CGRect, layer: Int = 0, capturable: Bool = true) -> ScreenshotProbeWindow {
            ScreenshotProbeWindow(globalBounds: bounds, layer: layer, alpha: 1,
                                  isOwnProcess: true, isCapturable: capturable,
                                  pid: ProcessInfo.processInfo.processIdentifier, windowNumber: 1)
        }
        let prefs = CGRect(x: 959, y: 25, width: 820, height: 648)
        let pin = CGRect(x: 100, y: 100, width: 300, height: 200)
        let clipboard = CGRect(x: 500, y: 200, width: 520, height: 360)
        let windows = [
            own(prefs),                                         // 偏好设置
            own(pin, layer: 3),                                 // 贴图
            own(clipboard, layer: 21),                          // 历史粘贴板
            own(CGRect(x: 0, y: 0, width: 1920, height: 1080), layer: 3, capturable: false), // 划词气泡这类 .none 的浮窗
            own(CGRect(x: 1527, y: 0, width: 32, height: 24), layer: 25),                    // 状态栏项
        ]
        let rects = ScreenshotWindowProbe.candidateRects(windows: windows, screenFrame: screen, mainTop: 1080)
        XCTAssertEqual(rects, [prefs, pin, clipboard],
                       "自家可采集的窗（含浮窗）必须能吸；不进冻结帧的、菜单栏层的都不吸")
    }

    // MARK: - 定格前提窗的目标判定
    //
    // 2026-11-05 用户要求：智能吸附时把窗口提到最前（默认开）。拍的是快捷键按下那一瞬的
    // 冻结帧，所以提窗必须发生在抓帧之前；这里的判据是「哪一扇值得提」：
    // 被同层窗压住的才提，压不过的（更高的层）不提，没被压住的不提。

    /// 被同层窗压住的那扇要提；自己就在最前面时一下都不动 —— 提了只会白切前台。
    func testRaiseTargetOnlyWhenTheWindowIsCoveredByTheSameLayer() {
        let covered = probeWindow(CGRect(x: 200, y: 200, width: 400, height: 300), pid: 100, number: 10)
        // cover 压住 covered 左上那角，但**不包住光标**：包住了它自己就是光标下那扇。
        let cover = probeWindow(CGRect(x: 0, y: 0, width: 250, height: 250), pid: 200, number: 20)
        let point = CGPoint(x: 300, y: 300)

        XCTAssertEqual(ScreenshotWindowProbe.raiseTarget(windows: [cover, covered], point: point)?.windowNumber,
                       10, "被压住的普通窗要提：不提的话冻结帧里只有露着的那半扇")
        XCTAssertNil(ScreenshotWindowProbe.raiseTarget(windows: [covered, cover], point: point),
                     "自己就在最前面时不动前台：截出来一模一样，还顺手把用户切了家")
    }

    /// 更高层的浮窗（贴图、面板）压着普通窗：提上去也压不过它，不提。
    func testRaiseTargetIgnoresCoverFromAHigherLayer() {
        let target = probeWindow(CGRect(x: 200, y: 200, width: 400, height: 300), pid: 100, number: 10)
        let floating = probeWindow(CGRect(x: 100, y: 100, width: 300, height: 300), layer: 3,
                                   pid: 300, number: 30)
        // 光标落在 target 里、不在 floating 里：浮窗只压住左下那一角。
        XCTAssertNil(ScreenshotWindowProbe.raiseTarget(windows: [floating, target],
                                                       point: CGPoint(x: 450, y: 450)),
                     "更高层的浮窗挡出来的那块提不上去，白切一次前台没有意义")
    }

    /// 别家的浮窗根本不进候选表，同层那一半判据在它身上量不出来 —— 拿自家的贴图
    /// （layer 3，够格）压自家偏好设置（layer 0）才是真能抓到「没看同层」的摆法：
    /// 把偏好设置提上来也压不过贴图，那一帧里照样是贴图在上。
    func testRaiseTargetIgnoresCoverFromAHigherOwnLayer() {
        let prefs = probeWindow(CGRect(x: 200, y: 200, width: 400, height: 300), own: true, number: 7)
        let pin = probeWindow(CGRect(x: 100, y: 100, width: 300, height: 300), layer: 3,
                              own: true, number: 8)
        XCTAssertNil(ScreenshotWindowProbe.raiseTarget(windows: [pin, prefs],
                                                       point: CGPoint(x: 550, y: 450)),
                     "同进程的高层浮窗压出来的那块，提偏好设置也压不过它")
    }

    /// 冻结帧里没有的窗（自家 `.none` 浮层）挡在光标上：既不能当目标，也不算「被压住」。
    func testRaiseTargetSkipsWindowsMissingFromTheFrame() {
        let target = probeWindow(CGRect(x: 200, y: 200, width: 400, height: 300), pid: 100, number: 10)
        let ghost = probeWindow(CGRect(x: 0, y: 0, width: 1920, height: 1080), own: true,
                                capturable: false, number: 99)
        let point = CGPoint(x: 300, y: 300)
        XCTAssertNil(ScreenshotWindowProbe.raiseTarget(windows: [ghost, target], point: point),
                     "圈不到的东西挡出来的一片，提窗也改不了冻结帧")
        XCTAssertEqual(ScreenshotWindowProbe.frontmostCandidate(at: point, in: [ghost, target])?.windowNumber,
                       10, "验「到没到最前」的那一读必须跳过不进帧的窗，否则永远等不到")
    }

    /// 「到没到最前」那一读必须按光标取：两个够格的窗并排时，光标在谁里面就答谁。
    /// 少了这一半，`waitUntilFront` 会拿别的窗当成目标，没提成也报成功。
    func testFrontmostCandidateOnlyAnswersForThePoint() {
        let left = probeWindow(CGRect(x: 0, y: 0, width: 200, height: 200), number: 1)
        let right = probeWindow(CGRect(x: 300, y: 0, width: 200, height: 200), number: 2)
        XCTAssertEqual(ScreenshotWindowProbe.frontmostCandidate(at: CGPoint(x: 400, y: 100),
                                                                in: [left, right])?.windowNumber,
                       2, "光标落在右边那扇里，就该答右边")
        XCTAssertNil(ScreenshotWindowProbe.frontmostCandidate(at: CGPoint(x: 900, y: 900),
                                                              in: [left, right]),
                     "光标不在任何够格的窗里时不许随便指一扇")
    }

    /// 提窗「成没成」的判据必须能分辨失败：压着它的同层窗还在前面时为 false，
    /// 提到最前后才 true。2026-11-05 装机实测里旧判据（光标下第一个够格的窗是不是
    /// 它）在提窗完全没动时也成立，把失败报成了「已到最前」。
    func testAheadOfSameLayerCoversDistinguishesAFailedRaise() {
        let covered = probeWindow(CGRect(x: 200, y: 200, width: 400, height: 300), pid: 100, number: 10)
        let cover = probeWindow(CGRect(x: 0, y: 0, width: 250, height: 250), pid: 200, number: 20)
        XCTAssertFalse(ScreenshotWindowProbe.isAheadOfSameLayerCovers(covered, in: [cover, covered]),
                       "同层窗还挡在前面，就是没提起来")
        XCTAssertTrue(ScreenshotWindowProbe.isAheadOfSameLayerCovers(covered, in: [covered, cover]),
                      "提到最前之后才该放行抓帧")
        XCTAssertFalse(ScreenshotWindowProbe.isAheadOfSameLayerCovers(covered, in: [cover]),
                       "目标已经不在表里（窗被关了），也别报成功")
    }

    /// 更高层的自家浮窗压在目标上：同层口径与 `raiseTarget` 一致，这一读不能被它
    /// 绊住 —— 提窗本来就压不过更高层，等它只会白等到超时。
    func testAheadOfSameLayerCoversIgnoresHigherLayers() {
        let prefs = probeWindow(CGRect(x: 200, y: 200, width: 400, height: 300), own: true, number: 7)
        let pin = probeWindow(CGRect(x: 100, y: 100, width: 300, height: 300), layer: 3,
                              own: true, number: 8)
        XCTAssertTrue(ScreenshotWindowProbe.isAheadOfSameLayerCovers(prefs, in: [pin, prefs]),
                      "更高层的浮窗不是这手能压过的，不该算作没提成")
    }

    /// 自家窗也参与提窗：偏好设置被别家普通窗压住时，按编号置前（走的是另一条路）。
    func testRaiseTargetIncludesCoveredOwnWindows() {
        let prefs = probeWindow(CGRect(x: 200, y: 200, width: 400, height: 300), own: true, number: 7)
        let cover = probeWindow(CGRect(x: 0, y: 0, width: 400, height: 400), pid: 200, number: 20)
        // 光标落在偏好设置里、cover 之外，cover 与它相交。
        let target = ScreenshotWindowProbe.raiseTarget(windows: [cover, prefs],
                                                       point: CGPoint(x: 550, y: 450))
        XCTAssertEqual(target?.windowNumber, 7)
        XCTAssertEqual(target?.isOwnProcess, true, "自家窗走按编号置前，不走别的进程的 AX")
    }

    /// 光标落在桌面、菜单栏、只有非普通层的窗上：没有目标，一下都不碰。
    func testRaiseTargetIsNilWithoutAnEligibleWindowUnderThePointer() {
        let dock = probeWindow(CGRect(x: 0, y: 1040, width: 1920, height: 40), layer: 20,
                               pid: 400, number: 40)
        XCTAssertNil(ScreenshotWindowProbe.raiseTarget(windows: [dock], point: CGPoint(x: 900, y: 1060)),
                     "程序坞那条整屏矩形不是可截的窗，不能提")
        XCTAssertNil(ScreenshotWindowProbe.raiseTarget(windows: [], point: CGPoint(x: 10, y: 10)))
    }

    private func probeWindow(_ bounds: CGRect, layer: Int = 0, alpha: Double = 1,
                             own: Bool = false, capturable: Bool = true,
                             pid: pid_t = 100, number: Int = 1) -> ScreenshotProbeWindow {
        ScreenshotProbeWindow(globalBounds: bounds, layer: layer, alpha: alpha,
                              isOwnProcess: own, isCapturable: capturable,
                              pid: own ? ProcessInfo.processInfo.processIdentifier : pid,
                              windowNumber: number)
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
