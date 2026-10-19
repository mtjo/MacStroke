//
//  ScreenshotToolPanelTests.swift
//
//  工具属性面板的取证（issue #73 的 2.3 + 用户那句「每个工具单独一套粗细和颜色，
//  默认色都是红色」）。
//
//  四条最容易错的地方：
//  ① 每格工具各记一套 —— 调了矩形再去动箭头，箭头必须还是它自己的默认，不能跟着变；
//  ② 面板改的值要真的落到**下一笔**上，不是只改了面板上那个数（所以每条都回头查注解）；
//  ③ 文字那三样（字号、粗斜体、边框/背景）各走各的路：字号进 fontSize、勾子进 bool、
//     色块进 optional 颜色，漏一条在屏幕上只是「少了个边框」，代码里看不出来；
//  ④ 面板压在选区上，它得吃掉落在自己身上的点击 —— 漏一次就是「在面板底下画出注解」。
//
//  打码那一格不弹面板（它既不吃色也不吃粗细），这条也钉住：以后谁给它加了一排灰控件，
//  在这儿会红，而不是等用户点出一块什么都没的面板。
//

import AppKit
import Storage
import XCTest

@testable import Screenshot

final class ScreenshotToolPanelTests: XCTestCase {

    // MARK: - 每工具一套

    /// 选中工具 → 面板在它那格上方浮出；换工具 → 各记各的；再点同一格取消 → 面板收。
    func testEachToolKeepsItsOwnStyleWithinTheSession() throws {
        let view = try editedView()
        XCTAssertNil(view.toolPanel, "没选中工具就没有面板可浮")
        view.toolbar?.onTool?(.rect)
        let panel = try XCTUnwrap(view.toolPanel, "选中矩形后面板没浮出来")
        XCTAssertFalse(panel.isHidden)
        XCTAssertEqual(panel.tool, .rect)
        // 默认色就是调色板第一档（红）：用户要的是「默认色都是红色」，每一格都得是。
        XCTAssertEqual(panel.style.color, ScreenshotToolbarView.palette[0])
        XCTAssertEqual(panel.style.lineWidth, 4)

        // 把滑杆拖到最右（24），只该记在矩形自己名下。
        setSliderToMax(panel)
        XCTAssertEqual(panel.style.lineWidth, ScreenshotToolStyle.widthRange.upperBound)

        view.toolbar?.onTool?(.arrow)
        XCTAssertEqual(panel.tool, .arrow)
        XCTAssertEqual(panel.style.lineWidth, 4, "箭头没调过，该还是它自己的默认")

        view.toolbar?.onTool?(.arrow)   // 再点一次 = 摘掉工具
        XCTAssertTrue(panel.isHidden, "没选中工具就没有锚，面板得收")

        view.toolbar?.onTool?(.rect)
        XCTAssertEqual(panel.style.lineWidth, ScreenshotToolStyle.widthRange.upperBound,
                       "本次截图里矩形那一套要还在")
    }

    /// 每格工具的默认都是红；但文字那一格给的粗细是 2（旧条子上最细那档），
    /// 因为文字的字号自己算，粗细只影响序号徽标那一类。
    func testEveryToolStartsRed() throws {
        for tool in ScreenshotTool.allCases where tool.hasStylePanel {
            let style = ScreenshotToolStyle.default(for: tool)
            XCTAssertEqual(style.color, ScreenshotToolbarView.palette[0], "\(tool) 的默认色不是红")
        }
    }

    /// 打码不吃颜色也不吃粗细：给它弹一块面板就是骗用户点。
    func testMosaicDoesNotOpenAPanel() throws {
        let view = try editedView()
        view.toolbar?.onTool?(.mosaic)
        XCTAssertEqual(view.tool, .mosaic)
        XCTAssertFalse(view.toolPanel?.isHidden == false, "打码不该把面板顶出来")
        XCTAssertFalse(ScreenshotTool.mosaic.hasStylePanel)
    }

    /// 面板上滑杆滑的值必须落到**下一笔**：只改了面板上的数字、注解还是老的，
    /// 屏幕上看不出区别。
    func testSliderAndPaletteLandOnTheNextStroke() throws {
        let view = try editedView(CGRect(x: 100, y: 60, width: 300, height: 400))
        view.toolbar?.onTool?(.rect)
        let panel = try XCTUnwrap(view.toolPanel)

        setSliderToMax(panel)
        panel.press(cell: "color")
        panel.press(cell: "palette.2")   // 绿

        drawRect(in: view, from: CGPoint(x: 130, y: 90), to: CGPoint(x: 260, y: 170))
        let drawn = try XCTUnwrap(view.annotations.last)
        XCTAssertEqual(drawn.lineWidth, ScreenshotToolStyle.widthRange.upperBound)
        XCTAssertEqual(drawn.color, ScreenshotToolbarView.palette[2])
    }

    // MARK: - 文字那一格

    /// 文字面板多一行样式：字号滑杆 + B + I + 边框 + 背景，缺一样就是「代码里少画一块」。
    func testTextPanelCarriesTheStyleRow() throws {
        let view = try editedView(CGRect(x: 100, y: 60, width: 300, height: 400))
        view.toolbar?.onTool?(.text)
        let panel = try XCTUnwrap(view.toolPanel)
        XCTAssertEqual(panel.elementsOnPanel,
                       ["label", "slider", "value", "color", "more",
                        "label.style", "bold", "italic", "border", "background"])
    }

    /// 非文字工具没有样式行 —— 边框和斜体对一条矩形没意义。
    func testShapePanelHasOnlyTheSliderRow() throws {
        for tool in [ScreenshotTool.rect, .ellipse, .arrow, .pen, .number] {
            let view = try editedView()
            view.toolbar?.onTool?(tool)
            let panel = try XCTUnwrap(view.toolPanel)
            XCTAssertEqual(panel.elementsOnPanel, ["label", "slider", "value", "color", "more"],
                           "\(tool) 那一格多出了不属于它的控件")
        }
    }

    /// 字号滑的是字号，不再是「粗细 ×4」—— 用户这条抱怨（「现在只能通过调整线条粗细调整
    /// 字体大小」）的正面取证：把字号拉到最大，注解的 fontSize 就是那个数，lineWidth 不动。
    func testTextToolSliderDrivesFontSizeNotLineWidth() throws {
        let view = try editedView(CGRect(x: 100, y: 60, width: 300, height: 400))
        view.toolbar?.onTool?(.text)
        let panel = try XCTUnwrap(view.toolPanel)
        setSliderToMax(panel)
        XCTAssertEqual(panel.style.fontSize, ScreenshotToolStyle.fontRange.upperBound)
        XCTAssertEqual(panel.style.lineWidth, 2, "字号滑杆不该顺手动粗细")

        let text = try commitText(in: view, at: CGPoint(x: 130, y: 90), string: "标注")
        XCTAssertEqual(text.fontSize, ScreenshotToolStyle.fontRange.upperBound)
        XCTAssertEqual(text.lineWidth, 2)
    }

    /// 粗体、斜体、边框、背景四样各自都能设进下一笔。
    func testTextStyleRowSetsAllFourOptions() throws {
        let view = try editedView(CGRect(x: 100, y: 60, width: 300, height: 400))
        view.toolbar?.onTool?(.text)
        let panel = try XCTUnwrap(view.toolPanel)
        panel.press(cell: "italic")                    // 默认粗，这里加斜
        panel.press(cell: "border")                    // 唤出调色板（给边框挑色）
        panel.press(cell: "palette.1")                 // 黄
        panel.press(cell: "background")
        panel.press(cell: "palette.6")                 // 黑

        XCTAssertEqual(panel.style.bold, true)
        XCTAssertEqual(panel.style.italic, true)
        XCTAssertEqual(panel.style.borderColor, ScreenshotToolbarView.palette[1])
        XCTAssertEqual(panel.style.backgroundColor, ScreenshotToolbarView.palette[6])

        let text = try commitText(in: view, at: CGPoint(x: 130, y: 90), string: "标注")
        XCTAssertTrue(text.bold)
        XCTAssertTrue(text.italic)
        XCTAssertEqual(text.borderColor, ScreenshotToolbarView.palette[1])
        XCTAssertEqual(text.backgroundColor, ScreenshotToolbarView.palette[6])
    }

    /// 「无」把边框/背景清回去：设错了要能取消，不然只能撤销整条重画。
    func testNoneChipClearsBorderAndBackground() throws {
        let view = try editedView(CGRect(x: 100, y: 60, width: 300, height: 400))
        view.toolbar?.onTool?(.text)
        let panel = try XCTUnwrap(view.toolPanel)
        panel.press(cell: "border")
        panel.press(cell: "palette.1")
        // 挑完色调色板自己收起（`applyPalette` 收尾），所以「无」要在重新展开的那一行里按。
        panel.press(cell: "border")
        panel.press(cell: "none")
        XCTAssertNil(panel.style.borderColor)

        let text = try commitText(in: view, at: CGPoint(x: 130, y: 90), string: "标注")
        XCTAssertNil(text.borderColor)
    }

    /// 主色不给「无」：一条没有颜色的注解等于没画，那格按下去只会让人以为是 bug。
    func testMainColorCannotBeSetToNone() throws {
        let view = try editedView(CGRect(x: 100, y: 60, width: 300, height: 400))
        view.toolbar?.onTool?(.text)
        let panel = try XCTUnwrap(view.toolPanel)
        panel.press(cell: "color")
        XCTAssertFalse(panel.elementsOnPanel.contains("none"), "主色那一行不该给出「无」")
        XCTAssertEqual(panel.style.color, ScreenshotToolbarView.palette[0])
    }

    // MARK: - 面板挡住的地方

    /// 落在面板里的点击不进遮罩：真事件由 `hitTest` 整块吃掉，判定树这边再挡一次，
    /// 两处都得挡 —— 少一处就是「在面板底下画出一条注解」。
    func testPanelConsumesItsOwnArea() throws {
        let view = try editedView(CGRect(x: 100, y: 60, width: 300, height: 400))
        view.toolbar?.onTool?(.rect)
        let panel = try XCTUnwrap(view.toolPanel)
        let onPanel = CGPoint(x: panel.frame.midX, y: panel.frame.midY)

        XCTAssertIdentical(view.window?.contentView?.hitTest(
            NSPoint(x: onPanel.x, y: view.bounds.height - onPanel.y)), panel,
            "从窗口根命中停不住在面板上，下面的判定就白挡了")

        view.pointerDown(onPanel, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: onPanel.x + 40, y: onPanel.y + 40))
        view.pointerReleased()
        XCTAssertTrue(view.annotations.isEmpty, "面板底下不能画出一条注解")
    }

    /// 条子被拖走时面板跟着走：它是钉在某一格上方的，格子动了它不动就成了凭空飘着的板子。
    ///
    /// 判据取**位移相等**，不取「面板在条子上方多少 pt」那种由面板自己算出来的数 ——
    /// 那条等于让被测对象给自己作证。条子上挑落点用「不属于任何格子的那一点」：
    /// 按在格子上那一下归格子，根本不会开始拖整条。
    func testPanelFollowsTheBar() throws {
        let view = try editedView(CGRect(x: 100, y: 60, width: 300, height: 400))
        let bar = try XCTUnwrap(view.toolbar)
        bar.onTool?(.rect)
        let panel = try XCTUnwrap(view.toolPanel)
        let blankSpot = CGPoint(x: (0...60).map { bar.frame.minX + CGFloat($0) * 2 }
            .first(where: { !bar.hasActionable(atOverlayPoint: CGPoint(x: $0, y: bar.frame.midY)) })
            ?? bar.frame.minX,
            y: bar.frame.midY)
        XCTAssertFalse(bar.hasActionable(atOverlayPoint: blankSpot), "落点得是条子上的空白")

        let barBefore = bar.frame.origin
        let panelBefore = panel.frame.origin
        view.pointerDown(blankSpot, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: blankSpot.x, y: blankSpot.y + 60))
        view.pointerReleased()

        XCTAssertEqual(bar.frame.origin.y, barBefore.y + 60, accuracy: 1, "前提：条子真被拖走了")
        XCTAssertEqual(panel.frame.origin.y, panelBefore.y + 60, accuracy: 1,
                       "条子挪了 60pt，面板得一起挪，不然尖指错了格子")
    }

    /// 上方放不下就翻到格子下面，横向钳在容器内 —— 贴着屏顶的选区不能把面板顶出屏。
    func testPanelFlipsAndClampsInsideTheContainer() throws {
        let container = CGRect(x: 0, y: 0, width: 800, height: 500)
        let panel = ScreenshotToolPanelView(frame: .zero)
        panel.show(tool: .rect, style: .default(for: .rect),
                   cell: CGRect(x: 20, y: 4, width: 32, height: 32), in: container)
        XCTAssertTrue(panel.pointerUp, "上方没地方还硬往上面顶，面板就跑出屏了")
        XCTAssertGreaterThanOrEqual(panel.frame.minY, 4)
        XCTAssertLessThanOrEqual(panel.frame.maxY, container.maxY)
        XCTAssertGreaterThanOrEqual(panel.frame.minX, container.minX)
        XCTAssertLessThanOrEqual(panel.frame.maxX, container.maxX)
    }

    /// 面板上每一格都必须落在自己那块底里。
    ///
    /// 右边那一组（数值 / 色块 / ⌄）钉在面板右沿、滑杆吃剩下的宽度。早先是反过来排的
    /// ——先按 `max(40, …)` 给滑杆留一段，再一格往右推：标签一长（英文串，或者本地化
    /// 没命中直接显示 key）滑杆被钳到下限、右边三格照样往右推，⌄ 整格顶出面板外，
    /// 画不出也点不着，等于面板丢了改颜色的入口。离屏渲染量出来的（测试环境里 `L`
    /// 正好回落到 key，是最长的标签）。
    func testEveryCellStaysInsideThePanel() throws {
        let container = CGRect(x: 0, y: 0, width: 1200, height: 900)
        for tool in ScreenshotTool.allCases where tool.hasStylePanel {
            for opensPalette in [false, true] {
                // 挂进容器：`toggle()` 开调色板时按 `superview.bounds` 重新摆位，
                // 游离视图没有 superview，那一行会按面板自己的 bounds 钳位。
                let host = NSView(frame: container)
                let panel = ScreenshotToolPanelView(frame: .zero)
                host.addSubview(panel)
                panel.show(tool: tool, style: .default(for: tool),
                           cell: CGRect(x: 400, y: 400, width: 32, height: 32), in: container)
                if opensPalette { panel.press(cell: "color") }   // 多顶出一行色块
                let ids = panel.elementsOnPanel
                XCTAssertFalse(ids.isEmpty, "\(tool) 的面板是空的")
                for id in ids {
                    let rect = try XCTUnwrap(panel.actionableRect(forCell: id), "\(id) 那一格没摆")
                    XCTAssertTrue(panel.frame.contains(rect),
                                  "\(tool) 的 \(id) 跑到面板外：\(rect) ∉ \(panel.frame)")
                }
                // 反向对照：⌄ 必须正好贴到右沿留白处，不然「没出界」可能只是整行都缩在左边。
                let more = try XCTUnwrap(panel.actionableRect(forCell: "more"))
                XCTAssertEqual(more.maxX, panel.frame.maxX - ScreenshotToolPanelView.padding,
                               accuracy: 0.5, "\(tool) 的 ⌄ 没钉在右沿")
            }
        }
    }

    // MARK: - 模型

    /// 显式给了字号就用它；没给才回到旧的「跟着线宽算」—— 序号徽标和存量那条路还靠它。
    func testFontSizeDefaultsToTheOldDerivation() throws {
        XCTAssertEqual(ScreenshotAnnotation(tool: .text, color: .red, lineWidth: 6,
                                            start: .zero, text: "a").fontSize, 24)
        XCTAssertEqual(ScreenshotAnnotation(tool: .text, color: .red, lineWidth: 6,
                                            start: .zero, text: "a", fontSize: 40).fontSize, 40)
        XCTAssertEqual(ScreenshotAnnotation(tool: .text, color: .red, lineWidth: 1,
                                            start: .zero, text: "a").fontSize, 13, "小字有地板")
    }

    /// 粗 + 斜得是真粗斜体：`boldSystemFont` 再叠 italic 会退成普通斜体，
    /// 屏幕上看着「斜了但没粗」，只有量字体特征才发现得了。
    func testBoldAndItalicCombine() throws {
        let both = ScreenshotAnnotation.font(size: 24, bold: true, italic: true)
        let traits = NSFontManager.shared.traits(of: both)
        XCTAssertTrue(traits.contains(.boldFontMask), "粗没上去：\(both.fontName)")
        XCTAssertTrue(traits.contains(.italicFontMask), "斜没上去：\(both.fontName)")

        let plain = ScreenshotAnnotation.font(size: 24, bold: false, italic: false)
        XCTAssertFalse(NSFontManager.shared.traits(of: plain).contains(.boldFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: plain).contains(.italicFontMask))
    }

    /// 勾上粗体之后底和框要罩住的正是变宽后的那一份 —— 按普通字宽算会短一截。
    ///
    /// 用拉丁字母量：中文那套系统字（苹方）各字重的前进宽度相同，实测「标注标注」
    /// 在 .AppleSystemUIFont 和 .SFNS-Bold 下都是 97.248pt，拿中文比宽只会测出一个恒等式。
    /// 字重有没有真上去由 `testBoldAndItalicCombine` 查字体特征，不归这条管。
    func testTextBoxFollowsTheFont() throws {
        let plain = ScreenshotAnnotation(tool: .text, color: .red, lineWidth: 2,
                                         start: CGPoint(x: 50, y: 50), text: "Bold text",
                                         fontSize: 24, bold: false)
        let bolded = ScreenshotAnnotation(tool: .text, color: .red, lineWidth: 2,
                                          start: CGPoint(x: 50, y: 50), text: "Bold text",
                                          fontSize: 24, bold: true)
        XCTAssertGreaterThan(bolded.textSize.width, plain.textSize.width)
        XCTAssertEqual(bolded.textBoxRect.width, bolded.textSize.width + bolded.textPadding * 2,
                       accuracy: 0.5)
        XCTAssertEqual(plain.dirtyRect, plain.textBoxRect)
    }

    /// 边框和背景要进成品图：导出这条路上少一次转发，屏上有、图里没有。
    ///
    /// 判据取**同一块地方两次渲染相比**，不跟 `palette` 常量逐通道比：位图自己的色彩空间
    /// 和 sRGB 不是一套，饱和色转换要偏 13%（条子的调色板那条取证就是这么定的），拿常量当
    /// 尺子会把色彩管理误差读成 bug。第二次渲染把边框和背景都摘掉，同一块地方只剩底图的
    /// 绿 —— 于是「有」和「没有」各是一头的硬数字，谁漏了转发当场露出来。
    func testBorderAndBackgroundSurviveExport() throws {
        let size = NSSize(width: 800, height: 500)
        let shot = try XCTUnwrap(ScreenshotFrame(
            image: try XCTUnwrap(QuadrantPattern.image(width: 800, height: 500)), pointSize: size))
        // 选区 = 右上绿象限：底和框都不是绿，量到的绿只可能是「压根没画」。
        let selection = CGRect(x: 400, y: 40, width: 400, height: 250)
        let annotation = ScreenshotAnnotation(tool: .text, color: .white, lineWidth: 2,
                                              start: CGPoint(x: 440, y: 80), text: "标注",
                                              fontSize: 28, bold: true, italic: false,
                                              borderColor: ScreenshotToolbarView.palette[1],
                                              backgroundColor: ScreenshotToolbarView.palette[6])
        let box = annotation.textBoxRect.offsetBy(dx: -selection.minX, dy: -selection.minY)

        func counts(_ annotations: [ScreenshotAnnotation], name: String) throws ->
            (border: Int, background: Int, backdrop: Int) {
            let image = try XCTUnwrap(ScreenshotComposer.compose(shot: shot, selection: selection,
                                                                 annotations: annotations))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(cgImage: image))
            if bitmap.pixelsWide != Int(selection.width) {
                throw XCTSkip("离屏渲染比例 \(bitmap.pixelsWide)/\(Int(selection.width)) ≠ 帧比例")
            }
            try dump(bitmap, name: name)
            var border = 0, background = 0, backdrop = 0
            for y in stride(from: 0, to: Int(box.height), by: 1) {
                for x in stride(from: 0, to: Int(box.width), by: 1) {
                    guard let color = bitmap.colorAt(x: Int(box.minX) + x, y: Int(box.minY) + y)?
                            .usingColorSpace(.sRGB) else { continue }
                    if color.greenComponent > 0.6, color.redComponent < 0.4, color.blueComponent < 0.4 {
                        backdrop += 1
                    } else if color.blueComponent < 0.4, color.redComponent > 0.6,
                            color.greenComponent > 0.45 {
                        border += 1        // 黄：红高、绿中高、蓝低
                    } else if color.redComponent < 0.4, color.greenComponent < 0.4,
                            color.blueComponent < 0.4 {
                        background += 1    // 黑底
                    }
                }
            }
            return (border, background, backdrop)
        }

        let withChrome = try counts([annotation], name: "text-border-background-export.png")
        let plain = try counts([ScreenshotAnnotation(tool: .text, color: .white, lineWidth: 2,
                                                     start: CGPoint(x: 440, y: 80), text: "标注",
                                                     fontSize: 28, bold: true)],
                               name: "text-plain-export.png")
        XCTAssertGreaterThan(withChrome.border, 4, "边框没进成品图")
        XCTAssertGreaterThan(withChrome.background, 20, "底色没进成品图")
        XCTAssertEqual(plain.border, 0, "没设边框却量到了黄，上面那条是空转")
        XCTAssertEqual(plain.background, 0, "没铺底却量到了黑，上面那条是空转")
        XCTAssertGreaterThan(plain.backdrop, 20, "取点不在底图的绿上，框跑到选区外了")
    }

    // MARK: - Esc 一层一层退（用户 2026-10-18 问的就是这条）

    /// 面板是「选中工具即浮出」的，浮得勤，就更要能吃掉第一下 Esc：不然用户想收一块
    /// 面板，结果整次截图没了。
    ///
    /// 判据走真的 `keyDown(with:)` —— 这一层只有键盘能进，绕开它直接调
    /// `hideToolPanel()` 测出来的只是那个函数自己的功劳，不是这条链路的。
    func testEscCollapsesThePanelBeforeKillingTheSession() throws {
        let view = try editedView()
        var cancelled = 0
        view.onCancel = { cancelled += 1 }
        view.toolbar?.onTool?(.rect)
        let panel = try XCTUnwrap(view.toolPanel, "选中矩形后面板没浮出来")
        XCTAssertFalse(panel.isHidden)

        view.keyDown(with: try escKey())
        XCTAssertTrue(panel.isHidden, "第一下 Esc 该只收面板")
        XCTAssertEqual(cancelled, 0, "面板还开着就把整次截图丢了")
        XCTAssertEqual(view.tool, .rect, "收面板不动工具：用户next要画的还是矩形")
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 100, width: 300, height: 300),
                       "选区得原地留着")

        // 第二下才轮到丢会话 —— 反向对照：要是第一下就把会话丢了，这里会是 2。
        view.keyDown(with: try escKey())
        XCTAssertEqual(cancelled, 1, "面板收了，第二下 Esc 就该丢会话")
    }

    /// 收了之后不许自己弹回来。面板的浮出挂在 `syncToolbar()` 上，而撤销/重做/提取文字
    /// 全都走它 —— 用户收完面板接着画两笔、撤一笔，面板又呼地出来，那两下 Esc 白按。
    func testCollapsedPanelStaysCollapsedUntilTheCellIsClickedAgain() throws {
        let view = try editedView()
        view.toolbar?.onTool?(.rect)
        let panel = try XCTUnwrap(view.toolPanel)

        drawRect(in: view, from: CGPoint(x: 140, y: 300), to: CGPoint(x: 240, y: 360))
        XCTAssertEqual(view.annotations.count, 1)
        view.keyDown(with: try escKey())
        XCTAssertTrue(panel.isHidden)

        view.undo()                       // 走 syncToolbar → syncPanel
        XCTAssertTrue(panel.isHidden, "撤销把收掉的面板又弹出来了")
        view.redo()
        XCTAssertTrue(panel.isHidden, "重做也是")

        // 再点那一格 = 重新选工具，这一下该弹回来（用户明摆着又要调属性）。
        view.toolbar?.onTool?(.rect)      // 第一次点：摘掉工具
        view.toolbar?.onTool?(.rect)      // 第二次点：重新选中
        XCTAssertFalse(panel.isHidden, "重新点格子后面板该回来")
    }

    /// 面板展开的调色板那一行也得跟着收：只收面板不清 `paletteTarget`，下次浮出时
    /// 用户看到的还是展开状态，等于没收。
    func testEscClearsTheExpandedPaletteRow() throws {
        let view = try editedView()
        view.toolbar?.onTool?(.rect)
        let panel = try XCTUnwrap(view.toolPanel)
        panel.press(cell: "color")
        XCTAssertNotNil(panel.paletteTarget, "⌄ 没把调色板那一行展开")

        view.keyDown(with: try escKey())
        XCTAssertTrue(panel.isHidden)
        XCTAssertNil(panel.paletteTarget, "调色板行还挂着，下次浮出仍是展开态")
    }

    /// ⌘C 不吃面板：面板上那串数字和色块都是 `draw(_:)` 现画的，没有文本框可选，
    /// 「复制面板内容」这件事根本不存在。这条钉住的是另一头 —— 面板别把 ⌘C 抢走，
    /// 也别让它顺手把会话结束掉（编辑态里 ⌘C 唯一有活干的时候是放大镜还在）。
    func testCommandCLeavesThePanelAndSessionAlone() throws {
        let view = try editedView()
        var cancelled = 0
        view.onCancel = { cancelled += 1 }
        view.toolbar?.onTool?(.rect)
        let panel = try XCTUnwrap(view.toolPanel)

        let commandC = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                      modifierFlags: [.command], timestamp: 0,
                                                      windowNumber: 0, context: nil,
                                                      characters: "c", charactersIgnoringModifiers: "c",
                                                      isARepeat: false, keyCode: 8))
        view.keyDown(with: commandC)
        XCTAssertFalse(panel.isHidden, "⌘C 不该动面板")
        XCTAssertEqual(cancelled, 0, "⌘C 不该丢会话")
        XCTAssertEqual(view.phase, .editing)
    }

    // MARK: - 调色板：七档预设 + 彩色自定义（用户 2026-10-19 的口径）

    /// 预设档就是用户点名的那七色，顺序也照他给的来。第一档必须是红 ——
    /// 「每格工具默认红」取的就是 `palette[0]`（那头由 `testEveryToolStartsRed` 管）。
    func testPresetColorsAreRedYellowGreenBlueWhiteGrayBlack() throws {
        let names = try ScreenshotToolbarView.palette.map { try hueName(of: $0) }
        XCTAssertEqual(names, ["红", "黄", "绿", "蓝", "白", "灰", "黑"])
    }

    /// 这一行**平铺**：头一格贴左边内边距、末一格贴右边内边距、中间等分。
    ///
    /// 早先是左对齐一格 4pt 排过去，右边留一大截空 —— 看着像这行少画了几格。这条把
    /// 「两头都顶到边、间距还相等」钉死：少一格、又缩回左对齐、或者间距算歪了，都会红。
    /// 主色一行 8 格（七档 + 自定义）和边框那一行 9 格（多一枚「无」）各验一遍。
    func testPaletteRowSpansTheWholeBubble() throws {
        let container = CGRect(x: 0, y: 0, width: 1200, height: 900)
        for (tool, opener, expected) in [(ScreenshotTool.rect, "color", 8),
                                         (.text, "border", 9)] {
            let host = NSView(frame: container)
            let panel = ScreenshotToolPanelView(frame: .zero)
            host.addSubview(panel)
            panel.show(tool: tool, style: .default(for: tool),
                       cell: CGRect(x: 400, y: 400, width: 32, height: 32), in: container)
            panel.press(cell: opener)
            let ids = panel.elementsOnPanel.filter {
                $0 == "none" || $0 == "custom" || $0.hasPrefix("palette.")
            }
            XCTAssertEqual(ids.count, expected, "\(tool) 的调色板行列数不对：\(ids)")
            XCTAssertEqual(ids.last, "custom", "自定义那一格得排在最后：\(ids)")
            let rects = try ids.map { try XCTUnwrap(panel.actionableRect(forCell: $0), $0) }
            let pad = ScreenshotToolPanelView.padding
            XCTAssertEqual(rects.first!.minX, panel.frame.minX + pad, accuracy: 0.01,
                           "\(tool)：头一格没贴左内边距")
            XCTAssertEqual(rects.last!.maxX, panel.frame.maxX - pad, accuracy: 0.01,
                           "\(tool)：末一格没贴右内边距，右边就是那块留白")
            let gaps = zip(rects, rects.dropFirst()).map { $1.minX - $0.maxX }
            for gap in gaps {
                XCTAssertEqual(gap, gaps.first!, accuracy: 0.01, "\(tool)：格间距不平分")
                XCTAssertGreaterThan(gap, 0, "\(tool)：格子挤叠在一起了")
            }
            XCTAssertEqual(rects.first!.width, rects.last!.width, accuracy: 0.01,
                           "\(tool)：色块大小不一致")
        }
    }

    /// 点彩色格 → 取色器开在**当前那一档**上，挑回来的颜色进主色，并吃到下一笔上。
    ///
    /// 判据走替身，不走 `NSColorPanel`：那块系统面板不在本视图的 `draw` 里，离屏拍不到，
    /// 「弹了没、颜色进的是哪一档」只有替身说得上话。
    func testCustomCellFeedsThePickedColorIntoTheMainColor() throws {
        let view = try editedView(CGRect(x: 100, y: 60, width: 300, height: 400))
        view.toolbar?.onTool?(.rect)
        let panel = try XCTUnwrap(view.toolPanel)
        let picker = FakeColorPicker()
        panel.colorPicker = picker

        panel.press(cell: "color")
        panel.press(cell: "custom")
        XCTAssertEqual(picker.shows, [ScreenshotToolbarView.palette[0]],
                       "取色器该开在当前那枚红上，不是开在默认黑上")
        XCTAssertTrue(panel.customPickerOpen)
        // 行不能收：用户是来连着试色的，把落点抽掉等于下一次挑色没处放。
        XCTAssertNotNil(panel.paletteTarget, "挑自定义色就把调色板行收了，连着调第二第三次没门")

        let purple = NSColor(srgbRed: 0.6, green: 0.2, blue: 0.9, alpha: 1)
        picker.pick(purple)
        XCTAssertEqual(panel.style.color, purple)
        XCTAssertTrue(panel.customColorSelected, "七档一个都没亮，看着像没生效")
        // 一次拖动回吐多次也认（`isContinuous` 那条路的契约）。
        picker.pick(NSColor(srgbRed: 0.1, green: 0.7, blue: 0.8, alpha: 1))

        drawRect(in: view, from: CGPoint(x: 130, y: 90), to: CGPoint(x: 260, y: 170))
        XCTAssertEqual(view.annotations.last?.color, NSColor(srgbRed: 0.1, green: 0.7, blue: 0.8, alpha: 1),
                       "面板上的自定义色没落到下一笔")
    }

    /// 从「边框」那格展开后点彩色格，改的必须只有边框 —— 落点认错一档，用户看到的
    /// 就是「我明明在调边框，字怎么变色了」。
    func testCustomCellFromTheBorderTargetOnlyChangesBorder() throws {
        let view = try editedView(CGRect(x: 100, y: 60, width: 300, height: 400))
        view.toolbar?.onTool?(.text)
        let panel = try XCTUnwrap(view.toolPanel)
        let picker = FakeColorPicker()
        panel.colorPicker = picker

        panel.press(cell: "border")
        panel.press(cell: "custom")
        let purple = NSColor(srgbRed: 0.6, green: 0.2, blue: 0.9, alpha: 1)
        picker.pick(purple)
        XCTAssertEqual(panel.style.borderColor, purple)
        XCTAssertEqual(panel.style.color, ScreenshotToolbarView.palette[0], "主色被边框那档带跑了")
        XCTAssertNil(panel.style.backgroundColor, "背景跟着一起变色就是落点串了")

        let text = try commitText(in: view, at: CGPoint(x: 130, y: 90), string: "标注")
        XCTAssertEqual(text.borderColor, purple)
        XCTAssertEqual(text.color, ScreenshotToolbarView.palette[0])
    }

    /// 取色器的三个收尾入口都得关掉那块系统面板：Esc 收面板、改挑预设、换工具。
    /// 漏任何一个，桌面上就飘一块没人认领的取色窗。
    func testTheColorPanelClosesOnEveryExit() throws {
        for exit in [PanelExit.esc, .preset, .switchTool, .sessionEnd] {
            let view = try editedView()
            view.toolbar?.onTool?(.rect)
            let panel = try XCTUnwrap(view.toolPanel)
            let picker = FakeColorPicker()
            panel.colorPicker = picker
            panel.press(cell: "color")
            panel.press(cell: "custom")
            XCTAssertEqual(picker.shownCount, 1, "\(exit) 的前提：取色器得先开起来")

            switch exit {
            case .esc: view.keyDown(with: try escKey())
            case .preset: panel.press(cell: "palette.2")
            case .switchTool: view.toolbar?.onTool?(.arrow)
            case .sessionEnd: view.closeToolColorPicker()
            }
            XCTAssertEqual(picker.dismissedCount, 1, "\(exit) 之后系统取色面板还开着")
            XCTAssertFalse(panel.customPickerOpen, "\(exit) 之后还记着开着")
        }
    }

    private enum PanelExit { case esc, preset, switchTool, sessionEnd }

    /// 按通道范围给预设档起个名，比逐通道写死数值好读，也照样能抓出错档。
    private func hueName(of color: NSColor) throws -> String {
        let s = try XCTUnwrap(color.usingColorSpace(.sRGB))
        let (r, g, b) = (s.redComponent, s.greenComponent, s.blueComponent)
        func near(_ v: CGFloat, _ t: CGFloat) -> Bool { abs(v - t) < 0.06 }
        if near(r, 1) && near(g, 1) && near(b, 1) { return "白" }
        if r < 0.1 && g < 0.1 && b < 0.1 { return "黑" }
        if near(r, g) && near(g, b) { return "灰" }
        if r > 0.8 && g < 0.5 && b < 0.5 { return "红" }
        if r > 0.8 && g > 0.6 && b < 0.3 { return "黄" }
        if g > 0.6 && r < 0.5 && b < 0.5 { return "绿" }
        if b > 0.8 && r < 0.5 { return "蓝" }
        return "不认识(\(r),\(g),\(b))"
    }

    /// 记账的取色器替身。真机上换成 `SystemColorPicker`（`NSColorPanel`），
    /// 测试靠它回答两件事：开在哪一档上、挑回来的颜色进了哪一档。
    private final class FakeColorPicker: ScreenshotColorPicking {
        private(set) var shows: [NSColor] = []
        private(set) var dismissedCount = 0
        private var changed: ((NSColor) -> Void)?
        var shownCount: Int { shows.count }
        func show(initial: NSColor, changed: @escaping (NSColor) -> Void) {
            shows.append(initial)
            self.changed = changed
        }
        func dismiss() { changed = nil; dismissedCount += 1 }
        /// 模拟用户在色轮上选了一次。
        func pick(_ color: NSColor) { changed?(color) }
    }

    // MARK: - 面板不超出条子左右（用户 2026-10-19 的第 1 条）

    /// 横向允许范围是个纯函数，直接喂 rect 判：钳位这条不能拿面板自己的 `frame` 反推，
    /// 不然等于让被测对象给自己作证 —— 钳错方向时它自己也说「我就该待在这儿」。
    func testHorizontalSpanPrefersTheBarAndFallsBackToTheScreen() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w = ScreenshotToolPanelView.width
        let margin = ScreenshotSelectionView.toolbarMargin
        XCTAssertEqual(ScreenshotToolPanelView.xSpan(panelWidth: w, container: screen, limits: nil),
                       margin...(1440 - margin), "没给条子时该还是原来那套屏内钳位")
        // 条子整个在屏里：允许范围收到条子的左右沿。
        XCTAssertEqual(ScreenshotToolPanelView.xSpan(panelWidth: w, container: screen,
                                                     limits: CGRect(x: 600, y: 800, width: 500, height: 42)),
                       600...1100)
        // 条子被屏边切掉一半，交集还塞得下面板：取交集，两头都不许跑出屏。
        XCTAssertEqual(ScreenshotToolPanelView.xSpan(panelWidth: w, container: screen,
                                                     limits: CGRect(x: 1100, y: 800, width: 500, height: 42)),
                       1100...(1440 - margin))
        // 交集比面板还窄（条子大半截在屏外）：退回屏内 —— 探出条子是难看，跑出屏是点不到。
        XCTAssertEqual(ScreenshotToolPanelView.xSpan(panelWidth: w, container: screen,
                                                     limits: CGRect(x: 1300, y: 800, width: 500, height: 42)),
                       margin...(1440 - margin))
        // 条子比面板还窄：退回屏内 —— 探出条子是难看，跑出屏是点不到。
        XCTAssertEqual(ScreenshotToolPanelView.xSpan(panelWidth: w, container: screen,
                                                     limits: CGRect(x: 700, y: 800, width: 100, height: 42)),
                       margin...(1440 - margin))
    }

    /// 面板横向不许探出注解条的左右沿。**挑首尾两格**做判据：锚在中间那格时屏边钳不到、
    /// 面板天然待在条子里，那条断言就成了运气。
    ///
    /// 反向对照紧跟着：把限制摘掉用同一个锚点重摆一次，同一格确实探出条子 —— 探不出
    /// 就说明上面两条是空转。
    func testPanelDoesNotStickleOutOfTheBar() throws {
        let view = try editedView(CGRect(x: 100, y: 100, width: 1200, height: 600))
        let bar = try XCTUnwrap(view.toolbar)
        let anchors = ScreenshotTool.allCases.filter { $0.hasStylePanel }
        func midX(_ tool: ScreenshotTool) -> CGFloat { bar.cellRect(for: tool)?.midX ?? 0 }
        let sorted = anchors.sorted { midX($0) < midX($1) }
        let left = try XCTUnwrap(sorted.first)
        let right = try XCTUnwrap(sorted.last)
        XCTAssertNotEqual(left, right, "首尾两格是同一格，说明能弹面板的工具只剩一个")

        for tool in [left, right] {
            view.toolbar?.onTool?(tool)
            XCTAssertEqual(view.tool, tool, "前提：\(tool) 没被选中")
            let panel = try XCTUnwrap(view.toolPanel, "\(tool) 的面板没浮出")
            XCTAssertGreaterThanOrEqual(panel.frame.minX, bar.frame.minX - 0.01,
                                        "\(tool) 那一格的面板探到条子左边外：\(panel.frame) ∉ \(bar.frame)")
            XCTAssertLessThanOrEqual(panel.frame.maxX, bar.frame.maxX + 0.01,
                                     "\(tool) 那一格的面板探到条子右边外：\(panel.frame) ∉ \(bar.frame)")
        }

        // 反向对照其一（左）：同一格、同一个容器，把限制摘掉重摆一次 —— 首格那面板确实朝左
        // 探出条子外一截。探不出来说明上面两条只是「条子够宽」的运气。
        let host = NSView(frame: view.bounds)
        let bare = ScreenshotToolPanelView(frame: .zero)
        host.addSubview(bare)
        bare.show(tool: left, style: .default(for: left),
                  cell: try XCTUnwrap(bar.cellRect(for: left)), in: view.bounds)
        XCTAssertGreaterThan(bar.frame.minX - bare.frame.minX, 40,
                             "摘掉限制后横向就没探出条子，上面几条是空转：\(bare.frame) / \(bar.frame)")
        view.toolbar?.onTool?(left)
        let fixed = try XCTUnwrap(view.toolPanel)
        XCTAssertEqual(fixed.frame.minX, bar.frame.minX, accuracy: 0.01,
                       "修好之后没贴在条子左沿，等于没被钳：\(fixed.frame)")

        // 反向对照其二（右）：工具格都排在条子左半段，末格中心离右沿还有一截，拿真格子
        // 测不出右探 —— 这里喂一个钉在条子右端的锚点，走的是同一个 `place`，钳位两侧同一份。
        let rightEdgeCell = CGRect(x: bar.frame.maxX - 24, y: bar.frame.minY, width: 20, height: 20)
        let bareRight = ScreenshotToolPanelView(frame: .zero)
        host.addSubview(bareRight)
        bareRight.show(tool: .rect, style: .default(for: .rect), cell: rightEdgeCell, in: view.bounds)
        XCTAssertGreaterThan(bareRight.frame.maxX - bar.frame.maxX, 40,
                             "右端锚点摘掉限制也没探出：\(bareRight.frame) / \(bar.frame)")
        bareRight.show(tool: .rect, style: .default(for: .rect), cell: rightEdgeCell,
                       in: view.bounds, within: bar.frame)
        XCTAssertEqual(bareRight.frame.maxX, bar.frame.maxX, accuracy: 0.01,
                       "右端锚点钳过之后没贴到条子右沿：\(bareRight.frame)")
    }

    /// 展开调色板那一行之后仍然守条子的左右沿：`toggle()` 会重新摆一次位，忘了带上限制
    /// 就成了「选中工具时守规矩，一挑色又跑出去」。
    ///
    /// 锚点必须挑**最左那一格**：能弹面板的工具全挤在条子左半段，锚在右边任一格时面板
    /// 天然待在条子里，限制带不带都一样 —— 上一版就是拿末格测的，变异「`toggle` 不传
    /// 限制」照样全绿。首格摘掉限制会朝左探出条子 40pt 以上（同文件反向对照已实测）。
    ///
    /// 开、收两条路分别钉：`toggle()` 开行、`hidePalette()` 收行各自 `place` 一次，
    /// 少带限制的是哪一个都能单独红。
    func testThePaletteRowKeepsRespectingTheBar() throws {
        let view = try editedView(CGRect(x: 100, y: 100, width: 1200, height: 600))
        let bar = try XCTUnwrap(view.toolbar)
        let anchors = ScreenshotTool.allCases.filter { $0.hasStylePanel }
        let left = try XCTUnwrap(anchors.min(by: { bar.cellRect(for: $0)!.midX
                                                 < bar.cellRect(for: $1)!.midX }))
        view.toolbar?.onTool?(left)
        let panel = try XCTUnwrap(view.toolPanel)
        // 前提：这一格不钳就待不住 —— 面板左沿正正贴在条子左沿上，钳位是真的在起作用。
        XCTAssertEqual(panel.frame.minX, bar.frame.minX, accuracy: 0.01,
                       "前提没成立：\(left) 的面板本来就没超出条子，下面几条成了空转：\(panel.frame) / \(bar.frame)")

        panel.press(cell: "color")
        XCTAssertEqual(panel.frame.minX, bar.frame.minX, accuracy: 0.01,
                       "展开色板那一行时把限制弄丢了，面板朝左探出条子：\(panel.frame)")
        XCTAssertLessThanOrEqual(panel.frame.maxX, bar.frame.maxX + 0.01,
                                 "展开色板那一行后超出条子右沿：\(panel.frame)")

        panel.press(cell: "palette.2")       // 挑一个预设色：走 hidePalette 那一次 place
        XCTAssertEqual(panel.frame.minX, bar.frame.minX, accuracy: 0.01,
                       "收掉色板那一行时把限制弄丢了：\(panel.frame)")
        XCTAssertNil(panel.paletteTarget, "前提：那一行确实收了")

        panel.press(cell: "color")           // 再开
        XCTAssertEqual(panel.frame.minX, bar.frame.minX, accuracy: 0.01,
                       "第二次展开又不守条子了：\(panel.frame)")
        panel.press(cell: "color")           // 再收（toggle 关的那一路，不是挑色关的）
        XCTAssertEqual(panel.frame.minX, bar.frame.minX, accuracy: 0.01,
                       "第二次收起来又不守条子了：\(panel.frame)")
    }

    /// 挑完一个预设色，那一行收起时面板要连着把多出来的一行高度缩回原形：只重排格子
    /// 不缩 frame，底沿（尖那头）会空出一条谁也点不着的带子。
    func testPickingAPresetShrinksThePanelBack() throws {
        let view = try editedView(CGRect(x: 100, y: 100, width: 1200, height: 600))
        view.toolbar?.onTool?(.rect)
        let panel = try XCTUnwrap(view.toolPanel)
        let closed = panel.frame.height

        panel.press(cell: "color")
        XCTAssertGreaterThan(panel.frame.height, closed, "前提：展开那一行确实长高了")

        panel.press(cell: "palette.2")
        XCTAssertNil(panel.paletteTarget, "挑完色那一行该收起")
        XCTAssertEqual(panel.frame.height, closed, accuracy: 0.5,
                       "行收了 frame 没缩：底沿空出一带 \(closed) → \(panel.frame.height)")
        for id in panel.elementsOnPanel where id.hasPrefix("palette.") {
            XCTFail("收起后还排着 \(id)")
        }
    }

    /// 文字那一格多一行样式，同样按条子收 —— 三行的面板比两行高，横向限制不该因此松动。
    func testTheTextStyleRowAlsoStaysInsideTheBar() throws {
        let view = try editedView(CGRect(x: 100, y: 100, width: 1200, height: 600))
        let bar = try XCTUnwrap(view.toolbar)
        view.toolbar?.onTool?(.text)
        let panel = try XCTUnwrap(view.toolPanel)
        panel.press(cell: "border")         // 9 格那一行：比主色一行更宽的一排
        XCTAssertGreaterThanOrEqual(panel.frame.minX, bar.frame.minX - 0.01)
        XCTAssertLessThanOrEqual(panel.frame.maxX, bar.frame.maxX + 0.01,
                                 "文字的面板超出条子：\(panel.frame) ∉ \(bar.frame)")
    }

    // MARK: - 辅助

    /// Esc 那条 keyDown。`characters` 给的是真 Esc 的 0x1B：`keyDown(with:)` 只看
    /// keyCode，但事件得长得像键盘上来的，不然以后谁改成按字符判定，这条用例不会红。
    private func escKey() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                       isARepeat: false, keyCode: 53))
    }

    /// 成品图落盘，人眼过一遍：色值判据只能说明「那块有这种颜色」，说不清框是不是歪了。
    private func dump(_ bitmap: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/macstroke-screenshot-check", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        NSLog("%@", "[ScreenshotTests] 成品图：\(url.path)")
    }

    /// 把滑杆按到最右端（`setValue(fromTrackX:)` 自己会钳进量程，正好按到端点就行）。
    private func setSliderToMax(_ panel: ScreenshotToolPanelView) {
        let track = panel.actionableRect(forCell: "slider")
        panel.press(cell: "slider", trackX: (track?.maxX ?? 0) - panel.frame.minX)
    }

    private func drawRect(in view: ScreenshotSelectionView, from: CGPoint, to: CGPoint) {
        view.pointerDown(from, clickCount: 1)
        view.pointerDragged(to: to)
        view.pointerReleased()
    }

    /// 走真链路写字：点选区起输入框 → 填内容 → 发出输入框自己挂的那个 action
    /// （回车那一条路就是 `NSControl` 把 action 发给 target，这里用 `NSApp.sendAction`
    /// 走同一次派发，不去直接调遮罩上的私有方法）。
    private func commitText(in view: ScreenshotSelectionView, at point: CGPoint,
                            string: String) throws -> ScreenshotAnnotation {
        view.pointerDown(point, clickCount: 1)
        let field = try XCTUnwrap(view.textEditor, "点选区没起输入框")
        field.stringValue = string
        let action = try XCTUnwrap(field.action, "输入框没挂提交动作")
        XCTAssertTrue(NSApp.sendAction(action, to: try XCTUnwrap(field.target), from: field),
                      "提交动作没能打到遮罩上")
        return try XCTUnwrap(view.annotations.last, "回车后没落笔")
    }

    private func overlay(size: NSSize = NSSize(width: 1440, height: 900)) throws
        -> ScreenshotSelectionView {
        let image = try XCTUnwrap(QuadrantPattern.image(width: Int(size.width), height: Int(size.height)))
        let shot = try XCTUnwrap(ScreenshotFrame(image: image, pointSize: size))
        let view = ScreenshotSelectionView(shot: shot)
        ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: size)).contentView = view
        return view
    }

    /// 拖好选区、进了编辑态、条子已摆位的遮罩。默认选区给得足够高：面板从条子那一格往上浮，
    /// 会压住选区底部一条，用例要点的地方都在上半部。
    ///
    /// `defaultTool` 故意留空：条子的回调是「再点同一格 = 摘掉工具」，这里预装了矩形，
    /// 用例再 `onTool?(.rect)` 就成了取消选择，测的却是另一条路。
    private func editedView(_ rect: CGRect = CGRect(x: 100, y: 100, width: 300, height: 300),
                            defaultTool: ScreenshotTool? = nil) throws -> ScreenshotSelectionView {
        let view = try overlay()
        view.defaultTool = defaultTool
        view.pointerDown(rect.origin, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: rect.maxX, y: rect.maxY))
        view.pointerReleased()
        XCTAssertEqual(view.phase, .editing)
        return view
    }
}
