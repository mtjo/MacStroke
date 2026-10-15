//
//  ScreenshotAnnotationTests.swift
//
//  注解和成品的取证。重点不是「画得好看」，而是两件最容易错又最难肉眼发现的事：
//  1. 注解落在哪 —— 合成里错位一次，屏上看着对、导出的图却是歪的。
//  2. 导出的图和屏幕上那块是不是同一块 —— 用四分之一色块图案做方向敏感断言。
//

import AppKit
import XCTest

@testable import Screenshot

final class ScreenshotAnnotationTests: XCTestCase {
    /// 选区 = 右上象限（整块都是绿色），这样任何非绿色的点都只能是注解画上去的。
    private let selection = CGRect(x: 400, y: 0, width: 400, height: 250)

    /// 800×500 的图案当底图，点/像素 1:1，断言里的坐标就是图案里的坐标。
    private func frame800x500() throws -> ScreenshotFrame {
        let shot = try XCTUnwrap(QuadrantPattern.image(width: 800, height: 500))
        return try XCTUnwrap(ScreenshotFrame(image: shot, pointSize: NSSize(width: 800, height: 500)))
    }

    private func render(_ annotations: [ScreenshotAnnotation], selection: CGRect? = nil) throws -> NSBitmapImageRep {
        let area = selection ?? self.selection
        let shot = try frame800x500()
        let image = try XCTUnwrap(ScreenshotComposer.compose(shot: shot, selection: area,
                                                            annotations: annotations))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(cgImage: image))
        // 下面全部按「1 点 = 1 像素」写坐标。帧是 1:1 合成的，只有离屏窗口的 backing
        // scale 不是 1（Retina 屏上跑测试）时两者才会不一致 —— 那是环境前提，不是产品
        // 缺陷，所以跳过而不是硬失败。
        if bitmap.pixelsWide != Int(area.width) {
            throw XCTSkip("离屏渲染比例 \(bitmap.pixelsWide)/\(Int(area.width)) ≠ 帧比例，按像素写的断言不适用")
        }
        return bitmap
    }

    func testComposeWithoutAnnotationsIsThePlainCrop() throws {
        let bitmap = try render([])
        XCTAssertEqual(bitmap.pixelsWide, 400)
        XCTAssertEqual(bitmap.pixelsHigh, 250)
        XCTAssertTrue(QuadrantPattern.isGreen(try color(bitmap, 10, 10)), "选区里就是原图")
        XCTAssertTrue(QuadrantPattern.isGreen(try color(bitmap, 390, 240)))
    }

    /// 矩形注解的位置取证：框在选区上半部，所以顶部横线该有颜色、下半部不该有。
    /// 合成里只要 y 被翻过一次，这两条就会同时反过来。
    func testRectAnnotationKeepsPosition() throws {
        let rect = ScreenshotAnnotation(tool: .rect, color: NSColor.systemBlue, lineWidth: 6,
                                        start: CGPoint(x: 420, y: 20), end: CGPoint(x: 700, y: 120))
        let bitmap = try render([rect])
        XCTAssertTrue(isBlue(try color(bitmap, 160, 22)), "横线该落在 y≈20 处")
        XCTAssertFalse(isBlue(try color(bitmap, 160, 200)), "选区下半部不该有任何蓝色")
        XCTAssertFalse(isBlue(try color(bitmap, 5, 5)), "框外保持原图")
    }

    /// 框有一部分拖到选区外：超出裁掉、伸进来的保留。四条探针一起卡住 x/y 对齐 ——
    /// 只要合成里平移错一次，「右边该有」和「右边该空」就会同时反过来。
    func testAnnotationOutsideSelectionIsCutOff() throws {
        let rect = ScreenshotAnnotation(tool: .rect, color: NSColor.systemBlue, lineWidth: 6,
                                        start: CGPoint(x: 300, y: 100), end: CGPoint(x: 450, y: 200))
        let bitmap = try render([rect])
        // 右边框落在全局 x 444..450 → 选区局部 44..50。
        XCTAssertTrue(isBlue(try color(bitmap, 46, 150)), "伸进选区的那段竖线该保留")
        XCTAssertFalse(isBlue(try color(bitmap, 60, 150)), "框右边界之外就该干净")
        // 上边框 y≈100 那条横线只有 x≥400 的一小截在选区内。
        XCTAssertTrue(isBlue(try color(bitmap, 10, 100)), "上边框在选区内的部分该保留")
        XCTAssertFalse(isBlue(try color(bitmap, 10, 60)), "框上边界之上不该有颜色")
    }

    /// 箭头：头在拖到的那端（end），不在起点。四向探针一起验，写反就挂。
    func testArrowHeadIsAtTheDraggedEnd() throws {
        let arrow = ScreenshotAnnotation(tool: .arrow, color: NSColor.systemBlue, lineWidth: 5,
                                        start: CGPoint(x: 450, y: 50), end: CGPoint(x: 650, y: 150))
        let bitmap = try render([arrow])
        XCTAssertTrue(isBlue(try color(bitmap, 150, 100)), "杆的中段该有线")
        XCTAssertTrue(isBlue(try color(bitmap, 245, 147)), "头顶在拖到的那端")
        XCTAssertFalse(isBlue(try color(bitmap, 258, 154)), "头再往外就该是空白")
        XCTAssertFalse(isBlue(try color(bitmap, 42, 46)), "起点的另一侧也该是空白")
    }

    /// 马赛克：上红下蓝保持不变（方向没错），跨分界的方块被平均成混色，
    /// 同块内相邻像素完全相等（说明真关了插值，不是糊成一片）。
    func testMosaicPixelatesWithoutRotating() throws {
        let mosaic = ScreenshotAnnotation(tool: .mosaic, color: .white, lineWidth: 2,
                                         start: CGPoint(x: 50, y: 50), end: CGPoint(x: 350, y: 450))
        let bitmap = try render([mosaic], selection: CGRect(x: 0, y: 0, width: 400, height: 500))
        XCTAssertTrue(QuadrantPattern.isRed(try color(bitmap, 100, 100)),
                      "打码之后上方仍该是红区，变蓝就是整块翻了")
        XCTAssertTrue(QuadrantPattern.isBlue(try color(bitmap, 100, 400)), "打码之后下方仍该是蓝区")
        let seam = try color(bitmap, 100, 250)
        XCTAssertFalse(QuadrantPattern.isRed(seam) || QuadrantPattern.isBlue(seam),
                       "跨红蓝分界的方块没被平均，马赛克没生效")
        XCTAssertEqual(try color(bitmap, 100, 100), try color(bitmap, 103, 104),
                       "同一个方块内必须是同一个颜色")
    }

    func testTextAnnotationLandsOnItsAnchor() throws {
        let text = ScreenshotAnnotation(tool: .text, color: NSColor.systemBlue, lineWidth: 7,
                                       start: CGPoint(x: 500, y: 100), text: "X")
        let bitmap = try render([text])
        var hit = false
        for y in 90..<145 {
            for x in 85..<155 where isBlue(try color(bitmap, x, y)) { hit = true; break }
        }
        XCTAssertTrue(hit, "字该出现在锚点（局部 100,100）附近")
        var stray = 0
        for y in stride(from: 180, to: 240, by: 4) {
            for x in stride(from: 20, to: 380, by: 6) where isBlue(try color(bitmap, x, y)) { stray += 1 }
        }
        XCTAssertEqual(stray, 0, "选区下方不该出现笔画")
    }

    func testNumberBadgeIsADiscAtItsPoint() throws {
        let badge = ScreenshotAnnotation(tool: .number, color: NSColor.systemBlue, lineWidth: 4,
                                        start: CGPoint(x: 500, y: 120), number: 3)
        let bitmap = try render([badge])
        let radius = Int(badge.badgeRadius)
        // 圆心让给白色数字，取圆内偏左的一格验底色。
        XCTAssertTrue(isBlue(try color(bitmap, 100 - radius + 2, 120)), "徽标该是个实心圆")
        XCTAssertFalse(isBlue(try color(bitmap, 100 + radius + 5, 120)), "圆外不该被涂到")
    }

    /// 椭圆和矩形吃同一个框，所以判据只能长在「角上」：框角空了才是圆的。
    /// 同一格用矩形做反向对照 —— 不然「角上没颜色」会因为压根没画东西而白过。
    func testEllipseStaysInsideItsBoxAndLeavesTheCornersEmpty() throws {
        let start = CGPoint(x: 420, y: 20)
        let end = CGPoint(x: 700, y: 120)
        let ellipse = ScreenshotAnnotation(tool: .ellipse, color: NSColor.systemBlue,
                                          lineWidth: 6, start: start, end: end)
        let bitmap = try render([ellipse])
        XCTAssertTrue(isBlue(try color(bitmap, 160, 23)), "上顶点该贴住框的上边（局部 x 是框中线）")
        XCTAssertTrue(isBlue(try color(bitmap, 24, 70)), "左顶点该贴住框的左边")
        XCTAssertFalse(isBlue(try color(bitmap, 23, 23)), "框角是空的：糊到角上就成矩形了")

        let rectBitmap = try render([ScreenshotAnnotation(tool: .rect, color: NSColor.systemBlue,
                                                         lineWidth: 6, start: start, end: end)])
        XCTAssertTrue(isBlue(try color(rectBitmap, 23, 23)), "对照：同一个框画矩形，角上是实的")
    }

    /// 画笔是一条折线，两个对角点装不下：轨迹绕回同一高度，包围盒高度仍要按整条算。
    func testPenBoundingBoxFollowsTheWholePath() {
        let pen = ScreenshotAnnotation(tool: .pen, color: NSColor.systemBlue, lineWidth: 6,
                                       start: CGPoint(x: 450, y: 40),
                                       points: [CGPoint(x: 450, y: 40), CGPoint(x: 550, y: 180),
                                               CGPoint(x: 650, y: 40)])
        XCTAssertEqual(pen.rect, CGRect(x: 450, y: 40, width: 200, height: 140),
                       "只按首尾两点算会得到 0 高的一条线")
        XCTAssertEqual(pen.dirtyRect, CGRect(x: 447, y: 37, width: 206, height: 146),
                       "描边以路径为中心，包围盒得让出半根线宽，否则贴边的笔画会被裁掉")
        XCTAssertEqual(pen.start, CGPoint(x: 450, y: 40))
        XCTAssertEqual(pen.end, CGPoint(x: 650, y: 40))
    }

    /// 轨迹抽稀：鼠标一帧报十几个点，挨得太近的要丢，否则一条随手线变成上千段。
    func testPenPathDropsPointsTooCloseToEachOther() {
        var points = [CGPoint(x: 100, y: 100)]
        points = ScreenshotAnnotation.penPath(byAppending: CGPoint(x: 101, y: 101), to: points)
        XCTAssertEqual(points.count, 1, "1.4pt 的抖动不进点列")
        points = ScreenshotAnnotation.penPath(byAppending: CGPoint(x: 103, y: 100), to: points)
        XCTAssertEqual(points.count, 2, "过了最小间距就该收下")
        points = ScreenshotAnnotation.penPath(byAppending: CGPoint(x: 103.5, y: 100), to: points)
        XCTAssertEqual(points.count, 2, "往回蹭半格不该再多一个点")
        XCTAssertEqual(ScreenshotAnnotation.penPath(byAppending: CGPoint(x: 7, y: 9), to: []).count, 1,
                       "空点列进来的第一个点直接收，没有『上一点』可比")
    }

    /// 画笔要沿整条折线描，不是只连首尾：中段和拐点有颜色、两腰之间空着才算数。
    func testPenDrawsEverySegmentOfThePath() throws {
        let pen = ScreenshotAnnotation(tool: .pen, color: NSColor.systemBlue, lineWidth: 5,
                                       start: CGPoint(x: 450, y: 40),
                                       points: [CGPoint(x: 450, y: 40), CGPoint(x: 550, y: 180),
                                               CGPoint(x: 650, y: 40)])
        let bitmap = try render([pen])
        XCTAssertTrue(isBlue(try color(bitmap, 75, 75)), "第一段的中点该有线")
        XCTAssertTrue(isBlue(try color(bitmap, 150, 180)), "拐点（轨迹最低处）该有线")
        XCTAssertTrue(isBlue(try color(bitmap, 225, 75)), "第二段的中点该有线")
        XCTAssertFalse(isBlue(try color(bitmap, 150, 40)),
                       "只连首尾会在这里画出一条横线，轨迹从没经过那儿")
    }

    // MARK: - 辅助

    private func color(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func isBlue(_ color: NSColor) -> Bool {
        guard let srgb = color.usingColorSpace(.sRGB) else { return false }
        return srgb.blueComponent > 0.5 && srgb.blueComponent > srgb.redComponent + 0.2
    }
}
