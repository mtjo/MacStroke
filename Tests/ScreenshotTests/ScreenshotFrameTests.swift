//
//  ScreenshotFrameTests.swift
//
//  坐标换算是截图功能最容易错、又最不容易被发现的一步：偏了不会报错，只会
//  「截到的不是屏幕上看到的那块」。所以除了纯数学，这里还用四分之一色块图案
//  做一次方向取证 —— y 轴一旦翻错，取到的颜色就会落到另一个象限。
//

import AppKit
import XCTest

@testable import Screenshot

final class ScreenshotFrameTests: XCTestCase {
    func testScaleIsPixelsPerPoint() throws {
        let shot = try XCTUnwrap(QuadrantPattern.image(width: 3840, height: 2160))
        let frame = try XCTUnwrap(ScreenshotFrame(image: shot, pointSize: NSSize(width: 1920, height: 1080)))
        XCTAssertEqual(frame.scale, 2)
    }

    /// 视图和底图同为左上原点，所以两个轴都是正比例，y 不翻。
    func testPixelRectScalesWithoutFlippingY() throws {
        let frame = try testFrame(image: 3840, height: 2160, points: 1920, height: 1080)
        let pixels = frame.pixelRect(for: CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(pixels, CGRect(x: 20, y: 40, width: 200, height: 100))
    }

    /// 鼠标拖到屏外时 AppKit 还会继续给越界坐标，必须钳住而不是裁出负尺寸。
    func testPixelRectClampsToImageBounds() throws {
        let frame = try testFrame(image: 2000, height: 1000, points: 1000, height: 500)
        let pixels = frame.pixelRect(for: CGRect(x: 900, y: 400, width: 300, height: 300))
        XCTAssertEqual(pixels, CGRect(x: 1800, y: 800, width: 200, height: 200))
    }

    func testPixelRectRejectsEmptyAndOffscreen() throws {
        let frame = try testFrame(image: 2000, height: 1000, points: 1000, height: 500)
        XCTAssertEqual(frame.pixelRect(for: .zero), .zero)
        XCTAssertEqual(frame.pixelRect(for: CGRect(x: -400, y: -400, width: 100, height: 100)), .zero)
        XCTAssertNil(frame.crop(viewRect: CGRect(x: -400, y: -400, width: 100, height: 100)))
    }

    /// 非整数缩放（缩放分辨率下常见）取整后仍要落在像素格上，裁切才不会偏半像素。
    /// `integral` 是向外扩，所以宁多一像素也不漏一像素。
    func testFractionalScaleRoundsToWholePixels() throws {
        let frame = try testFrame(image: 2880, height: 1800, points: 1512, height: 945)
        let pixels = frame.pixelRect(for: CGRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertEqual(pixels, CGRect(x: 190, y: 190, width: 382, height: 382))
        XCTAssertEqual(pixels.origin.x.rounded(), pixels.origin.x)
        XCTAssertEqual(pixels.width.rounded(), pixels.width)
        XCTAssertLessThanOrEqual(pixels.maxX, 2880)
        XCTAssertLessThanOrEqual(pixels.maxY, 1800)
    }

    /// 方向取证：裁「视图坐标的左半边」必须上红下蓝 —— 正好是图案左列的上下两个
    /// 象限。如果哪里把 y 翻了，这里会变成上蓝下红；而这种 bug 在真实桌面上只表现为
    /// 「截到的内容比看到的位置偏上/偏下」，很难被抓出来。
    func testCropKeepsImageOrientation() throws {
        let shot = try XCTUnwrap(QuadrantPattern.image(width: 800, height: 400))
        let frame = try XCTUnwrap(ScreenshotFrame(image: shot, pointSize: NSSize(width: 800, height: 400)))
        let cut = try XCTUnwrap(frame.crop(viewRect: CGRect(x: 0, y: 0, width: 400, height: 400)))
        XCTAssertEqual(cut.width, 400)
        XCTAssertEqual(cut.height, 400)
        let rep = try XCTUnwrap(NSBitmapImageRep(cgImage: cut.image))
        XCTAssertTrue(QuadrantPattern.isRed(rep.colorAt(x: 10, y: 10) ?? .clear), "裁片顶部应是左上象限的红")
        XCTAssertTrue(QuadrantPattern.isBlue(rep.colorAt(x: 10, y: 390) ?? .clear), "裁片底部应是左下象限的蓝")
    }

    /// 反向对照：先证明这张图案本身是方向敏感的（上红下蓝、左红右绿）。
    /// 图案要是自己就是倒的，上面那条方向断言就成了空转。
    func testPatternIsOrientationSensitive() throws {
        let shot = try XCTUnwrap(QuadrantPattern.image(width: 800, height: 400))
        let rep = try XCTUnwrap(NSBitmapImageRep(cgImage: shot))
        XCTAssertTrue(QuadrantPattern.isRed(rep.colorAt(x: 10, y: 10) ?? .clear))
        XCTAssertTrue(QuadrantPattern.isGreen(rep.colorAt(x: 790, y: 10) ?? .clear))
        XCTAssertTrue(QuadrantPattern.isBlue(rep.colorAt(x: 10, y: 390) ?? .clear))
        XCTAssertTrue(QuadrantPattern.isWhite(rep.colorAt(x: 790, y: 390) ?? .clear))
    }

    /// 真屏取证：`NSScreenNumber` → `CGDirectDisplayID` 这条链只能在接了显示器的机器上
    /// 验，NSScreen 造不出来。抓图**不**断言成功：测试进程没有屏幕录制授权，实测
    /// macOS 13 上未授权时 `CGDisplayCreateImage` 直接返回 nil（不是 RemoteScreenCapture
    /// 注释里说的「给一张壁纸」），所以这里只验 displayID 解析和「拿不到图就干净返回
    /// nil」这条降级路径。真出图要等装了 App 的进程来验。
    func testGrabResolvesTheRealDisplayID() throws {
        guard let screen = ScreenshotGrabber.targetScreen() else { throw XCTSkip("没有可用屏幕") }
        XCTAssertNotEqual(try XCTUnwrap(ScreenshotGrabber.displayID(for: screen)), CGDirectDisplayID(0))
        guard let shot = ScreenshotGrabber.grab(screen: screen) else { return }
        XCTAssertEqual(shot.pointSize, screen.frame.size)
        XCTAssertGreaterThanOrEqual(shot.scale, 1)
        let rect = CGRect(x: 20, y: 20, width: 120, height: 80)
        XCTAssertEqual(CGFloat(try XCTUnwrap(shot.crop(viewRect: rect)).width), shot.pixelRect(for: rect).width)
    }

    private func testFrame(image imageWidth: Int, height imageHeight: Int,
                           points pointWidth: CGFloat, height pointHeight: CGFloat) throws -> ScreenshotFrame {
        let shot = try XCTUnwrap(QuadrantPattern.image(width: imageWidth, height: imageHeight))
        return try XCTUnwrap(ScreenshotFrame(image: shot, pointSize: NSSize(width: pointWidth, height: pointHeight)))
    }
}

/// 四象限纯色图案：左上红、右上绿、左下蓝、右下白。方向敏感，专门用来抓 y 翻转。
enum QuadrantPattern {
    static func image(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let half = CGSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        let full = CGSize(width: CGFloat(width), height: CGFloat(height))
        // CGContext 是左下原点：这里的「右上」在图像数据里就是行首，即视觉左上。
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(origin: CGPoint(x: 0, y: half.height), size: half))
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(origin: CGPoint(x: half.width, y: half.height),
                            size: CGSize(width: full.width - half.width, height: half.height)))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(origin: .zero, size: CGSize(width: half.width, height: full.height - half.height)))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: CGPoint(x: half.width, y: 0),
                            size: CGSize(width: full.width - half.width, height: full.height - half.height)))
        return context.makeImage()
    }

    static func isRed(_ color: NSColor) -> Bool { rgb(color).r > 0.6 && rgb(color).g < 0.4 && rgb(color).b < 0.4 }
    static func isBlue(_ color: NSColor) -> Bool { rgb(color).b > 0.6 && rgb(color).r < 0.4 && rgb(color).g < 0.4 }
    static func isGreen(_ color: NSColor) -> Bool { rgb(color).g > 0.6 && rgb(color).r < 0.4 && rgb(color).b < 0.4 }
    static func isWhite(_ color: NSColor) -> Bool { rgb(color).r > 0.6 && rgb(color).g > 0.6 && rgb(color).b > 0.6 }

    private static func rgb(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
    }
}
