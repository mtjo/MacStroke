//
//  ScreenshotRenderTests.swift
//
//  离屏渲染取证，不靠截屏也不靠枚举窗口：把视图画进一张 bitmap 再逐点验。
//
//  三块关注点：
//  1. **选区内一点遮罩都没有**。判据取自底图自己（同一位置的原始像素），不取自遮罩
//     的某个属性：亮区必须和底图对得上，暗区必须明显比底图暗。用户报的「选中的那块
//     也蒙了层灰」正好是这条能抓住的。
//  2. 底图在 flipped 视图里必须是正的（NSImage 的 draw(in:) 方向由视图 flipped
//     决定，写错就是整屏倒过来）。
//  3. 编辑态里注解真的画在选区内、漏出选区的部分被钳掉、注解条浮在下沿外侧且有选中态。
//
//  每张图都顺手导出到 /tmp，肉眼再核一遍方向和对齐。
//

import AppKit
import XCTest

@testable import Screenshot

final class ScreenshotRenderTests: XCTestCase {
    private var exportDirectory: URL {
        URL(fileURLWithPath: "/tmp/macstroke-screenshot-check", isDirectory: true)
    }

    private enum RenderFailure: Error {
        case noBitmap, noPNGData, noPattern
    }

    // MARK: - 遮罩

    func testSelectionRevealsUprightBackdrop() throws {
        let scene = try overlayScene(selection: CGRect(x: 400, y: 0, width: 400, height: 250))
        let bitmap = try render(scene.view, name: "selection.png")

        // 选区盖住图案的右上象限（视图 y 从上往下 = 图像 y 从上往下）。
        let revealed = try XCTUnwrap(color(in: bitmap, x: 600, y: 100))
        XCTAssertTrue(QuadrantPattern.isGreen(revealed),
                      "选区内应是原图右上象限的绿色；拿到蓝色说明底图被画倒了")
        // 选区外（左上象限）还是那块红，但被压暗。压暗后红分量只剩 0.45 倍，
        // 所以这里只比「哪个通道占优」，不再拿绝对阈值认颜色。
        let dimmed = try XCTUnwrap(color(in: bitmap, x: 200, y: 100))
        XCTAssertGreaterThan(dimmed.redComponent, max(dimmed.greenComponent, dimmed.blueComponent),
                             "选区外应仍是红色的暗版，而不是换了内容")
        XCTAssertLessThan(dimmed.redComponent, 0.9, "选区外必须被压暗")
    }

    /// 选区内 = 底图原亮度，选区外 = 底图被压暗。
    /// 判据取自一张「只有底图、没有任何遮罩」的参照渲染，不取自遮罩自己的属性：
    /// 用户报的「选中的那块也蒙了层灰」正是这条能抓住的，而拿 CGImage 原像素比会
    /// 被色彩管理带偏（实测纯红在参照图里是 1.00/0.15/0.14，比值天生不等于 1）。
    func testNoMaskInsideTheSelectedRegion() throws {
        let scene = try overlayScene(selection: CGRect(x: 150, y: 60, width: 500, height: 380))
        let bitmap = try render(scene.view, name: "selection.png")

        // 含紧贴四边内侧的几处 —— 带子要是少围了一条，最先在这里露出来。
        for (x, y) in [(400, 250), (160, 70), (640, 70), (160, 430), (640, 430), (300, 200)] {
            XCTAssertEqual(try brightness(in: bitmap, scene: scene, x: x, y: y), 1, accuracy: 0.02,
                           "选区内 (\(x),\(y)) 该是底图原亮度，一层遮罩都不该有")
        }
        // 外面同一批位置必须暗下去，否则上面那组断言就成了「压根没压暗」。
        for (x, y) in [(60, 60), (740, 60), (60, 460), (400, 470)] {
            XCTAssertLessThan(try brightness(in: bitmap, scene: scene, x: x, y: y), 0.65,
                              "选区外 (\(x),\(y)) 必须压暗，不然亮/暗根本没有区分")
        }
    }

    func testFullScreenIsDimmedBeforeDragging() throws {
        let scene = try overlayScene(selection: .zero)
        let bitmap = try render(scene.view, name: "hint.png")
        var probed = 0
        for x in stride(from: 20, through: 780, by: 120) {
            // 0.45 = 压暗那一档（alpha 0.55 的黑）。等于 1 就是压根没压暗。
            XCTAssertEqual(try brightness(in: bitmap, scene: scene, x: x, y: 100), 0.45, accuracy: 0.03,
                           "还没拖选区时整屏都该压暗")
            probed += 1
        }
        XCTAssertEqual(probed, 7)
    }

    /// 吸附预览：鼠标停在哪个窗上，那块就该是**原样亮度**，其余压暗。
    /// 这就是「截图区域不该看起来半透明」的取证 —— 如果预览区也跟着暗，用户根本
    /// 分不清选中了哪块。
    func testSnappedWindowIsPreviewedAtFullBrightness() throws {
        let scene = try overlayScene(selection: .zero)
        scene.view.windows = [CGRect(x: 400, y: 0, width: 400, height: 250)]
        scene.view.pointerMoved(CGPoint(x: 600, y: 100))
        let bitmap = try render(scene.view, name: "hover.png")

        let bright = try XCTUnwrap(color(in: bitmap, x: 600, y: 100))
        XCTAssertTrue(QuadrantPattern.isGreen(bright), "吸附到的那块该透出原图本色")
        XCTAssertEqual(try brightness(in: bitmap, scene: scene, x: 600, y: 100), 1, accuracy: 0.02,
                       "吸附预览区不该有一层遮罩")
        XCTAssertLessThan(try brightness(in: bitmap, scene: scene, x: 200, y: 100), 0.65,
                          "预览区之外仍要压暗")
    }

    /// 落到桌面上的吸附 = 整块屏原亮度：全屏截图那条路不能还留着暗边。
    func testWholeScreenHoverIsNotDimmedAtAll() throws {
        let scene = try overlayScene(selection: .zero)
        scene.view.windows = [CGRect(x: 400, y: 0, width: 400, height: 250)]
        scene.view.pointerMoved(CGPoint(x: 20, y: 480))
        XCTAssertEqual(scene.view.hover, scene.view.bounds, "桌面上没有普通窗，就该吸整块屏")
        let bitmap = try render(scene.view, name: "hover-full.png")

        for (x, y) in [(200, 100), (600, 100), (200, 400), (600, 400), (400, 20)] {
            XCTAssertEqual(try brightness(in: bitmap, scene: scene, x: x, y: y), 1, accuracy: 0.02,
                           "整屏吸附时 (\(x),\(y)) 不该有任何压暗")
        }
    }

    // MARK: - 编辑态

    /// 就地编辑的整层取证：注解读在选区里、漏出选区的部分被钳掉、注解条浮在选区下沿
    /// 外侧且选中态看得出来。
    func testEditingShowsAnnotationsAndToolbarBelowSelection() throws {
        let selection = CGRect(x: 100, y: 60, width: 400, height: 300)
        let active = try overlayScene(selection: selection, editing: true)
        active.view.annotations = [
            ScreenshotAnnotation(tool: .rect, color: .systemBlue, lineWidth: 6,
                                 start: CGPoint(x: 120, y: 100), end: CGPoint(x: 320, y: 260)),
            // 右半边拖到选区外（x 698 > 500）：这条只能被裁进选区里那一段。
            ScreenshotAnnotation(tool: .rect, color: .systemBlue, lineWidth: 6,
                                 start: CGPoint(x: 150, y: 120), end: CGPoint(x: 700, y: 300)),
        ]
        // 走条子的点击回调：那才是真链路，同时更新 tool 和格子的选中态高亮。
        active.view.toolbar?.onTool?(.rect)
        let bitmap = try render(active.view, name: "editing.png")

        // 第一条的上边描边：路径中心在 y = 100 + lineWidth/2。这里在左上象限（红）上，
        // 蓝笔不透明压过去，红通道必须塌下去。
        let stroke = try XCTUnwrap(color(in: bitmap, x: 200, y: 103))
        XCTAssertGreaterThan(stroke.blueComponent, 0.8, "注解要画在选区里的底图上")
        XCTAssertLessThan(stroke.redComponent, 0.3, "纯蓝描边不该还带着底下的红")

        // 第二条的右边在选区外（右上象限 = 绿，压暗后发暗）：漏出去就该看得见。
        let clipped = try XCTUnwrap(color(in: bitmap, x: 698, y: 200))
        XCTAssertGreaterThan(clipped.greenComponent, clipped.blueComponent,
                             "选区外的注解必须被钳掉，否则成品里会多出选区外的半条线")

        // 把手：白底方块压在红底上，四条边和四个角各一个，用户靠它知道这块还能改。
        let handle = try XCTUnwrap(color(in: bitmap, x: 100, y: 210))
        XCTAssertGreaterThan(min(handle.redComponent, min(handle.greenComponent, handle.blueComponent)), 0.8,
                             "选区左边中点该有一个白色把手方块")

        // 注解条位置 + 选中态：选中那一格铺系统蓝，没选中的格子是中性面板底。
        // 取的是格子里图标之外的一点（下方留白），否则比的是白色图标本身。
        let idle = try overlayScene(selection: selection, editing: true)
        let idleBitmap = try render(idle.view, name: "editing-idle.png")
        let bar = try XCTUnwrap(idle.view.toolbar, "进编辑态就该有注解条")
        XCTAssertEqual(bar.frame.minY, selection.maxY + 8, "注解条浮在选区下沿外侧")
        let probe = firstToolCellProbe(bar: bar)
        let activePixel = try XCTUnwrap(color(in: bitmap, x: probe.x, y: probe.y))
        let idlePixel = try XCTUnwrap(color(in: idleBitmap, x: probe.x, y: probe.y))
        XCTAssertGreaterThan(activePixel.blueComponent - activePixel.redComponent, 0.3,
                             "选中工具时那一格要铺系统蓝，否则用户看不出当前用了哪个工具")
        XCTAssertLessThan(abs(idlePixel.blueComponent - idlePixel.redComponent), 0.12,
                          "没选中的格子该是中性底：跟着发蓝就成了「一直选中」")
    }

    /// 用户指定的参照物是 QQ 那条注解条：底色是深色胶囊（不跟着系统外观发亮），
    /// 两个出口各带自己的语义色 —— 红✕、绿✓。
    ///
    /// 判据取「色相占优的像素数」而不是「这一点是什么色」：图标是线性的，格子里一大半
    /// 还是条子的底色，照单点去领会随笔画到哪一笔而飘。
    func testBarIsADarkCapsuleWithColoredExits() throws {
        let selection = CGRect(x: 100, y: 60, width: 400, height: 300)
        let scene = try overlayScene(selection: selection, editing: true)
        let bitmap = try render(scene.view, name: "bar-qq.png")
        let bar = try XCTUnwrap(scene.view.toolbar)

        // 最后一个格子右边那点留白：那里只有条子的底，没有图标。
        let fill = try XCTUnwrap(color(in: bitmap, x: Int(bar.frame.maxX) - 3, y: Int(bar.frame.midY)))
        XCTAssertLessThan(sum(fill), 1.2, "条子该是深色胶囊底，不是跟着系统发亮的浅底：\(fill)")

        // 出口是最后三格（保存 / ✕ / ✓），顺序由 testBarFollowsTheQQOrder 锁住。
        let exits = bar.actionableRects.suffix(3)
            .map { $0.offsetBy(dx: bar.frame.minX, dy: bar.frame.minY) }
        XCTAssertEqual(exits.count, 3)
        // 「哪个色相占优」而不是「是不是纯红/纯绿」：图标是半透明底上的细线，边缘全在
        // 和条子的深底混色，按绝对阈值认会把一整枚图标漏掉。
        let isRedGlyph: (NSColor) -> Bool = { $0.redComponent > $0.greenComponent + 0.25
            && $0.redComponent > $0.blueComponent + 0.25 }
        let isGreenGlyph: (NSColor) -> Bool = { $0.greenComponent > $0.redComponent + 0.25
            && $0.greenComponent > $0.blueComponent + 0.25 }
        XCTAssertGreaterThanOrEqual(count(in: bitmap, in: exits[1], isRedGlyph), 8,
                                    "✕ 没烫成红色就成了普通白图标")
        XCTAssertGreaterThanOrEqual(count(in: bitmap, in: exits[2], isGreenGlyph), 8,
                                    "✓ 没烫成绿色就成了普通白图标")
        // 反向对照：保存那一格是白图标，里面一格红/绿都不该有。
        XCTAssertEqual(count(in: bitmap, in: exits[0]) { isRedGlyph($0) || isGreenGlyph($0) },
                       0, "普通出口跟着发了色，上面两条断言就成了空转")
    }

    /// 一个矩形里有多少个点符合判据（往里缩 2pt：格子边上那圈是条子的底和描边）。
    private func count(in bitmap: NSBitmapImageRep, in rect: NSRect,
                       _ isMatch: (NSColor) -> Bool) -> Int {
        var hit = 0
        for x in stride(from: Int(rect.minX) + 2, to: max(Int(rect.minX) + 2, Int(rect.maxX) - 2), by: 1) {
            for y in stride(from: Int(rect.minY) + 2, to: max(Int(rect.minY) + 2, Int(rect.maxY) - 2), by: 1) {
                if let color = color(in: bitmap, x: x, y: y), isMatch(color) { hit += 1 }
            }
        }
        return hit
    }

    /// 打码那一格是「两档灰交替的 4x4 像素块」，不是笔画图标 —— 用户嫌系统那枚
    /// `mosaic`（几块不等大的板子拼的方框）读起来像分栏布局，不像打码。
    ///
    /// 判据取「自成一片的半透明像素数」。笔画图标只有 1.5pt 粗的线，线上每个灰像素都
    /// 紧挨着亮像素（抗锯齿毛边），5x5 邻域里必然找得到亮点；棋盘格里的暗格是 4pt 见方
    /// 的一块，中心周围两圈全是同档灰。实测：矩形/椭圆/箭头这一档恒为 0，打码格 24。
    func testMosaicCellIsATwoTonePixelBlock() throws {
        let selection = CGRect(x: 100, y: 60, width: 400, height: 300)
        let scene = try overlayScene(selection: selection, editing: true)
        let bitmap = try render(scene.view, name: "bar-mosaic.png")
        let bar = try XCTUnwrap(scene.view.toolbar)

        let lum: (Int, Int) -> CGFloat = { [self] x, y in
            guard let c = color(in: bitmap, x: x, y: y) else { return 0 }
            return sum(c) / 3
        }
        func tones(of index: Int) -> (solid: Int, dim: Int, loneDim: Int) {
            let cell = bar.actionableRects[index].offsetBy(dx: bar.frame.minX, dy: bar.frame.minY)
            var solid = 0, dim = 0, loneDim = 0
            for x in Int(cell.minX)...Int(cell.maxX - 1) {
                for y in Int(cell.minY)...Int(cell.maxY - 1) {
                    let l = lum(x, y)
                    if l > 0.6 { solid += 1; continue }
                    guard l > 0.28 else { continue }
                    dim += 1
                    var nearSolid = false
                    for dx in -2...2 where !nearSolid {
                        for dy in -2...2 where lum(x + dx, y + dy) > 0.6 { nearSolid = true; break }
                    }
                    if !nearSolid { loneDim += 1 }
                }
            }
            return (solid, dim, loneDim)
        }

        let mosaic = tones(of: 6)
        XCTAssertGreaterThanOrEqual(mosaic.loneDim, 12,
                                    "半透明那一档要自成一块，不能只是笔画边的毛刺：\(mosaic)")
        XCTAssertGreaterThanOrEqual(mosaic.dim, 150, "暗格要有面积：\(mosaic)")
        XCTAssertGreaterThanOrEqual(mosaic.solid, 100, "实心格也要有面积，只剩一档就成了实心方块：\(mosaic)")
        // 反向对照：旁边三格是笔画图标，同一条判据必须是 0 —— 否则上面三条谁都能满足。
        for index in [0, 1, 2] {
            XCTAssertEqual(tones(of: index).loneDim, 0, "第 \(index) 格是笔画图标，不该有一片同档灰")
        }
    }

    /// 悬停在某一格上：那一格正上方冒出气泡，深底 + 白字。
    ///
    /// 判据是「同一块地方悬停前后差多少」，不是「这一点是什么色」：气泡底下本来就是亮色
    /// 底图（这里挑下面那块蓝，亮度约 0.33，既不到气泡的深底档也不到白字档）。选区特意
    /// 压到屏底 —— 条子放不下会翻进选区内侧，气泡于是整个落在亮区里，不用跟选区外那条
    /// 压暗带比灰度（压暗底 0.15 和气泡深底 0.14 分不开）。
    func testHoverOverBarCellPopsATipBubble() throws {
        let selection = CGRect(x: 100, y: 300, width: 400, height: 180)
        let scene = try overlayScene(selection: selection, editing: true)
        let view = scene.view
        let bar = try XCTUnwrap(view.toolbar)
        let cell = try XCTUnwrap(bar.actionableRects[6].offsetBy(dx: bar.frame.minX, dy: bar.frame.minY))

        view.pointerMoved(CGPoint(x: cell.midX, y: cell.midY))
        let tip = try XCTUnwrap(view.tipView, "悬停在格子上就该有提示")
        XCTAssertFalse(tip.isHidden)
        XCTAssertEqual(tip.frame.maxY, cell.minY - ScreenshotTipView.gap, accuracy: 0.5,
                       "气泡摆在格子正上方（视图 flipped，上方就是更小的 y）")
        XCTAssertEqual(tip.frame.midX, cell.midX, accuracy: 0.5, "横向对着那一格居中")
        XCTAssertEqual(tip.frame.height, ScreenshotTipView.height)
        XCTAssertTrue(selection.contains(tip.frame), "整只气泡要在亮区里，下面的判据才比得开")

        let shown = try render(view, name: "tip-shown.png")
        view.pointerMoved(CGPoint(x: 20, y: 20))
        let hidden = try render(view, name: "tip-hidden.png")

        let dark = count(in: shown, in: tip.frame) { sum($0) / 3 < 0.25 }
        let light = count(in: shown, in: tip.frame) { sum($0) / 3 > 0.75 }
        XCTAssertGreaterThanOrEqual(dark, 1000, "气泡得是那块深底，不是只有一圈边：\(dark)")
        XCTAssertGreaterThanOrEqual(light, 100, "深底上得印得出白字：\(light)")
        let control = count(in: hidden, in: tip.frame) { abs(sum($0) / 3 - 0.33) > 0.2 }
        XCTAssertEqual(control, 0, "反向对照：没悬停时这块蓝底两档都不该有，否则上面两条是空转")
    }

    /// 选中打码那一格之后：整块铺系统蓝，棋盘格转白，但**两档都还在**。
    ///
    /// 两条判据各管一种错：白像素没了 = 图标跟着蓝底糊成一片（深底上「浅色一块」和
    /// 「没选中」差得太少，所以选中态必须翻白）；蓝像素没了 = 整格被涂成实心白块，
    /// 用户就认不出这还是刚才那枚像素格。
    func testMosaicCellTurnsWhiteOnBlueWhenSelected() throws {
        let selection = CGRect(x: 100, y: 60, width: 400, height: 300)
        let scene = try overlayScene(selection: selection, editing: true)
        let bar = try XCTUnwrap(scene.view.toolbar)
        let cell = bar.actionableRects[6].offsetBy(dx: bar.frame.minX, dy: bar.frame.minY)
        scene.view.toolbar?.onTool?(.mosaic)   // 走条子的回调：那才是真链路
        let bitmap = try render(scene.view, name: "bar-mosaic-active.png")

        let isBlue: (NSColor) -> Bool = { $0.blueComponent > 0.6
            && $0.blueComponent > $0.redComponent + 0.25 }
        let isWhite: (NSColor) -> Bool = {
            min($0.redComponent, min($0.greenComponent, $0.blueComponent)) > 0.8
        }
        let blue = count(in: bitmap, in: cell, isBlue)
        let white = count(in: bitmap, in: cell, isWhite)
        XCTAssertGreaterThanOrEqual(blue, 60, "选中格要铺得住蓝底，两档也得都在：\(blue)/\(white)")
        XCTAssertGreaterThanOrEqual(white, 60, "蓝底上棋盘格要转白：\(blue)/\(white)")

        // 反向对照：没选中的同一格一格蓝都不该有，否则「铺蓝」这条谁都能满足。
        let idle = try overlayScene(selection: selection, editing: true)
        let idleBitmap = try render(idle.view, name: "bar-mosaic-idle.png")
        XCTAssertEqual(count(in: idleBitmap, in: cell, isBlue), 0, "没选中也跟着发蓝")
    }

    /// 打码的边框只是**拖动过程中的蓝色辅助线**：跟着这一笔的矩形走，松手就没了。
    ///
    /// 用户要的是「拖的时候看得清这块到哪为止」，但别让它进成品，所以判据分三头：拖动
    /// 时四条边上都得读到那圈蓝；松手后同一块地方一点蓝、一点墨都不许有；这一笔的墨是
    /// 调色板第一档的红，所以「辅助线跟着墨色走」这种改法也会当场露出来。反向对照取
    /// `Scene.bare`（同一块底图、没遮罩的参照渲染），两处恒为 0，量到的蓝才真是辅助线。
    /// 选区落在右上绿象限：绿底上任何非绿都只可能是画上去的。
    func testMosaicGuideFollowsTheDragAndVanishesOnRelease() throws {
        let selection = CGRect(x: 420, y: 40, width: 300, height: 200)
        let scene = try overlayScene(selection: selection, editing: true)
        let view = scene.view
        XCTAssertEqual(view.colorIndex, 0, "这一笔用的是调色板第一档（红）")
        view.toolbar?.onTool?(.mosaic)   // 走条子的回调：那才是真链路
        view.pointerDown(CGPoint(x: 460, y: 80), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 660, y: 200))

        // 逐点扫，不用 `count(in:in:_:)`：那条判据的尺子往里缩 2pt，而辅助线只有 1.5pt
        // 粗，缩一下就正好把线扫没了。
        func pixels(_ rect: CGRect, in bitmap: NSBitmapImageRep,
                    matching isMatch: (NSColor) -> Bool) -> Int {
            var hit = 0
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for y in Int(rect.minY)..<Int(rect.maxY) {
                    if let color = color(in: bitmap, x: x, y: y), isMatch(color) { hit += 1 }
                }
            }
            return hit
        }
        let isGuideBlue: (NSColor) -> Bool = { $0.blueComponent > 0.75
            && $0.greenComponent > 0.35 && $0.greenComponent < 0.85 && $0.redComponent < 0.45 }
        let isInkRed: (NSColor) -> Bool = { $0.redComponent > 0.8 && $0.greenComponent < 0.55
            && $0.blueComponent < 0.5 }
        // 四边各一条 3pt 宽的带，压在矩形边界那一列上（这一笔是 460,80 → 660,200）。
        let edges = [CGRect(x: 459, y: 100, width: 3, height: 60),     // 左边
                     CGRect(x: 520, y: 79, width: 60, height: 3),      // 上边
                     CGRect(x: 659, y: 100, width: 3, height: 60),     // 右边
                     CGRect(x: 520, y: 199, width: 60, height: 3)]     // 下边
        let interior = CGRect(x: 500, y: 110, width: 120, height: 60)
        // 选区内侧一整块：四周各让开 8pt，绕开选区主色描边和八个把手（那也是蓝的）。
        let insideSelection = CGRect(x: 428, y: 48, width: 284, height: 184)

        let dragging = try render(view, name: "mosaic-dragging.png")
        for edge in edges {
            // 实测每条带都满（60 行每一行都压在线上），所以 54 已经是「断一截就红」。
            XCTAssertGreaterThanOrEqual(pixels(edge, in: dragging, matching: isGuideBlue), 54,
                                        "拖动时这一圈辅助线得看得见：\(edge)")
            XCTAssertEqual(pixels(edge, in: dragging, matching: isInkRed), 0,
                           "辅助线是那圈固定的蓝，不跟着这一笔的墨色走：\(edge)")
        }
        XCTAssertEqual(pixels(interior, in: dragging, matching: isGuideBlue), 0,
                       "辅助线是一圈边线，不是把整块涂蓝")
        XCTAssertEqual(pixels(insideSelection, in: scene.bare, matching: isGuideBlue), 0,
                       "反向对照：同一块底图里本来就没有这种蓝，上面那些判据才量得出东西")
        XCTAssertEqual(pixels(insideSelection, in: scene.bare, matching: isInkRed), 0,
                       "反向对照：底图里也没有这种红")

        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 1, "这一笔是要留下来的")
        XCTAssertEqual(view.annotations.first?.tool, .mosaic)
        let committed = try render(view, name: "mosaic-committed.png")
        XCTAssertEqual(pixels(insideSelection, in: committed, matching: isGuideBlue), 0,
                       "松手后辅助线必须整个收掉：它不该进成品图")
        XCTAssertEqual(pixels(insideSelection, in: committed, matching: isInkRed), 0,
                       "松手后的打码块也不该带一圈自己墨色的边框")
    }

    /// 条子和气泡**不跟随系统外观**（用户指定的参照物是 QQ 那条：浅桌面底下也是深底）。
    ///
    /// 配色是一档写死的 sRGB，所以换外观必须逐像素一样。这条判据管的是回退：谁把某处
    /// 改回语义色（windowBackgroundColor 那类），浅/深两套外观就会给出两种墨色，而单看
    /// 一张渲染图发现不了 —— 曾经有一条断言正是这么空转掉的。
    func testBarAndTipIgnoreSystemAppearance() throws {
        let selection = CGRect(x: 100, y: 300, width: 400, height: 180)
        let scene = try overlayScene(selection: selection, editing: true)
        let view = scene.view
        let bar = try XCTUnwrap(view.toolbar)
        let cell = try XCTUnwrap(bar.actionableRects[6].offsetBy(dx: bar.frame.minX, dy: bar.frame.minY))
        view.pointerMoved(CGPoint(x: cell.midX, y: cell.midY))
        let tip = try XCTUnwrap(view.tipView)
        let region = tip.frame.union(bar.frame)

        view.appearance = NSAppearance(named: .aqua)
        let light = try render(view, name: "tip-aqua.png")
        view.appearance = NSAppearance(named: .darkAqua)
        let dark = try render(view, name: "tip-darkaqua.png")

        func worstDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> CGFloat {
            var worst: CGFloat = 0
            for x in stride(from: Int(region.minX) + 2, to: Int(region.maxX) - 2, by: 1) {
                for y in stride(from: Int(region.minY) + 2, to: Int(region.maxY) - 2, by: 1) {
                    guard let left = color(in: a, x: x, y: y), let right = color(in: b, x: x, y: y)
                    else { continue }
                    worst = max(worst, abs(left.redComponent - right.redComponent),
                                abs(left.greenComponent - right.greenComponent),
                                abs(left.blueComponent - right.blueComponent))
                }
            }
            return worst
        }

        let acrossAppearance = worstDifference(light, dark)
        XCTAssertLessThanOrEqual(acrossAppearance, 0.005,
                                 "条子/气泡的配色写死一档，换外观必须逐像素一样：最大偏差 \(acrossAppearance)")
        // 反向对照：这把尺子量得出真差别 —— 同一外观下「有气泡」和「没气泡」必须差得远。
        view.appearance = NSAppearance(named: .aqua)
        view.pointerMoved(CGPoint(x: 20, y: 20))
        let noTip = try render(view, name: "tip-aqua-none.png")
        XCTAssertGreaterThan(worstDifference(light, noTip), 0.3,
                             "两档都量不出差别的话，上面那条就是空转")
    }

    // MARK: - 辅助

    /// 一张场景 = 遮罩视图 + 同一块底图「没遮罩」的参照渲染。
    /// 判据从参照图取，不从被测对象取。
    private struct Scene {
        let view: ScreenshotSelectionView
        let bare: NSBitmapImageRep
    }

    private func overlayScene(selection: CGRect, size: NSSize = NSSize(width: 800, height: 500),
                              editing: Bool = false) throws -> Scene {
        let image = try pattern(width: Int(size.width), height: Int(size.height))
        let frame = try XCTUnwrap(ScreenshotFrame(image: image, pointSize: size))
        let view = ScreenshotSelectionView(shot: frame)
        view.selection = selection
        attach(view, size: size)
        // 注解条要在挂窗之后摆：它的位置是按 bounds 算的。
        if editing { view.enterEditing() }
        // 参照图也要挂窗：没进窗的视图拿到的位图色彩空间和遮罩那张不是一套，
        // 两边比出来的差就成了色彩管理误差（实测饱和色偏 13%，白/黑看不出来）。
        let bare = BackdropOnlyView(shot: frame)
        attach(bare, size: size)
        return Scene(view: view, bare: try render(bare, name: "bare.png"))
    }

    /// 挂到一扇窗上再渲染：不挂窗时 AppKit 的 focus 上下文不完整，文字类绘制会缺笔画。
    private func attach(_ view: NSView, size: NSSize) {
        ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: size)).contentView = view
    }

    @discardableResult
    private func render(_ view: NSView, name: String) throws -> NSBitmapImageRep {
        view.needsDisplay = true
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RenderFailure.noBitmap
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try export(bitmap, name: name)
        return bitmap
    }

    private func export(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderFailure.noPNGData
        }
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let url = exportDirectory.appendingPathComponent(name)
        try data.write(to: url)
        NSLog("%@", "[ScreenshotTests] 渲染结果：\(url.path)")
    }

    /// bitmap 的像素坐标是左上原点，和视图（flipped）一致，所以能直接用视图坐标取点。
    private func color(in bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private func sum(_ color: NSColor) -> CGFloat {
        color.redComponent + color.greenComponent + color.blueComponent
    }

    /// 同一位置「渲染值 / 无遮罩参照值」。1 = 一点没被遮；0.45 = 压暗那一档。
    ///
    /// 两边都**不做色彩管理转换**，直接按位图自己的空间取值相比：压暗是在那个空间里
    /// 乘 0.45，换到 sRGB 之后被 gamma 一弯，比值就不再是 0.45（实测 0.51）。参照图和
    /// 遮罩图都出自同一块屏的 cacheDisplay，空间一致，raw 值才可比。
    private func brightness(in bitmap: NSBitmapImageRep, scene: Scene, x: Int, y: Int) throws -> CGFloat {
        let rendered = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
        let bare = try XCTUnwrap(scene.bare.colorAt(x: x, y: y))
        XCTAssertGreaterThan(sum(bare), 0.3, "测试图案在这个位置太黑，比值没有意义")
        return sum(rendered) / sum(bare)
    }

    /// 第一个工具格子里、图标之外的另一点：选中格的蓝底会铺到这里，图标本体不会。
    private func firstToolCellProbe(bar: ScreenshotToolbarView) -> (x: Int, y: Int) {
        let inset = (ScreenshotToolbarView.barHeight - ScreenshotToolbarView.itemHeight) / 2
        return (Int(bar.frame.minX + ScreenshotToolbarView.edgePadding
                    + ScreenshotToolbarView.iconItemWidth / 2),
                Int(bar.frame.minY + inset + ScreenshotToolbarView.itemHeight - 4))
    }

    private func pattern(width: Int, height: Int) throws -> CGImage {
        guard let image = QuadrantPattern.image(width: width, height: height) else {
            throw RenderFailure.noPattern
        }
        return image
    }
}

/// 参照物：只把底图 1:1 铺满，不压暗、不描边、不写字。
/// 亮度判据必须来自这张图，而不是来自遮罩自己 —— 否则「选区内也蒙了层灰」这种错
/// 会两边一起错，断言就成了空转。走的是和遮罩同一套渲染管线（同一个 flipped 视图、
/// 同一个 cacheDisplay），所以色彩管理不会造成假差异。
private final class BackdropOnlyView: NSView {
    private let shot: ScreenshotFrame

    init(shot: ScreenshotFrame) {
        self.shot = shot
        super.init(frame: NSRect(origin: .zero, size: shot.pointSize))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: shot.image, size: shot.pointSize).draw(in: bounds)
    }
}
