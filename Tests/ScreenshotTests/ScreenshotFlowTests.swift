//
//  ScreenshotFlowTests.swift
//
//  「选 → 就地改 → 出图」这条状态机的取证。NSEvent 造不出来，所以判定逻辑全部收在
//  pointer* 几个方法里，这里直接喂点坐标驱动。
//
//  选和改发生在同一层遮罩上（注解坐标 = 整屏 flipped 视图的点坐标），所以这里既验
//  picking 的吸附/拖选，也验 editing 的工具、撤销和出口。
//

import AppKit
import Storage
import XCTest

@testable import Screenshot

final class ScreenshotFlowTests: XCTestCase {
    // MARK: - picking：选哪块

    /// 拖出一个选区：松手进编辑态，注解条浮在选区下沿外侧。
    func testDragEndsInEditingWithToolbar() throws {
        // 1440×900：条子 791pt 宽，800pt 的屏里「对着选区居中」会被留白钳位钳掉，
        // 这条要验的就是居中本身，得给一块放得下的屏。
        let view = try overlay(size: NSSize(width: 1440, height: 900))
        view.pointerDown(CGPoint(x: 500, y: 100), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 700, y: 200))
        view.pointerReleased()

        XCTAssertEqual(view.selection, CGRect(x: 500, y: 100, width: 200, height: 100))
        XCTAssertEqual(view.phase, .editing)
        let bar = try XCTUnwrap(view.toolbar, "松手就该把注解条亮出来")
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.frame.minY, 208, "条子摆在选区下沿外面 8pt")
        XCTAssertEqual(bar.frame.width, bar.preferredWidth, accuracy: 0.5)
        XCTAssertEqual(bar.frame.midX, view.selection.midX, accuracy: 0.5, "横向对着选区居中")
    }

    /// 手抖出来的几个像素不算选区：清空重拖，而不是裁出一条 1px 的线。
    func testTinyDragLeavesNoSelection() throws {
        let view = try overlay()
        view.pointerDown(CGPoint(x: 100, y: 100), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 102, y: 101))
        view.pointerReleased()
        XCTAssertEqual(view.selection, .zero)
        XCTAssertEqual(view.phase, .picking, "没选成区就不该进编辑态")
    }

    /// 鼠标划过 → 亮出那个窗；按下不拖 → 认下它并直接进编辑态。
    func testClickWithoutDragAcceptsSnappedWindow() throws {
        let view = try overlay()
        view.windows = [CGRect(x: 100, y: 80, width: 240, height: 160)]
        view.pointerMoved(CGPoint(x: 150, y: 150))
        XCTAssertEqual(view.hover, CGRect(x: 100, y: 80, width: 240, height: 160))

        view.pointerDown(CGPoint(x: 150, y: 150), clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 80, width: 240, height: 160))
        XCTAssertNil(view.hover, "已经把它变成选区了，预览态必须收掉，否则两条亮区重叠")
        XCTAssertEqual(view.phase, .editing)
    }

    /// 桌面上（没有普通窗的那几条边）吸的是**整块屏**：点一下就得到一张全屏截图，
    /// 不用手拖到四个角。
    func testOffWindowSnapsToWholeScreen() throws {
        let view = try overlay()
        view.windows = [CGRect(x: 100, y: 80, width: 240, height: 160)]
        view.pointerMoved(CGPoint(x: 5, y: 5))
        XCTAssertEqual(view.hover, view.bounds)

        view.pointerDown(CGPoint(x: 5, y: 5), clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(view.selection, view.bounds, "整块屏 = 全屏截图")
        XCTAssertEqual(view.phase, .editing)
    }

    /// 还没挪过鼠标时不该凭空亮一块，也不该直接出图。
    func testNothingIsSnappedBeforeTheFirstMove() throws {
        let view = try overlay()
        view.windows = [CGRect(x: 100, y: 80, width: 240, height: 160)]
        XCTAssertNil(view.hover)
        view.pointerDown(CGPoint(x: 5, y: 5), clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(view.selection, .zero)
        XCTAssertEqual(view.phase, .picking)
    }

    // MARK: - editing：就地画注解

    /// 选了矩形工具后拖 → 一条注解；工具保持选中，接着画第二条。
    func testToolDragAppendsAnnotation() throws {
        let view = try editedView()
        view.tool = .rect
        view.pointerDown(CGPoint(x: 120, y: 120), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 240, y: 180))
        XCTAssertEqual(view.draft?.rect, CGRect(x: 120, y: 120, width: 120, height: 60))
        view.pointerReleased()
        XCTAssertNil(view.draft)
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.annotations[0].tool, .rect)

        view.pointerDown(CGPoint(x: 140, y: 140), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 190, y: 160))
        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 2, "工具没取消选中，接着画第二条")
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 100, width: 200, height: 100),
                       "选区内的拖动只画注解，不能把选区改掉")
    }

    /// 手抖（不到 3px）不进列表，也不吃掉上一次的工具选择。
    func testJitterDraftIsDiscarded() throws {
        let view = try editedView()
        view.tool = .mosaic
        view.pointerDown(CGPoint(x: 150, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 151, y: 151))
        view.pointerReleased()
        XCTAssertTrue(view.annotations.isEmpty)
        XCTAssertEqual(view.tool, .mosaic, "丢弃一条抖动不该把工具也取消掉")
    }

    /// 序号自动往后排，撤销后下一个编号回到被撤的那个。
    func testNumberingFollowsUndo() throws {
        let view = try editedView()
        view.tool = .number
        view.pointerDown(CGPoint(x: 120, y: 120), clickCount: 1)
        view.pointerDown(CGPoint(x: 140, y: 150), clickCount: 1)
        XCTAssertEqual(view.annotations.map { $0.number }, [1, 2])
        view.undo()
        XCTAssertEqual(view.annotations.count, 1)
        view.pointerDown(CGPoint(x: 160, y: 170), clickCount: 1)
        XCTAssertEqual(view.annotations.last?.number, 2, "撤销掉的 2 该被重新用上")
    }

    /// 箭头只拖一条水平线（高度 0）也留着；只按宽度判断会误杀横着的箭头。
    func testThinArrowSurvives() throws {
        let view = try editedView()
        view.tool = .arrow
        view.pointerDown(CGPoint(x: 110, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 290, y: 150))
        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.annotations[0].rect.height, 0)
    }

    /// 椭圆和矩形共用两个对角点：框一致，但只有矩形该被认成框。
    func testEllipseDragUsesTheTwoPointBox() throws {
        let view = try editedView()
        view.tool = .ellipse
        view.pointerDown(CGPoint(x: 120, y: 120), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 240, y: 180))
        XCTAssertEqual(view.draft?.rect, CGRect(x: 120, y: 120, width: 120, height: 60))
        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.annotations[0].tool, .ellipse)
        XCTAssertTrue(view.annotations[0].points.isEmpty, "椭圆只有两个对角点，不该带上轨迹")
    }

    /// 画笔：拖动期间整条轨迹都在 draft 上，松手原样进列表（点列抽过稀）。
    func testPenDragKeepsTheWholePath() throws {
        let view = try editedView()
        view.tool = .pen
        view.pointerDown(CGPoint(x: 120, y: 120), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 121, y: 121))
        view.pointerDragged(to: CGPoint(x: 160, y: 180))
        view.pointerDragged(to: CGPoint(x: 200, y: 120))
        XCTAssertEqual(view.draft?.points.count, 3, "1.4pt 的抖动不该进点列")
        view.pointerReleased()

        let pen = try XCTUnwrap(view.annotations.first, "松手该留下一条注解")
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(pen.points, [CGPoint(x: 120, y: 120), CGPoint(x: 160, y: 180),
                                    CGPoint(x: 200, y: 120)])
        XCTAssertEqual(pen.rect, CGRect(x: 120, y: 120, width: 80, height: 60),
                       "包围盒按整条轨迹算，不然一个 V 会被当成 0 高的线")
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 100, width: 200, height: 100),
                       "画轨迹不能把选区拖走")
    }

    /// 只按下不拖 = 轨迹上孤零零一个点，画不出东西，跟矩形的手抖一样丢掉。
    func testPenTapWithoutDragIsDiscarded() throws {
        let view = try editedView()
        view.tool = .pen
        view.pointerDown(CGPoint(x: 150, y: 150), clickCount: 1)
        view.pointerReleased()
        XCTAssertTrue(view.annotations.isEmpty)
        XCTAssertEqual(view.tool, .pen, "丢掉一次点击不该把画笔也取消选中")
    }

    /// 枚举里添了工具、条子上漏一个，用户就压根选不到它 —— 看代码看不出来，只能对着
    /// 装配好的条子数。
    func testEveryToolHasAButtonOnTheBar() throws {
        let bar = ScreenshotToolbarView(frame: .zero)
        XCTAssertEqual(bar.toolsOnBar, Set(ScreenshotTool.allCases),
                       "条子上的工具格和枚举对不上：\(Set(ScreenshotTool.allCases).subtracting(bar.toolsOnBar)) 没地方点")
    }

    /// 条子的摆法就是需求本身（照 QQ 那条）：形状类 → 贴图/裁剪 → 颜色与线宽 →
    /// 撤销重做 → 出口。漏一格、多一格、摆错顺序都算没照着做。
    func testBarFollowsTheQQOrder() throws {
        XCTAssertEqual(ScreenshotToolbarView(frame: .zero).elementsOnBar, [
            "tool.rect", "tool.ellipse", "tool.arrow", "tool.pen", "tool.text", "tool.number",
            "tool.mosaic",
            "pin", "crop", "ocr",
            "color", "color", "color", "color", "color", "width", "width", "width",
            "undo", "redo",
            "save", "cancel", "copy",
        ])
    }

    // MARK: - 悬停功能提示

    /// 真链路的两步：先从窗口根做命中拿到那一格，再把 mouseMoved 事件发给它 —— 响应链
    /// 要能把事件从格子上送回遮罩，气泡才冒得出来。
    ///
    /// 为什么不直接 `window.sendEvent`：离屏那扇窗没上屏，AppKit 的 mouse-moved 派发
    /// 走的是它自己的 tracking 记账，喂不进去（实测事件被丢掉）。窗内派发这一段只能装机
    /// 用鼠标验，这里覆盖的是最容易断的那一段：条子的 hitTest 把事件截在格子上，而处理
    /// 提示的代码在遮罩 —— 响应链一断，测试全绿、真机上气泡压根不冒。
    func testTipComesThroughTheRealEventChain() throws {
        let view = try editedView(CGRect(x: 300, y: 100, width: 300, height: 200),
                                  size: NSSize(width: 1440, height: 900))
        let bar = try XCTUnwrap(view.toolbar)
        let window = try XCTUnwrap(view.window)
        let cell = try XCTUnwrap(bar.actionableRects[3].offsetBy(dx: bar.frame.minX, dy: bar.frame.minY))
        // 窗口坐标不 flipped，视图 flipped：换一次 y。
        let inWindow = NSPoint(x: cell.midX, y: view.bounds.height - cell.midY)

        let target = try XCTUnwrap(window.contentView?.hitTest(inWindow), "从窗口根命中不到那一格")
        XCTAssertNotIdentical(target, view, "命中的应该是条子上的格子，不是遮罩本身")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: inWindow,
                                                     modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 0, pressure: 0),
                                  "造不出 mouseMoved 事件")
        target.mouseMoved(with: event)

        let tip = try XCTUnwrap(view.tipView, "事件停在格子上就该顺着响应链冒到遮罩")
        XCTAssertFalse(tip.isHidden)
        XCTAssertEqual(tip.frame.midX, cell.midX, accuracy: 0.5, "提示要对着被指到的那一格")
    }

    /// 一按下去、或移出格子，气泡都得收：它只是「这一格是什么」，没格子可指时留着就成
    /// 了挡内容的板子。
    func testTipHidesOnPressAndWhenPointerLeavesTheBar() throws {
        let view = try editedView()
        let bar = try XCTUnwrap(view.toolbar)
        let cell = try XCTUnwrap(bar.actionableRects[0].offsetBy(dx: bar.frame.minX, dy: bar.frame.minY))
        let onCell = CGPoint(x: cell.midX, y: cell.midY)
        let blankSpot = CGPoint(x: bar.frame.maxX - 1, y: bar.frame.midY)

        view.pointerMoved(onCell)
        XCTAssertEqual(view.tipView?.isHidden, false)
        // 气泡自己不能参与命中，否则它会吃掉那一片的点击（那里本该是「在选区里画注解」）。
        //
        // 必须从窗口根、用**窗口坐标**问：`hitTest` 收的是父视图坐标，而遮罩的父视图是那扇
        // 窗（非 flipped），拿遮罩坐标直接问会落到上下镜像的位置上 —— 那条判断恒真，实测
        // 把放行重写删掉它照样答遮罩自己。
        let shown = try XCTUnwrap(view.tipView)
        let overTip = view.convert(NSPoint(x: shown.frame.midX, y: shown.frame.midY), to: nil)
        let window = try XCTUnwrap(view.window)
        XCTAssertIdentical(window.contentView?.hitTest(overTip), view, "提示是装饰，不该拦点击")
        view.pointerDown(blankSpot, clickCount: 1)
        XCTAssertEqual(view.tipView?.isHidden, true, "按下之后气泡还留着就是挡内容")
        view.pointerReleased()

        view.pointerMoved(onCell)
        XCTAssertEqual(view.tipView?.isHidden, false, "松手后重新悬停还要能再冒出来")
        view.pointerMoved(CGPoint(x: 10, y: 10))
        XCTAssertEqual(view.tipView?.isHidden, true, "移出格子就该收")
    }

    /// 裁剪和重框会把条子收掉，气泡不能留在屏幕上。
    func testTipHidesWhenTheBarGoesAway() throws {
        let view = try editedView()
        let bar = try XCTUnwrap(view.toolbar)
        view.pointerMoved(CGPoint(x: bar.actionableRects[0].midX + bar.frame.minX,
                                  y: bar.actionableRects[0].midY + bar.frame.minY))
        XCTAssertEqual(view.tipView?.isHidden, false)
        view.beginCrop()
        XCTAssertEqual(view.tipView?.isHidden, true, "条子收了气泡还亮着，用户会以为还能按")
    }

    /// 挤到屏边的那一格：气泡整个得留在屏内，并且翻到格子下面去，不能顶出屏。
    func testTipBubbleStaysInsideTheScreen() throws {
        let container = NSRect(x: 0, y: 0, width: 800, height: 500)
        let tip = ScreenshotTipView()
        tip.show("贴着左上角的一格", cell: NSRect(x: 2, y: 2, width: 32, height: 30), in: container)
        XCTAssertEqual(tip.frame.minY, 32 + ScreenshotTipView.gap, accuracy: 0.5,
                       "上面放不下就翻到格子下面")
        XCTAssertGreaterThanOrEqual(tip.frame.minX, 6, "横向也得钳回屏内")
        XCTAssertTrue(container.contains(tip.frame), "整只气泡都得看得见：\(tip.frame)")

        tip.show("贴着右下角的一格", cell: NSRect(x: 770, y: 465, width: 32, height: 30), in: container)
        XCTAssertEqual(tip.frame.maxX, container.maxX - 7, accuracy: 0.5,
                       "右边放不下也得钳回屏内")
        XCTAssertTrue(container.contains(tip.frame), "整只气泡都得看得见：\(tip.frame)")
    }

    /// 条子上每一个可点格子都得有自己的提示，而且**报得对这一格**。
    ///
    /// 三条判据各管一种错：
    /// ① 格子数和文案数相等 —— 漏写一格（少传一个参数，编译器不会拦）；
    /// ② 同一 id 只有一句话、不同 id 之间不撞 —— 复制粘贴漏改，两格串成同一段话；
    /// ③ 按位置查到的那句 == 装配顺序里的那句 —— 位置和文案串线（比如格子换了 frame
    ///    却没跟着换提示），只看前两条查不出来。
    /// 角上那四个内缩 1pt 的点管的是「整格都要有提示」：只在中心有效的话，用户停在
    /// 格子边上就什么也不出，而手不会正好停在中心。
    func testEveryBarCellCarriesItsOwnTip() throws {
        let view = try editedView(CGRect(x: 100, y: 100, width: 1200, height: 200),
                                  size: NSSize(width: 1440, height: 900))
        let bar = try XCTUnwrap(view.toolbar)
        let tips = bar.tipsOnBar
        let cells = bar.actionableRects
        XCTAssertEqual(tips.count, cells.count, "有格子没写提示，也有格子压根没进提示表")
        XCTAssertFalse(tips.contains { $0.text.isEmpty }, "提示不能是空串：那是留了个空位")

        let byID = Dictionary(grouping: tips, by: \.id).mapValues { Set($0.map(\.text)) }
        for (id, texts) in byID {
            XCTAssertEqual(texts.count, 1, "\(id) 那几格文案不一致：\(texts)")
        }
        XCTAssertEqual(Set(byID.values).count, byID.count, "两种不同的格子串了同一句提示")

        // 每格该说什么，这张表在测试里**独立**声明一遍。上面那几条只查得出「漏写」和
        // 「两格撞成同一句」；把相邻两格的文案传错（pin 拿到 crop 那句）时，两格各自仍
        // 有文案、彼此也不撞，前几条全绿 —— 因为 `tipsOnBar` 和按位置查的那条路读的是
        // 同一个 `item.tipText`，等于让实现自证。对着这张表比才查得出串线。
        let expected: [(id: String, key: String)] = [
            ("tool.rect", "Screenshot Rect"), ("tool.ellipse", "Screenshot Ellipse"),
            ("tool.arrow", "Screenshot Arrow"), ("tool.pen", "Screenshot Pen"),
            ("tool.text", "Screenshot Text"), ("tool.number", "Screenshot Number"),
            ("tool.mosaic", "Screenshot Mosaic"),
            ("pin", "Screenshot Pin"), ("crop", "Screenshot Crop"), ("ocr", "Screenshot OCR"),
            ("color", "Screenshot Color"), ("width", "Screenshot Line Width"),
            ("undo", "Screenshot Undo"), ("redo", "Screenshot Redo"),
            ("save", "Screenshot Save"), ("cancel", "Screenshot Cancel"),
            ("copy", "Screenshot Copy"),
        ]
        var idsInOrder: [String] = []
        for tip in tips where idsInOrder.last != tip.id { idsInOrder.append(tip.id) }
        XCTAssertEqual(idsInOrder, expected.map(\.id), "格子种类或顺序和预期不符")
        for (id, key) in expected {
            XCTAssertEqual(tips.first { $0.id == id }?.text, L(key),
                           "\(id) 那一格提示的不是它自己该说的话")
        }

        for (index, cell) in cells.enumerated() {
            let rect = cell.offsetBy(dx: bar.frame.minX, dy: bar.frame.minY)
            for probe in [CGPoint(x: rect.midX, y: rect.midY),
                          CGPoint(x: rect.minX + 1, y: rect.minY + 1),
                          CGPoint(x: rect.maxX - 1, y: rect.minY + 1),
                          CGPoint(x: rect.minX + 1, y: rect.maxY - 1),
                          CGPoint(x: rect.maxX - 1, y: rect.maxY - 1)] {
                view.pointerMoved(probe)
                let tip = try XCTUnwrap(view.tipView, "第 \(index) 格停在 \(probe) 没出提示")
                XCTAssertFalse(tip.isHidden, "第 \(index) 格没出提示")
                XCTAssertEqual(tip.text, tips[index].text,
                               "第 \(index) 格（\(tips[index].id)）报的不是自己那句话")
            }
        }
    }

    /// 停在分隔条和两端留白上不该冒提示：那里没有「这一格是什么」可答，留着就成了一块
    /// 无端压在画面上的板子。
    func testBlankSpotsOnTheBarShowNoTip() throws {
        let view = try editedView(CGRect(x: 100, y: 100, width: 1200, height: 200),
                                  size: NSSize(width: 1440, height: 900))
        let bar = try XCTUnwrap(view.toolbar)
        let cell = try XCTUnwrap(bar.actionableRects.first?.offsetBy(dx: bar.frame.minX,
                                                                    dy: bar.frame.minY))
        view.pointerMoved(CGPoint(x: cell.midX, y: cell.midY))
        XCTAssertEqual(view.tipView?.isHidden, false, "前提：先让气泡出来")

        // 把条子横着扫一遍，取出「不属于任何可点格子」的连续段，每段正中停一次。
        var runs: [[CGFloat]] = []
        var x = bar.frame.minX + 1
        while x < bar.frame.maxX - 1 {
            if bar.hasActionable(atOverlayPoint: CGPoint(x: x, y: bar.frame.midY)) {
                x += 1
                continue
            }
            if runs.last?.last == x - 1 {
                runs[runs.count - 1].append(x)
            } else {
                runs.append([x])
            }
            x += 1
        }
        let blanks = runs.filter { $0.count >= 2 }.map { $0[$0.count / 2] }
        XCTAssertGreaterThanOrEqual(blanks.count, 5, "分隔条比预期少：布局变了，这条判据得跟着改")
        for blank in blanks {
            view.pointerMoved(CGPoint(x: blank, y: bar.frame.midY))
            XCTAssertEqual(view.tipView?.isHidden, true, "停在 \(blank) 这点（空白处）还出提示")
        }
    }

    /// 灭着的格子（此刻按不动的撤销/重做）悬停照样要出提示 —— 用户正因为按不动它，
    /// 才更需要知道它是干什么的。
    func testDisabledCellStillShowsItsTip() throws {
        let view = try editedView(CGRect(x: 100, y: 100, width: 1200, height: 200),
                                  size: NSSize(width: 1440, height: 900))
        let bar = try XCTUnwrap(view.toolbar)
        XCTAssertTrue(bar.disabledElementsOnBar.contains("undo"), "前提：一条注解没画，撤销是灭的")
        let index = try XCTUnwrap(bar.tipsOnBar.firstIndex { $0.id == "undo" })
        let cell = bar.actionableRects[index].offsetBy(dx: bar.frame.minX, dy: bar.frame.minY)

        view.pointerMoved(CGPoint(x: cell.midX, y: cell.midY))
        let tip = try XCTUnwrap(view.tipView, "灭着的格子就不给提示了")
        XCTAssertFalse(tip.isHidden)
        XCTAssertEqual(tip.text, bar.tipsOnBar[index].text)
    }

    /// 气泡压住的那一块还得能画注解：它是装饰，不是第二层遮罩。
    ///
    /// 和 `testTipHidesOnPressAndWhenPointerLeavesTheBar` 里那条窗口命中判据各管一段：
    /// 那条管「AppKit 的命中不会停在气泡上」，这条管「判定树在这块地方照样走画注解」。
    ///
    /// 条子要先挪进选区中间：它默认摆在选区下沿外侧，而气泡中心因此恒在选区下沿内侧
    /// 5pt 处 —— 那正是把手的判定带（`handleSlop` 8pt），按下去会去改选区大小而不是画
    /// 注解，测的就不是这条要测的东西了。
    func testDrawingStillWorksWithTheTipInTheWay() throws {
        let view = try editedView(CGRect(x: 100, y: 100, width: 1200, height: 400),
                                  size: NSSize(width: 1440, height: 900))
        let bar = try XCTUnwrap(view.toolbar)
        let grab = CGPoint(x: bar.frame.maxX - 1, y: bar.frame.midY)
        view.pointerDown(grab, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: grab.x, y: grab.y - 160))
        view.pointerReleased()

        view.tool = .rect
        let cell = try XCTUnwrap(bar.actionableRects[2].offsetBy(dx: bar.frame.minX,
                                                                dy: bar.frame.minY))
        view.pointerMoved(CGPoint(x: cell.midX, y: cell.midY))
        let tip = try XCTUnwrap(view.tipView)
        let spot = CGPoint(x: tip.frame.midX, y: tip.frame.midY)
        XCTAssertTrue(view.selection.contains(spot), "前提：气泡正压在选区内容上：\(tip.frame)")
        XCTAssertNil(ScreenshotSelectionView.handle(at: spot, of: view.selection),
                     "前提：这点不能落在改选区大小的把手带上")

        view.pointerDown(spot, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: spot.x - 80, y: spot.y - 40))
        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 1, "气泡压住的地方按下去画不出注解")
    }

    /// 屏边三种真实摆位下气泡都得整个看得见：选区贴左、贴右，以及用户把条子拖到屏顶
    /// （这时上面放不下，气泡要翻到格子下面）。
    func testTipStaysOnScreenAtRealBarPositions() throws {
        let screen = NSSize(width: 1440, height: 900)
        for selection in [CGRect(x: 0, y: 300, width: 300, height: 200),
                          CGRect(x: 1140, y: 300, width: 300, height: 200)] {
            let view = try editedView(selection, size: screen)
            let bar = try XCTUnwrap(view.toolbar)
            for index in [0, bar.actionableRects.count - 1] {
                let cell = bar.actionableRects[index].offsetBy(dx: bar.frame.minX,
                                                               dy: bar.frame.minY)
                view.pointerMoved(CGPoint(x: cell.midX, y: cell.midY))
                let tip = try XCTUnwrap(view.tipView, "选区在 \(selection) 时第 \(index) 格没提示")
                XCTAssertTrue(view.bounds.contains(tip.frame),
                              "选区 \(selection) 第 \(index) 格：气泡越界 \(tip.frame)")
            }
        }

        // 把条子拖到屏顶：上面放不下那 26pt，气泡必须翻到格子下面而不是顶出屏。
        let view = try editedView(CGRect(x: 500, y: 300, width: 400, height: 200), size: screen)
        let bar = try XCTUnwrap(view.toolbar)
        let grab = CGPoint(x: bar.frame.maxX - 1, y: bar.frame.midY)
        view.pointerDown(grab, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: grab.x, y: grab.y - bar.frame.minY + 12))
        view.pointerReleased()
        XCTAssertLessThan(bar.frame.minY, 30, "前提：条子已经贴到屏顶：\(bar.frame)")
        let cell = try XCTUnwrap(bar.actionableRects[4].offsetBy(dx: bar.frame.minX,
                                                                dy: bar.frame.minY))
        view.pointerMoved(CGPoint(x: cell.midX, y: cell.midY))
        let flipped = try XCTUnwrap(view.tipView)
        XCTAssertEqual(flipped.frame.minY, cell.maxY + ScreenshotTipView.gap, accuracy: 0.5,
                       "上面放不下就该翻到下面")
        XCTAssertTrue(view.bounds.contains(flipped.frame), "翻到下面后越界：\(flipped.frame)")
    }

    // MARK: - 撤销 / 重做

    /// 撤掉的还能放回来；放回来的是同一条（位置、颜色、轨迹都在对象里）。
    func testRedoPutsTheUndoneAnnotationBack() throws {
        let view = try editedView()
        view.tool = .rect
        view.pointerDown(CGPoint(x: 120, y: 120), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 220, y: 180))
        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 1)

        view.undo()
        XCTAssertTrue(view.annotations.isEmpty)
        view.redo()
        XCTAssertEqual(view.annotations.count, 1, "重做该把刚撤掉的那条放回原位")
        XCTAssertEqual(view.annotations.first?.rect, CGRect(x: 120, y: 120, width: 100, height: 60))
    }

    /// 撤掉 A 之后画了 B，就不该还能把 A 塞回 B 后面 —— 那样屏幕上会凭空多出一条
    /// 用户已经放弃的注解。
    func testNewAnnotationClearsTheRedoStack() throws {
        let view = try editedView()
        view.tool = .rect
        view.pointerDown(CGPoint(x: 120, y: 120), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 220, y: 180))
        view.pointerReleased()
        view.undo()
        XCTAssertEqual(view.undone.count, 1)

        view.tool = .arrow
        view.pointerDown(CGPoint(x: 130, y: 130), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 200, y: 160))
        view.pointerReleased()
        XCTAssertTrue(view.undone.isEmpty, "画了新的就该终结重做栈")
        view.redo()
        XCTAssertEqual(view.annotations.count, 1, "重做栈空了就不该凭空多出第二条")
    }

    // MARK: - 裁剪

    /// 点「裁剪」= 拿当前选区当底板再框一块：新框出不了底板，画好的注解一条不丢。
    func testCropConfinesTheNewSelection() throws {
        let view = try editedView(CGRect(x: 100, y: 100, width: 300, height: 200))
        view.annotations = [ScreenshotAnnotation(tool: .rect, color: .systemBlue, lineWidth: 2,
                                                 start: CGPoint(x: 120, y: 120),
                                                 end: CGPoint(x: 200, y: 180))]
        view.toolbar?.onCrop?()
        XCTAssertEqual(view.cropBounds, CGRect(x: 100, y: 100, width: 300, height: 200))
        XCTAssertEqual(view.phase, .picking)
        XCTAssertTrue(view.toolbar?.isHidden ?? false, "裁剪途中条子先收起来，别压着要框的那块")

        // 往底板外拖：右下角就是底板边界，不能越出去截到别的内容。
        view.pointerDown(CGPoint(x: 380, y: 280), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 900, y: 900))
        XCTAssertEqual(view.selection, CGRect(x: 380, y: 280, width: 20, height: 20))
        view.pointerReleased()

        XCTAssertNil(view.cropBounds, "裁剪落定就该退出这块状态")
        XCTAssertEqual(view.phase, .editing)
        XCTAssertFalse(view.toolbar?.isHidden ?? true, "新框定了，条子要跟着浮回来")
        XCTAssertEqual(view.annotations.count, 1, "裁剪只是改框，画好的注解不能清掉")
    }

    /// 裁剪中按下没拖动 = 这一刀不切了：回到原来那块。不能停在「既没进编辑态、条子又
    /// 是收着的」那种死路上。
    func testCropWithoutDragRestoresTheOldSelection() throws {
        let view = try editedView()
        view.toolbar?.onCrop?()
        view.pointerDown(CGPoint(x: 150, y: 120), clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 100, width: 200, height: 100))
        XCTAssertNil(view.cropBounds)
        XCTAssertEqual(view.phase, .editing)
        XCTAssertFalse(view.toolbar?.isHidden ?? true)
    }

    /// 拖出一个比手指还小的框（1px）不该把原来的选区也弄没。
    func testCropTinyDragKeepsTheOldFrame() throws {
        let view = try editedView()
        view.toolbar?.onCrop?()
        view.pointerDown(CGPoint(x: 150, y: 120), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 153, y: 122))
        view.pointerReleased()
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 100, width: 200, height: 100),
                       "这刀不值得切，原框得留着")
        XCTAssertEqual(view.phase, .editing)
    }

    /// 裁剪途中不吸窗：那是在一块已经框好的图上再切一刀，吸到窗口边界会把框顶出底板。
    func testCropDoesNotSnapToWindows() throws {
        let view = try editedView()
        view.windows = [CGRect(x: 0, y: 0, width: 800, height: 500)]
        view.toolbar?.onCrop?()
        view.pointerMoved(CGPoint(x: 150, y: 120))
        XCTAssertNil(view.hover, "裁剪中鼠标划过不该亮出整块屏")
    }

    // MARK: - 贴图

    /// 图钉那一枚要连同「这块在屏幕上的位置」一起交出去：贴图钉回原处靠它。视图是
    /// flipped 的、屏原点也可能不是 (0,0)，翻 y 这一步错了就钉到别的地方去。
    func testPinDeliversTheSelectionsScreenRect() throws {
        let view = try editedView()
        var output: ScreenshotOutput?
        var rect: NSRect?
        view.onFinish = { _, out, screenRect in output = out; rect = screenRect }
        view.toolbar?.onPin?()

        XCTAssertEqual(output, .pin)
        let window = try XCTUnwrap(view.window)
        XCTAssertEqual(rect, NSRect(x: window.frame.minX + 100,
                                    y: window.frame.maxY - 200,
                                    width: 200, height: 100))
    }

    /// 没选工具时，选区外的拖动 = 重新框选，松手回到编辑态且一条注解都不画。
    func testReselectionOutsideSelectionReentersEditing() throws {
        let view = try editedView()
        view.pointerDown(CGPoint(x: 100, y: 300), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 300, y: 400))
        XCTAssertEqual(view.phase, .picking, "重框过程中条子要先收起来")
        XCTAssertTrue(view.toolbar?.isHidden ?? false)
        view.pointerReleased()
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 300, width: 200, height: 100))
        XCTAssertEqual(view.phase, .editing)
        XCTAssertFalse(view.toolbar?.isHidden ?? true, "新选区落定，条子跟着挪过来")
        XCTAssertEqual(view.toolbar?.frame.minY, 408)
        XCTAssertTrue(view.annotations.isEmpty)
    }

    /// 双击落在选区内 = 直接出图复制（QQ/微信的手感），拿到的就是这一块。
    func testDoubleClickInsideSelectionFinishes() throws {
        let view = try editedView()
        var finished: CGImage?
        var output: ScreenshotOutput?
        view.onFinish = { image, out, _ in finished = image; output = out }

        view.pointerDown(CGPoint(x: 150, y: 150), clickCount: 1)
        XCTAssertNil(finished, "双击的第一下不能把图交出去，否则第二下永远等不到")
        view.pointerReleased()
        view.pointerDown(CGPoint(x: 150, y: 150), clickCount: 2)
        XCTAssertEqual(output, .copy)
        let image = try XCTUnwrap(finished)
        XCTAssertEqual(image.width, image.height * 2, accuracy: 2, "选区 200×100，长宽比得保住")
    }

    // MARK: - editing：确认之后还能改框

    /// 角上那点同时落在两条边的判定区里，必须让角先赢，否则拖角会退化成只动一条边。
    func testHandleHitTestingPrefersCorners() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let probe = ScreenshotSelectionView.handle(at:of:)
        XCTAssertEqual(probe(CGPoint(x: 102, y: 98), rect), .topLeft)
        XCTAssertEqual(probe(CGPoint(x: 296, y: 196), rect), .bottomRight)
        XCTAssertEqual(probe(CGPoint(x: 200, y: 98), rect), .top)
        XCTAssertEqual(probe(CGPoint(x: 298, y: 150), rect), .right)
        XCTAssertNil(probe(CGPoint(x: 200, y: 150), rect), "选区正中不该命中任何把手")
        XCTAssertNil(probe(CGPoint(x: 200, y: 130), rect), "离边框 22pt 就是画注解的地方了")
    }

    /// 拖右边把手 = 只动右边界：编辑态不掉、注解读不掉、注解条跟着挪。
    func testEdgeHandleResizesSelection() throws {
        let view = try editedView(CGRect(x: 300, y: 100, width: 200, height: 100),
                                  size: NSSize(width: 1440, height: 900))
        view.annotations = [ScreenshotAnnotation(tool: .rect, color: .systemBlue, lineWidth: 2,
                                                 start: CGPoint(x: 320, y: 120),
                                                 end: CGPoint(x: 480, y: 180))]
        view.pointerDown(CGPoint(x: 500, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 560, y: 150))
        XCTAssertEqual(view.selection, CGRect(x: 300, y: 100, width: 260, height: 100))
        XCTAssertEqual(view.phase, .editing, "改框不该把编辑态打回选区态")
        XCTAssertEqual(try XCTUnwrap(view.toolbar).frame.midX, view.selection.midX, accuracy: 0.5,
                       "条子要跟着框走，否则出口会留在原地")
        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 1, "改框不能把画好的注解清掉")
    }

    /// 角把手一次改两条边。
    func testCornerHandleResizesBothEdges() throws {
        let view = try editedView()
        view.pointerDown(CGPoint(x: 100, y: 100), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 60, y: 70))
        XCTAssertEqual(view.selection, CGRect(x: 60, y: 70, width: 240, height: 130))
    }

    /// 把手拖过对边不能翻面，也只能缩到还看得见的下限。
    func testResizeNeverFlipsOrCollapses() throws {
        let view = try editedView()
        view.pointerDown(CGPoint(x: 300, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 20, y: 150))
        XCTAssertEqual(view.selection.width, ScreenshotSelectionView.minRegionSize, accuracy: 0.01)
        XCTAssertEqual(view.selection.minX, 100, accuracy: 0.01, "右边界被拖到左边去了，也不能翻面")
        view.pointerDragged(to: CGPoint(x: 5000, y: 150))
        XCTAssertLessThanOrEqual(view.selection.maxX, view.bounds.maxX, "不能拖出屏")
    }

    /// 没选工具时，选区内按住拖动 = 整块平移，尺寸不变。
    ///
    /// 这是默认路径：偏好里「截图默认工具」关着，进编辑态一个工具都不装。
    func testDragInsideSelectionMovesIt() throws {
        let view = try editedView()
        XCTAssertNil(view.tool, "默认关闭时选区落定不该装工具")
        view.pointerDown(CGPoint(x: 200, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 260, y: 130))
        XCTAssertEqual(view.selection, CGRect(x: 160, y: 80, width: 200, height: 100))
        XCTAssertTrue(view.annotations.isEmpty, "平移不是画注解")
        view.pointerReleased()
        XCTAssertEqual(view.toolbar?.frame.minY, 188)
    }

    /// 平移到屏边就停住，不能把选区推出去一半。
    func testMoveClampsToScreen() throws {
        let view = try editedView()
        view.pointerDown(CGPoint(x: 200, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 900, y: 900))
        XCTAssertEqual(view.selection, CGRect(x: 600, y: 400, width: 200, height: 100))
    }

    /// 偏好里选了打码，框选确认那一格就直接装上：条子上对应格子跟着亮，
    /// 选区内的拖动变成画注解，不再走平移。
    func testDefaultToolArmsItselfWhenSelectionLands() throws {
        let view = try editedView(defaultTool: .mosaic)
        XCTAssertEqual(view.tool, .mosaic, "偏好里选了打码，落定就该装上")
        XCTAssertEqual(view.toolbar?.activeToolOnBar, .mosaic, "条子上那一格也得跟着亮")
        let before = view.selection
        view.pointerDown(CGPoint(x: 150, y: 130), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 250, y: 160))
        view.pointerReleased()
        XCTAssertEqual(view.selection, before, "第一笔不该把选区拖走")
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.annotations.first?.tool, .mosaic)
    }

    /// 装了默认工具不等于回不到平移：条子上再点一次同一格就是摘掉，
    /// 摘掉后选区内拖动恢复成整块平移。
    func testArmedDefaultToolCanBeUndoneFromTheBar() throws {
        let view = try editedView(defaultTool: .pen)
        XCTAssertEqual(view.tool, .pen)
        view.toolbar?.onTool?(.pen)
        XCTAssertNil(view.tool)
        XCTAssertNil(view.toolbar?.activeToolOnBar, "摘掉之后条子上不该还有亮着的格子")
        view.pointerDown(CGPoint(x: 200, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 260, y: 130))
        XCTAssertEqual(view.selection, CGRect(x: 160, y: 80, width: 200, height: 100),
                       "摘掉工具后这一路要回到平移")
        XCTAssertTrue(view.annotations.isEmpty)
    }

    /// 选了工具之后，选区内的拖动还是画注解（平移只在不选工具时抢这一路）。
    func testToolDragInsideSelectionStillDraws() throws {
        let view = try editedView()
        view.tool = .rect
        view.pointerDown(CGPoint(x: 200, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 260, y: 180))
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 100, width: 200, height: 100), "选区不该跟着漂走")
        XCTAssertNotNil(view.draft)
    }

    // MARK: - 注解条摆放

    /// 按住条子的空白处拖动 = 把整条挪走，选区一点不动。全屏截图时条子压在画面上，
    /// 不让挪就没法编辑被盖住的那块。
    func testDragToolbarBlankAreaMovesIt() throws {
        // 选区摆在中段偏右：这样条子往左挪 40pt 还在线内，量到的是「跟着手走」而不是
        // 「被屏边钳住」。条子现在 756pt 宽，800 宽的容器里它天生贴边，往哪挪都是撞墙。
        let view = try editedView(CGRect(x: 700, y: 100, width: 200, height: 100),
                                  size: NSSize(width: 1440, height: 900))
        let bar = try XCTUnwrap(view.toolbar)
        let before = bar.frame
        // 空白处：最后一个按钮右边到条子边界之间那段留白。
        let blank = CGPoint(x: bar.frame.maxX - 1, y: bar.frame.midY)
        XCTAssertFalse(bar.hasActionable(atOverlayPoint: blank))

        view.pointerDown(blank, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: blank.x - 40, y: blank.y - 160))
        XCTAssertEqual(view.toolbar?.frame.origin,
                       CGPoint(x: before.minX - 40, y: before.minY - 160))
        view.pointerReleased()
        XCTAssertEqual(view.selection, CGRect(x: 700, y: 100, width: 200, height: 100),
                       "拖条子不该把选区也带走")
        XCTAssertEqual(view.phase, .editing)
    }

    /// 拖到屏外要停住：条子上带着复制/存盘/取消，整条推出去就等于把出口弄丢了。
    func testToolbarDragStaysInsideScreen() throws {
        let view = try editedView()
        let bar = try XCTUnwrap(view.toolbar)
        let blank = CGPoint(x: bar.frame.maxX - 1, y: bar.frame.midY)
        view.pointerDown(blank, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: blank.x + 4000, y: blank.y - 4000))
        let moved = try XCTUnwrap(view.toolbar).frame
        XCTAssertTrue(view.bounds.contains(moved), "整条还得在屏内 \(moved)")
        XCTAssertEqual(moved.size, CGSize(width: bar.preferredWidth,
                                          height: ScreenshotToolbarView.barHeight),
                       "只能挪位置，不能改尺寸")
    }

    /// 手抖一下（不到 slop）不该把条子从「跟着选区走」改成钉死在原地。
    func testToolbarDragNeedsSlop() throws {
        let view = try editedView(CGRect(x: 300, y: 100, width: 200, height: 100),
                                  size: NSSize(width: 1440, height: 900))
        let bar = try XCTUnwrap(view.toolbar)
        let before = bar.frame
        let blank = CGPoint(x: bar.frame.maxX - 1, y: bar.frame.midY)
        view.pointerDown(blank, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: blank.x + 2, y: blank.y))
        XCTAssertEqual(view.toolbar?.frame, before, "两三个像素的抖动不算挪条子")
        view.pointerReleased()

        // 还在跟随态：接着改框，条子应当重新贴回选区下沿。
        view.pointerDown(CGPoint(x: 500, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 560, y: 150))
        view.pointerReleased()
        XCTAssertEqual(try XCTUnwrap(view.toolbar).frame.minY, 208, "没拖成就还得跟着选区走")
        XCTAssertEqual(try XCTUnwrap(view.toolbar).frame.midX, view.selection.midX, accuracy: 0.5)
    }

    /// 按在按钮上那一下归按钮自己：不能顺带把整条拖走（真事件里 hitTest 就拦下了，
    /// 这里验判定树给出同样的答案）。
    func testPressOnToolbarButtonDoesNotMoveIt() throws {
        let view = try editedView()
        let bar = try XCTUnwrap(view.toolbar)
        let button = try XCTUnwrap(bar.actionableRects.first)
        let center = CGPoint(x: bar.frame.minX + button.midX, y: bar.frame.minY + button.midY)
        XCTAssertTrue(bar.hasActionable(atOverlayPoint: center))

        let before = bar.frame
        view.pointerDown(center, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: center.x, y: center.y - 120))
        XCTAssertEqual(view.toolbar?.frame, before, "从按钮上起拖不该把条子带走")
        XCTAssertEqual(view.phase, .editing, "也不该把编辑态打回选区态")
    }

    /// 拖走之后再改框：条子留在用户放的那个点，不再弹回选区下沿。
    func testPinnedToolbarIgnoresSelectionChanges() throws {
        let view = try editedView()
        let bar = try XCTUnwrap(view.toolbar)
        let blank = CGPoint(x: bar.frame.maxX - 1, y: bar.frame.midY)
        view.pointerDown(blank, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: blank.x - 60, y: blank.y - 180))
        view.pointerReleased()
        let pinned = try XCTUnwrap(view.toolbar).frame

        view.pointerDown(CGPoint(x: 300, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 360, y: 150))
        view.pointerReleased()
        XCTAssertEqual(view.toolbar?.frame, pinned, "改框不该把用户拖好的条子顶回去")
    }

    /// 重新框选 = 新的一轮：条子回到跟着新选区摆。
    func testNewSelectionReattachesToolbar() throws {
        let view = try editedView()
        let bar = try XCTUnwrap(view.toolbar)
        let blank = CGPoint(x: bar.frame.maxX - 1, y: bar.frame.midY)
        view.pointerDown(blank, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: blank.x, y: blank.y - 180))
        view.pointerReleased()

        view.pointerDown(CGPoint(x: 100, y: 300), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 300, y: 400))
        view.pointerReleased()
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 300, width: 200, height: 100))
        XCTAssertEqual(view.toolbar?.frame.minY, 408, "新选区落定，条子重新贴到下沿")
    }

    /// 条子永远留在屏内：横向钳回屏内，下面顶到屏底就翻进选区内侧。
    ///
    /// 容器用 1440×900：条子已经 791pt 宽，800pt 的屏扣掉两边留白**没有**放得下的位置了
    /// —— 在那种屏上断言「贴住右边缘还不出屏」是在断言一件不可能成立的事。判据要落在
    /// 真放得下的屏上，钳位规则本身才有意义。
    func testToolbarFrameStaysInsideContainer() throws {
        let width = ScreenshotToolbarView(frame: .zero).preferredWidth
        let height = ScreenshotToolbarView.barHeight
        let container = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin = ScreenshotSelectionView.toolbarMargin

        let normal = ScreenshotSelectionView.toolbarFrame(
            selection: CGRect(x: 620, y: 100, width: 200, height: 100),
            toolbarWidth: width, container: container)
        XCTAssertEqual(normal.minY, 208, "默认摆在选区下沿外面")
        XCTAssertEqual(normal.midX, 720, accuracy: 0.5, "横向对着选区居中")

        // 选区压到屏底：下面放不下，翻进选区内侧、贴着下沿留 8pt 缝。
        let low = ScreenshotSelectionView.toolbarFrame(
            selection: CGRect(x: 620, y: 700, width: 200, height: 180),
            toolbarWidth: width, container: container)
        XCTAssertEqual(low.maxY, 880 - 8, accuracy: 1, "翻进选区内侧：下沿外面留 8pt 缝")

        // 贴着屏左/屏右的窄选区：整条钳回屏内，出口一个都不能跑到屏外。
        let left = ScreenshotSelectionView.toolbarFrame(
            selection: CGRect(x: 5, y: 100, width: 50, height: 100),
            toolbarWidth: width, container: container)
        let right = ScreenshotSelectionView.toolbarFrame(
            selection: CGRect(x: 1385, y: 100, width: 50, height: 100),
            toolbarWidth: width, container: container)
        XCTAssertEqual(left.minX, container.minX + margin, accuracy: 0.5,
                       "居中会跑出左边缘时，停在左边留白处")
        XCTAssertEqual(right.maxX, container.maxX - margin, accuracy: 0.5,
                       "放不下就贴住右边缘，不能整条拖出屏")
        for frame in [normal, low, left, right] {
            XCTAssertTrue(container.contains(frame), "整条都得在屏内，否则用户点不到出口 \(frame)")
            XCTAssertEqual(frame.height, height)
        }
    }

    // MARK: - 辅助

    private func overlay(size: NSSize = NSSize(width: 800, height: 500)) throws -> ScreenshotSelectionView {
        let shot = try XCTUnwrap(ScreenshotFrame(image: pattern(size), pointSize: size))
        let view = ScreenshotSelectionView(shot: shot)
        // 挂到一扇窗上：不挂窗时 AppKit 的 focus 上下文不完整，文字绘制会缺笔画。
        ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: size)).contentView = view
        return view
    }

    /// 已经拖好选区、进了编辑态的遮罩。默认选区 (100,100,200,100)。
    ///
    /// `size` 默认 800×500：够摆下选区本身。凡是要拿「条子跟着选区居中」当判据的用例
    /// 得传宽屏 —— 注解条现在有 756pt，800 宽的容器里它天生居不了中（只能贴边），
    /// 那不是摆放逻辑错，是容器不够。
    /// `defaultTool` 是偏好里「截图默认工具」那一格，控制器在 `start()` 里塞给视图；
    /// 这里必须在拖选之前摆好，落定那一刻才轮得到它装。
    private func editedView(_ rect: CGRect = CGRect(x: 100, y: 100, width: 200, height: 100),
                            size: NSSize = NSSize(width: 800, height: 500),
                            defaultTool: ScreenshotTool? = nil)
        throws -> ScreenshotSelectionView {
        let view = try overlay(size: size)
        view.defaultTool = defaultTool
        view.pointerDown(rect.origin, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: rect.maxX, y: rect.maxY))
        view.pointerReleased()
        XCTAssertEqual(view.selection, rect)
        XCTAssertEqual(view.phase, .editing)
        return view
    }

    private func pattern(_ size: NSSize) throws -> CGImage {
        try XCTUnwrap(QuadrantPattern.image(width: Int(size.width), height: Int(size.height)),
                      "拿不到 \(size) 的测试图案")
    }
}
