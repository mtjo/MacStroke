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
//  4. 注解条的底衬和墨色**跟随系统外观**（调色板那七档固定色除外），见
//     `overlayScene(appearance:)`：那些亮度带是照深档标的，所以默认钉在 darkAqua，
//     要验翻档的用例自己显式传两档。
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

    /// 参照物是 QQ 那条注解条，借的是**图标语言和格子顺序**；底衬和墨色跟系统外观走
    /// （用户 2026-10-16：「我是要图标参考，但是还要跟随主题功能」）。
    ///
    /// 所以这条判的是「翻档」：浅外观下浅底深图标、深外观下深底浅图标，墨色相对底衬的
    /// **方向**必须反过来。两个阈值取自实测那两档语义色：windowBackgroundColor 在 aqua
    /// 是 0.9255、darkAqua 0.1961（压 0.94 alpha 后仍有 0.87 / 0.18），labelColor 是
    /// 同色相 84.7% 不透明度的墨，落在底衬上离底至少 0.6。
    func testBarBaseAndInkFlipWithSystemAppearance() throws {
        let selection = CGRect(x: 100, y: 60, width: 400, height: 300)
        let light = try overlayScene(selection: selection, editing: true, appearance: .aqua)
        let dark = try overlayScene(selection: selection, editing: true, appearance: .darkAqua)
        let lightBitmap = try render(light.view, name: "bar-aqua.png")
        let darkBitmap = try render(dark.view, name: "bar-darkaqua.png")
        let bar = try XCTUnwrap(light.view.toolbar)

        // 最后一个格子右边那点留白：那里只有条子的底，没有图标。
        let probe = (x: Int(bar.frame.maxX) - 3, y: Int(bar.frame.midY))
        let lightFill = luminance(try XCTUnwrap(color(in: lightBitmap, x: probe.x, y: probe.y)))
        let darkFill = luminance(try XCTUnwrap(color(in: darkBitmap, x: probe.x, y: probe.y)))
        XCTAssertGreaterThan(lightFill, 0.75, "浅色外观下条子该是浅底：\(lightFill)")
        XCTAssertLessThan(darkFill, 0.35, "深色外观下条子该是深底：\(darkFill)")

        // 第一格（矩形）是笔画图标：墨色相对底衬的方向在两档里正好相反。
        let cell = bar.actionableRects[0].offsetBy(dx: bar.frame.minX, dy: bar.frame.minY)
        XCTAssertGreaterThanOrEqual(count(in: lightBitmap, in: cell) {
            luminance($0) < lightFill - 0.3
        }, 8, "浅底上图标要换成深墨，否则浅桌面底下这条就是白的")
        XCTAssertGreaterThanOrEqual(count(in: darkBitmap, in: cell) {
            luminance($0) > darkFill + 0.3
        }, 8, "深底上图标要换成浅墨：\(darkFill)")
        // 反向对照：同一档里墨只朝一个方向偏。墨色没跟着翻（写死成白）时浅底那格会在这里
        // 冒出比底还亮的像素，上面两条就成了空转。
        XCTAssertEqual(count(in: lightBitmap, in: cell) {
            luminance($0) > lightFill + 0.3
        }, 0, "浅底上不该有一批比底还亮的墨")
        XCTAssertEqual(count(in: darkBitmap, in: cell) {
            luminance($0) < darkFill - 0.3
        }, 0, "深底上不该有一批比底还暗的墨")
    }

    /// 两个出口在**两档外观下**都得是红✕、绿✓：语义色本身也分档（aqua 的 systemRed
    /// 1/0.2314/0.1882、darkAqua 1/0.2706/0.2275），换档只改亮度不改色相，所以判据取
    /// 「色相占优的像素数」而不是「这一点是什么色」—— 图标是线性的，格子里一大半还是底。
    func testExitsStayRedAndGreenInBothAppearances() throws {
        let selection = CGRect(x: 100, y: 60, width: 400, height: 300)
        let isRedGlyph: (NSColor) -> Bool = { $0.redComponent > $0.greenComponent + 0.25
            && $0.redComponent > $0.blueComponent + 0.25 }
        let isGreenGlyph: (NSColor) -> Bool = { $0.greenComponent > $0.redComponent + 0.25
            && $0.greenComponent > $0.blueComponent + 0.25 }

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let scene = try overlayScene(selection: selection, editing: true, appearance: name)
            let bitmap = try render(scene.view, name: "bar-exits-\(name.rawValue).png")
            let bar = try XCTUnwrap(scene.view.toolbar)
            // 出口是最后三格（保存 / ✕ / ✓），顺序由 testBarFollowsTheQQOrder 锁住。
            let exits = bar.actionableRects.suffix(3)
                .map { $0.offsetBy(dx: bar.frame.minX, dy: bar.frame.minY) }
            XCTAssertEqual(exits.count, 3)
            XCTAssertGreaterThanOrEqual(count(in: bitmap, in: exits[1], isRedGlyph), 8,
                                        "\(name.rawValue) 下 ✕ 没烫成红色就成了普通图标")
            XCTAssertGreaterThanOrEqual(count(in: bitmap, in: exits[2], isGreenGlyph), 8,
                                        "\(name.rawValue) 下 ✓ 没烫成绿色就成了普通图标")
            // 反向对照：保存那一格是普通图标，里面一格红/绿都不该有。
            XCTAssertEqual(count(in: bitmap, in: exits[0]) { isRedGlyph($0) || isGreenGlyph($0) },
                           0, "\(name.rawValue) 下普通出口跟着发了色，上面两条就是空转")
        }
    }

    /// 色块那一排**不跟外观**：七档固定色要原样进成品 PNG，浅外观深外观烘出来必须是同一个值。
    /// 翻档的是底衬和描边，不是色值本身 —— 谁把调色板换成 labelColor 那类，这条当场红。
    ///
    /// 不拿 `palette` 常量当尺子：位图自己的色彩空间和 sRGB 不是一套，饱和色转换要偏
    /// 13%（实测 aqua 那档红在位图里是 0.896/0.900/0.941），逐通道比常量会把色彩管理误差
    /// 当成 bug。两档渲染走的是同一条管线，所以**互相比**才干净；再要求每档彼此分得开，
    /// 免得取点取到底衬上、比出「全部一样」的空转结果。
    func testPaletteSwatchesStayFixedAcrossAppearances() throws {
        let selection = CGRect(x: 100, y: 60, width: 400, height: 300)
        var samples: [NSAppearance.Name: [NSColor]] = [:]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let scene = try overlayScene(selection: selection, editing: true, appearance: name)
            // 色块现在长在工具面板上（条子里那 5 格收进去了）：先按条子的回调选中矩形，
            // 面板才浮出，再按「更多颜色」那一格把调色板那一行展开。
            scene.view.toolbar?.onTool?(.rect)
            let panel = try XCTUnwrap(scene.view.toolPanel, "选中工具后面板没浮出来")
            panel.press(cell: "more")
            let bitmap = try render(scene.view, name: "panel-palette-\(name.rawValue).png")
            samples[name] = try ScreenshotToolbarView.palette.indices.map { offset in
                let cell = try XCTUnwrap(panel.actionableRect(forCell: "palette.\(offset)"),
                                         "调色板那一行少了第 \(offset) 档")
                return try XCTUnwrap(color(in: bitmap, x: Int(cell.midX), y: Int(cell.midY)))
            }
        }
        let light = try XCTUnwrap(samples[.aqua])
        let dark = try XCTUnwrap(samples[.darkAqua])
        for (offset, pair) in zip(light, dark).enumerated() {
            XCTAssertEqual(pair.0.redComponent, pair.1.redComponent, accuracy: 0.02,
                           "第 \(offset) 档色块跨外观不能变：\(pair.0) / \(pair.1)")
            XCTAssertEqual(pair.0.greenComponent, pair.1.greenComponent, accuracy: 0.02)
            XCTAssertEqual(pair.0.blueComponent, pair.1.blueComponent, accuracy: 0.02)
        }
        // 反向对照：这几点确实是各不相同的墨色，不是底衬上同一片灰。
        for (i, left) in light.enumerated() {
            for (j, right) in light.enumerated() where j > i {
                let spread = max(abs(left.redComponent - right.redComponent),
                                 abs(left.greenComponent - right.greenComponent),
                                 abs(left.blueComponent - right.blueComponent))
                XCTAssertGreaterThan(spread, 0.2, "第 \(i) 档和第 \(j) 档分不开，取点取错了地方")
            }
        }
    }

    /// 自定义那一格得是**一条色相带**，不是纯色块也不是加号：它排在七档预设后面，用户靠
    /// 「这块颜色不属于任何一档」认出它是自定义入口（用户 2026-10-19：「最后一个是个
    /// 彩色的自定义颜色按钮」）。
    ///
    /// 判据取同一格里的三个横向取点：左偏红、中偏绿、右偏蓝紫。取点要是落在底衬上三点
    /// 会一模一样，所以最后那条「两两分得开」就是这事的反向对照。
    func testCustomColorCellPaintsAHueSweep() throws {
        let selection = CGRect(x: 100, y: 60, width: 400, height: 300)
        let scene = try overlayScene(selection: selection, editing: true, appearance: .darkAqua)
        scene.view.toolbar?.onTool?(.rect)
        let panel = try XCTUnwrap(scene.view.toolPanel, "选中矩形后面板没浮出来")
        panel.press(cell: "color")
        let cell = try XCTUnwrap(panel.actionableRect(forCell: "custom"), "调色板里少了自定义那一格")
        let bitmap = try render(scene.view, name: "panel-custom-color.png")

        func sampled(_ fraction: CGFloat) throws -> NSColor {
            try XCTUnwrap(color(in: bitmap, x: Int(cell.minX + cell.width * fraction),
                                y: Int(cell.midY)), "自定义那一格取不到点")
        }
        let left = try sampled(0.12), middle = try sampled(0.5), right = try sampled(0.88)
        XCTAssertGreaterThan(left.redComponent, left.greenComponent, "左端不偏红：\(left)")
        XCTAssertGreaterThan(middle.greenComponent, middle.redComponent, "中段不偏绿：\(middle)")
        XCTAssertGreaterThan(right.blueComponent, right.greenComponent, "右端不偏蓝紫：\(right)")
        for (a, b) in [(left, middle), (middle, right), (left, right)] {
            let spread = max(abs(a.redComponent - b.redComponent),
                             abs(a.greenComponent - b.greenComponent),
                             abs(a.blueComponent - b.blueComponent))
            XCTAssertGreaterThan(spread, 0.15, "两处取点一样，色相带没画出来：\(a) / \(b)")
        }
    }

    /// 面板的底衬和墨色跟条子同一条规矩：翻档整块反过来（用户 2026-10-16 定的是「图标参考
    /// QQ，底衬墨色跟主题」，面板是条子长出来的第二块，不能自己另定一套）。
    ///
    /// 顺带钉住文字那一格多出的样式行**真画出来了**：第二行有墨，且墨只朝一个方向偏。
    /// 少画一行在代码里只是 `placeCells()` 少 append 几条，位图上却是一块看得见的空洞。
    ///
    /// 最后钉那颗尖：它画在面板自己的 bounds 里（尖那 6pt 算进 frame）。早先画在外面，
    /// `cacheDisplay` 只重放 bounds 内的绘制，取证里一根都不剩；这层挂在 borderless 窗里，
    /// 一旦转成 layer-backed，屏幕上也会被同样裁掉。与其赌，不如把尖算进 frame。
    func testToolPanelFlipsWithAppearanceAndDrawsTheStyleRow() throws {
        let selection = CGRect(x: 100, y: 60, width: 400, height: 300)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let scene = try overlayScene(selection: selection, editing: true, appearance: name)
            scene.view.toolbar?.onTool?(.text)
            let panel = try XCTUnwrap(scene.view.toolPanel, "\(name.rawValue) 下文字面板没浮出")
            let bitmap = try render(scene.view, name: "panel-text-\(name.rawValue).png")

            // 面板左侧那 10pt 留白：只有底，没有字。
            let fill = luminance(try XCTUnwrap(color(in: bitmap, x: Int(panel.frame.minX) + 3,
                                                     y: Int(panel.frame.midY))))
            if name == .aqua {
                XCTAssertGreaterThan(fill, 0.75, "浅色外观下面板该是浅底：\(fill)")
            } else {
                XCTAssertLessThan(fill, 0.35, "深色外观下面板该是深底：\(fill)")
            }

            // 第一行的标签 + 第二行的 B/I 两格都得有墨，且方向相对底衬翻得过来。
            // `actionableRect(forCell:)` 给的就是遮罩坐标，不再平移。
            let ink: (NSRect) -> Int = { rect in
                self.count(in: bitmap, in: rect) {
                    name == .aqua ? self.luminance($0) < fill - 0.3
                                  : self.luminance($0) > fill + 0.3
                }
            }
            let label = try XCTUnwrap(panel.actionableRect(forCell: "label"))
            XCTAssertGreaterThanOrEqual(ink(label), 8, "\(name.rawValue) 下第一行标签没着墨")
            for id in ["bold", "italic"] {
                let chip = try XCTUnwrap(panel.actionableRect(forCell: id), "\(id) 那一格没摆")
                XCTAssertGreaterThanOrEqual(ink(chip), 3, "\(name.rawValue) 下 \(id) 格是空的")
            }
            // 反向对照：面板左沿那 9pt 留白（格子从 padding=10 才开始）一格墨都不该有。
            // 按本体量，不按 `bounds`：尖那 6pt 带在两侧没画东西，量的是背景，会被当成墨。
            let blank = CGRect(x: 0, y: panel.bodyRect.minY, width: 9, height: panel.bodyRect.height)
                .offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
            XCTAssertEqual(ink(blank), 0, "留白里也量到了墨，上面的判据就成了空转")

            // 尖得真画出来，还得指着选中那一格。
            //
            // 判据用**同一场景两次渲染相比**（面板在 / 面板藏起来），不跟底衬色比：
            // 深色外观下面板底衬 0.20 和那块压暗背景 0.15 只差 0.05，任何「朝哪边偏」
            // 的阈值都会在某一档外观上翻车。两次渲染唯一的差别就是面板画的那些像素，
            // 于是「尖那一条带有变化、左右 25pt 处没变化」是一条不依赖外观的硬判据。
            panel.isHidden = true
            let without = try render(scene.view, name: "panel-off-\(name.rawValue).png")
            panel.isHidden = false
            let cell = try XCTUnwrap(scene.view.toolbar?.cellRect(for: .text))
            let tipX = panel.frame.minX + panel.pointerX
            XCTAssertLessThanOrEqual(abs(tipX - cell.midX), 1.5,
                                     "\(name.rawValue) 下尖指偏了：\(tipX) vs \(cell.midX)")
            // 尖占本体下沿到 frame 下沿那 6pt（这一档选区没顶到屏边，尖朝下）。
            let bandTop = panel.frame.minY + panel.bodyRect.maxY
            func changed(in rect: NSRect) -> Int {
                var hit = 0
                for y in Int(rect.minY + 1)..<Int(rect.maxY - 1) {
                    for x in Int(rect.minX + 1)..<Int(rect.maxX - 1) {
                        guard let a = bitmap.colorAt(x: x, y: y),
                              let b = without.colorAt(x: x, y: y) else { continue }
                        if abs(a.redComponent - b.redComponent) > 0.02
                            || abs(a.greenComponent - b.greenComponent) > 0.02
                            || abs(a.blueComponent - b.blueComponent) > 0.02 { hit += 1 }
                    }
                }
                return hit
            }
            let band = CGRect(x: tipX - 4, y: bandTop, width: 8,
                              height: panel.frame.maxY - bandTop)
            XCTAssertGreaterThanOrEqual(changed(in: band), 12,
                                        "\(name.rawValue) 下尖没画出来：\(band)")
            for dx in [-25.0, 25.0] {
                XCTAssertEqual(changed(in: CGRect(x: tipX + dx - 4, y: bandTop, width: 8,
                                                  height: panel.frame.maxY - bandTop)), 0,
                               "\(name.rawValue) 下尖两侧 \(abs(dx).rounded())pt 处也有变化：那不是尖")
            }
        }
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

    /// 悬停在某一格上：那一格正上方冒出气泡（中性底 + 反色字）。
    ///
    /// 判据用**色度**不用绝对亮度：底衬现在跟系统外观走，实测深色档 0.266、浅色档 0.912，
    /// 而气泡底下那块蓝是 0.33 —— 深档下两者只差 0.06，亮度带就分不出「气泡」和「底图」了。
    /// 气泡是中性灰（|R−B| 很小），底图那块蓝是饱和的（|R−B| ≈ 1），这一条两档外观都成立。
    /// 选区特意压到屏底：条子放不下会翻进选区内侧，气泡于是整个落在亮区里。
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

        let neutral: (NSColor) -> Bool = { abs($0.redComponent - $0.blueComponent) < 0.12 }
        // 左边 4pt 那点：气泡内边距是 9pt，那里只有底衬、没有字。
        let body = luminance(try XCTUnwrap(color(in: shown, x: Int(tip.frame.minX) + 4,
                                                 y: Int(tip.frame.midY))))
        XCTAssertGreaterThanOrEqual(count(in: shown, in: tip.frame, neutral), 1000,
                                    "气泡得是那块中性底，不是只有一圈边")
        // 字只管「离底衬差多少」，不管朝哪个方向差：浅底深字、深底浅字都算印出来了。
        XCTAssertGreaterThanOrEqual(count(in: shown, in: tip.frame) {
            abs(luminance($0) - body) > 0.3
        }, 100, "底衬上得印得出反色字：底衬亮度 \(body)")
        XCTAssertEqual(count(in: hidden, in: tip.frame, neutral), 0,
                       "反向对照：没悬停时这块是饱和的蓝，一条中性都不该有，否则上面两条是空转")
    }

    /// 悬停提示在**像素上**真的压住属性面板（用户 2026-10-19 的第 2 条：「鼠标悬浮提示
    /// 汽泡应该放在最上层，现在被粗细颜色的汽泡挡住了」）。
    ///
    /// 判据方向跟直觉相反：**把面板收起再渲染一次，气泡盖过的那一带该纹丝不动**。气泡在
    /// 顶上时，面板画不画都在它下面，那块一个像素都不该变；面板压在气泡上时（`barFill` 是
    /// 0.94 alpha 的墨底，几乎不透，正是用户看到的「被挡住」），收起面板那块立刻换成气泡
    /// 内容，差成一片。
    ///
    /// 为什么不是「把气泡藏掉、比重叠区差多少」—— 比不出来：气泡和面板用的是同一档
    /// `barFill`，气泡没了那块还是同一档墨，实测被挡住那一态照样差 373 点（阈值 40 抓不住）。
    /// 只有「被压住的那块该不该跟着面板变」才有方向。
    ///
    /// 反向对照自带在同一对渲染里：面板上**气泡没盖到**的那一段收起面板前后必须大片变色
    /// —— 否则上面那条「没变」只是因为面板根本没在画。
    /// 顺序要紧：先悬停（气泡先建）、再选工具（面板后建）、最后再悬停一次端上来。
    func testTipIsStillPaintedOverTheStylePanel() throws {
        let size = NSSize(width: 1440, height: 900)
        let selection = CGRect(x: 100, y: 100, width: 1200, height: 600)
        let scene = try overlayScene(selection: selection, size: size, editing: true)
        let view = scene.view
        let bar = try XCTUnwrap(view.toolbar)
        let cell = try XCTUnwrap(bar.cellRect(for: .rect))

        view.pointerMoved(CGPoint(x: cell.midX, y: cell.midY))
        let tip = try XCTUnwrap(view.tipView, "悬停在工具格上就该有提示")
        bar.onTool?(.rect)
        view.pointerMoved(CGPoint(x: cell.midX + 0.5, y: cell.midY))
        let panel = try XCTUnwrap(view.toolPanel, "选了矩形后面板没浮出")
        let overlap = tip.frame.intersection(panel.frame)
        XCTAssertGreaterThan(overlap.width, 20, "前提：两块没重叠：\(tip.frame) / \(panel.frame)")
        XCTAssertGreaterThan(overlap.height, 8, "前提：竖向没重叠")

        let shown = try render(view, name: "tip-over-panel-shown.png")
        if shown.pixelsWide != Int(size.width) {
            throw XCTSkip("离屏渲染比例 \(shown.pixelsWide)/\(Int(size.width)) ≠ 帧比例")
        }
        // 反向对照的量尺：面板上气泡**没**盖到的那一段，取同一行高。
        // 往气泡右边取，不能往左边取 —— 气泡横向只钳屏、不钳条子，比面板更靠左是常态
        // （实测 tip x 377…491、panel x 411…647），往左那段压根不在面板上，比出来恒为 0。
        let beside = CGRect(x: tip.frame.maxX + 4, y: overlap.minY + 1,
                            width: panel.frame.maxX - tip.frame.maxX - 8,
                            height: overlap.height - 2)
        XCTAssertGreaterThan(beside.width, 40,
                             "前提：面板右边那段太窄，反向对照比不出来：\(beside) / \(panel.frame)")

        panel.isHidden = true
        let withoutPanel = try render(view, name: "tip-over-panel-no-panel.png")
        panel.isHidden = false

        let underTip = differences(shown, withoutPanel, overlap)
        let unshaded = differences(shown, withoutPanel, beside)
        let tipPixels = Int(overlap.width - 2) * Int(overlap.height - 2)
        let sidePixels = Int(beside.width - 2) * Int(beside.height - 2)
        XCTAssertLessThanOrEqual(underTip, tipPixels / 20,
                                 "收起面板后气泡盖着那块跟着变了 \(underTip)/\(tipPixels)：气泡其实在面板底下（tip \(tip.frame) panel \(panel.frame)）")
        XCTAssertGreaterThanOrEqual(unshaded, sidePixels / 4,
                                    "反向对照失效：收起面板连气泡没盖到的那段都没变色（\(unshaded)/\(sidePixels)），说明面板根本没画")
    }

    /// 两张同一场景的渲染在 `rect` 内差多少**个像素**（三通道任一差过 0.08 算变）。
    /// 逐点比亮度会被同档墨底糊弄，比「变没变」才分得出谁压谁。
    private func differences(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, _ rect: NSRect) -> Int {
        var hit = 0
        for y in stride(from: Int(rect.minY) + 1, to: Int(rect.maxY) - 1, by: 1) {
            for x in stride(from: Int(rect.minX) + 1, to: Int(rect.maxX) - 1, by: 1) {
                guard let left = color(in: a, x: x, y: y), let right = color(in: b, x: x, y: y) else {
                    continue
                }
                let spread = max(abs(left.redComponent - right.redComponent),
                                 abs(left.greenComponent - right.greenComponent),
                                 abs(left.blueComponent - right.blueComponent))
                if spread > 0.08 { hit += 1 }
            }
        }
        return hit
    }

    ///
    /// 两条判据各管一种错：白像素没了 = 图标跟着蓝底糊成一片（深底上「浅色一块」和
    /// 「没选中」差得太少，所以选中态必须翻白）；蓝像素没了 = 整格被涂成实心白块，
    /// 用户就认不出这还是刚才那枚像素格。
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
        XCTAssertEqual(view.currentStyle.color, ScreenshotToolbarView.palette[0],
                       "这一笔用的是调色板第一档（红）")
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
        // 「画完即选中」（用户 2026-10-19 定的口径）之后，松手那一瞬这一条还带着选中辅助线 ——
        // 它是系统强调色（约 0, 0.48, 1.0），和上面那圈 `isGuideBlue` 落在同一个色窗里，
        // 光按颜色分不开「辅助线没收」和「选中框在」这两种红。所以先把选中交还掉，剩下的
        // 蓝才只可能是打码辅助线。选中框本身由 ScreenshotAnnotationEditTests 那套判据管。
        XCTAssertEqual(view.selectedIndex, 0, "前提：松手时这一条是选中态")
        view.selectAnnotation(nil)
        let committed = try render(view, name: "mosaic-committed.png")
        XCTAssertEqual(pixels(insideSelection, in: committed, matching: isGuideBlue), 0,
                       "松手后辅助线必须整个收掉：它不该进成品图")
        XCTAssertEqual(pixels(insideSelection, in: committed, matching: isInkRed), 0,
                       "松手后的打码块也不该带一圈自己墨色的边框")
    }

    /// 气泡和条子是同一档底衬，所以它也必须**跟随系统外观**（用户 2026-10-16：
    /// 「我是要图标参考，但是还要跟随主题功能」）。
    ///
    /// 三条判据各管一种错：底衬亮度管「整只气泡没翻档」；文字墨色相对底衬的方向管
    /// 「底翻了字没翻」（这种错单看一张渲染图最容易漏）；两档渲染逐像素比的最大差
    /// 管「尺子空转」—— 曾经有一条断言正是这么废掉的，所以这条留着，只是方向反过来了。
    func testTipBubbleFlipsWithSystemAppearance() throws {
        let selection = CGRect(x: 100, y: 300, width: 400, height: 180)
        func hovered(_ name: NSAppearance.Name, _ file: String) throws
            -> (bitmap: NSBitmapImageRep, tip: ScreenshotTipView, body: CGFloat) {
            let scene = try overlayScene(selection: selection, editing: true, appearance: name)
            let view = scene.view
            let bar = try XCTUnwrap(view.toolbar)
            let cell = bar.actionableRects[6].offsetBy(dx: bar.frame.minX, dy: bar.frame.minY)
            view.pointerMoved(CGPoint(x: cell.midX, y: cell.midY))
            let tip = try XCTUnwrap(view.tipView)
            let bitmap = try render(view, name: file)
            // 左边 4pt 那点：气泡内边距是 9pt，那里只有底衬、没有字。
            let body = luminance(try XCTUnwrap(color(in: bitmap, x: Int(tip.frame.minX) + 4,
                                                     y: Int(tip.frame.midY))))
            return (bitmap, tip, body)
        }

        let light = try hovered(.aqua, "tip-flip-aqua.png")
        let dark = try hovered(.darkAqua, "tip-flip-darkaqua.png")
        XCTAssertGreaterThan(light.body, 0.75, "浅色外观下气泡该是浅底：\(light.body)")
        XCTAssertLessThan(dark.body, 0.35, "深色外观下气泡该是深底：\(dark.body)")

        // 文字朝反方向偏：浅底深字、深底浅字，两档都得有一批离底 0.3 以上的字。
        XCTAssertGreaterThanOrEqual(count(in: light.bitmap, in: light.tip.frame) {
            luminance($0) < light.body - 0.3
        }, 60, "浅底上气泡文字要换成深墨：\(light.body)")
        XCTAssertGreaterThanOrEqual(count(in: dark.bitmap, in: dark.tip.frame) {
            luminance($0) > dark.body + 0.3
        }, 60, "深底上气泡文字要换成浅墨：\(dark.body)")

        let acrossAppearance = worstDifference(in: light.tip.frame.union(dark.tip.frame),
                                               light.bitmap, dark.bitmap)
        XCTAssertGreaterThan(acrossAppearance, 0.5,
                             "换外观必须真改到像素（最大偏差 \(acrossAppearance)）：没翻档就成了空转")
    }

    /// 一块区域里两张图的最大逐通道差。
    private func worstDifference(in region: NSRect, _ a: NSBitmapImageRep,
                                 _ b: NSBitmapImageRep) -> CGFloat {
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

    // MARK: - 辅助

    /// 一张场景 = 遮罩视图 + 同一块底图「没遮罩」的参照渲染。
    /// 判据从参照图取，不从被测对象取。
    private struct Scene {
        let view: ScreenshotSelectionView
        let bare: NSBitmapImageRep
    }

    /// `appearance` 默认钉在深档：下面那些亮度带（`> 0.6` 算实心、`> 0.28` 算半透明那一档、
    /// 气泡 `< 0.25` 算深底）是照着条子的深底白图标标的，不钉的话测试机切一下明暗就红一片。
    /// 要验「跟随主题」的用例自己显式传两档。
    private func overlayScene(selection: CGRect, size: NSSize = NSSize(width: 800, height: 500),
                              editing: Bool = false,
                              appearance: NSAppearance.Name = .darkAqua) throws -> Scene {
        let image = try pattern(width: Int(size.width), height: Int(size.height))
        let frame = try XCTUnwrap(ScreenshotFrame(image: image, pointSize: size))
        let view = ScreenshotSelectionView(shot: frame)
        view.appearance = NSAppearance(named: appearance)
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

    /// 三通道平均。底衬/墨色那种「整块翻档」的判据用它，色相占优的判据不用（红和绿的
    /// 平均数可以一样）。
    private func luminance(_ color: NSColor) -> CGFloat { sum(color) / 3 }

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
