//
//  ScreenshotModeTests.swift
//
//  模式条 + 实况采集这条新线的取证。分三层：
//  1. **状态机**：四档各自的出口对不对（就地编辑 / 交给实况采集 / 直接认字），
//     以及模式条不能把「从屏顶往下拖一个选区」这条路吃掉。
//  2. **离屏渲染**：条子的底衬和墨色跟随系统外观翻档，选中那格真铺上强调色底 ——
//     判据取自渲染出来的位图，不取自条子自己的属性。
//  3. **纯计算**：滚动拼接的位移识别、段落裁剪、长图铺设，浮层摆放，坐标换算，
//     编码尺寸，落盘命名。真采集要屏幕和录屏权限，所以判据全部落在能离线喂数据的
//     那一部分；真链路只能在装好的 .app 里验。
//
//  合成图用「行号编码进颜色」的条纹纸：相邻两行差得很开（每通道各乘一个与 256 互质的
//  数），错位一行的平均差是几十，远在容差 6 之外；对齐时是 0。周期 256 行，而这里最长
//  一帧 240 行、搜索范围不到 200 —— 不会出现「隔一整个周期假装对上」的假命中。
//

import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import XCTest

@testable import Screenshot

final class ScreenshotModeTests: XCTestCase {
    // MARK: - 条子装配

    /// 四档都在条子上，顺序就是 QQ 那条（截图 → 滚动截图 → 录屏 → 文字识别）。
    /// 漏一档、摆错顺序在代码里只是数组少一个元素，肉眼看不出来，只能数装配结果。
    func testModeBarCarriesAllFourModesInOrder() throws {
        let view = try overlay()
        view.showModeBar()
        let bar = try XCTUnwrap(view.modeBar, "摆出来就该挂着")
        XCTAssertEqual(bar.elementsOnBar, ["still", "scroll", "record", "text"])
        XCTAssertEqual(bar.activeModeOnBar, .still, "默认亮在第一档")
        XCTAssertEqual(view.mode, .still)
    }

    /// 格子一个不落、一重不撞：横向挨着排，全部落在条子里。
    func testModeBarCellsTileTheBarWithoutOverlapping() throws {
        let view = try overlay()
        view.showModeBar()
        let bar = try XCTUnwrap(view.modeBar)
        let rects = bar.actionableRects
        XCTAssertEqual(rects.count, 4)
        XCTAssertEqual(bar.frame.width, bar.preferredWidth, accuracy: 0.5)
        for (index, rect) in rects.enumerated() {
            XCTAssertGreaterThan(rect.width, 40, "每格要装得下一个图标加一行字：\(rect)")
            XCTAssertEqual(rect.height, ScreenshotModeBarView.cellHeight)
            XCTAssertTrue(bar.bounds.contains(rect), "格子不能跑到条子外面 \(rect)")
            if index > 0 {
                XCTAssertEqual(rect.minX, rects[index - 1].maxX + ScreenshotModeBarView.cellGap,
                               accuracy: 0.5, "格子之间只留一格缝")
            }
        }
    }

    /// 摆位规则：横向对屏居中，纵向让开菜单栏再留一格缝。
    func testModeBarSitsBelowTheMenuBarAndCenters() {
        let container = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = ScreenshotSelectionView.modeBarFrame(width: 300, container: container, topInset: 25)
        XCTAssertEqual(frame.midX, 720, accuracy: 0.5)
        XCTAssertEqual(frame.minY, 25 + ScreenshotModeBarView.topMargin, accuracy: 0.5)
        XCTAssertEqual(frame.height, ScreenshotModeBarView.barHeight)
        // 拿不到屏（还没挂窗）时 inset 答 0，条子贴屏顶摆 —— 但不能是负数。
        XCTAssertEqual(ScreenshotSelectionView.menuBarInset(of: nil), 0)
    }

    // MARK: - 分流：四档各走各的出口

    /// 第一档维持原样：松手进就地编辑，注解条亮出来，模式条收掉。
    func testStillModeStillEntersEditing() throws {
        let view = try overlay()
        view.showModeBar()
        drag(in: view, from: (200, 120), to: (420, 260))
        XCTAssertEqual(view.phase, .editing)
        XCTAssertFalse(view.toolbar?.isHidden ?? true, "注解条该亮着")
        XCTAssertTrue(view.modeBar?.isHidden ?? false, "选区落定后模式条要让位")
    }

    /// 「提取文字」那条专用快捷键（issue #74）开出来的就是这样一场：控制器在建好遮罩、
    /// 摆模式条**之前**把档摆上。所以条子一出现亮的就该是文字那一格，松手直接开认字，
    /// 中间不停在注解条上。
    func testStartingPresetOnTextModeLightsThatCellAndRoutesTheDrag() throws {
        let view = try overlay()
        view.mode = .text
        view.showModeBar()
        XCTAssertEqual(view.modeBar?.activeModeOnBar, .text, "开出来就要亮在提取文字那一格")

        drag(in: view, from: (200, 120), to: (420, 260))
        XCTAssertTrue(view.ocrRunning, "松手就该直接开认字")
        XCTAssertNil(view.toolbar, "这一档不该亮出注解条")
        XCTAssertTrue(view.modeBar?.isHidden ?? false, "认字期间模式条要让位")
    }

    /// 滚动截图：选区交给实况采集，**不进**编辑态（注解条这时候没用，屏还要还给被滚的 App）。
    func testScrollModeHandsTheSelectionToLiveCapture() throws {
        let view = try overlay()
        view.showModeBar()
        view.modeBar?.onPick?(.scroll)
        XCTAssertEqual(view.mode, .scroll)

        var handed: (mode: ScreenshotMode, rect: CGRect, screen: NSRect)?
        view.onLiveCapture = { handed = ($0, $1, $2) }
        drag(in: view, from: (200, 120), to: (420, 260))

        let got = try XCTUnwrap(handed, "这一档要落到实况采集，而不是就地编辑")
        XCTAssertEqual(got.mode, .scroll)
        XCTAssertEqual(got.rect, CGRect(x: 200, y: 120, width: 220, height: 140))
        XCTAssertNil(view.toolbar, "注解条不该被亮出来")
        XCTAssertEqual(view.phase, .picking)
    }

    /// 录屏同样交给实况采集，而且交的是**这一块屏的 AppKit 矩形**（浮层要按它摆描边）。
    func testRecordModeHandsOverTheScreenRect() throws {
        let view = try overlay(size: NSSize(width: 1440, height: 900))
        view.showModeBar()
        view.modeBar?.onPick?(.record)

        var handed: (mode: ScreenshotMode, rect: CGRect, screen: NSRect)?
        view.onLiveCapture = { handed = ($0, $1, $2) }
        drag(in: view, from: (100, 200), to: (500, 600))

        let got = try XCTUnwrap(handed)
        XCTAssertEqual(got.mode, .record)
        // 视图是 flipped 的（原点左上），AppKit 屏幕矩形是左下原点：y = 900 - 600 = 300。
        XCTAssertEqual(got.screen, NSRect(x: 100, y: 300, width: 400, height: 400))
    }

    /// 换档之后，屏上那句按键说明要跟着换 —— 文案读的是 `mode.hintKey`，
    /// 档换了 key 没换的话，用户看到还是「回车进入编辑」。
    func testEveryModeHasItsOwnHintKey() {
        let keys = Set(ScreenshotMode.allCases.map { $0.hintKey })
        XCTAssertEqual(keys.count, ScreenshotMode.allCases.count, "四档的说明不能撞成同一句")
        for mode in ScreenshotMode.allCases {
            XCTAssertFalse(mode.hintKey.isEmpty, "\(mode) 没有按键说明")
            XCTAssertFalse(mode.title.isEmpty, "\(mode) 没有档名")
        }
    }

    /// 再点一次已经亮着的那一档等于没改：不给「取消当前档」这种谁也不会想要的中间态。
    func testRePickingTheActiveModeChangesNothing() throws {
        let view = try overlay()
        view.showModeBar()
        view.modeBar?.onPick?(.record)
        view.modeBar?.onPick?(.record)
        XCTAssertEqual(view.mode, .record)
        XCTAssertEqual(view.modeBar?.activeModeOnBar, .record)
    }

    /// 条子不能把屏顶那一条横贯整屏的区域都吃掉：按在它旁边的空白处仍然要能起选区
    /// （从菜单栏下方往下拖一块屏是合法操作）。
    func testBlankSpotsBesideTheModeBarStillStartASelection() throws {
        let view = try overlay(size: NSSize(width: 1440, height: 900))
        view.showModeBar()
        let bar = try XCTUnwrap(view.modeBar)
        let blank = CGPoint(x: bar.frame.minX - 20, y: bar.frame.midY)
        XCTAssertFalse(bar.hasActionable(atOverlayPoint: blank))

        drag(in: view, from: (blank.x, blank.y), to: (blank.x + 300, blank.y + 200))
        XCTAssertEqual(view.selection, CGRect(x: blank.x, y: blank.y, width: 300, height: 200),
                       "从条子旁边的空白处起拖要能框出选区")
    }

    /// 按在格子上那一下归格子：不能顺带把选区拖出来（真事件里格子自己的 mouseDown 拦下，
    /// 这里验判定树给出同一个答案）。
    func testPressOnAModeCellDoesNotStartASelection() throws {
        let view = try overlay(size: NSSize(width: 1440, height: 900))
        view.showModeBar()
        let bar = try XCTUnwrap(view.modeBar)
        let cell = try XCTUnwrap(bar.rect(for: .scroll, atBarOrigin: bar.frame.origin))
        let center = CGPoint(x: cell.midX, y: cell.midY)
        XCTAssertTrue(bar.hasActionable(atOverlayPoint: center))

        drag(in: view, from: (center.x, center.y), to: (center.x + 300, center.y + 200))
        XCTAssertEqual(view.selection, .zero, "从格子上起拖不该框出一块")
        XCTAssertEqual(view.mode, .still, "按下不等于换档，抬起才算")
    }

    /// 实况档里点一下吸附到的窗 = 直接采集那一块，不能掉进注解编辑态
    /// （掉进去的话用户看到的是注解条，这一档等于没生效）。
    func testClickOnASnappedWindowRoutesByMode() throws {
        let view = try overlay()
        view.showModeBar()
        view.modeBar?.onPick?(.scroll)
        var handed = 0
        view.onLiveCapture = { _, _, _ in handed += 1 }
        view.windows = [CGRect(x: 100, y: 100, width: 300, height: 200)]
        view.pointerMoved(CGPoint(x: 150, y: 150))
        view.pointerDown(CGPoint(x: 150, y: 150), clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(handed, 1)
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 100, width: 300, height: 200),
                       "交出去的要就是吸附到的那块窗")
        XCTAssertNil(view.toolbar, "不该亮出注解条")
        XCTAssertEqual(view.phase, .picking)
    }

    /// 实况档下双击已有选区 = 「再来一次这一档的事」，走同一个分流口，而不是把这张图复制走。
    /// （文字识别认输后选区还留着，这一条就是它的重试路径。）
    func testDoubleClickInLiveModeRoutesAgain() throws {
        let view = try overlay()
        view.showModeBar()
        view.modeBar?.onPick?(.scroll)
        var handed = 0
        view.onLiveCapture = { _, _, _ in handed += 1 }
        drag(in: view, from: (100, 100), to: (400, 300))
        XCTAssertEqual(handed, 1)
        view.pointerDown(CGPoint(x: 200, y: 200), clickCount: 2)
        XCTAssertEqual(handed, 2, "双击选区要再走一次分流，而不是复制这张图")
    }

    // MARK: - 离屏渲染：跟随系统外观

    /// 底衬和墨色跟着明暗翻档（QQ 只借图标语言和格子顺序，颜色不借）。
    /// 判据取自两档各自渲染出来的位图，不取自条子自己的属性。
    func testModeBarFollowsSystemAppearance() throws {
        let light = try renderModeBar(.aqua, name: "mode-bar-aqua.png")
        let dark = try renderModeBar(.darkAqua, name: "mode-bar-darkaqua.png")

        XCTAssertGreaterThan(light.body, 0.75, "浅色外观下条子该是浅底：\(light.body)")
        XCTAssertLessThan(dark.body, 0.35, "深色外观下条子该是深底：\(dark.body)")
        XCTAssertGreaterThan(zip(light.cellPixels, dark.cellPixels).map { abs($0 - $1) }.max() ?? 0, 0.5,
                             "换外观必须真改到像素：没翻档就成了空转")
        // 两档都要有一批离底 0.3 的字，否则「翻了档但字没了」这种错会漏过去。
        XCTAssertGreaterThanOrEqual(light.ink, 60, "浅底上的图标文字要换成深墨")
        XCTAssertGreaterThanOrEqual(dark.ink, 60, "深底上的图标文字要换成浅墨")
    }

    /// 亮着的那一格真铺上强调色底，而且底色跟着换档走：选中态不能只活在状态位里。
    func testActiveModeCellCarriesTheAccentChip() throws {
        let stillOn = try renderModeBar(.aqua, name: "mode-bar-accent.png")
        let stillOff = try renderModeBar(.aqua, name: "mode-bar-accent-move.png", mode: .record)

        XCTAssertGreaterThan(stillOn.blueShare(of: .still), 0.15, "亮着的那一格该铺上蓝底")
        XCTAssertLessThan(stillOff.blueShare(of: .still), 0.02,
                          "换档后灭掉的那格不该还留着蓝底：\(stillOff.blueShare(of: .still))")
        XCTAssertGreaterThan(stillOff.blueShare(of: .record), 0.15, "蓝底要跟着换档走到新格子")
    }

    // MARK: - 长截图：拼接数学

    /// 认得出注入的那一次滚动：帧顶从 0 走到 30，位移就该报 30。
    func testStitcherFindsTheScrollShift() throws {
        let first = try rows(of: stripes(top: 0))
        let second = try rows(of: stripes(top: 30))
        XCTAssertEqual(ScreenshotStitcher.shift(previous: first, next: second, expected: 30), 30)
        // 先验给错也认得出来（惯性滚动落点和注入量对不上是常事）。
        XCTAssertEqual(ScreenshotStitcher.shift(previous: first, next: second, expected: 90), 30)
    }

    /// 到底了（画面一动没动）报 0，让调用方停止；对不上的图报 nil，宁可不拼。
    func testStitcherReportsBottomAndRefusal() throws {
        let first = try rows(of: stripes(top: 0))
        XCTAssertEqual(ScreenshotStitcher.shift(previous: first, next: first, expected: 30), 0)
        let smaller = try rows(of: stripes(top: 0, height: 200))
        XCTAssertNil(ScreenshotStitcher.shift(previous: first, next: smaller, expected: 30),
                     "帧高都变了，谈不上位移")
        // 一次跳超过一屏：重合不足 40 行，判「对不上」而不是硬猜。
        let jumped = try rows(of: stripes(top: 220))
        XCTAssertNil(ScreenshotStitcher.shift(previous: first, next: jumped, expected: 30))
    }

    /// 只把新露出来的那一段接上去：段高等于位移，段内容是全局行 240…270。
    func testSegmentKeepsOnlyTheNewlyRevealedRows() throws {
        let segment = try XCTUnwrap(ScreenshotScrollCapture.segment(from: stripes(top: 30),
                                                                     shift: 30, canvasHeight: 240))
        XCTAssertEqual(segment.image.height, 30)
        XCTAssertEqual(segment.top, 240)
        for row in 0..<30 {
            XCTAssertEqual(gray(segment.image, row: row), redOf(240 + row), accuracy: 2,
                           "接进去的第 \(row) 行该是全局第 \(240 + row) 行")
        }
    }

    /// 往上接的时候新内容在帧的**顶上**，位置在长图顶边之上（全局行号是负数）。
    func testUpwardSegmentTakesTheTopRowsAboveTheCanvas() throws {
        let segment = try XCTUnwrap(ScreenshotScrollCapture.upwardSegment(from: stripes(top: 200),
                                                                         shift: 100, canvasTop: 0))
        XCTAssertEqual(segment.image.height, 100)
        XCTAssertEqual(segment.top, -100, "接在长图顶上，全局行号就该是负的")
        for row in 0..<100 {
            XCTAssertEqual(gray(segment.image, row: row), redOf(200 + row), accuracy: 2,
                           "接进去的第 \(row) 行该是全局第 \(200 + row) 行")
        }
        XCTAssertNil(ScreenshotScrollCapture.upwardSegment(from: stripes(top: 200),
                                                          shift: 0, canvasTop: 0))
    }

    /// 端到端：两帧各截一次「往下滚了 30 行」的画面，铺出来的长图每一行都对得上全局行号。
    func testComposedLongShotHasEveryRowInOrder() throws {
        let first = stripes(top: 0)
        let second = stripes(top: 30)
        let shift = try XCTUnwrap(ScreenshotStitcher.shift(previous: rows(of: first),
                                                           next: rows(of: second), expected: 30))
        let segment = try XCTUnwrap(ScreenshotScrollCapture.segment(from: second, shift: shift,
                                                                    canvasHeight: 240))
        let long = try XCTUnwrap(ScreenshotStitcher.compose([(first, 0), segment],
                                                            width: 40, height: 240 + segment.image.height))
        XCTAssertEqual(long.height, 270)
        for row in stride(from: 0, to: 270, by: 7) {
            XCTAssertEqual(gray(long, row: row), redOf(row), accuracy: 2,
                           "第 \(row) 行对不上全局行号，拼接错位了")
        }
    }

    /// 位移小于等于 0 或者越界都拒掉：段高钳到帧高，整帧都是新内容时全收。
    func testSegmentRefusesBadShifts() {
        let frame = stripes(top: 0)
        XCTAssertEqual(ScreenshotScrollCapture.segment(from: frame, shift: 240,
                                                       canvasHeight: 100)?.image.height, 240)
        XCTAssertNil(ScreenshotScrollCapture.segment(from: frame, shift: 0, canvasHeight: 100))
        XCTAssertNil(ScreenshotScrollCapture.segment(from: frame, shift: -5, canvasHeight: 100))
    }

    // MARK: - 长截图：注入与坐标

    /// 注入量按这块屏的倍率换算成像素行：2x 屏上滚 100 点，画面走 200 行。
    func testExpectedShiftUsesTheDisplayScale() {
        XCTAssertEqual(ScreenshotScrollCapture.expectedShift(points: 100, scale: 2), 200)
        XCTAssertEqual(ScreenshotScrollCapture.expectedShift(points: 100, scale: 1), 100)
        XCTAssertEqual(ScreenshotScrollCapture.expectedShift(points: 99.6, scale: 2), 199)
    }

    /// 事件里填的是**点**，比对用的是**像素行**：这两件事必须分开，中间只有 `expectedShift`
    /// 做换算。给事件也乘上倍率等于让设置项「每次滚动的量」在 2x 屏上滚两倍，矮选区一次
    /// 跳过一整屏 → 重合不够 → 拼接认不上 → 用户看到的是长截图没反应。
    /// （`.pixel` 单位落点是点：实测见 `RemoteClickExecutor.scrollBy` 那条注释。）
    func testInjectedWheelCarriesPointsNotDeviceRows() {
        XCTAssertEqual(ScreenshotScrollCapture.wheelUnits(points: 100), 100)
        XCTAssertEqual(ScreenshotScrollCapture.wheelUnits(points: 20), 20)
        XCTAssertEqual(ScreenshotScrollCapture.wheelUnits(points: 99.6), 100)
        XCTAssertNotEqual(Int(ScreenshotScrollCapture.wheelUnits(points: 100)),
                          ScreenshotScrollCapture.expectedShift(points: 100, scale: 2),
                          "2x 屏上这两数必须不同：一样就说明事件里被乘过倍率了")
    }

    /// 视图坐标（flipped，原点在这块屏左上）→ 滚轮事件的全局 CG 坐标。
    /// 原点翻错就滚到底下的 Dock 或者另一块屏上，而且错得很安静。
    func testScrollLocationHandlesSecondaryDisplays() {
        let primary = CGFloat(900)
        XCTAssertEqual(ScreenshotScrollCapture.cgPoint(viewPoint: CGPoint(x: 120, y: 100),
                                                       screenFrame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                                       primaryHeight: primary),
                       CGPoint(x: 120, y: 100), "主屏上这一点视图坐标和全局 CG 坐标本来就一致")
        // 挂在主屏下面的副屏：这块屏顶上第 200 行 = 全局 900 + 200。
        XCTAssertEqual(ScreenshotScrollCapture.cgPoint(viewPoint: CGPoint(x: 50, y: 200),
                                                       screenFrame: NSRect(x: 0, y: -1080, width: 1920, height: 1080),
                                                       primaryHeight: primary),
                       CGPoint(x: 50, y: 1100))
        // 挂在右边、和主屏顶对齐的副屏（1080 高，原点落到 -180）：x 要带上这块屏的偏移，
        // y 仍然按「距这块屏顶 200」翻出来。
        XCTAssertEqual(ScreenshotScrollCapture.cgPoint(viewPoint: CGPoint(x: 50, y: 200),
                                                       screenFrame: NSRect(x: 1440, y: -180, width: 1920, height: 1080),
                                                       primaryHeight: primary),
                       CGPoint(x: 1490, y: 200))
    }

    // MARK: - 长截图：循环本身

    /// 滚三下到底，长图把四屏内容按全局行号接成一串，并且自己收场。
    ///
    /// 这是这一路唯一没被覆盖过的地方：其余取证都在纯计算上，「抓帧 → 注入 → 等画面稳住 →
    /// 比对 → 裁段 → 收场」这个定时器驱动的圈一次都没真转过，而用户实测报「长截图没实现」
    /// 报的就是这个圈。外围（真抓屏、真滚轮）用 `frameSource`/`scrollInjector` 两个接缝替掉：
    /// 测试进程里 `CGDisplayCreateImage` 返回 nil、`CGEvent.post` 会被整个丢掉（未授权，
    /// 实测见 `ScreenshotFrameTests` 那条注释），换掉外围之后循环本身照原样跑。
    func testScrollLoopStitchesEveryScrolledScreenAndStopsAtTheBottom() throws {
        let session = try paperSession(step: 100, limit: 300)
        session.capture.start()
        XCTAssertTrue(pump(until: { session.outcome != nil }, timeout: 10),
                      "循环没自己收场：滚了 \(session.injections) 次、\(session.readouts)")

        XCTAssertEqual(session.injections, 4, "最后一次注入是探到底的那一下，不能少")
        let result = try XCTUnwrap(session.outcome)
        guard case .composed(let image, let appended) = result else {
            failWith(result, "四屏内容本该拼成长图")
            return
        }
        XCTAssertEqual(appended, 3, "第一帧之外还要接三段")
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 540, "240 + 3×100：每一屏新露出来的那一段都要进图")
        // 逐行对全局行号：错位一行、重复一段、漏一段都会在这里露出来。
        for row in stride(from: 0, to: 540, by: 7) {
            XCTAssertEqual(gray(image, row: row), redOf(row), accuracy: 2,
                           "长图第 \(row) 行不是全局第 \(row) 行，拼接错位了")
        }
        XCTAssertEqual(session.readouts, ["40×240", "40×340", "40×440", "40×540"],
                       "每接一段该报一次当前长图尺寸（浮层读数靠它）")
    }

    /// 页面不吃滚轮时**不能**报成功：旧行为是出一张「只有第一屏」的图，提示还写「已复制
    /// 40×240」，用户只能认为长截图坏了。现在 `appended == 0` 单独交出去，由控制器报失败。
    /// 两个方向都得试过才认输：向下一下、翻成向上再一下。
    func testScrollLoopSaysZeroSegmentsWhenThePageNeverMoves() throws {
        let session = try paperSession(step: 100, limit: 0)
        session.capture.start()
        XCTAssertTrue(pump(until: { session.outcome != nil }, timeout: 10), "循环没自己收场")

        XCTAssertEqual(session.injections, 2, "向下滚不动该翻成向上再试一下，两边都不动才收场")
        let result = try XCTUnwrap(session.outcome)
        guard case .composed(let image, let appended) = result else {
            failWith(result, "画面没动不算失败：只是这一段没接上")
            return
        }
        XCTAssertEqual(appended, 0, "一段都没接上还敢报成功，就是这条 bug 的成因")
        XCTAssertEqual(image.height, 240, "这时候的图等同于一张普通截图")
        XCTAssertEqual(session.readouts, ["40×240"])
    }

    /// 框住的这块**本来就停在底部**（聊天记录、翻到底的网页）时，向下滚一动没动不等于没内容：
    /// 上面还有整整几屏。这一场从底部起手，循环该翻成向上接，把上面三屏补到长图顶上，
    /// 出来的图仍然是「全局第 0…540 行按行号排好」的一张完整长图。
    ///
    /// 用户实测报的「长截图报错」就是这个场景：Qoder 的聊天窗自动贴底，旧代码只会向下滚，
    /// 滚不动就报「页面没跟着滚轮动」，长截图在最常见的用法上直接不可用。
    func testScrollLoopFlipsUpwardWhenTheSelectionStartsAtTheBottom() throws {
        let session = try paperSession(step: 100, limit: 300, startTop: 300)
        session.capture.start()
        XCTAssertTrue(pump(until: { session.outcome != nil }, timeout: 15),
                      "循环没自己收场：滚了 \(session.injections) 次、\(session.readouts)")

        let result = try XCTUnwrap(session.outcome)
        guard case .composed(let image, let appended) = result else {
            failWith(result, "从底部起手该往上接出长图")
            return
        }
        XCTAssertEqual(appended, 3, "第一帧之外往上还要接三段")
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 540, "240 + 3×100：往上接的那几屏也要进图")
        XCTAssertEqual(session.injections, 5, "向下那一下白花掉，之后向上四下（最后一下探到顶）")
        // 顺序是这条测试的要点：往上接的段落在全局行号上是负数，铺图前要整体平移；
        // 平移错一点，第一帧就不在长图底部而在中间，逐行对全局行号当场露馅。
        for row in stride(from: 0, to: 540, by: 7) {
            XCTAssertEqual(gray(image, row: row), redOf(row), accuracy: 2,
                           "长图第 \(row) 行不是全局第 \(row) 行，往上接的段摆错位了")
        }
        XCTAssertEqual(session.readouts, ["40×240", "40×340", "40×440", "40×540"],
                       "每接一段该报一次当前长图尺寸（浮层读数靠它）")
        XCTAssertEqual(session.top, 0, "翻上去之后该一路滚到内容的顶")
    }

    /// 已经往下接过段了，就**不能**再翻上去：翻上去看到的是刚接过的那几屏，
    /// 往长图顶上再铺一遍就是一段重复内容 —— 比短一截的长图糟得多。
    func testScrollLoopNeverFlipsUpAfterItHasStitchedSomething() throws {
        let session = try paperSession(step: 100, limit: 300)
        session.capture.start()
        XCTAssertTrue(pump(until: { session.outcome != nil }, timeout: 15), "循环没自己收场")

        XCTAssertEqual(session.injections, 4, "到底之后就该收场，不该再往回滚一下")
        let result = try XCTUnwrap(session.outcome)
        guard case .composed(let image, let appended) = result else {
            failWith(result, "到底了该把已经接好的出图")
            return
        }
        XCTAssertEqual(appended, 3)
        XCTAssertEqual(image.height, 540)
        for row in stride(from: 0, to: 540, by: 7) {
            XCTAssertEqual(gray(image, row: row), redOf(row), accuracy: 2,
                           "长图第 \(row) 行不是全局第 \(row) 行")
        }
    }

    /// 内容一直滚得动也得停在「最多接几屏」这个上限上，不能滚到用户喊停为止。
    func testScrollLoopStopsAtTheMaxScreensCap() throws {
        let session = try paperSession(step: 100, limit: 100_000, maxScreens: 2)
        session.capture.start()
        XCTAssertTrue(pump(until: { session.outcome != nil }, timeout: 10),
                      "撞了上限也不收场：滚了 \(session.injections) 次")

        let result = try XCTUnwrap(session.outcome)
        guard case .composed(let image, let appended) = result else {
            failWith(result, "上限收场该出图")
            return
        }
        XCTAssertEqual(appended, 3)
        XCTAssertEqual(image.height, 540, "上限 2 屏 = 480 行，接过头的那一段照样进图")
        XCTAssertEqual(session.injections, 3,
                       "够了上限还往底下那个 App 里注滚轮，用户面上的页面会被多滚一屏")
    }

    /// 连第一帧都拿不到（屏被拔掉/休眠）是唯一一条不出一路的收场：必须报失败，
    /// 而且不能把定时器留在身上。
    func testScrollLoopFailsCleanlyWithoutTheFirstFrame() throws {
        let session = try paperSession(step: 100, limit: 300)
        session.capture.frameSource = { nil }
        session.capture.start()

        let result = try XCTUnwrap(session.outcome, "拿不到第一帧必须当场报失败")
        guard case .failed(let reason) = result else {
            XCTFail("拿不到第一帧还出图：\(result)")
            return
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(session.injections, 0, "第一帧都没有，不该往底下那个 App 注入滚动")
        XCTAssertTrue(session.readouts.isEmpty)
        // `start()` 是同步走失败的，此时没有定时器留下；等一秒确认它不会在后面偷偷出图。
        _ = pump(until: { false }, timeout: 1)
        if case .composed = session.outcome { XCTFail("失败之后又出了图") }
    }

    /// 中途按停止：把已经拼出来的部分照常交出去，别把用户滚了半天换来的那几屏丢掉。
    func testScrollLoopKeepsWhatIsAlreadyStitchedWhenStoppedByHand() throws {
        let session = try paperSession(step: 100, limit: 100_000, maxScreens: 20)
        session.capture.start()
        XCTAssertTrue(pump(until: { session.readouts.count >= 3 }, timeout: 10),
                      "还没接出两段就被叫停了：\(session.readouts)")
        session.capture.stop()

        let result = try XCTUnwrap(session.outcome, "手动停止也得给个收场")
        guard case .composed(let image, let appended) = result else {
            failWith(result, "停止时已经拼好的部分该出图")
            return
        }
        XCTAssertGreaterThanOrEqual(appended, 2)
        XCTAssertEqual(image.height, 240 + 100 * appended, accuracy: 1)
        let injections = session.injections
        _ = pump(until: { false }, timeout: 1)
        XCTAssertEqual(session.injections, injections, "停了之后还在滚：定时器没关掉")
    }

    // MARK: - 浮层摆放

    /// 控制胶囊默认贴在区域**下沿外侧**、右端对齐。
    func testControlPillSitsBelowTheRegion() {
        let region = NSRect(x: 200, y: 200, width: 600, height: 400)
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let size = NSSize(width: 160, height: ScreenshotLivePanelView.height)
        let frame = ScreenshotLivePanel.controlFrame(region: region, size: size, visible: visible)
        XCTAssertEqual(frame.maxX, region.maxX, accuracy: 0.5, "右端对齐区域")
        XCTAssertEqual(frame.maxY, region.minY - ScreenshotLivePanel.gap, accuracy: 0.5,
                       "贴在区域下沿外面")
        XCTAssertTrue(visible.contains(frame))
    }

    /// 下面顶到 Dock 就翻到区域上沿外侧；两边都放不下才压进区域内部的底边。
    func testControlPillFlipsAboveOrFallsInside() {
        let size = NSSize(width: 160, height: ScreenshotLivePanelView.height)
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)

        let region = NSRect(x: 200, y: 26, width: 600, height: 200)
        let low = ScreenshotLivePanel.controlFrame(region: region, size: size, visible: visible)
        XCTAssertEqual(low.minY, region.maxY + ScreenshotLivePanel.gap, accuracy: 0.5,
                       "下沿放不下就该翻到区域上沿外面：\(low)")
        XCTAssertGreaterThanOrEqual(low.maxY, visible.minY + ScreenshotLivePanel.margin,
                                    "翻到上沿也不能出可见区：\(low)")

        // 区域几乎占满整屏：上下都放不下，压进区域内部底边，且不能出屏。
        let tight = ScreenshotLivePanel.controlFrame(
            region: visible.insetBy(dx: 2, dy: 2), size: size, visible: visible)
        XCTAssertTrue(visible.contains(tight), "怎么挪都不能把浮层推出可见区：\(tight)")
    }

    /// 时长读数格式稳定：`1:05` 和 `12:34` 都占五位，读数变化不会把浮层宽度抖一下。
    func testDurationReadoutFormat() {
        XCTAssertEqual(ScreenshotController.duration(0), "0:00")
        XCTAssertEqual(ScreenshotController.duration(9.4), "0:09")
        XCTAssertEqual(ScreenshotController.duration(65), "1:05")
        XCTAssertEqual(ScreenshotController.duration(754), "12:34")
    }

    // MARK: - 录屏：坐标与编码

    /// 视图坐标（左上原点）→ 这块屏的 AppKit 坐标（左下原点）：只翻 y，x 不动。
    /// 原点猜反的话录出来会框到屏幕另一头，而且错得很安静。
    func testCropRectFlipsYWithinItsOwnDisplay() {
        XCTAssertEqual(ScreenshotRecorder.cropRect(viewRect: CGRect(x: 120, y: 80, width: 400, height: 300),
                                                   screenHeight: 900),
                       CGRect(x: 120, y: 520, width: 400, height: 300))
        // 贴屏底的那块翻过去就该贴这块屏的下沿（y=0）。
        XCTAssertEqual(ScreenshotRecorder.cropRect(viewRect: CGRect(x: 0, y: 600, width: 100, height: 300),
                                                   screenHeight: 900).minY, 0)
    }

    /// H.264 只吃偶数边长；码率夹在一个不会把盘写爆的区间里。
    func testEncoderDimensionsAndBitrate() {
        XCTAssertEqual(ScreenshotRecorder.even(101), 100)
        XCTAssertEqual(ScreenshotRecorder.even(100), 100)
        XCTAssertEqual(ScreenshotRecorder.bitrate(width: 1920, height: 1080, frameRate: 30), 6_220_800)
        XCTAssertEqual(ScreenshotRecorder.bitrate(width: 40, height: 40, frameRate: 30), 2_000_000,
                       "小区域也要有个下限，不然画质糊得没法看")
        XCTAssertEqual(ScreenshotRecorder.bitrate(width: 8000, height: 4000, frameRate: 30), 40_000_000,
                       "上限钉死，防止一次误操作把盘写满")
    }

    // MARK: - 录屏：编码器真链路（离线可跑）
    //
    // `AVCaptureScreenInput` 要屏幕录制授权（测试进程永远拿不到），但 `AVAssetWriter`
    // 什么授权都不要，而用户报的两个症状 —— 时长不走、停止后没有视频 —— 全在 writer
    // 这一侧。所以这里绕开采集，直接 `beginFile` + 喂合成帧，把 `add(input)`、adaptor
    // 的建立时机、时间戳、收带这四件事在 `swift test` 里钉死。判据一律取自盘上那个文件
    // 读回来的样子，不取自 recorder 自己的属性。

    /// 喂 1.5 秒合成帧就该得到一段真能读回来的 1.5 秒 MP4。
    /// 修复前这一条会给出 0 字节的空文件：writer 没挂上轨道，一帧都进不去。
    func testRecorderEncodesSyntheticFramesIntoAPlayableVideo() throws {
        let url = try temporaryVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = ScreenshotRecorder()
        recorder.beginFile(at: url)

        let appended = feed(recorder, frames: 45, width: 320, height: 240)
        XCTAssertEqual(appended, 45, "按真节奏喂就该一帧都不被拒")

        let outcome = try stopAndWait(recorder)
        guard case .saved(let file, let seconds) = outcome else {
            return XCTFail("该报成片，实际是 \(describe(outcome))")
        }
        XCTAssertEqual(file, url)
        XCTAssertEqual(seconds, 1.47, accuracy: 0.1, "读数就是最后一帧的时刻")
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 1_000, "0 字节的 mp4 等于没录")

        let read = try readBack(url)
        XCTAssertEqual(read.duration, 1.5, accuracy: 0.25, "文件读回来的时长")
        XCTAssertGreaterThanOrEqual(read.frames, 40, "帧数对不上就是时间戳被丢掉了")
        XCTAssertEqual(read.size, CGSize(width: 320, height: 240))
    }

    /// 胶囊上的读数一秒跳一次、而且真在往前走 —— 用户报的「录制时间没有在走」就是这条。
    /// 逐帧刷会让数字抖成一片，一秒不刷就永远停在 0:00。
    func testRecorderTicksOncePerSecondAndTheClockAdvances() throws {
        let url = try temporaryVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = ScreenshotRecorder()
        var ticks: [TimeInterval] = []
        recorder.onTick = { ticks.append($0) }
        recorder.beginFile(at: url)

        feed(recorder, frames: 45, width: 160, height: 120)
        _ = try stopAndWait(recorder)
        // onTick 是抛到主线程的，收带那一下已经摇过 runloop，这里再摇一圈兜住尾巴。
        pump(until: { ticks.count >= 2 }, timeout: 2)

        XCTAssertEqual(ticks.map { Int($0) }, [0, 1], "1.5 秒的画面就该报两次，一秒一次")
        XCTAssertEqual(ticks.last ?? -1, 1.0, accuracy: 0.05)
    }

    /// 一帧都没进片时不许在盘上留东西：修复前每次失败都在下载目录里攒一个打不开的
    /// 0 字节 mp4，用户以为录上了。
    func testStoppingWithNothingRecordedLeavesNoFileBehind() throws {
        let url = try temporaryVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = ScreenshotRecorder()
        recorder.beginFile(at: url)

        let outcome = try stopAndWait(recorder)
        guard case .empty = outcome else {
            return XCTFail("没录到东西该报 .empty，实际是 \(describe(outcome))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "半成品文件必须一起收掉")
    }

    /// writer 起不来（目录不存在、盘满）要立刻说清楚，而不是安静地把帧全丢掉：
    /// 采集那一侧收到 `.broken` 才会停会话、收浮层、把原因报给用户。
    func testIngestReportsBrokenWhenTheFileCannotBeCreated() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstroke-no-such-dir-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("out.mp4")
        let recorder = ScreenshotRecorder()
        recorder.beginFile(at: missing)

        let buffer = try XCTUnwrap(frame(index: 0, width: 64, height: 64))
        XCTAssertEqual(recorder.ingest(buffer, at: Self.pts(frame: 0)), .broken)
        // 废了之后还得能收场，不能把停止那一下吊死。
        guard case .empty = try stopAndWait(recorder) else {
            return XCTFail("编码器废掉后停止该报 .empty")
        }
    }

    /// 出帧是奇数边长时走中转缓冲削成偶数：H.264 不吃奇数，硬喂会让 `startWriting`
    /// 直接失败（那类 -11800）。
    func testOddSizedFramesGetNormalizedToEvenDimensions() throws {
        let url = try temporaryVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = ScreenshotRecorder()
        recorder.beginFile(at: url)

        let appended = feed(recorder, frames: 15, width: 321, height: 241)
        XCTAssertEqual(appended, 15)

        guard case .saved = try stopAndWait(recorder) else {
            return XCTFail("奇数边长也该出片")
        }
        let read = try readBack(url)
        XCTAssertEqual(read.size, CGSize(width: 320, height: 240))
        XCTAssertEqual(read.duration, 0.5, accuracy: 0.2)
    }

    /// 控制器撒手（`self.recorder = nil`）之后，收带照样得走完、文件照样得能播。
    ///
    /// 这一条是用户报的那个现场：录了 20 秒、点停止、盘上是个 977KB 却打不开的 mp4
    /// （只有 mdat 没有 moov，AVAsset 报 -11829 Cannot Open），胶囊也没收 ——
    /// completion 根本没回来。`setSampleBufferDelegate` 不持有代理，收带又是异步的，
    /// 所以「唯一强引用在收带期间断掉」这件事在别的测试里全被掩盖了：它们都把 recorder
    /// 攥在手里到最后一行。这里必须让它只剩一根引用，然后放开。
    func testRecorderFinishesTheFileAfterItsOwnerLetsGo() throws {
        let url = try temporaryVideoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var outcome: ScreenshotRecordOutcome?
        var owner: ScreenshotRecorder? = ScreenshotRecorder()
        do {
            let recorder = try XCTUnwrap(owner)
            recorder.beginFile(at: url)
            feed(recorder, frames: 15, width: 160, height: 120)
            recorder.stop { outcome = $0 }
        }
        owner = nil                       // ← 控制器 `finishLive()` 做的就是这一下

        XCTAssertTrue(pump(until: { outcome != nil }, timeout: 20), "撒手之后收带回调还是得回来")
        guard case .saved = try XCTUnwrap(outcome) else {
            return XCTFail("该报成片，实际是 \(describe(outcome!))")
        }
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 1_000, "0 字节的 mp4 等于没录")
        let read = try readBack(url)
        XCTAssertEqual(read.duration, 0.5, accuracy: 0.2, "读得到时长才说明 moov 写进去了")
        XCTAssertGreaterThanOrEqual(read.frames, 10, "帧数对不上就是收带被掐断了")
    }

    // MARK: 录屏辅助

    /// 采集给的时间戳是 mach 绝对时间（几万秒量级），所以基线也取一个大数：
    /// 用小数字喂帧的话，「忘记用原始 PTS」这个缺陷就测不出来。
    private static let ptsBase = CMTime(value: 123_456_789, timescale: 1000)

    static func pts(frame index: Int) -> CMTime {
        CMTimeAdd(ptsBase, CMTime(value: Int64(index), timescale: 30))
    }

    /// 按真节奏喂帧并数出真进了片的那几帧。
    ///
    /// 必须真等：`expectsMediaDataInRealTime` 会挡住比实时更快的数据（实测 90 帧一口气
    /// 灌进去只收下 10 帧，其余全被 `isReadyForMoreMediaData == false` 退回）。这一等
    /// 顺带把「采集按 30fps 出帧」这个前提也一起跑了。
    @discardableResult
    private func feed(_ recorder: ScreenshotRecorder, frames: Int, width: Int, height: Int) -> Int {
        var appended = 0
        for index in 0..<frames {
            guard let buffer = frame(index: index, width: width, height: height) else {
                XCTFail("合成不出第 \(index) 帧")
                return appended
            }
            usleep(33_333)
            if case .appended = recorder.ingest(buffer, at: Self.pts(frame: index)) { appended += 1 }
        }
        return appended
    }

    private func temporaryVideoURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstroke-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("out.mp4")
    }

    /// 一帧合成画面：底色 + 一条随帧号走的竖条（有变化编码器才有东西可编）。
    private func frame(index: Int, width: Int, height: Int) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes, &made) == kCVReturnSuccess,
              let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let gray = UInt8(40 + (index % 20) * 8)
        let bar = (index * 7) % max(width - 24, 1)
        for y in 0..<height {
            memset(base + y * row, Int32(gray), row)
            memset(base + y * row + bar * 4, 0xFF, 24 * 4)
        }
        return buffer
    }

    private func stopAndWait(_ recorder: ScreenshotRecorder) throws -> ScreenshotRecordOutcome {
        var outcome: ScreenshotRecordOutcome?
        recorder.stop { outcome = $0 }
        XCTAssertTrue(pump(until: { outcome != nil }, timeout: 20), "收带没回结局")
        return try XCTUnwrap(outcome)
    }

    private func readBack(_ url: URL) throws -> (frames: Int, duration: TimeInterval, size: CGSize) {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first, "文件里没有视频轨")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "读不回来：\(String(describing: reader.error))")
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        return (frames, asset.duration.seconds, track.naturalSize)
    }

    private func describe(_ outcome: ScreenshotRecordOutcome) -> String {
        switch outcome {
        case .saved(let url, let seconds): return "成片 \(url.lastPathComponent) \(seconds) 秒"
        case .empty: return "空（一帧都没录到）"
        case .failed(let reason): return "失败：\(reason)"
        }
    }

    // MARK: - 落盘

    /// 录像和截图共用偏好里那个目录；撞名往后缀找空位，不覆盖用户上一段。
    func testVideoURLSharesTheSaveDirectoryAndAvoidsCollisions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstroke-video-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = ScreenshotSettings(autoSave: true, directory: directory, snapToWindows: false,
                                          magnifier: false, magnification: 8, defaultTool: nil)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = settings.videoURL(date: date)
        XCTAssertEqual(first.pathExtension, "mp4")
        XCTAssertEqual(first.deletingLastPathComponent(), directory)
        try Data([0x00]).write(to: first)
        let second = settings.videoURL(date: date)
        XCTAssertNotEqual(second, first, "同名就得往后缀找空位：\(second)")
        // 后缀加在 `.mp4` **前面**：名字里本来就有点（时间戳 `22.13.20`），
        // 所以这里只比整串文件名，不碰 pathExtension 那套切法。
        XCTAssertEqual(second.lastPathComponent,
                       first.deletingPathExtension().lastPathComponent + " 2.mp4")
    }

    // MARK: - 辅助

    private var exportDirectory: URL {
        URL(fileURLWithPath: "/tmp/macstroke-screenshot-check", isDirectory: true)
    }

    private func overlay(size: NSSize = NSSize(width: 1440, height: 900)) throws -> ScreenshotSelectionView {
        let shot = try XCTUnwrap(ScreenshotFrame(image: pattern(size), pointSize: size))
        let view = ScreenshotSelectionView(shot: shot)
        ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: size)).contentView = view
        return view
    }

    /// 拖出一个选区（走真实那三步：按下、拖、抬起）。
    private func drag(in view: ScreenshotSelectionView, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
        view.pointerDown(CGPoint(x: from.0, y: from.1), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: to.0, y: to.1))
        view.pointerReleased()
    }

    private func pattern(_ size: NSSize) throws -> CGImage {
        try XCTUnwrap(QuadrantPattern.image(width: Int(size.width), height: Int(size.height)),
                      "拿不到 \(size) 的测试图案")
    }

    // MARK: 条纹纸

    /// 一帧「条纹纸」：第 r 行（全局行号 = `top` + r）的颜色只由行号决定。
    private func stripes(top: Int, width: Int = 40, height: Int = 240) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let index = (top + row) % 256
            for column in 0..<width {
                let at = (row * width + column) * 4
                bytes[at] = UInt8((index * 97) % 256)
                bytes[at + 1] = UInt8((index * 31) % 256)
                bytes[at + 2] = UInt8((index * 53) % 256)
                bytes[at + 3] = 255
            }
        }
        // 缓冲第 0 行就是画面顶行（实测，见 `ScreenshotRowPrint.capture` 那条注释），
        // 所以这里按行号正着填，和 `cropping(to: y=0)` 的读法一致。
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context!.makeImage()!
    }

    private func rows(of image: CGImage) throws -> ScreenshotRowPrint {
        try XCTUnwrap(ScreenshotRowPrint.capture(image))
    }

    // MARK: 跑在内存里的长截图

    /// 一整套接缝都装好的会话：条纹纸当画面，注入只改纸的滚动位置。
    ///
    /// 纸的倍率是 1（像素尺寸 == 点尺寸），所以「注入多少点」就是「往下走多少行」，
    /// 断言能直接拿全局行号对。`limit` 是那块内容的**底**：滚到底之后画面不再动，
    /// 循环就该认出「到头了」；`limit: 0` 模拟「这块内容压根不吃滚轮」。`startTop` 让
    /// 这一场从中间或底部起手 —— 「框住的这块本来就停在底部」就是这么摆出来的。
    private func paperSession(step: Int, limit: Int, maxScreens: Int = 20,
                              width: Int = 40, height: Int = 240,
                              startTop: Int = 0) throws -> PaperSession {
        let screen = try XCTUnwrap(ScreenshotGrabber.targetScreen(), "这台机器没接显示器")
        let session = PaperSession(screen: screen, width: width, height: height,
                                   limit: limit, maxScreens: maxScreens, startTop: startTop)
        session.capture.pointsPerStep = CGFloat(step)
        session.capture.frameSource = { [weak session, weak self] in
            guard let session, let self else { return nil }
            return ScreenshotFrame(image: self.stripes(top: session.top, width: width, height: height),
                                   pointSize: NSSize(width: width, height: height))
        }
        session.capture.scrollInjector = { session.scroll(points: $0) }
        session.capture.onOutcome = { session.outcome = $0 }
        session.capture.onReadout = { session.readouts.append($0) }
        return session
    }

    /// 摇主线程 runloop 直到 `done` 为真，超时返回 false。
    /// 这一圈是 `Timer` 驱动的，测试必须真等它转，不能绕过节奏自己调一次内部方法。
    @discardableResult
    private func pump(until done: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() >= deadline { return false }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private func failWith(_ outcome: ScreenshotScrollOutcome, _ expect: String) {
        switch outcome {
        case .failed(let reason): XCTFail("\(expect)，实际报了失败：\(reason)")
        case .composed(_, let appended): XCTFail("\(expect)，实际接了 \(appended) 段")
        }
    }

    private func redOf(_ globalRow: Int) -> CGFloat {
        CGFloat((globalRow % 256) * 97 % 256)
    }

    /// 读出某一行第 0 列的红色分量（每行内部是纯色）。
    private func gray(_ image: CGImage, row: Int) -> CGFloat {
        guard let cut = image.cropping(to: CGRect(x: 0, y: row, width: 1, height: 1)) else { return -1 }
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context!.interpolationQuality = .none
        context!.draw(cut, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGFloat(bytes[0])
    }

    // MARK: 条子渲染

    /// 一次模式条渲染：整块遮罩画进位图，再按格子取样。
    private struct BarRender {
        let bitmap: NSBitmapImageRep
        let bar: NSRect
        let cells: [ScreenshotMode: NSRect]
        /// 条子底衬（上沿那 5pt 留白：格子高 24、条子高 34，那里只有底衬没有字）。
        let body: CGFloat
        /// 第一格内部逐点取样（横向每半像素取一列，纵向两行）。
        let cellPixels: [CGFloat]
        /// 整条上离底 0.3 以上的像素数：字还在不在。
        let ink: Int

        func blueShare(of mode: ScreenshotMode) -> CGFloat {
            guard let cell = cells[mode] else { return 0 }
            var blue = 0
            var total = 0
            var x = Int(cell.minX) + 1
            while x < Int(cell.maxX) {
                var y = Int(cell.minY) + 1
                while y < Int(cell.maxY) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                        total += 1
                        if color.blueComponent > color.redComponent + 0.15,
                           color.blueComponent > color.greenComponent + 0.15 { blue += 1 }
                    }
                    y += 1
                }
                x += 1
            }
            guard total > 0 else { return 0 }
            return CGFloat(blue) / CGFloat(total)
        }
    }

    private func renderModeBar(_ appearance: NSAppearance.Name, name: String,
                               mode: ScreenshotMode = .still) throws -> BarRender {
        let view = try overlay(size: NSSize(width: 1440, height: 400))
        view.appearance = NSAppearance(named: appearance)
        view.showModeBar()
        if mode != .still { view.modeBar?.onPick?(mode) }
        let bar = try XCTUnwrap(view.modeBar)
        view.needsDisplay = true
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw BarFailure.noBitmap
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try export(bitmap, name: name)

        var cells: [ScreenshotMode: NSRect] = [:]
        for entry in ScreenshotMode.allCases {
            cells[entry] = bar.rect(for: entry, atBarOrigin: bar.frame.origin)
        }
        let body = luminance(try XCTUnwrap(color(in: bitmap, x: Int(bar.frame.midX),
                                                 y: Int(bar.frame.minY) + 2)))
        var pixels: [CGFloat] = []
        var ink = 0
        for entry in ScreenshotMode.allCases {
            guard let cell = cells[entry] else { continue }
            var x = Int(cell.minX) + 1
            while x < Int(cell.maxX) {
                var y = Int(cell.minY) + 1
                while y < Int(cell.maxY) {
                    let value = color(in: bitmap, x: x, y: y).map { luminance($0) }
                    if let value {
                        if abs(value - body) > 0.3 { ink += 1 }
                        if entry == .still { pixels.append(value) }
                    }
                    y += 1
                }
                x += 1
            }
        }
        XCTAssertFalse(pixels.isEmpty, "第一格取不到样本，两档对比就成了空转")
        XCTAssertGreaterThan(ink, 0, "格子上一个和条子底色不同的像素都没有，选中态无从对比")
        return BarRender(bitmap: bitmap, bar: bar.frame, cells: cells, body: body,
                         cellPixels: pixels, ink: ink)
    }

    private enum BarFailure: Error { case noBitmap }

    private func export(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let url = exportDirectory.appendingPathComponent(name)
        try data.write(to: url)
        NSLog("%@", "[ScreenshotTests] 渲染结果：\(url.path)")
    }

    private func color(in bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }
}

/// 一场跑在内存条纹纸上的长截图：会话本体是生产代码里那个，外围换成接缝。
/// 凭证（滚了几次、报过哪些读数、最后交出什么）都攒在这里，断言只读这些。
private final class PaperSession {
    let capture: ScreenshotScrollCapture
    /// 视口顶端的全局行号。
    var top = 0
    /// 循环真的注入了几次。
    var injections = 0
    var outcome: ScreenshotScrollOutcome?
    var readouts: [String] = []
    private let limit: Int

    init(screen: NSScreen, width: Int, height: Int, limit: Int, maxScreens: Int, startTop: Int = 0) {
        self.limit = limit
        self.top = startTop
        capture = ScreenshotScrollCapture(screen: screen,
                                          region: CGRect(x: 0, y: 0, width: width, height: height))
        capture.maxScreens = maxScreens
    }

    /// 纸的响应：往下走「注入的点数」那么多行（倍率 1，负数就是往上），两头都不越界。
    func scroll(points: CGFloat) {
        injections += 1
        top = max(0, min(limit, top + Int(points)))
    }
}
