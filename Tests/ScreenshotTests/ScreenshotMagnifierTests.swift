//
//  ScreenshotMagnifierTests.swift
//
//  放大镜的取证分三层：
//  1. **几何**（摆位、取景范围、一格几像素）：这些错了不会崩，只会「十字线指的和光标
//     指的差一个像素」，肉眼看图根本分辨不出来，所以必须用数字验。
//  2. **取样**：坐标和色值都来自那张已经定格的帧，且和选区走同一套换算 —— 面板上写的
//     颜色必须就是最后存出去的那个像素。
//  3. **离屏渲染**：放大必须是最近邻取样（不能糊），十字线必须落在真实偏移的那一格上
//     （贴边时取景块被往里推过）。判据取自图案自己（红/绿两半的硬边界），不取自绘制代码。
//
//  状态机那几条验的是「只在选区阶段跟着走」：进了编辑态就该收掉，关掉开关压根不建视图。
//

import AppKit
import Storage
import XCTest

@testable import Screenshot

final class ScreenshotMagnifierTests: XCTestCase {

    private enum RenderFailure: Error {
        case noBitmap, noPattern
    }

    private static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// 400×400、1:1（scale=1）的底图：上半左红右绿、下半左蓝右下白，硬边界正好在
    /// x=200、y=200，拿它验「放大后边缘还是不是硬的」。
    private func frame(_ size: Int = 400) throws -> ScreenshotFrame {
        guard let image = QuadrantPattern.image(width: size, height: size) else {
            throw RenderFailure.noPattern
        }
        return try XCTUnwrap(ScreenshotFrame(image: image, pointSize: NSSize(width: size, height: size)))
    }

    // MARK: - 倍率档位

    func testStoredZoomMapsToADiscreteLevel() {
        XCTAssertEqual(ScreenshotMagnification(stored: 4), .normal)
        XCTAssertEqual(ScreenshotMagnification(stored: 8), .medium)
        XCTAssertEqual(ScreenshotMagnification(stored: 16), .large)
        // 手改 plist / 以后加档位：不能落回 0 倍，否则取景窗宽是 0。
        XCTAssertEqual(ScreenshotMagnification(stored: 5), .medium)
        XCTAssertEqual(ScreenshotMagnification(stored: 0), .medium)
        XCTAssertEqual(ScreenshotMagnification(stored: -8), .medium)
    }

    func testZoomTitlesAreTheMultiplierThePageShows() {
        XCTAssertEqual(ScreenshotMagnification.allCases.map(\.title), ["4×", "8×", "16×"])
    }

    /// 一格 8 点时 15 格刚好铺满 120；奇数格是「被指的那格落在正中」的前提。
    func testPixelsAcrossIsAlwaysOddAndFillsTheWindow() {
        XCTAssertEqual(ScreenshotMagnifierView.pixelsAcross(for: 4), 29)
        XCTAssertEqual(ScreenshotMagnifierView.pixelsAcross(for: 8), 15)
        XCTAssertEqual(ScreenshotMagnifierView.pixelsAcross(for: 16), 7)
        for cell: CGFloat in [4, 8, 16] {
            let across = ScreenshotMagnifierView.pixelsAcross(for: cell)
            XCTAssertLessThanOrEqual(CGFloat(across) * cell, ScreenshotMagnifierView.imageSide,
                                     "\(cell) 倍时 \(across) 格会溢出取景窗")
            XCTAssertEqual(across % 2, 1, "偶数格会把被指的像素挤到半格上")
        }
    }

    // MARK: - 取景范围

    func testSourceRectCentersThePointedPixel() {
        let rect = ScreenshotMagnifierView.sourceRect(around: CGPoint(x: 210, y: 100), across: 15,
                                                      imageSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(rect, CGRect(x: 203, y: 93, width: 15, height: 15))
    }

    /// 贴边时整块往里推、尺寸不缩水 —— 十字线按真实偏移画，所以推过之后指的仍是那一个像素。
    func testSourceRectStaysInsideTheImage() {
        let image = CGSize(width: 400, height: 400)
        XCTAssertEqual(ScreenshotMagnifierView.sourceRect(around: CGPoint(x: 3, y: 100), across: 15,
                                                           imageSize: image),
                       CGRect(x: 0, y: 93, width: 15, height: 15))
        let far = ScreenshotMagnifierView.sourceRect(around: CGPoint(x: 399, y: 399), across: 15,
                                                     imageSize: image)
        XCTAssertEqual(far, CGRect(x: 385, y: 385, width: 15, height: 15))
        XCTAssertLessThanOrEqual(far.maxX, image.width)
        XCTAssertLessThanOrEqual(far.maxY, image.height)
    }

    /// 底图比取景窗还小（合成图/超小屏）时按图缩放，不能裁出负尺寸。
    func testSourceRectShrinksToATinyImage() {
        let rect = ScreenshotMagnifierView.sourceRect(around: CGPoint(x: 8, y: 8), across: 15,
                                                      imageSize: CGSize(width: 10, height: 10))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    // MARK: - 摆位

    /// 面板默认在光标右下；快要出屏时翻到另一侧；整块屏都放不下时才钳在屏内。
    func testPanelFlipsToTheOtherSideAtTheEdges() {
        let size = ScreenshotMagnifierView.panelSize
        XCTAssertEqual(ScreenshotMagnifierView.panelOrigin(cursor: CGPoint(x: 100, y: 100),
                                                            size: size, in: Self.screen),
                       CGPoint(x: 118, y: 118))
        XCTAssertEqual(ScreenshotMagnifierView.panelOrigin(cursor: CGPoint(x: 1400, y: 100),
                                                            size: size, in: Self.screen).x,
                       1400 - ScreenshotMagnifierView.cursorGap - size.width)
        XCTAssertEqual(ScreenshotMagnifierView.panelOrigin(cursor: CGPoint(x: 100, y: 860),
                                                            size: size, in: Self.screen).y,
                       860 - ScreenshotMagnifierView.cursorGap - size.height)
        let corner = CGRect(origin: ScreenshotMagnifierView.panelOrigin(cursor: CGPoint(x: 1439, y: 899),
                                                                        size: size, in: Self.screen),
                            size: size)
        XCTAssertTrue(Self.screen.contains(corner), "贴着角也不能把面板甩出屏：\(corner.origin)")
    }

    /// 面板尺寸不随倍率变：改设置时不该突然变大挡在光标前面。
    func testPanelSizeDoesNotDependOnZoom() throws {
        let view = ScreenshotMagnifierView(shot: try frame())
        view.follow(point: CGPoint(x: 300, y: 300), magnification: .normal, in: Self.screen)
        let small = view.frame.size
        view.follow(point: CGPoint(x: 300, y: 300), magnification: .large, in: Self.screen)
        XCTAssertEqual(view.frame.size, small)
        XCTAssertEqual(small, ScreenshotMagnifierView.panelSize)
    }

    // MARK: - 取样：坐标与色值都来自定格的那一帧

    func testPixelIndexScalesAndClamps() throws {
        let shot = try XCTUnwrap(ScreenshotFrame(
            image: try XCTUnwrap(QuadrantPattern.image(width: 800, height: 400)),
            pointSize: NSSize(width: 400, height: 200)))
        XCTAssertEqual(shot.pixelIndex(for: CGPoint(x: 100, y: 50)), CGPoint(x: 200, y: 100))
        XCTAssertEqual(shot.pixelIndex(for: CGPoint(x: -20, y: -1)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(shot.pixelIndex(for: CGPoint(x: 999, y: 999)), CGPoint(x: 799, y: 399))
    }

    /// 方向不能翻：左上取到红、左下取到蓝。翻了不会报错，只会「面板报的色和截出来的不是
    /// 同一块」。
    func testHexColorFollowsTheQuadrantUnderTheCursor() throws {
        let shot = try XCTUnwrap(ScreenshotFrame(
            image: try XCTUnwrap(QuadrantPattern.image(width: 800, height: 400)),
            pointSize: NSSize(width: 800, height: 400)))
        let top = try XCTUnwrap(shot.hexColor(for: CGPoint(x: 10, y: 10)))
        let bottom = try XCTUnwrap(shot.hexColor(for: CGPoint(x: 10, y: 390)))
        assertIsHex(top)
        assertIsHex(bottom)
        let topRGB = try XCTUnwrap(shot.rgb(for: CGPoint(x: 10, y: 10)))
        let bottomRGB = try XCTUnwrap(shot.rgb(for: CGPoint(x: 10, y: 390)))
        XCTAssertGreaterThan(topRGB.red, max(topRGB.green, topRGB.blue), "左上该是红：\(top)")
        XCTAssertGreaterThan(bottomRGB.blue, bottomRGB.red, "左下该是蓝：\(bottom)")
        XCTAssertNotEqual(top, bottom)
    }

    func testColorTextIsThePointThePanelIsShowing() throws {
        let shot = try frame()
        let view = ScreenshotMagnifierView(shot: shot)
        view.follow(point: CGPoint(x: 100, y: 100), magnification: .medium, in: Self.screen)
        XCTAssertEqual(view.colorText, shot.hexColor(for: CGPoint(x: 100, y: 100)))
        view.follow(point: CGPoint(x: 300, y: 100), magnification: .medium, in: Self.screen)
        XCTAssertNotEqual(view.colorText, shot.hexColor(for: CGPoint(x: 100, y: 100)),
                          "换点了还报旧颜色，⌘C 就会复制出错的那一个")
    }

    /// ⌘C 的守卫：面板收起来时不能悄悄往剪贴板写一个用户没看见的值。
    /// （真复制走 NSPasteboard.general，这里不测，免得把用户当前的剪贴板刷掉。）
    func testCopyRefusesWhileThePanelIsHidden() throws {
        let scene = try overlayScene()
        let view = scene.view
        view.pointerDown(CGPoint(x: 100, y: 100), clickCount: 1)
        view.pointerDragged(to: CGPoint(x: 300, y: 300))
        view.pointerReleased()
        XCTAssertEqual(view.phase, .editing)
        XCTAssertFalse(view.copyMagnifierColor(), "编辑态里放大镜已经收了，这时候 ⌘C 不该复制色值")
    }

    /// 指到另一个像素上，「已复制」必须跟着撤掉 —— 留着是在说另一个点的色值。
    func testCopiedFlagClearsWhenThePointChanges() throws {
        let view = ScreenshotMagnifierView(shot: try frame())
        view.follow(point: CGPoint(x: 100, y: 100), magnification: .medium, in: Self.screen)
        view.markCopied()
        XCTAssertTrue(view.isShowingCopied)
        view.follow(point: CGPoint(x: 100.4, y: 100.4), magnification: .medium, in: Self.screen)
        XCTAssertTrue(view.isShowingCopied, "还在同一个像素上，别把「已复制」抹掉")
        view.follow(point: CGPoint(x: 120, y: 100), magnification: .medium, in: Self.screen)
        XCTAssertFalse(view.isShowingCopied)
    }

    // MARK: - 离屏渲染

    /// 放大必须是最近邻取样：红/绿的分界在底图 x=200，放大后一格之内必须处处同色，
    /// 过了分界立刻换成另一色。插值一开，格子靠边的那几列就成了过渡色 —— 实测把
    /// interpolation 调成 .default，这一格从 x=50 起就是 244/42、233/54、210/84，一路
    /// 糊到 7/249；用户照着糊掉的边去卡准，选出来的就不是那一条。
    func testMagnifiedPatchKeepsHardPixelEdges() throws {
        let view = ScreenshotMagnifierView(shot: try frame())
        view.follow(point: CGPoint(x: 201, y: 100), magnification: .medium,
                    in: CGRect(x: 0, y: 0, width: 400, height: 400))
        let bitmap = try render(view, name: "magnifier-8x-edge.png")
        // 取景块 = 底图 x∈[194,208]，一格 8 点、左内边 6 → 199 列铺面板 x∈[46,54)，
        // 200 列铺 [54,62)。逐像素格线正好压在这两格的边界上（45/46、53/54 被压暗一截），
        // 所以只比格子内部的列。
        let red = try pixel(in: bitmap, x: 47, y: 100)
        for x in 48...52 {
            XCTAssertEqual(try pixel(in: bitmap, x: x, y: 100), red, "红格内部出现过渡色：x=\(x)")
        }
        let green = try pixel(in: bitmap, x: 55, y: 100)
        for x in 56...60 {
            XCTAssertEqual(try pixel(in: bitmap, x: x, y: 100), green, "绿格内部出现过渡色：x=\(x)")
        }
        XCTAssertTrue(QuadrantPattern.isRed(srgb(red)), "取景块左半该是底图 199 列的红：\(red)")
        XCTAssertTrue(QuadrantPattern.isGreen(srgb(green)), "取景块右半该是底图 200 列的绿：\(green)")
        XCTAssertNotEqual(red, green, "两格必须真是两色，否则上面的「处处同色」是空转")
    }

    /// 贴左边缘时取景块被往里推到 x=0，十字线必须按真实偏移画到第 3 格，而不是死在窗口
    /// 正中 —— 后者指的是第 7 格，报的坐标/色值全跟着错。
    func testCrosshairMarksThePointedPixelEvenAtTheEdge() throws {
        let view = ScreenshotMagnifierView(shot: try frame())
        view.follow(point: CGPoint(x: 3, y: 100), magnification: .medium,
                    in: CGRect(x: 0, y: 0, width: 400, height: 400))
        let bitmap = try render(view, name: "magnifier-8x-edge-crosshair.png")
        // 取景块 x∈[0,14]，被指的是第 3 列 → 面板 x = 6 + 3.5×8 = 34。
        XCTAssertTrue(isCrosshair(try color(in: bitmap, x: 34, y: 100)), "十字线应落在被指的像素上")
        XCTAssertTrue(QuadrantPattern.isRed(try color(in: bitmap, x: 20, y: 100)), "第 1 格不该被线扫到")
        XCTAssertTrue(QuadrantPattern.isRed(try color(in: bitmap, x: 50, y: 100)),
                      "第 5 格同理：线要是画在窗口正中就会跑到这里")
    }

    /// 逐像素格线只在格子够大时画：4 倍那一档一格只有 4 点，画格线等于把一层噪点糊在内容上。
    /// 判据取自同一行里「离中位最远的一格」的相对偏差，不取自代码里的 if。
    func testGridLinesOnlyAppearWhenCellsAreWideEnough() throws {
        let eight = try gridContrast(magnification: .medium, from: 8, to: 56)
        let four = try gridContrast(magnification: .normal, from: 8, to: 56)
        XCTAssertLessThan(four.spread, 0.02, "4 倍那一档画了格线：亮度落差 \(four.spread)")
        XCTAssertGreaterThan(eight.spread, 0.02, "8 倍那一档该有格线帮用户数像素，落差只剩 \(eight.spread)")
    }

    // MARK: - 遮罩接线

    func testMagnifierFollowsTheCursorWhilePicking() throws {
        let scene = try overlayScene()
        scene.view.pointerMoved(CGPoint(x: 300, y: 200))
        let panel = try XCTUnwrap(scene.view.magnifierView, "开着放大镜就该建出这层视图")
        XCTAssertFalse(panel.isHidden)
        XCTAssertEqual(panel.frame.origin,
                       ScreenshotMagnifierView.panelOrigin(cursor: CGPoint(x: 300, y: 200),
                                                           size: panel.frame.size, in: scene.view.bounds))
        XCTAssertEqual(panel.colorText, scene.shot.hexColor(for: CGPoint(x: 300, y: 200)))

        scene.view.pointerMoved(CGPoint(x: 320, y: 210))
        XCTAssertEqual(panel.frame.origin,
                       ScreenshotMagnifierView.panelOrigin(cursor: CGPoint(x: 320, y: 210),
                                                           size: panel.frame.size, in: scene.view.bounds))
    }

    /// 拖选阶段才是真正在卡边界的时候，这时放大镜必须还在。
    func testMagnifierKeepsFollowingDuringTheDrag() throws {
        let scene = try overlayScene()
        scene.view.pointerDown(CGPoint(x: 100, y: 100), clickCount: 1)
        scene.view.pointerDragged(to: CGPoint(x: 300, y: 260))
        let panel = try XCTUnwrap(scene.view.magnifierView)
        XCTAssertFalse(panel.isHidden, "边界就是在这一步上卡准的，拖选时不能收")
        XCTAssertEqual(panel.colorText, scene.shot.hexColor(for: CGPoint(x: 300, y: 260)))
    }

    func testMagnifierIsGoneAfterTheSelectionIsLocked() throws {
        let scene = try overlayScene()
        scene.view.pointerMoved(CGPoint(x: 300, y: 200))
        XCTAssertFalse(try XCTUnwrap(scene.view.magnifierView).isHidden)
        scene.view.pointerDown(CGPoint(x: 100, y: 100), clickCount: 1)
        scene.view.pointerDragged(to: CGPoint(x: 300, y: 300))
        scene.view.pointerReleased()
        XCTAssertTrue(try XCTUnwrap(scene.view.magnifierView).isHidden, "编辑态里它是块挡路的死面板")
    }

    /// 偏好里关掉：压根不建这层视图。
    func testMagnifierSwitchOffBuildsNoView() throws {
        let scene = try overlayScene()
        scene.view.magnifierEnabled = false
        scene.view.pointerMoved(CGPoint(x: 300, y: 200))
        scene.view.pointerDown(CGPoint(x: 100, y: 100), clickCount: 1)
        scene.view.pointerDragged(to: CGPoint(x: 300, y: 300))
        XCTAssertNil(scene.view.magnifierView)
    }

    /// 纯装饰：面板压在选区上也不能吃掉事件，否则用户点它盖住的那块就选不到了。
    func testMagnifierNeverEatsClicks() throws {
        let view = ScreenshotMagnifierView(shot: try frame())
        view.frame = NSRect(origin: .zero, size: ScreenshotMagnifierView.panelSize)
        XCTAssertNil(view.hitTest(CGPoint(x: 60, y: 60)))
    }

    /// 遮罩建的这层视图用的就是偏好里那一档倍率（跟着换算出的格宽必须是整数点）。
    func testOverlayBuildsThePanelAtTheConfiguredZoom() throws {
        let scene = try overlayScene()
        scene.view.magnification = .large
        scene.view.pointerMoved(CGPoint(x: 300, y: 200))
        XCTAssertEqual(try XCTUnwrap(scene.view.magnifierView).frame.size,
                       ScreenshotMagnifierView.panelSize)
    }

    // MARK: - Helpers

    private func overlayScene(size: NSSize = NSSize(width: 800, height: 500))
        throws -> (view: ScreenshotSelectionView, shot: ScreenshotFrame) {
        guard let image = QuadrantPattern.image(width: Int(size.width), height: Int(size.height)) else {
            throw RenderFailure.noPattern
        }
        let shot = try XCTUnwrap(ScreenshotFrame(image: image, pointSize: size))
        let view = ScreenshotSelectionView(shot: shot)
        // 挂到一扇窗上：不挂窗时 AppKit 的 focus 上下文不完整，文字绘制会缺笔画。
        ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: size)).contentView = view
        return (view, shot)
    }

    /// 取一行内容像素，量它偏离中位数最远的那一截：画了格线就会在格子边界上冒出来。
    /// 量**绝对**偏差而不是「暗下去多少」—— 格线在浅色外观下是黑 12%、深色下是白 14%，
    /// 只往一个方向量会让这条判据跟着系统外观切换而失效（实测入夜后自动变暗时整条空转）。
    /// 指的那一点也为此挪到绿区正中：贴着红绿分界取样，行里本来就有一道内容硬边，
    /// 那条边会被当成「格线」量进来。
    private func gridContrast(magnification: ScreenshotMagnification, from: Int, to: Int)
        throws -> (spread: CGFloat, samples: [CGFloat]) {
        let view = ScreenshotMagnifierView(shot: try frame())
        view.follow(point: CGPoint(x: 300, y: 100), magnification: magnification,
                    in: CGRect(x: 0, y: 0, width: 400, height: 400))
        let bitmap = try render(view, name: "magnifier-grid-\(magnification.rawValue).png")
        var sums: [CGFloat] = []
        for x in from...to {
            sums.append(sum(try color(in: bitmap, x: x, y: 100)))
        }
        let median = sums.sorted()[sums.count / 2]
        let spread = sums.map { abs($0 - median) / median }.max() ?? 0
        return (spread, sums)
    }

    private func render(_ view: NSView, name: String) throws -> NSBitmapImageRep {
        view.needsDisplay = true
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RenderFailure.noBitmap
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            let directory = URL(fileURLWithPath: "/tmp/macstroke-magnifier-check", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            NSLog("%@", "[ScreenshotTests] 放大镜渲染结果：\(url.path)")
        }
        return bitmap
    }

    /// bitmap 的像素坐标是左上原点，和面板（flipped）一致，所以直接用面板坐标取点。
    private func color(in bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    /// 取成 0-255 的三个整数：格子里那几列必须逐位相同，比颜色对象相等可靠。
    private func pixel(in bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> [Int] {
        let c = try color(in: bitmap, x: x, y: y)
        return [Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded())]
    }

    private func srgb(_ pixel: [Int]) -> NSColor {
        NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    private func sum(_ color: NSColor) -> CGFloat {
        color.redComponent + color.greenComponent + color.blueComponent
    }

    /// 十字线的绿：浅/深两档都是「绿通道压倒性占优」，而测试图案在那片区域是纯红，
    /// 所以这个判据不用管当前外观是哪一套。
    private func isCrosshair(_ color: NSColor) -> Bool {
        color.greenComponent > 0.6 && color.redComponent < 0.45 && color.blueComponent < 0.45
    }

    private func assertIsHex(_ text: String, _ context: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let digits = "0123456789ABCDEF"
        let ok = text.hasPrefix("#") && text.count == 7
            && text.dropFirst().allSatisfy { digits.contains($0) }
        XCTAssertTrue(ok, "色值要写成 #RRGGBB：\(text) \(context)", file: file, line: line)
    }
}
