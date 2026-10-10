//
//  RemoteScreenCapture.swift
//  MacStroke
//
//  抓一帧主屏 → 等比缩小 → JPEG，给触屏模式当画面源。
//
//  为什么是 CGDisplayCreateImage 而不是 ScreenCaptureKit：本包最低 macOS 13，SCK 要
//  先异步取 SCShareableContent、再为每台设备维持一条 SCStream 代理链，代码量是这条
//  同步取图路径的好几倍，而我们只要 3 fps 的一帧静图。它在 macOS 14 起被标记废弃
//  （14/15 实测仍然出图），真要换成 SCK 只需要改 capture() 这一个函数。
//
//  权限：没有「屏幕录制」授权时 CGDisplayCreateImage **不报错**，只会给出一张干净的
//  壁纸加光标——所有 App 窗口都不画进来。所以权限必须单独 preflight，不能拿图像判。
//

import CoreGraphics
import Foundation
import ImageIO

/// 编码完成的一帧，`jpeg` 是 JPEG 字节本体（base64 由协议层加）。
public struct RemoteScreenFrame {
    public let width: Int
    public let height: Int
    public let jpeg: Data

    public init(width: Int, height: Int, jpeg: Data) {
        self.width = width
        self.height = height
        self.jpeg = jpeg
    }
}

public enum RemoteScreenCapture {
    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 弹系统授权框。刚授完权的进程通常要重启才真的能截到窗口，调用方别当即成。
    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 抓主屏并缩放到 `maxWidth` 宽以内。显示器休眠、没有外接屏被拔掉之类取不到图时返回 nil。
    public static func capture(maxWidth: Int, quality: Int) -> RemoteScreenFrame? {
        let display = CGMainDisplayID()
        guard let shot = CGDisplayCreateImage(display) else { return nil }
        let target = scaledSize(width: shot.width, height: shot.height, maxWidth: maxWidth)
        let image = (target.w == shot.width && target.h == shot.height) ? shot : resized(shot, to: target)
        guard let image, let jpeg = jpegData(from: image, quality: quality) else { return nil }
        return RemoteScreenFrame(width: target.w, height: target.h, jpeg: jpeg)
    }

    /// 等比缩到不超过 `maxWidth`；本来就更窄就原样，不放大（放大只会更糊更大）。
    static func scaledSize(width: Int, height: Int, maxWidth: Int) -> (w: Int, h: Int) {
        guard width > 0, height > 0, width > maxWidth else {
            return (max(width, 1), max(height, 1))
        }
        return (maxWidth, max(Int((Double(height) * Double(maxWidth) / Double(width)).rounded()), 1))
    }

    static func jpegData(from image: CGImage, quality: Int) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        let percent = Double(min(max(quality, 1), 99)) / 100
        let options: [NSString: Any] = [kCGImageDestinationLossyCompressionQuality: percent]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    private static func resized(_ image: CGImage, to size: (w: Int, h: Int)) -> CGImage? {
        guard let context = CGContext(data: nil, width: size.w, height: size.h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // 桌面图里全是文字和小图标，low 会糊掉 12px 的菜单字，best 又慢一倍。
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.w, height: size.h))
        return context.makeImage()
    }
}
