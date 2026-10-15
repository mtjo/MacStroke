//
//  ScreenshotPinTests.swift
//
//  「图钉贴图」那几格的取证。分三块：总账（窗有没有人持有、能不能一张张关掉）、
//  缩放的算术（等比 + 不甩走 + 钳上下限），以及贴图内容的方向。
//
//  方向这块和遮罩那边同理：这层窗也是 flipped 视图，画 CGImage 时翻错一次就上下颠倒，
//  而在实机上只表现为「钉出来的图和屏幕上看到的反着」，没人会去逐像素核对。
//

import AppKit
import XCTest

@testable import Screenshot

final class ScreenshotPinTests: XCTestCase {
    private let pattern: CGImage = {
        guard let image = QuadrantPattern.image(width: 400, height: 200) else {
            preconditionFailure("拿不到测试图案")
        }
        return image
    }()

    override func tearDown() {
        ScreenshotPinBoard.closeAll()
        super.tearDown()
    }

    /// 一次能钉多张：总账得把每张窗都持有住。没人强持有的 borderless 窗，orderOut 之后
    /// 随时被回收，用户手上就凭空少了几张贴图。
    func testPinsAreHeldUntilClosed() throws {
        let first = ScreenshotPinBoard.show(image: pattern,
                                            screenRect: NSRect(x: 100, y: 100, width: 200, height: 120))
        let second = ScreenshotPinBoard.show(image: pattern,
                                             screenRect: NSRect(x: 400, y: 300, width: 160, height: 90))
        XCTAssertEqual(ScreenshotPinBoard.count, 2)
        XCTAssertEqual(first.frame.size, NSSize(width: 200, height: 120), "贴图开起来就是选区那块大小")
        XCTAssertEqual(second.frame.origin, CGPoint(x: 400, y: 300), "钉回它原来在屏幕上的位置")
        XCTAssertEqual(first.level, .floating, "要压在其他 App 之上，又不能高过菜单栏")
        XCTAssertTrue(first.isMovableByWindowBackground, "没有标题栏，整扇窗的背景就得能拖")

        ScreenshotPinBoard.close(first)
        XCTAssertEqual(ScreenshotPinBoard.count, 1)
        XCTAssertTrue(ScreenshotPinBoard.pins.contains { $0 === second })

        ScreenshotPinBoard.closeAll()
        XCTAssertEqual(ScreenshotPinBoard.count, 0)
    }

    /// 滚轮缩放：宽高等比例乘同一个倍率、窗中心不动，并且钳在上下限里。
    /// 不等比会缩成一条细长方框，锚在左上角会越滚越偏 —— 这两种都只在连着滚好几格
    /// 之后才看得出来，所以拿算术验。
    func testZoomKeepsAspectCenterAndBounds() throws {
        let base = NSSize(width: 200, height: 100)
        var frame = NSRect(x: 300, y: 200, width: 200, height: 100)

        frame = ScreenshotPinWindow.zoomed(frame, up: true, base: base)
        XCTAssertEqual(frame.width, 220, accuracy: 0.01)
        XCTAssertEqual(frame.height, 110, accuracy: 0.01, "长宽比得跟着走，不能只放大一条边")
        XCTAssertEqual(frame.midX, 400, accuracy: 0.01, "缩放不能把窗甩走")
        XCTAssertEqual(frame.midY, 250, accuracy: 0.01)

        for _ in 0..<60 { frame = ScreenshotPinWindow.zoomed(frame, up: true, base: base) }
        XCTAssertEqual(frame.width, base.width * ScreenshotPinWindow.maxZoom, accuracy: 0.5,
                       "放大得到头，不然能滚出一张糊满全屏幕的图")

        for _ in 0..<120 { frame = ScreenshotPinWindow.zoomed(frame, up: false, base: base) }
        XCTAssertEqual(frame.width, base.width * ScreenshotPinWindow.minZoom, accuracy: 0.5,
                       "缩小也要有下限")
        XCTAssertEqual(frame.height, base.height * ScreenshotPinWindow.minZoom, accuracy: 0.5)
    }

    /// 内容必须画正：左上红、右上绿、左下蓝、右下白（图案本身方向敏感）。
    func testPinContentIsUpright() throws {
        let view = ScreenshotPinView(image: pattern, naturalSize: NSSize(width: 400, height: 200))
        let window = ScreenshotOverlayWindow(screenFrame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = view
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("拿不到离屏位图")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)

        let color = { (x: Int, y: Int) in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear }
        XCTAssertTrue(QuadrantPattern.isRed(color(10, 10)), "左上是红，画倒了就成了蓝")
        XCTAssertTrue(QuadrantPattern.isGreen(color(390, 10)))
        XCTAssertTrue(QuadrantPattern.isBlue(color(10, 190)))
        XCTAssertTrue(QuadrantPattern.isWhite(color(390, 190)))
    }
}
