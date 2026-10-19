//
//  ScreenshotAnnotationEditTests.swift
//
//  「画完之后还要改」的取证（用户 2026-10-19：「添加的注释方向方框等要支持编辑」，
//  口径三条：入口 = 没选工具时直接点它；范围 = 平移 + 缩放 + 改样式 + 删这一条；
//  改样式只改被选中的那一条）。
//
//  三层各管一段，缺一段就会漏一类错：
//  ① 模型那半边全是纯函数 —— 命中、把手、平移、缩放、改样式。这里逐条钉死几何口径：
//     空心框只认看得见的那条线（不然画个大框就把整块选区平移吞了）、文字缩放改的是
//     字号而不是把字拉扁、序号有半径下限、样式字段一个都不能在复制时丢。
//  ② 遮罩那半边是状态机 —— 谁先赢（选区边框 > 露着的注解把手 > 注解本体 > 选区本体）、
//     只有选中才露把手、面板改的确实只有那一条、一次手势 = 一步撤销、Esc 一层层退。
//  ③ 渲染取证 —— 选中框只画在遮罩上、只画在亮区里，**绝不进成品图**。判据拿同一场景
//     两种状态逐像素相比（差在哪、差多少），再拿导出图逐字节相比（必须零差异）；
//     「同一个状态连拍两张一模一样」是反向对照，没有它，上面那些差异不知道是谁带来的。
//

import AppKit
import Storage
import XCTest

@testable import Screenshot

/// 模型那半边用的量程：和遮罩默认容器一致（`applyingResize` 的 `limit` 就是遮罩 bounds）。
private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

final class ScreenshotAnnotationEditTests: XCTestCase {

    // MARK: - 命中：只有看得见的地方才抓得住

    /// 空心矩形只认那条线：框住的中间留给「平移整块选区」。
    func testHollowRectGrabsItsInkNotItsMiddle() {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        XCTAssertTrue(rect.contains(CGPoint(x: 120, y: 150), slop: 6), "左边线上")
        XCTAssertTrue(rect.contains(CGPoint(x: 190, y: 180), slop: 6), "下边线上")
        XCTAssertTrue(rect.contains(CGPoint(x: 266, y: 150), slop: 6), "线外侧 6pt 的容错也要算")
        XCTAssertFalse(rect.contains(CGPoint(x: 190, y: 150), slop: 6), "空心中央不该归它")
        XCTAssertFalse(rect.contains(CGPoint(x: 100, y: 150), slop: 6), "离线 20pt 就是没按到")
    }

    /// 椭圆同理：认曲线那一圈，不认整块。
    func testEllipseGrabsTheCurve() {
        let ellipse = shape(.ellipse, CGRect(x: 120, y: 120, width: 140, height: 60))
        XCTAssertTrue(ellipse.contains(CGPoint(x: 190, y: 180), slop: 6), "下顶点")
        XCTAssertTrue(ellipse.contains(CGPoint(x: 120, y: 150), slop: 6), "左顶点")
        XCTAssertFalse(ellipse.contains(CGPoint(x: 190, y: 150), slop: 6), "中心")
        XCTAssertFalse(ellipse.contains(CGPoint(x: 190, y: 132), slop: 6), "往里还留着 18pt，不算线上")
        XCTAssertFalse(ellipse.contains(CGPoint(x: 300, y: 150), slop: 6), "框外")
    }

    /// 箭头和画笔都按「点到线段的距离」判：轨迹拐弯处的空档不该整块都算。
    func testArrowAndPenGrabTheirStroke() {
        let arrow = ScreenshotAnnotation(tool: .arrow, color: red, lineWidth: 4,
                                         start: CGPoint(x: 120, y: 150), end: CGPoint(x: 260, y: 150))
        XCTAssertTrue(arrow.contains(CGPoint(x: 190, y: 152), slop: 6))
        XCTAssertFalse(arrow.contains(CGPoint(x: 190, y: 170), slop: 6))
        XCTAssertFalse(arrow.contains(CGPoint(x: 100, y: 150), slop: 6), "箭尾外 20pt")

        let pen = ScreenshotAnnotation(tool: .pen, color: red, lineWidth: 4,
                                       start: CGPoint(x: 120, y: 120),
                                       points: [CGPoint(x: 120, y: 120), CGPoint(x: 160, y: 160),
                                                CGPoint(x: 200, y: 120)])
        XCTAssertTrue(pen.contains(CGPoint(x: 140, y: 142), slop: 6), "第一段上")
        XCTAssertTrue(pen.contains(CGPoint(x: 200, y: 122), slop: 6), "终点附近")
        XCTAssertFalse(pen.contains(CGPoint(x: 160, y: 140), slop: 6), "两段之间的空档不算")
        XCTAssertFalse(pen.contains(CGPoint(x: 100, y: 100), slop: 6))
    }

    /// 打码、文字、序号是实心的一块，整块都能抓 —— 它们的「线」就是那块面。
    func testSolidBlocksGrabTheirWholeArea() {
        let mosaic = shape(.mosaic, CGRect(x: 120, y: 120, width: 140, height: 60))
        XCTAssertTrue(mosaic.contains(CGPoint(x: 190, y: 150), slop: 6))
        XCTAssertFalse(mosaic.contains(CGPoint(x: 275, y: 150), slop: 6), "块外就是外")

        let text = ScreenshotAnnotation(tool: .text, color: red, lineWidth: 2,
                                        start: CGPoint(x: 130, y: 130), text: "abc", fontSize: 24)
        XCTAssertTrue(text.textBoxRect.width > 20 && text.textBoxRect.maxX < 190,
                      "前提：这几个字量得出来又没长过 190：\(text.textBoxRect)")
        XCTAssertTrue(text.contains(CGPoint(x: 130, y: 130), slop: 6), "字的锚点在内")
        XCTAssertTrue(text.contains(CGPoint(x: 150, y: 140), slop: 6), "字身上任一处")
        XCTAssertFalse(text.contains(CGPoint(x: 200, y: 130), slop: 6))

        let number = ScreenshotAnnotation(tool: .number, color: red, lineWidth: 4,
                                          start: CGPoint(x: 200, y: 200), number: 1)
        XCTAssertTrue(number.contains(CGPoint(x: 200, y: 200), slop: 6))
        XCTAssertTrue(number.contains(CGPoint(x: 209, y: 209), slop: 6), "半径 11 + 容错 6")
        XCTAssertFalse(number.contains(CGPoint(x: 200, y: 220), slop: 6), "圈外")
    }

    /// 拖出一个只有 4pt 宽的窄框时，内缩矩形会翻面 —— 那时候整块都算线上，否则点不着。
    func testTooThinHollowRectStaysGrabable() {
        let thin = shape(.rect, CGRect(x: 120, y: 150, width: 4, height: 20))
        XCTAssertTrue(thin.contains(CGPoint(x: 122, y: 160), slop: 6),
                      "两条边重合了，中间那点也是墨迹")
        XCTAssertFalse(thin.contains(CGPoint(x: 134, y: 160), slop: 6))
    }

    // MARK: - 把手：谁露几颗、点哪儿算按住了

    /// 每格工具露出的把手不一样：形状八颗、文字/序号只给四颗角、箭头给两个端点。
    func testEachToolExposesItsOwnHandles() {
        let box = CGRect(x: 120, y: 120, width: 140, height: 60)
        XCTAssertEqual(shape(.rect, box).editableGrabs, RegionHandle.grabOrder.map { AnnotationGrab.box($0) })
        XCTAssertEqual(shape(.ellipse, box).editableGrabs.count, 8)
        XCTAssertEqual(shape(.mosaic, box).editableGrabs.count, 8)
        let arrow = ScreenshotAnnotation(tool: .arrow, color: red, lineWidth: 4,
                                         start: box.origin, end: CGPoint(x: box.maxX, y: box.maxY))
        XCTAssertEqual(arrow.editableGrabs, [.head, .tail])
        let text = ScreenshotAnnotation(tool: .text, color: red, lineWidth: 2,
                                        start: box.origin, text: "标注", fontSize: 24)
        XCTAssertEqual(text.editableGrabs, RegionHandle.cornerOrder.map { AnnotationGrab.box($0) },
                       "文字是等比放大，给边把手等于允诺一个「把字拉扁」它做不到的事")
        let number = ScreenshotAnnotation(tool: .number, color: red, lineWidth: 4,
                                          start: box.origin, number: 2)
        XCTAssertEqual(number.editableGrabs.count, 4)
    }

    /// 把手画在哪儿 —— 和 `editableGrabs` 一一对应，画歪一处就是「看得见却点不着」。
    func testGrabCentersAreWhereTheHandlesArePainted() {
        let box = CGRect(x: 120, y: 120, width: 140, height: 60)
        let rect = shape(.rect, box)
        XCTAssertEqual(rect.grabCenter(.box(.topLeft)), CGPoint(x: 120, y: 120))
        XCTAssertEqual(rect.grabCenter(.box(.bottomRight)), CGPoint(x: 260, y: 180))
        XCTAssertEqual(rect.grabCenter(.box(.right)), CGPoint(x: 260, y: 150))
        XCTAssertEqual(rect.grabCenter(.box(.top)), CGPoint(x: 190, y: 120))

        let arrow = ScreenshotAnnotation(tool: .arrow, color: red, lineWidth: 4,
                                         start: CGPoint(x: 120, y: 150), end: CGPoint(x: 260, y: 150))
        XCTAssertEqual(arrow.grabCenter(.tail), CGPoint(x: 120, y: 150))
        XCTAssertEqual(arrow.grabCenter(.head), CGPoint(x: 260, y: 150))

        let number = ScreenshotAnnotation(tool: .number, color: red, lineWidth: 4,
                                          start: CGPoint(x: 200, y: 200), number: 1)
        XCTAssertEqual(number.grabCenter(.box(.bottomRight)), CGPoint(x: 211, y: 211),
                       "序号的角在外切方上（半径 11）")
    }

    /// 命中顺序：角先于边；离手柄 8pt 开外就该交还给「整条平移」。
    func testCornersWinAndFarAwayIsNotAGrab() {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        XCTAssertEqual(rect.grab(at: CGPoint(x: 260, y: 180)), .box(.bottomRight))
        XCTAssertEqual(rect.grab(at: CGPoint(x: 266, y: 186)), .box(.bottomRight), "角区内不该退化成只动一条边")
        XCTAssertEqual(rect.grab(at: CGPoint(x: 272, y: 180)), nil, "离手柄 12pt 就不算按着它")
        XCTAssertEqual(rect.grab(at: CGPoint(x: 190, y: 150)), nil, "正中不是把手")
        // 空心框的墨就贴着这条边。命中区要是沿整条边铺开（照抄选区那条算法），选中之后
        // 沿着框线一按先撞上「缩框」，想平移得先挪开 —— 手感直接废掉一半。
        XCTAssertEqual(rect.grab(at: CGPoint(x: 150, y: 120)), nil, "上边只有中点那一小块是缩框把手，边上别处归挪整条")
        XCTAssertEqual(rect.grab(at: CGPoint(x: 190, y: 120)), .box(.top), "中点那 16×16 才是缩框")

        let arrow = ScreenshotAnnotation(tool: .arrow, color: red, lineWidth: 4,
                                         start: CGPoint(x: 120, y: 150), end: CGPoint(x: 260, y: 150))
        XCTAssertEqual(arrow.grab(at: CGPoint(x: 260, y: 150)), .head, "水平箭的箭头正好落在包围盒的角上")
        XCTAssertEqual(arrow.grab(at: CGPoint(x: 120, y: 152)), .tail)
        XCTAssertEqual(arrow.grab(at: CGPoint(x: 190, y: 150)), nil, "杆子中间归挪整条")
    }

    /// `editBox` 是「这条真正占到的地方」：文字和序号的 `rect` 是零面积，不能拿它画框。
    func testEditBoxCoversWhatTheShapeActuallyPaints() {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        XCTAssertEqual(rect.editBox, rect.rect)

        let text = ScreenshotAnnotation(tool: .text, color: red, lineWidth: 2,
                                        start: CGPoint(x: 130, y: 140), text: "标注", fontSize: 24)
        XCTAssertEqual(text.rect.size, CGSize(width: 0, height: 0), "文字的 start 只是锚点")
        XCTAssertEqual(text.editBox, text.textBoxRect)
        XCTAssertGreaterThan(text.editBox.width, 20)

        let number = ScreenshotAnnotation(tool: .number, color: red, lineWidth: 4,
                                          start: CGPoint(x: 200, y: 200), number: 1)
        XCTAssertEqual(number.editBox, CGRect(x: 189, y: 189, width: 22, height: 22))
    }

    // MARK: - 改一条：平移

    /// 平移逐字段照抄自己，只挪坐标。轨迹、字号、粗斜体、描边、背景一个都不许丢。
    func testMoveShiftsEveryCoordinateAndKeepsTheStyle() {
        let pen = ScreenshotAnnotation(tool: .pen, color: .systemBlue, lineWidth: 6,
                                       start: CGPoint(x: 120, y: 120),
                                       points: [CGPoint(x: 120, y: 120), CGPoint(x: 160, y: 160),
                                                CGPoint(x: 200, y: 120)],
                                       fontSize: 30, bold: false, italic: true,
                                       borderColor: .black, backgroundColor: .yellow)
        let moved = pen.movedBy(CGSize(width: 40, height: -20))
        XCTAssertEqual(moved.points, [CGPoint(x: 160, y: 100), CGPoint(x: 200, y: 140),
                                      CGPoint(x: 240, y: 100)])
        XCTAssertEqual(moved.color, .systemBlue)
        XCTAssertEqual(moved.lineWidth, 6)
        XCTAssertEqual(moved.fontSize, 30, "平移不能把字号按粗细重算一遍")
        XCTAssertEqual(moved.bold, false)
        XCTAssertEqual(moved.italic, true)
        XCTAssertEqual(moved.borderColor, .black)
        XCTAssertEqual(moved.backgroundColor, .yellow)
        XCTAssertEqual(moved.movedBy(.zero), moved, "没挪动就该完全相等 —— 撤销栈靠这个空转不记账")
    }

    /// 老式「粗细即字号」派生出来的那档也要原样带过去（`init` 的默认参数会重算它）。
    func testMoveKeepsADerivedFontSize() {
        let text = ScreenshotAnnotation(tool: .text, color: red, lineWidth: 8,
                                        start: CGPoint(x: 130, y: 140), text: "hi")
        XCTAssertEqual(text.fontSize, 32, "前提：8×4 那档派生字号")
        XCTAssertEqual(text.movedBy(CGSize(width: 10, height: 10)).fontSize, 32)
        XCTAssertEqual(text.movedBy(.zero), text)
    }

    // MARK: - 改一条：缩放

    /// 拖右下角 = 左上角钉住，两轴各自缩放。
    func testCornerResizeScalesTheBoxFromTheOppositeCorner() {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let bigger = rect.applyingResize(.box(.bottomRight), to: CGPoint(x: 300, y: 240), limit: screen)
        XCTAssertEqual(bigger.rect, CGRect(x: 120, y: 120, width: 180, height: 120))
        XCTAssertEqual(bigger.start, CGPoint(x: 120, y: 120))
        XCTAssertEqual(bigger.lineWidth, 4, "缩放只改几何，笔宽交给面板")

        let left = rect.applyingResize(.box(.left), to: CGPoint(x: 100, y: 150), limit: screen)
        XCTAssertEqual(left.rect, CGRect(x: 100, y: 120, width: 160, height: 60), "只动那一条边")
    }

    /// 拖过头不翻面，也不能缩到抓不住（`minEditSize`，比选区那档 20pt 小得多）。
    func testResizeNeverFlipsOrCollapsesPastTheFloor() {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let squished = rect.applyingResize(.box(.right), to: CGPoint(x: 60, y: 150), limit: screen)
        XCTAssertEqual(squished.rect.width, ScreenshotAnnotation.minEditSize, accuracy: 0.01)
        XCTAssertEqual(squished.rect.minX, 120, accuracy: 0.01, "右边界被拖到左边去了也不能翻面")

        let offscreen = rect.applyingResize(.box(.bottomRight), to: CGPoint(x: 5000, y: 5000), limit: screen)
        XCTAssertLessThanOrEqual(offscreen.rect.maxX, screen.maxX, "不能拖出屏")
        XCTAssertLessThanOrEqual(offscreen.rect.maxY, screen.maxY)
    }

    /// 画笔的整条轨迹跟着包围盒走；拖成一条竖线（零宽）那一轴不缩放，只平移。
    func testPenTraceScalesWithItsBox() {
        let pen = ScreenshotAnnotation(tool: .pen, color: red, lineWidth: 4,
                                       start: CGPoint(x: 120, y: 120),
                                       points: [CGPoint(x: 120, y: 120), CGPoint(x: 160, y: 160),
                                                CGPoint(x: 200, y: 120)])
        let grown = pen.applyingResize(.box(.bottomRight), to: CGPoint(x: 280, y: 200), limit: screen)
        XCTAssertEqual(grown.points, [CGPoint(x: 120, y: 120), CGPoint(x: 200, y: 200),
                                      CGPoint(x: 280, y: 120)])

        let vertical = ScreenshotAnnotation(tool: .pen, color: red, lineWidth: 4,
                                            start: CGPoint(x: 150, y: 100),
                                            points: [CGPoint(x: 150, y: 100), CGPoint(x: 150, y: 200)])
        let pulled = vertical.applyingResize(.box(.right), to: CGPoint(x: 250, y: 150), limit: screen)
        XCTAssertEqual(pulled.points, vertical.points,
                       "零宽那轴除不了，只能跟着平移 —— 别把竖线糊成一块谁都没要的板")
    }

    /// 箭头的「缩放」就是两颗端点：钉住另一头，端点只能拖到屏边。
    func testArrowEndpointDragKeepsTheOtherEnd() {
        let arrow = ScreenshotAnnotation(tool: .arrow, color: red, lineWidth: 4,
                                         start: CGPoint(x: 120, y: 150), end: CGPoint(x: 260, y: 150))
        let longer = arrow.applyingResize(.head, to: CGPoint(x: 400, y: 220), limit: screen)
        XCTAssertEqual(longer.start, CGPoint(x: 120, y: 150), "箭尾钉住")
        XCTAssertEqual(longer.end, CGPoint(x: 400, y: 220))
        XCTAssertEqual(longer.lineWidth, 4, "改端点不碰样式")

        let offscreen = arrow.applyingResize(.head, to: CGPoint(x: 5000, y: -5000), limit: screen)
        XCTAssertEqual(offscreen.end, CGPoint(x: screen.maxX, y: screen.minY))

        let tail = arrow.applyingResize(.tail, to: CGPoint(x: 80, y: 100), limit: screen)
        XCTAssertEqual(tail.start, CGPoint(x: 80, y: 100))
        XCTAssertEqual(tail.end, CGPoint(x: 260, y: 150))
    }

    /// 文字：拖角改的是**字号**，不是把字拉扁；对角钉住；取整；不越量程。
    func testTextCornerDragChangesFontSizeNotAspect() {
        let text = ScreenshotAnnotation(tool: .text, color: red, lineWidth: 2,
                                        start: CGPoint(x: 130, y: 140), text: "标注",
                                        fontSize: 24, bold: true)
        let before = text.textBoxRect
        let grown = text.applyingResize(.box(.bottomRight),
                                        to: CGPoint(x: before.maxX + 120, y: before.maxY + 120),
                                        limit: screen)
        XCTAssertGreaterThan(grown.fontSize, text.fontSize)
        XCTAssertEqual(grown.fontSize, grown.fontSize.rounded(), "字号取整：13.7 号复现不了，缩两下就漂")
        XCTAssertEqual(grown.textBoxRect.minX, before.minX, accuracy: 1, "拖右下，左上那头不该跑")
        XCTAssertEqual(grown.textBoxRect.minY, before.minY, accuracy: 1)
        XCTAssertEqual(grown.text, "标注")
        XCTAssertEqual(grown.bold, true)
        XCTAssertLessThanOrEqual(grown.fontSize, ScreenshotToolStyle.fontRange.upperBound,
                                 "拉到天边也只有 72")

        let tiny = text.applyingResize(.box(.bottomRight),
                                       to: CGPoint(x: before.minX + 7, y: before.minY + 7), limit: screen)
        XCTAssertEqual(tiny.fontSize, ScreenshotToolStyle.fontRange.lowerBound, accuracy: 0.01,
                       "缩到量程底就停住")

        let fromOtherCorner = text.applyingResize(.box(.topLeft),
                                                  to: CGPoint(x: before.minX - 80, y: before.minY - 80),
                                                  limit: screen)
        XCTAssertGreaterThan(fromOtherCorner.fontSize, text.fontSize)
        XCTAssertEqual(fromOtherCorner.textBoxRect.maxX, before.maxX, accuracy: 1, "拖左上，右下那头钉住")
        XCTAssertEqual(fromOtherCorner.textBoxRect.maxY, before.maxY, accuracy: 1)
    }

    /// 序号没有字号可滑，圈的大小就是粗细；半径有 11 的下限。
    func testNumberCornerDragScalesTheBadge() {
        let number = ScreenshotAnnotation(tool: .number, color: red, lineWidth: 4,
                                          start: CGPoint(x: 200, y: 200), number: 3)
        XCTAssertEqual(number.badgeRadius, 11, "前提：默认粗细 4 的徽标正卡在下限上")
        let box = number.editBox
        let big = number.applyingResize(.box(.bottomRight),
                                        to: CGPoint(x: box.maxX + 44, y: box.maxY + 44), limit: screen)
        XCTAssertGreaterThan(big.badgeRadius, 11)
        XCTAssertGreaterThan(big.lineWidth, number.lineWidth)
        XCTAssertEqual(big.editBox.minX, box.minX, accuracy: 1, "左上那头钉住")
        XCTAssertEqual(big.editBox.minY, box.minY, accuracy: 1)
        XCTAssertEqual(big.number, 3, "缩放不改编号")

        let small = number.applyingResize(.box(.bottomRight),
                                          to: CGPoint(x: box.minX + 8, y: box.minY + 8), limit: screen)
        XCTAssertEqual(small.badgeRadius, 11, "数字总比圈大就没法看了 —— 缩到下限停住")
    }

    // MARK: - 改一条：换样式

    /// 面板那套值整包换进去，几何一个字不动。
    func testStyledSwapsTheWholeStyleAndKeepsGeometry() {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let style = ScreenshotToolStyle(color: .systemBlue, lineWidth: 9, fontSize: 30,
                                        bold: false, italic: true,
                                        borderColor: .black, backgroundColor: .yellow)
        let restyled = rect.styled(with: style)
        XCTAssertEqual(restyled.rect, rect.rect)
        XCTAssertEqual(restyled.color, .systemBlue)
        XCTAssertEqual(restyled.lineWidth, 9)
        XCTAssertEqual(restyled.fontSize, 30)
        XCTAssertEqual(restyled.bold, false)
        XCTAssertEqual(restyled.italic, true)
        XCTAssertEqual(restyled.borderColor, .black)
        XCTAssertEqual(restyled.backgroundColor, .yellow)
        XCTAssertEqual(restyled.styleValue, style, "下次弹面板得显示同一套值")

        // 取消描边/背景：`styled` 吃的是整套值，nil 就该真的清空。
        let cleared = restyled.styled(with: ScreenshotToolStyle(color: .systemBlue, lineWidth: 9,
                                                                fontSize: 30, bold: false, italic: true,
                                                                borderColor: nil, backgroundColor: nil))
        XCTAssertNil(cleared.borderColor)
        XCTAssertNil(cleared.backgroundColor)
    }

    /// 从自身读出的样式再写回去 = 完全同一条。这条不变式一红，就说明某个字段在
    /// `styleValue` 或 `styled(with:)` 里漏了（两边各写一遍最容易漏在这儿）。
    func testStyleRoundTripsThroughEveryField() {
        let cases = [
            ScreenshotAnnotation(tool: .rect, color: red, lineWidth: 4,
                                 start: CGPoint(x: 120, y: 120), end: CGPoint(x: 260, y: 180)),
            ScreenshotAnnotation(tool: .pen, color: .green, lineWidth: 7,
                                 start: CGPoint(x: 120, y: 120),
                                 points: [CGPoint(x: 120, y: 120), CGPoint(x: 180, y: 160)]),
            ScreenshotAnnotation(tool: .text, color: .blue, lineWidth: 2,
                                 start: CGPoint(x: 130, y: 140), text: "标注", fontSize: 36,
                                 bold: false, italic: true, borderColor: .black),
            ScreenshotAnnotation(tool: .number, color: .white, lineWidth: 9,
                                 start: CGPoint(x: 200, y: 200), number: 7),
        ]
        for item in cases {
            XCTAssertEqual(item.styled(with: item.styleValue), item, "\(item.tool) 的样式往返丢了字段")
        }
    }

    // MARK: - 遮罩：点谁选中谁、拖的是哪一条

    /// 一下按下去既选中又开始挪；后画的压在先画的上面，重叠处该选靠前的那条。
    func testPressOnAShapeSelectsTheTopmostAndMovesIt() throws {
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60)),
                                                 shape(.rect, CGRect(x: 260, y: 150, width: 80, height: 50))])
        XCTAssertEqual(view.annotationIndex(at: CGPoint(x: 260, y: 165)), 1,
                       "这一点同时压在两条的线上，视觉上最靠前的那条先被抓")

        view.pointerDown(CGPoint(x: 260, y: 165), clickCount: 1)
        XCTAssertEqual(view.selectedIndex, 1)
        view.pointerDragged(to: CGPoint(x: 300, y: 185))
        view.pointerReleased()
        XCTAssertEqual(view.annotations[1].rect, CGRect(x: 300, y: 170, width: 80, height: 50))
        XCTAssertEqual(view.annotations[0].rect, CGRect(x: 120, y: 120, width: 140, height: 60),
                       "另一条一点不动")
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 100, width: 300, height: 300),
                       "挪注解不该把整块选区带走")
    }

    /// 选中之后再把同一处一按：不是手柄的地儿就还是「挪整条」，不会退化成缩框。
    func testPressingTheSameShapeAgainStillMovesIt() throws {
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))])
        view.pointerDown(CGPoint(x: 120, y: 130), clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(view.selectedIndex, 0)
        XCTAssertNil(view.selectedGrab(at: CGPoint(x: 120, y: 130)),
                     "离手柄 20pt 的那一段线该交还给平移")
        XCTAssertTrue(view.hideToolPanel(), "前提：选中后面板弹出来了")

        view.pointerDown(CGPoint(x: 120, y: 130), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 120, y: 170))
        XCTAssertEqual(view.annotations[0].rect, CGRect(x: 120, y: 160, width: 140, height: 60),
                       "第二次按下去还是挪，不是缩框")
        view.pointerReleased()
    }

    /// 把手只有选中了才露出来：没选中时照着某条的角一按，是选中并挪它，不是当场缩框。
    func testHandlesOnlyExistOnTheSelectedShape() throws {
        let second = shape(.rect, CGRect(x: 120, y: 220, width: 140, height: 60))
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60)),
                                                 second])
        XCTAssertNil(view.selectedGrab(at: CGPoint(x: 260, y: 180)), "没选中就不该有把手")

        view.selectAnnotation(0)
        XCTAssertEqual(view.selectedGrab(at: CGPoint(x: 260, y: 180)), .box(.bottomRight))
        XCTAssertNil(view.selectedGrab(at: CGPoint(x: 260, y: 280)), "另一条的角不该跟着亮")

        view.pointerDown(CGPoint(x: 260, y: 180), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 300, y: 220))
        XCTAssertEqual(view.annotations[0].rect, CGRect(x: 120, y: 120, width: 180, height: 100))
        XCTAssertEqual(view.annotations[1].rect, second.rect)
        view.pointerReleased()
        XCTAssertEqual(view.history.count, 1, "一次拖动 = 一步撤销")

        view.selectAnnotation(nil)
        XCTAssertNil(view.selectedGrab(at: CGPoint(x: 300, y: 220)))
    }

    /// 按住选中那条的角拖 = 缩放它；选区、其他条都不动。
    func testHandleDragResizesTheSelectedShapeOnly() throws {
        let other = shape(.ellipse, CGRect(x: 120, y: 240, width: 100, height: 40))
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60)),
                                                 other])
        view.selectAnnotation(0)
        XCTAssertTrue(view.hideToolPanel())

        view.pointerDown(CGPoint(x: 260, y: 180), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 320, y: 240))
        XCTAssertEqual(view.annotations[0].rect, CGRect(x: 120, y: 120, width: 200, height: 120))
        XCTAssertEqual(view.annotations[1].rect, other.rect)
        XCTAssertEqual(view.selection, CGRect(x: 100, y: 100, width: 300, height: 300),
                       "改注解不该动选区")
        view.pointerReleased()
        XCTAssertEqual(view.history.count, 1)
    }

    /// 空心框的中间还是「平移整块选区」：画一个大框不该把框里那块吞掉。
    func testClickingTheHollowCentreStillPansTheSelection() throws {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let view = try editedScene(annotations: [rect])
        view.selectAnnotation(0)
        XCTAssertTrue(view.hideToolPanel())

        view.pointerDown(CGPoint(x: 190, y: 150), clickCount: 1)
        XCTAssertNil(view.selectedIndex, "点着空处先把选中交还掉")
        view.pointerDragged(to: CGPoint(x: 230, y: 170))
        XCTAssertEqual(view.selection, CGRect(x: 140, y: 120, width: 300, height: 300))
        XCTAssertEqual(view.annotations[0].rect, rect.rect, "注解不跟着选区跑")
        view.pointerReleased()
    }

    /// 选区边框那一按归边框：注解的墨迹正好压在上面时也不能抢走（先改框）。
    func testSelectionBorderOutranksAnAnnotationUnderIt() throws {
        let block = shape(.mosaic, CGRect(x: 60, y: 120, width: 80, height: 60))
        let view = try editedScene(annotations: [block])
        XCTAssertTrue(block.contains(CGPoint(x: 100, y: 150), slop: 6), "前提：这一点确实压在打码块上")

        view.pointerDown(CGPoint(x: 100, y: 150), clickCount: 1)
        XCTAssertNil(view.selectedIndex, "这一按该归选区左边界")
        view.pointerDragged(to: CGPoint(x: 140, y: 150))
        XCTAssertEqual(view.selection, CGRect(x: 140, y: 100, width: 260, height: 300))
        XCTAssertEqual(view.annotations[0].rect, block.rect, "打码块一点没动")
        view.pointerReleased()
    }

    /// 装了工具、**拖**出去还是画新的：起点压在已有注解上也照样落笔。这一半口径没变 ——
    /// 变了的是「点一下不拖」那一半（见 `testTappingAnAnnotationWithAToolArmedSelectsIt…`），
    /// 想在框里再框一块靠的就是这一条。
    func testArmedToolDrawsInsteadOfSelecting() throws {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let view = try editedScene(annotations: [rect])
        view.tool = .rect
        view.pointerDown(CGPoint(x: 120, y: 150), clickCount: 1)
        XCTAssertNotNil(view.draft, "装了工具，这一按是画新的")
        XCTAssertNil(view.selectedIndex)
        view.pointerDragged(to: CGPoint(x: 220, y: 170))
        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 2)
        XCTAssertEqual(view.annotations[0].rect, rect.rect, "画新的一笔不该挪动旧的")
    }

    // MARK: - 编辑入口的新口径（用户 2026-10-19：「要取消掉工具选择才能点选对应的框」）

    /// 装了矩形格，**点**在已画的框上（按下去没拖出东西）= 选中它，而不是在原地画一条
    /// 谁都没要的 0×0 空注解。这一条就是用户报的那件事：摘掉工具那一步整个取消掉。
    func testTappingAnAnnotationWithAToolArmedSelectsItInsteadOfDrawing() throws {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let view = try editedScene(annotations: [rect])
        view.tool = .rect
        view.pointerDown(CGPoint(x: 120, y: 150), clickCount: 1)
        XCTAssertNotNil(view.draft, "前提：装了工具，按下那一刻先按「画新笔」起笔")
        XCTAssertEqual(view.tapSelectCandidate, 0, "压着的那条先记成候选，等松手再定")

        view.pointerDragged(to: CGPoint(x: 121, y: 151))   // 两像素的抖，不到一条注解的最小尺寸
        view.pointerReleased()
        XCTAssertNil(view.draft)
        XCTAssertNil(view.tapSelectCandidate, "结算过一次就该清账")
        XCTAssertEqual(view.annotations.count, 1, "点一下不该在原地留下一条空注解")
        XCTAssertEqual(view.annotations[0].rect, rect.rect, "旧的一条一点没动")
        XCTAssertEqual(view.selectedIndex, 0)
        XCTAssertEqual(view.panelOwner(), .annotation(0), "点它就是要改它：面板跟着给它调")
        XCTAssertEqual(view.tool, .rect, "点选不摘工具：改完这条接着画下一条")
    }

    /// 同一条线上按下去**拖**出去 = 照旧画新的一条，那一笔记的候选作废。
    /// 反过来（按下就选中）会让「在大框里再框一小块」变成挪大框 —— 那是更常做的事。
    func testDraggingFromAnAnnotationWithAToolArmedStillDraws() throws {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let view = try editedScene(annotations: [rect])
        view.tool = .rect
        view.pointerDown(CGPoint(x: 120, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 180, y: 170))
        XCTAssertEqual(view.tapSelectCandidate, 0, "前提：起点确实压着那一条")
        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 2, "拖出去了就是画新笔")
        XCTAssertEqual(view.annotations[0].rect, rect.rect, "旧的一条不该被挪走")
        XCTAssertEqual(view.annotations[1].rect, CGRect(x: 120, y: 150, width: 60, height: 20))
        XCTAssertNil(view.tapSelectCandidate, "画成了就该把候选清掉，别留到下一按")
    }

    /// 每一笔画完就是「现在要改的那条」：把手当场就能按、面板改的是它，不用摘工具再点一次。
    /// 工具仍装着 —— 画完想接着画下一条是同一条路。
    func testEveryFreshStrokeComesSelected() throws {
        let view = try editedScene()
        view.tool = .rect
        view.pointerDown(CGPoint(x: 120, y: 120), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 220, y: 180))
        view.pointerReleased()
        XCTAssertEqual(view.selectedIndex, 0, "画完这一条马上就是选中那条")
        XCTAssertEqual(view.panelOwner(), .annotation(0))
        XCTAssertEqual(view.selectedGrab(at: CGPoint(x: 220, y: 180)), .box(.bottomRight),
                       "把手当场就能按，不必先摘工具")

        view.pointerDown(CGPoint(x: 120, y: 250), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 200, y: 280))
        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 2)
        XCTAssertEqual(view.selectedIndex, 1, "选中跟着最新那一笔走")
        XCTAssertNil(view.selectedGrab(at: CGPoint(x: 220, y: 180)), "上一条的把手该收回去")
        XCTAssertEqual(view.tool, .rect, "画完不摘工具")
    }

    /// 选中的那一条优先于装着的工具：按在它身上（线上 / 把手上）就是改它。
    /// 这一条和上一条是同一件事的两半 —— 画完自动选中之后，「马上挪它」必须还能挪。
    func testSelectedShapeOutranksTheArmedTool() throws {
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))])
        view.selectAnnotation(0)
        view.tool = .rect
        // 左边线上、离上下两个角和边中点都远的一段：还是「挪整条」，不是缩框、不是画新的。
        view.pointerDown(CGPoint(x: 120, y: 132), clickCount: 1)
        XCTAssertNil(view.draft, "选中那条身上这一按不是画新笔")
        view.pointerDragged(to: CGPoint(x: 160, y: 152))
        XCTAssertEqual(view.annotations[0].rect, CGRect(x: 160, y: 140, width: 140, height: 60))
        XCTAssertEqual(view.annotations.count, 1, "挪它，不是又画一条")
        view.pointerReleased()

        view.pointerDown(CGPoint(x: 300, y: 200), clickCount: 1)   // 右下角把手
        XCTAssertNil(view.draft, "把手那一下也不是画新笔")
        XCTAssertEqual(view.selectedGrab(at: CGPoint(x: 300, y: 200)), .box(.bottomRight), "前提")
        view.pointerDragged(to: CGPoint(x: 320, y: 220))
        XCTAssertEqual(view.annotations[0].rect, CGRect(x: 160, y: 140, width: 160, height: 80))
        view.pointerReleased()
        XCTAssertEqual(view.history.count, 2, "挪一下 + 缩一下 = 两步撤销")
    }

    /// 文字那一格按下去就出输入框，等不到松手看位移 —— 所以「点它=选中它」必须在按下
    /// 那一刻分家：按在自己写的字上 = 选中它（不起新框），按在空处 = 照旧写字。
    func testTextCellDecidesAtPressTime() throws {
        let text = ScreenshotAnnotation(tool: .text, color: .systemBlue, lineWidth: 2,
                                        start: CGPoint(x: 130, y: 140), text: "标注", fontSize: 40)
        let view = try editedScene(annotations: [text])
        view.tool = .text

        view.pointerDown(CGPoint(x: 140, y: 150), clickCount: 1)
        XCTAssertNil(view.textEditor, "按在自己写的字上不该再起一个框写字")
        XCTAssertNil(view.tapSelectCandidate, "按下就定了的两格不记候选")
        XCTAssertEqual(view.selectedIndex, 0)
        view.pointerReleased()

        view.pointerDown(CGPoint(x: 280, y: 130), clickCount: 1)
        XCTAssertNotNil(view.textEditor, "按在空处还是写字")
        XCTAssertNil(view.editingAnnotationIndex, "新起的一框不是改旧字")
        view.pointerReleased()
    }

    /// 序号那一格同上：按在已画的东西上 = 选中它，不另盖一个章；按在空处 = 照旧盖章。
    /// 用户要的是「点它就能改它」，而不是「先在哪个数字上补一个洞」。
    func testNumberCellDecidesAtPressTime() throws {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let view = try editedScene(annotations: [rect])
        view.tool = .number

        view.pointerDown(CGPoint(x: 120, y: 132), clickCount: 1)
        XCTAssertEqual(view.selectedIndex, 0, "按在框线上 = 选中它")
        XCTAssertEqual(view.annotations.count, 1, "不该凭空多出一个章")
        view.pointerReleased()

        view.pointerDown(CGPoint(x: 300, y: 150), clickCount: 1)
        XCTAssertEqual(view.annotations.count, 2, "按在空处才盖章")
        XCTAssertEqual(view.annotations[1].tool, .number)
        XCTAssertEqual(view.annotations[1].number, 1)
    }

    /// 双击已写的字 = 把它的字请回输入框改：框盖在原字上、样式读那一条自己的，
    /// 提交只换内容。这是「点它=选中它」之后给改旧字留的唯一一条路。
    func testDoubleClickOnTextReopensItsContent() throws {
        let text = ScreenshotAnnotation(tool: .text, color: .systemBlue, lineWidth: 2,
                                        start: CGPoint(x: 130, y: 140), text: "标注",
                                        fontSize: 40, bold: true, italic: true,
                                        borderColor: .black, backgroundColor: .yellow)
        let view = try editedScene(annotations: [text])
        let spot = CGPoint(x: 140, y: 150)
        view.pointerDown(spot, clickCount: 1)
        view.pointerReleased()
        view.pointerDown(spot, clickCount: 2)

        let field = try XCTUnwrap(view.textEditor, "双击旧文字没把字请回输入框")
        XCTAssertEqual(view.editingAnnotationIndex, 0, "这一趟是在改第 0 条，不是新写一条")
        XCTAssertEqual(field.stringValue, "标注", "框里装的是那一条自己的字")
        XCTAssertEqual(field.font, text.textFont, "样式跟那条走，不是面板当前那套")
        // 逐分量比而不是整只 CGPoint：`XCTAssertEqual(_, _, accuracy:)` 只吃标量，
        // 拿 CGPoint 传进去编译就过不去（而「不跳位」要量的正是这两个分量）。
        XCTAssertEqual(field.frame.origin.x, text.start.x, accuracy: 0.5)
        XCTAssertEqual(field.frame.origin.y, text.start.y, accuracy: 0.5, "框盖在原字上，不跳位")

        field.stringValue = "改好的字"
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(field.action),
                                       to: try XCTUnwrap(field.target), from: field),
                      "回车那条派发没打到遮罩上")
        XCTAssertEqual(view.annotations.count, 1, "改字不是再画一条")
        let edited = try XCTUnwrap(view.annotations.first)
        XCTAssertEqual(edited.text, "改好的字")
        XCTAssertEqual(edited.start, text.start, "位置一个像素不动")
        XCTAssertEqual(edited.fontSize, 40)
        XCTAssertTrue(edited.italic)
        XCTAssertEqual(edited.backgroundColor, .yellow, "只改内容，描边/背景不该被重铺")
    }

    /// 没装工具时双击也一样能改 —— 用户不必为了改一个字先去点文字那一格。
    func testDoubleClickOnTextWorksWithNoToolArmed() throws {
        let text = ScreenshotAnnotation(tool: .text, color: .systemBlue, lineWidth: 2,
                                        start: CGPoint(x: 130, y: 140), text: "标注", fontSize: 40)
        let view = try editedScene(annotations: [text])
        XCTAssertNil(view.tool, "前提：一个工具都没装")
        view.pointerDown(CGPoint(x: 140, y: 150), clickCount: 1)
        view.pointerReleased()
        view.pointerDown(CGPoint(x: 140, y: 150), clickCount: 2)
        XCTAssertNotNil(view.textEditor)
        XCTAssertEqual(view.editingAnnotationIndex, 0)
    }

    /// 双击没压在文字上（压着矩形框的线、或空处）还是老手感：复制并收起。
    /// 这一条是反向对照 —— 上面那两条改的是同一个门，别的落点要是也被拐走就红了。
    func testDoubleClickElsewhereStillCopies() throws {
        let rect = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let view = try editedScene(annotations: [rect])
        var finished = 0
        view.onFinish = { _, _, _ in finished += 1 }
        view.pointerDown(CGPoint(x: 120, y: 150), clickCount: 2)
        XCTAssertNil(view.textEditor, "框线上双击不是改字")
        XCTAssertEqual(finished, 1, "双击压在框线上仍是复制并收起")

        let blank = try editedScene(annotations: [rect])
        var blankFinished = 0
        blank.onFinish = { _, _, _ in blankFinished += 1 }
        blank.pointerDown(CGPoint(x: 300, y: 260), clickCount: 2)
        XCTAssertEqual(blankFinished, 1, "空处双击也照旧")
    }

    /// 把字删空再提交 = 这一条不要了：留一块空底衬在屏上，谁都不认那是自己想要的。
    /// 撤销还能把它连同原来那套样式放回来（删这一条是一步，不是把整场清空）。
    func testCommittingAnEmptiedTextRemovesThatAnnotation() throws {
        let text = ScreenshotAnnotation(tool: .text, color: .systemBlue, lineWidth: 2,
                                        start: CGPoint(x: 130, y: 140), text: "标注", fontSize: 40)
        let block = shape(.rect, CGRect(x: 200, y: 220, width: 80, height: 40))
        let view = try editedScene(annotations: [text, block])
        view.pointerDown(CGPoint(x: 140, y: 150), clickCount: 1)
        view.pointerReleased()
        view.pointerDown(CGPoint(x: 140, y: 150), clickCount: 2)
        let field = try XCTUnwrap(view.textEditor)
        field.stringValue = "   "
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(field.action),
                                       to: try XCTUnwrap(field.target), from: field))
        XCTAssertEqual(view.annotations.count, 1, "字删空 = 这一条没了")
        XCTAssertEqual(view.annotations[0].rect, block.rect, "删的该是被改的那一条，不是别的")
        XCTAssertNil(view.selectedIndex, "那条没了，下标不能留着指到别的上")
        view.undo()
        XCTAssertEqual(view.annotations, [text, block], "撤销放回原来那两条")
    }

    /// 改到一半按 Esc 只丢这一趟输入：旧字原样留着，会话也别跟着丢。
    ///
    /// 走的是输入框那条 delegate（`control(_:textView:doCommandBy:)`）—— 它只读
    /// `commandSelector`，`textView` 那块在本用例里没人看，所以拿不到真 field editor 时
    /// 给一块空的即可，判定不变。
    func testEscInsideTheFieldLeavesTheOldTextAlone() throws {
        let text = ScreenshotAnnotation(tool: .text, color: .systemBlue, lineWidth: 2,
                                        start: CGPoint(x: 130, y: 140), text: "标注", fontSize: 40)
        let view = try editedScene(annotations: [text])
        var cancelled = 0
        view.onCancel = { cancelled += 1 }
        view.pointerDown(CGPoint(x: 140, y: 150), clickCount: 1)
        view.pointerReleased()
        view.pointerDown(CGPoint(x: 140, y: 150), clickCount: 2)
        let field = try XCTUnwrap(view.textEditor)
        field.stringValue = "改到一半"
        let editor = (field.currentEditor() as? NSTextView) ?? NSTextView()

        XCTAssertTrue(view.control(field, textView: editor,
                                   doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertNil(view.textEditor, "输入框该收了")
        XCTAssertEqual(view.annotations.first?.text, "标注", "Esc 是把这一趟丢掉，不是提交半截")
        XCTAssertEqual(cancelled, 0, "输入框里的 Esc 不该把整次截图也丢掉")
    }

    // MARK: - 面板：只给被选中的那一条调

    /// 选中一条 → 面板弹在它自己那一格上方，显示的是**这条**的样式。
    func testSelectingAShapePopsThePanelOnItsOwnToolCell() throws {
        let view = try editedScene(annotations: [
            ScreenshotAnnotation(tool: .text, color: .systemBlue, lineWidth: 2,
                                 start: CGPoint(x: 130, y: 140), text: "标注",
                                 fontSize: 40, bold: true, italic: true, backgroundColor: .yellow),
        ])
        XCTAssertNil(view.toolPanel, "没选中就没有面板")

        view.pointerDown(CGPoint(x: 140, y: 150), clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(view.panelOwner(), .annotation(0))
        let panel = try XCTUnwrap(view.toolPanel, "选中一条文字注解后面板没浮出来")
        XCTAssertFalse(panel.isHidden)
        XCTAssertEqual(panel.tool, .text)
        XCTAssertEqual(panel.style.fontSize, 40, "显示的是这条自己的字号，不是工具默认那档")
        XCTAssertTrue(panel.style.italic)
        XCTAssertEqual(panel.style.color, .systemBlue)
        XCTAssertEqual(panel.style.backgroundColor, .yellow)

        let bar = try XCTUnwrap(view.toolbar)
        let cell = try XCTUnwrap(bar.cellRect(for: .text))
        XCTAssertGreaterThan(cell.midX - ScreenshotToolPanelView.width / 2,
                             bar.frame.minX + ScreenshotSelectionView.toolbarMargin,
                             "前提：这一格的面板不会被钳位，居中断言才有意义")
        XCTAssertEqual(panel.frame.midX, cell.midX, accuracy: 1, "面板钉在它自己那一格上")
        XCTAssertGreaterThanOrEqual(panel.frame.minX, bar.frame.minX, "横向不许探出条子")
        XCTAssertLessThanOrEqual(panel.frame.maxX, bar.frame.maxX)
    }

    /// 面板改的是被选中的那一条：同工具的另一条不受影响，那一格工具的默认值也不受影响。
    func testPanelEditsOnlyTheSelectedAnnotation() throws {
        let first = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let view = try editedScene(annotations: [first,
                                                 shape(.rect, CGRect(x: 120, y: 220, width: 140, height: 50))])
        view.pointerDown(CGPoint(x: 120, y: 150), clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(view.selectedIndex, 0)

        let panel = try XCTUnwrap(view.toolPanel)
        panel.press(cell: "color")
        panel.press(cell: "palette.2")   // 绿
        XCTAssertEqual(view.annotations[0].color, ScreenshotToolbarView.palette[2])
        XCTAssertEqual(view.annotations[1].color, ScreenshotToolbarView.palette[0],
                       "另一条同工具的该还是原来那支红笔（用户定的：只改被选中的那一条）")
        XCTAssertNil(view.styles[.rect], "改旧的一条不该顺手把下一笔的默认值也刷掉")
        XCTAssertEqual(view.annotations[0].rect, first.rect, "改样式不碰几何")
    }

    /// 换一条不同工具的注解，面板跟着跳到它那一格、跟着换成它那一套值。
    func testThePanelFollowsTheNewlySelectedAnnotation() throws {
        let arrow = ScreenshotAnnotation(tool: .arrow, color: .systemBlue, lineWidth: 9,
                                         start: CGPoint(x: 130, y: 250), end: CGPoint(x: 240, y: 200))
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60)),
                                                 arrow])
        view.selectAnnotation(0)
        let panel = try XCTUnwrap(view.toolPanel)
        XCTAssertEqual(panel.tool, .rect)
        XCTAssertEqual(panel.style.lineWidth, 4)

        view.selectAnnotation(1)
        XCTAssertEqual(view.panelOwner(), .annotation(1))
        XCTAssertEqual(panel.tool, .arrow)
        XCTAssertEqual(panel.style.color, .systemBlue)
        XCTAssertEqual(panel.style.lineWidth, 9, "面板得换成这支箭自己的粗细")

        view.selectAnnotation(nil)
        XCTAssertNil(view.panelOwner(), "没选中、又没装工具 → 没得给")
        XCTAssertTrue(panel.isHidden)
    }

    /// 拿起工具 = 不再编辑那一条：选中交还掉，面板改的回到「下一笔」。
    func testPickingAToolDropsTheAnnotationSelection() throws {
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))])
        view.selectAnnotation(0)
        XCTAssertEqual(view.panelOwner(), .annotation(0))
        view.toolbar?.onTool?(.arrow)
        XCTAssertNil(view.selectedIndex, "拿起工具 = 不再编辑那一条")
        XCTAssertEqual(view.panelOwner(), .tool(.arrow))
    }

    /// 打码既不吃色也不吃粗细：选中它不弹面板。
    func testMosaicSelectionKeepsThePanelAway() throws {
        let view = try editedScene(annotations: [shape(.mosaic, CGRect(x: 120, y: 120, width: 140, height: 60))])
        view.pointerDown(CGPoint(x: 190, y: 150), clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(view.selectedIndex, 0, "打码块本身还是要能挪的")
        XCTAssertNil(view.panelOwner(), "弹一块只有灰控件的面板等于骗用户点")
        XCTAssertTrue(view.toolPanel?.isHidden ?? true)
    }

    // MARK: - 出口：删那一条 / 一层层退

    /// 选中之后按删除键只删那一条；撤销还能把它连同位置一起放回来。
    func testDeleteRemovesOnlyTheSelectedOne() throws {
        let first = shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        let second = shape(.ellipse, CGRect(x: 120, y: 220, width: 100, height: 50))
        let view = try editedScene(annotations: [first, second])
        view.pointerDown(CGPoint(x: 120, y: 150), clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(view.selectedIndex, 0)

        view.keyDown(with: try backspaceKey())
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.annotations[0].rect, second.rect, "删的该是选中的那条")
        XCTAssertNil(view.selectedIndex, "那条已经不存在了，下标不能留着指到别的上")
        XCTAssertEqual(view.history.count, 1)

        view.undo()
        XCTAssertEqual(view.annotations.count, 2)
        XCTAssertEqual(view.annotations, [first, second], "撤销要放回原来那两条")
    }

    /// 没选中时删除键还是老行为：撤掉最后画的那条。
    ///
    /// 「画完即选中」之后这一态得**再取消一次**才造得出来：画完那一条马上就是选中态，
    /// 只把工具摘掉不会把选中交还（老写法 `tool = nil` 之后还断言 `selectedIndex` 是 nil，
    /// 那是「装了工具画完就什么都没选」的旧口径，现在口径变了）。
    func testDeleteWithoutSelectionFallsBackToUndo() throws {
        let view = try editedScene()
        view.tool = .rect
        view.pointerDown(CGPoint(x: 120, y: 120), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 220, y: 180))
        view.pointerReleased()
        view.tool = nil
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.selectedIndex, 0, "前提：画完即选中 —— 刚画的那条就是选中态")
        view.selectAnnotation(nil)
        XCTAssertNil(view.selectedIndex)

        view.keyDown(with: try backspaceKey())
        XCTAssertTrue(view.annotations.isEmpty, "没选中就退回「撤掉最后画的一条」")
        XCTAssertEqual(view.future.count, 1)
        view.redo()
        XCTAssertEqual(view.annotations.count, 1)
    }

    /// Esc 一层层退：先收面板，再取消选中，最后才丢掉整个会话。
    func testEscStepsOutOneLayerAtATime() throws {
        var cancelled = 0
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))])
        view.onCancel = { cancelled += 1 }
        view.pointerDown(CGPoint(x: 120, y: 150), clickCount: 1)
        view.pointerReleased()
        XCTAssertFalse(view.toolPanel?.isHidden ?? true, "前提：面板开着")

        view.keyDown(with: try escKey())
        XCTAssertTrue(view.toolPanel?.isHidden ?? true, "第一层只收面板")
        XCTAssertEqual(view.selectedIndex, 0, "选中的那条还在")
        XCTAssertEqual(cancelled, 0)

        view.keyDown(with: try escKey())
        XCTAssertNil(view.selectedIndex, "第二层取消选中")
        XCTAssertEqual(cancelled, 0)

        view.keyDown(with: try escKey())
        XCTAssertEqual(cancelled, 1, "第三层才丢掉会话")
    }

    /// 收过面板之后再点它：面板重新弹出来，Esc 不等于「这条改不了了」。
    func testPressingTheShapeAgainReopensThePanel() throws {
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))])
        view.pointerDown(CGPoint(x: 120, y: 150), clickCount: 1)
        view.pointerReleased()
        view.keyDown(with: try escKey())
        XCTAssertTrue(view.toolPanel?.isHidden ?? true)

        view.pointerDown(CGPoint(x: 190, y: 120), clickCount: 1)
        view.pointerReleased()
        XCTAssertFalse(view.toolPanel?.isHidden ?? true, "重新点它就是「要调这块」的意思")
    }

    // MARK: - 撤销的粒度

    /// 同一条拖两次 = 两步撤销，撤两次才回到今天最早那一态；撤销顺手把选中交还掉。
    func testOneDragIsOneUndoStep() throws {
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))])
        view.pointerDown(CGPoint(x: 120, y: 150), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 160, y: 170))
        view.pointerReleased()
        XCTAssertEqual(view.annotations[0].rect, CGRect(x: 160, y: 140, width: 140, height: 60))
        XCTAssertEqual(view.history.count, 1)

        // 左边线上、离上下两个角和边中点都远的一段：还是「挪整条」。
        view.pointerDown(CGPoint(x: 160, y: 152), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 200, y: 152))
        view.pointerReleased()
        XCTAssertEqual(view.annotations[0].rect, CGRect(x: 200, y: 140, width: 140, height: 60))
        XCTAssertEqual(view.history.count, 2, "第二次挪该另记一步，不能和第一次并成一步")

        view.undo()
        XCTAssertEqual(view.annotations[0].rect, CGRect(x: 160, y: 140, width: 140, height: 60))
        view.undo()
        XCTAssertEqual(view.annotations[0].rect, CGRect(x: 120, y: 120, width: 140, height: 60))
        XCTAssertNil(view.selectedIndex, "撤销把那条换掉了，下标留着就会指错")
        XCTAssertTrue(view.toolPanel?.isHidden ?? true, "面板也得跟着收")
    }

    /// 按下没拖动不占一步撤销；一次滑杆手势回吐上百次也只算一步。
    func testGesturesThatChangeNothingOrFireManyTimesAreOneStep() throws {
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))])
        view.pointerDown(CGPoint(x: 120, y: 150), clickCount: 1)
        view.pointerReleased()
        XCTAssertTrue(view.history.isEmpty, "一下没挪动的按不该占一步")

        let panel = try XCTUnwrap(view.toolPanel)
        for step in 1 ... 30 {
            let track = try XCTUnwrap(panel.actionableRect(forCell: "slider"))
            panel.press(cell: "slider",
                        trackX: track.minX + track.width * CGFloat(step) / 30 - panel.frame.minX)
        }
        XCTAssertEqual(view.annotations[0].lineWidth, ScreenshotToolStyle.widthRange.upperBound,
                       "按到最右端就该是量程上限")
        XCTAssertTrue(view.history.isEmpty, "手势还没结算，不该提前记账")

        view.selectAnnotation(nil)
        XCTAssertEqual(view.history.count, 1, "一整个手势 = 一步撤销")
        view.undo()
        XCTAssertEqual(view.annotations[0].lineWidth, 4)
    }

    /// 面板改完样式紧接着画新的：先结算这一路，撤销才是一笔一笔退，而不是把两笔一起吞掉。
    func testDiscreteChangeAfterAPanelGestureSettlesFirst() throws {
        let view = try editedScene(annotations: [shape(.rect, CGRect(x: 120, y: 120, width: 140, height: 60))])
        view.selectAnnotation(0)
        let panel = try XCTUnwrap(view.toolPanel)
        panel.press(cell: "color")
        panel.press(cell: "palette.2")

        view.tool = .rect
        view.pointerDown(CGPoint(x: 130, y: 250), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 200, y: 280))
        view.pointerReleased()
        XCTAssertEqual(view.annotations.count, 2)
        XCTAssertEqual(view.history.count, 2, "改样式 + 画新的 = 两步")

        view.undo()
        XCTAssertEqual(view.annotations.count, 1, "先撤新画的那条")
        XCTAssertEqual(view.annotations[0].color, ScreenshotToolbarView.palette[2],
                       "上一条样式改动不该被这一笔一起带走")
        view.undo()
        XCTAssertEqual(view.annotations[0].color, ScreenshotToolbarView.palette[0])
    }

    // MARK: - 渲染取证：选中框只留在屏上，不进成品图

    /// 选中那条之后遮罩上确实多了圈虚线，而且一个像素都没跑到框外。
    func testSelectionChromeIsPaintedAndStaysInsideTheBox() throws {
        let view = try editedScene(NSSize(width: 900, height: 600),
                                   annotations: [shape(.rect, CGRect(x: 140, y: 160, width: 180, height: 100))])
        let bare = try render(view)
        view.selectAnnotation(0)
        XCTAssertTrue(view.hideToolPanel(), "前提：面板开着会把差异带到面板那一片")
        let shown = try render(view)
        // 反向对照：同一个状态连拍两张必须一模一样，否则上面那些差异不知道是谁带来的。
        XCTAssertEqual(rawBytes(shown), rawBytes(try render(view)), "离屏渲染不确定，差异判据不能用")

        let box = view.annotations[0].editBox
        let scale = CGFloat(shown.pixelsWide) / view.bounds.width
        let hits = differingPixels(bare, shown)
        XCTAssertGreaterThan(hits.count, 100, "一圈虚线 + 八颗把手不可能只有几十像素")
        for hit in hits {
            let point = CGPoint(x: CGFloat(hit.x) / scale, y: CGFloat(hit.y) / scale)
            XCTAssertTrue(box.insetBy(dx: -9, dy: -9).contains(point),
                          "差异跑到选中框外面了：\(point) ∉ \(box)")
        }
        try dump(shown, name: "annotation-chrome-rect.png")
        // 虚线：上沿那一行既有差、又留着没差的空档 —— 画成实线框就是这里红。
        //
        // 数的是**列**不是像素：一笔 1 点宽的横线在 2x 屏上占两行像素，按像素数会算出
        // 2×边长，判据得和 `span` 同单位才比得出「占了几成」。上下各带一行是给描边留
        // 的余量（落在哪一行取决于取整），同一列只算一次。
        let row = Int((box.minY * scale).rounded())
        let left = Int((box.minX + 4) * scale), right = Int((box.maxX - 4) * scale)
        let columns = Set(hits.filter { abs($0.y - row) <= 1 && $0.x > left && $0.x < right }.map { $0.x })
        let span = right - left
        XCTAssertGreaterThan(columns.count, span * 2 / 5, "上沿只有一小截：虚线没铺满整条边？")
        XCTAssertLessThan(columns.count, span * 3 / 4, "上沿铺满了：那是实线框，不是虚线")

        // 文字那条：`rect` 是零面积的锚点，框必须钉在**实际占到的地方**（textBoxRect）。
        // 拿 rect 画会缩成锚点上的一坨 —— 差异既少又全跑到 textBoxRect 外，两头都红。
        let textView = try editedScene(NSSize(width: 900, height: 600),
                                       annotations: [ScreenshotAnnotation(tool: .text, color: red, lineWidth: 2,
                                                                          start: CGPoint(x: 150, y: 170),
                                                                          text: "这是一行标注", fontSize: 24)])
        let textBare = try render(textView)
        textView.selectAnnotation(0)
        XCTAssertTrue(textView.hideToolPanel())
        let textShown = try render(textView)
        let textHits = differingPixels(textBare, textShown)
        let textBox = textView.annotations[0].editBox
        XCTAssertGreaterThan(textHits.count, 80, "文字那条的选中框缩没了：\(textBox)")
        for hit in textHits {
            let point = CGPoint(x: CGFloat(hit.x) / scale, y: CGFloat(hit.y) / scale)
            XCTAssertTrue(textBox.insetBy(dx: -9, dy: -9).contains(point),
                          "文字的选中框画到它实际占的地方之外了：\(point) ∉ \(textBox)")
        }
        try dump(textShown, name: "annotation-chrome-text.png")
    }

    /// 压出选区的那一半不许亮：虚线只在亮区里，和打码辅助线同一条规矩。
    func testChromeIsClippedToTheSelection() throws {
        let view = try editedScene(NSSize(width: 900, height: 600),
                                   annotations: [shape(.rect, CGRect(x: 40, y: 160, width: 180, height: 100))])
        let bare = try render(view)
        view.selectAnnotation(0)
        XCTAssertTrue(view.hideToolPanel())
        let shown = try render(view)

        let hits = differingPixels(bare, shown)
        try dump(shown, name: "annotation-chrome-clipped.png")
        XCTAssertGreaterThan(hits.count, 50, "亮区里那半边总得画出框来，否则这条断言是空转")
        let scale = CGFloat(shown.pixelsWide) / view.bounds.width
        // 留一个像素的容错：裁切边界那一列被抗锯齿抹过半格，不算「画到选区外」。
        let allowed = view.selection.insetBy(dx: -0.6, dy: -0.6)
        let outside = hits.filter { !allowed.contains(CGPoint(x: CGFloat($0.x) / scale,
                                                              y: CGFloat($0.y) / scale)) }
        XCTAssertTrue(outside.isEmpty, "选区外的暗区上被画了 \(outside.count) 个像素：\(outside.prefix(5))")
    }

    /// 成品图一个字节都不该因为选中而改变，也不该带上「画辅助线那支笔」的颜色。
    ///
    /// 两条判据各挡一种错法：
    /// ① 选中前后字节相同 —— 挡「导出偷看遮罩状态」（把 `selectedIndex` 传进合成那条路）；
    /// ② 成品图里一个主色像素都没有 —— 挡「导出视图自己画了一圈框」。那种错法两次渲染
    ///    照样一模一样，①是空转（反向变异 M08 实测：只加①时全绿）。
    func testChromeNeverReachesTheExport() throws {
        let size = NSSize(width: 1000, height: 700)
        let frame = try shot(size)
        let view = try editedScene(size, shot: frame, annotations: [
            shape(.rect, CGRect(x: 140, y: 160, width: 180, height: 100)),
            ScreenshotAnnotation(tool: .text, color: ScreenshotToolbarView.palette[2], lineWidth: 2,
                                 start: CGPoint(x: 160, y: 220), text: "标注", fontSize: 24),
        ])
        let plain = try XCTUnwrap(ScreenshotComposer.compose(shot: frame, selection: view.selection,
                                                             annotations: view.annotations))
        view.selectAnnotation(0)
        let selected = try XCTUnwrap(ScreenshotComposer.compose(shot: frame, selection: view.selection,
                                                                annotations: view.annotations))
        XCTAssertEqual(plain.width, selected.width)
        XCTAssertEqual(rawBytes(plain), rawBytes(selected),
                       "选中框是帮用户看清「抓到哪儿」的辅助线，不该烘进 PNG")

        let accent = NSColor.controlAccentColor
        // 前提：这台机器的强调色得和图里用得着的几种色分得开，否则下面那个 0 是撞色撞出来的。
        let space = NSBitmapImageRep(cgImage: selected).colorSpace ?? .sRGB
        for sample in [red, ScreenshotToolbarView.palette[2], NSColor.white, NSColor.blue,
                       NSColor.green, NSColor.red] {
            XCTAssertGreaterThan(colorDistance(sample, accent, in: space), 0.3,
                                 "\(sample) 和强调色撞了，这条判据在这台机器上量不出东西")
        }
        XCTAssertEqual(nearAccent(NSBitmapImageRep(cgImage: selected), accent: accent, scale: 1), 0,
                       "成品图里出现了画选中框那支笔的颜色：辅助线被烘进 PNG 了")
        // 正对照：同一把尺子量屏上那一版（确实画了虚线 + 把手），量不到就说明上面那个 0 是空转。
        // 量尺限定在选中框那一圈：注解条选中格的蓝底也是主色，不能拿它冒充「框画上了」。
        XCTAssertTrue(view.hideToolPanel(), "前提：面板开着会把主色带到别处去")
        let chrome = try render(view)
        let box = view.annotations[0].editBox
        let scale = CGFloat(chrome.pixelsWide) / view.bounds.width
        XCTAssertGreaterThan(nearAccent(chrome, accent: accent, scale: scale,
                                        region: box.insetBy(dx: -9, dy: -9)), 20,
                             "屏上这一版连主色都量不到，说明尺子有问题，成品图那个 0 不算数")
        try dump(selected, name: "annotation-edit-export.png")
    }

    /// 编辑已写的字时，遮罩上不该同时压着「旧字」和「正在打的字」两层：被改那一条先撤掉
    /// （`drawAnnotations` 跳过 `editingAnnotationIndex`），字只在输入框里活着。
    ///
    /// 判据取遮罩渲染的**差异表**，不数「还剩几个蓝字像素」：底图自己带颜色，绝对值说不清
    /// 是字没了还是别的东西动了。两张渲染之间只拧 `editingAnnotationIndex` 这一个开关，
    /// 差异必须**只**落在那块字上 —— 虚线圈、把手、底图一个像素都不许跟着动。
    ///
    /// 为什么不走「真的把输入框起来再渲染一张」：实测那条路自己会吞掉判据 —— 对已经当
    /// 第一响应者的输入框动 `isHidden` 会触发 `controlTextDidEndEditing`，那一趟编辑立刻
    /// 结算、遮罩重画，两张渲染必然一模一样（前两个版本就是这么被「差异 0」和输入框那
    /// 220×48 的半透底来回骗的）。所以这里只量遮罩自己的画法；「双击确实把开关拨到那一条
    /// 上」由 `testDoubleClickOnTextReopensItsContent` 走真链路证明（它断言
    /// `editingAnnotationIndex == 0`），两条合起来才是完整链路。
    func testTheOldTextStepsOutWhileTheFieldIsUp() throws {
        let text = ScreenshotAnnotation(tool: .text, color: .systemBlue, lineWidth: 2,
                                        start: CGPoint(x: 130, y: 140), text: "标注",
                                        fontSize: 40, backgroundColor: .yellow)
        // 小一号容器：判据按像素面积走，1440×900 一张要跑十几秒。
        let view = try editedScene(NSSize(width: 720, height: 450), annotations: [text])
        let spot = CGPoint(x: 140, y: 150)
        // 先按一下把这条选中：两张渲染都带着同一圈选中辅助线，差异表里才只剩「字在不在」。
        view.pointerDown(spot, clickCount: 1)
        view.pointerReleased()
        XCTAssertEqual(view.selectedIndex, 0, "前提：那条字已经是选中态")
        XCTAssertNil(view.editingAnnotationIndex, "前提：还没进编辑")

        /// 差异表按一块区域分两堆：区域内 / 区域外（位图坐标换算回视图坐标，两者同向）。
        func split(_ pixels: [(x: Int, y: Int)], around region: CGRect, scale: CGFloat)
            -> (inside: Int, outside: Int) {
            var hit = 0
            var miss = 0
            for pixel in pixels {
                let at = CGPoint(x: CGFloat(pixel.x) / scale, y: CGFloat(pixel.y) / scale)
                if region.contains(at) { hit += 1 } else { miss += 1 }
            }
            return (hit, miss)
        }

        let drawn = try render(view)
        let scale = CGFloat(drawn.pixelsWide) / view.bounds.width
        view.editingAnnotationIndex = 0
        let hidden = try render(view)

        // ① 撤字：差异必须落在字块上，而且**只**落在字块上。
        let ink = split(differingPixels(drawn, hidden),
                        around: text.textBoxRect.insetBy(dx: -6, dy: -6), scale: scale)
        XCTAssertGreaterThan(ink.inside, 20, "开关拨到 0 之后遮罩上那条字还在：编辑时屏上是两层字")
        XCTAssertEqual(ink.outside, 0, "跳过这一条字把别的地方也改了（虚线圈/把手/底图不许跟着动）")
        try dump(hidden, name: "text-editing-hides-old-ink.png")

        // ② 反向对照：同一张位图重渲染一次不该自己漂走 —— 上面那个 outside==0 才有意义
        //    （否则「渲染不确定」也会被判成「别的地方没改」）。
        XCTAssertEqual(differingPixels(hidden, try render(view)).count, 0, "同一状态两次渲染不一致，判据作废")
        view.editingAnnotationIndex = nil
        XCTAssertEqual(differingPixels(drawn, try render(view)).count, 0, "开关拨回去该逐像素回到原来那一版")
    }

    // MARK: - 辅助

    /// 调色板第一档（红）：真实落笔用的就是它，拿 `.systemRed` 当默认色会让「没改过」这种
    /// 断言在两个色值之间来回骗人。
    private var red: NSColor { ScreenshotToolbarView.palette[0] }

    /// 一条从 `box` 拖出来的形状注解（默认红、粗细 4 = 面板那档默认值）。
    private func shape(_ tool: ScreenshotTool, _ box: CGRect,
                       lineWidth: CGFloat = 4, color: NSColor? = nil) -> ScreenshotAnnotation {
        ScreenshotAnnotation(tool: tool, color: color ?? red, lineWidth: lineWidth, start: box.origin,
                             end: CGPoint(x: box.maxX, y: box.maxY))
    }

    private func shot(_ size: NSSize) throws -> ScreenshotFrame {
        let image = try XCTUnwrap(QuadrantPattern.image(width: Int(size.width), height: Int(size.height)))
        return try XCTUnwrap(ScreenshotFrame(image: image, pointSize: size))
    }

    /// 已经拖好选区、进了编辑态的遮罩，`annotations` 直接摆好（不走画的那条路，所以不进撤销栈）。
    ///
    /// 默认选区 (100,100,300,300) @ 1440×900：面板从条子那一格往上浮会压住选区底部一条，
    /// 用例要按的地方都留在上半部。要渲染取证的用例自己传小一号的容器（像素循环按面积走）。
    private func editedScene(_ size: NSSize = NSSize(width: 1440, height: 900),
                             selection: CGRect = CGRect(x: 100, y: 100, width: 300, height: 300),
                             shot custom: ScreenshotFrame? = nil,
                             annotations: [ScreenshotAnnotation] = []) throws -> ScreenshotSelectionView {
        let frame = try custom ?? shot(size)
        let view = ScreenshotSelectionView(shot: frame)
        // 挂到一扇窗上：不挂窗时 AppKit 的 focus 上下文不完整，文字绘制会缺笔画。
        ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: size)).contentView = view
        view.pointerDown(selection.origin, clickCount: 1)
        view.pointerDragged(to: CGPoint(x: selection.maxX, y: selection.maxY))
        view.pointerReleased()
        XCTAssertEqual(view.selection, selection, "前提：选区得按给定那块落定")
        XCTAssertEqual(view.phase, .editing, "前提：进了编辑态")
        view.annotations = annotations
        return view
    }

    private func escKey() throws -> NSEvent {
        try key(code: 53, character: "\u{1b}")
    }

    private func backspaceKey() throws -> NSEvent {
        try key(code: 51, character: "\u{7f}")
    }

    /// 键盘事件得长得像从键盘上来的：`keyDown(with:)` 只看 keyCode，但以后谁改成按字符
    /// 判定，这两条用例不会悄悄变成空转。
    private func key(code: UInt16, character: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: character, charactersIgnoringModifiers: character,
                                       isARepeat: false, keyCode: code))
    }

    // MARK: 渲染取证

    private func render(_ view: ScreenshotSelectionView) throws -> NSBitmapImageRep {
        view.needsDisplay = true
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                                   "拿不到离屏位图")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func rawBytes(_ bitmap: NSBitmapImageRep) -> [UInt8] {
        guard let data = bitmap.bitmapData else { return [] }
        return [UInt8](UnsafeRawBufferPointer(start: data,
                                              count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    private func rawBytes(_ image: CGImage) -> [UInt8] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return [UInt8](UnsafeRawBufferPointer(start: data,
                                              count: context.bytesPerRow * image.height))
    }

    /// 两张位图逐像素相比，返回**不一样**的像素坐标（位图坐标，左上原点，和 flipped 视图同向）。
    ///
    /// 判据一律从这张差异表来，不从遮罩自己报的把手坐标来 —— 那只能说明「代码以为画在
    /// 这儿」，说明不了屏幕上真画在这儿。
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [(x: Int, y: Int)] {
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh)
        XCTAssertEqual(a.bytesPerRow, b.bytesPerRow)
        guard let pa = a.bitmapData, let pb = b.bitmapData else { return [] }
        let stride = a.bitsPerPixel / 8
        var out: [(Int, Int)] = []
        for y in 0 ..< min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0 ..< min(a.pixelsWide, b.pixelsWide) {
                let i = y * a.bytesPerRow + x * stride
                if pa[i] != pb[i] || pa[i + 1] != pb[i + 1]
                    || pa[i + 2] != pb[i + 2] || pa[i + 3] != pb[i + 3] {
                    out.append((x, y))
                }
            }
        }
        return out
    }

    /// 两个色在同一条空间里的欧氏距离（0…1.73）。
    ///
    /// 一律**不做色彩管理转换**之外的手脚：两边都换到位图自己的空间再比 raw 值，换到
    /// sRGB 再比会被 gamma 弯一次（见 `ScreenshotRenderTests` 里亮度比值同一课的备注）。
    private func colorDistance(_ a: NSColor, _ b: NSColor, in space: NSColorSpace) -> CGFloat {
        let x = a.usingColorSpace(space) ?? a
        let y = b.usingColorSpace(space) ?? b
        let dr = x.redComponent - y.redComponent
        let dg = x.greenComponent - y.greenComponent
        let db = x.blueComponent - y.blueComponent
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// 有多少像素落在「画选中框那支笔」的颜色附近。`region` 给的是视图点坐标里的一小块，
    /// 用来把量尺限定在要看的地方 —— 不然注解条选中格的蓝底也会算成「框画上了」。
    private func nearAccent(_ bitmap: NSBitmapImageRep, accent: NSColor, scale: CGFloat,
                            region: CGRect? = nil) -> Int {
        let space = bitmap.colorSpace ?? .sRGB
        let target = accent.usingColorSpace(space) ?? accent
        let columns: Range<Int>
        let rows: Range<Int>
        if let region {
            columns = max(0, Int(region.minX * scale)) ..< min(bitmap.pixelsWide, Int(region.maxX * scale))
            rows = max(0, Int(region.minY * scale)) ..< min(bitmap.pixelsHigh, Int(region.maxY * scale))
        } else {
            columns = 0 ..< bitmap.pixelsWide
            rows = 0 ..< bitmap.pixelsHigh
        }
        var count = 0
        for y in rows {
            for x in columns {
                guard let raw = bitmap.colorAt(x: x, y: y) else { continue }
                if colorDistance(raw, target, in: space) < 0.25 { count += 1 }
            }
        }
        return count
    }

    /// 落盘一张，人眼过一遍：像素计数只说明「这儿多了点东西」，说不清那圈虚线歪没歪。
    private func dump(_ image: CGImage, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/macstroke-screenshot-check", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        NSLog("%@", "[ScreenshotTests] 成品图：\(url.path)")
    }

    private func dump(_ bitmap: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/macstroke-screenshot-check", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        NSLog("%@", "[ScreenshotTests] 遮罩图：\(url.path)")
    }
}
