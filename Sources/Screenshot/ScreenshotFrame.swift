//
//  ScreenshotFrame.swift
//  MacStroke
//
//  截图的第一块地基：把「一帧全屏原图」和「这块屏有多少点」绑在一起，并给出
//  选区矩形 → 像素矩形的换算。
//
//  为什么是「先冻结一帧」而不是把遮罩做成实时透屏：微信/QQ 截图触发后画面会
//  立刻定格，用户在静止的图上拖选区。这样选得准（拖的过程中内容不会变），
//  而且自家半透明遮罩天然不会被截进去。代价是定格之后的那一瞬发生的变化截不到，
//  这个代价所有同类工具都在付。
//
//  还是不用 ScreenCaptureKit：这里要的是「整块屏的原图像素」，SCStream 是异步
//  回调 + 每台设备一条代理链，为了拿一帧静图不值当。屏幕录制权限的坑和
//  RemoteScreenCapture 一样 —— 没授权时 CGDisplayCreateImage 不报错，只给一张
//  干净壁纸，所以权限必须单独 preflight。
//

import AppKit
import CoreGraphics

/// 一块屏的一帧定格画面。
public struct ScreenshotFrame {
    /// 抓屏得到的原图，**像素**尺寸，左上原点（CoreGraphics 的位图惯例）。
    public let image: CGImage
    /// 这块屏有多少**点**（= overlay 视图的尺寸）。存尺寸而不是 NSScreen，
    /// 是为了让换算能被单测覆盖：测试里造不出一块指定分辨率的屏。
    public let pointSize: NSSize
    /// 每点对应多少像素。用图像宽除以点宽算出来，而不是读 `backingScaleFactor`：
    /// 缩放分辨率下后者和实际帧宽对不上，直接算比值永远自洽。
    public let scale: CGFloat

    public init?(image: CGImage, pointSize: NSSize) {
        guard pointSize.width > 0, image.width > 0 else { return nil }
        self.image = image
        self.pointSize = pointSize
        self.scale = CGFloat(image.width) / pointSize.width
    }

    /// 视图坐标（overlay 是 flipped 视图，原点在屏左上角）里的选区 → 底图像素矩形。
    ///
    /// flipped 视图和 CGImage 都是左上原点，所以这里**连 y 都不用翻**，只剩缩放。
    /// 工程里现有的 `y = primaryHeight - y`（CanvasManager）只对主屏成立；副屏上
    /// 那种写法必然偏，靠这个巧合绕开了。
    ///
    /// 结果按整像素取整并和底图求交：越界（选区拖到屏外）会被钳掉，完全不相交时
    /// 返回 `.zero`，调用方据此判定「这块不能裁」。
    public func pixelRect(for viewRect: CGRect) -> CGRect {
        guard !viewRect.isEmpty else { return .zero }
        let scaled = CGRect(x: viewRect.minX * scale,
                            y: viewRect.minY * scale,
                            width: viewRect.width * scale,
                            height: viewRect.height * scale)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let clamped = scaled.intersection(bounds)
        guard !clamped.isNull, !clamped.isEmpty else { return .zero }
        return clamped.integral
    }

    /// 从这帧里裁出选区。选区太小（取整后不足 1px）或落在屏外时返回 nil。
    public func crop(viewRect: CGRect) -> (image: CGImage, width: Int, height: Int)? {
        let rect = pixelRect(for: viewRect)
        guard rect.width >= 1, rect.height >= 1, let cut = image.cropping(to: rect) else { return nil }
        return (cut, cut.width, cut.height)
    }

    /// 视图坐标里那一点落在底图的哪个像素（整数索引，左上原点）。
    /// 越界是钳到边上而不是返回 nil：放大镜贴着屏边走时也要有一个确定的中心像素。
    public func pixelIndex(for viewPoint: CGPoint) -> CGPoint {
        let x = min(max(0, (viewPoint.x * scale).rounded(.down)), CGFloat(image.width - 1))
        let y = min(max(0, (viewPoint.y * scale).rounded(.down)), CGFloat(image.height - 1))
        return CGPoint(x: x, y: y)
    }

    /// 该像素的 #RRGGBB。取不到（屏被拔掉、格式不认识）返回 nil。
    public func hexColor(for viewPoint: CGPoint) -> String? {
        guard let rgb = rgb(for: viewPoint) else { return nil }
        return String(format: "#%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
    }

    /// 该像素的 RGB 三分量。
    ///
    /// 走「裁 1×1 → 画进 1×1 的 RGBA8 上下文 → 读四个字节」，而不是直接按
    /// `image.bytesPerRow` 去索引原始位图：抓屏给的位图字节序/alpha 布局不保证，
    /// 而 CoreGraphics 的这次绘制会替我转成我要的格式。1×1 的开销可以忽略。
    public func rgb(for viewPoint: CGPoint) -> (red: Int, green: Int, blue: Int)? {
        let index = pixelIndex(for: viewPoint)
        guard let cut = image.cropping(to: CGRect(x: index.x, y: index.y, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(cut, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}

public enum ScreenshotGrabber {
    /// 鼠标当前所在的那块屏 —— 截图要落在用户手边，不是「主屏」。
    /// 和 Toast 的选屏逻辑一致（WindowManager/Toast.swift）。
    public static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// 定格某块屏的一帧。显示器休眠/被拔掉时 `CGDisplayCreateImage` 返回 nil。
    public static func grab(screen: NSScreen) -> ScreenshotFrame? {
        guard let id = displayID(for: screen), let shot = CGDisplayCreateImage(id) else { return nil }
        return ScreenshotFrame(image: shot, pointSize: screen.frame.size)
    }

    /// `NSScreenNumber` 就是 `CGDirectDisplayID`，这是 AppKit 唯一认账的对应关系。
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
