//
//  ScreenshotAnnotation.swift
//  MacStroke
//
//  截图之后的注解层：矩形、椭圆、箭头、画笔、文字、马赛克、序号。
//
//  一条贯穿全局的约定 —— **所有注解坐标都是遮罩视图的点坐标**（整屏 flipped 视图，
//  原点在本屏左上角）。绘制、命中、合成三条路径都吃同一套坐标，所以导出时只需要
//  「平移进选区 + 按 scale 放大」一次，不会各算各的。
//
//  马赛克不是画笔轨迹而是一块矩形像素化：真按笔刷涂抹要把轨迹栅格化成 mask，
//  代价和收益完全不成比例（QQ 自己也提供矩形打码）。画笔只做「沿点列描一条」，
//  它不进 mask，所以两者的数据结构分得开：椭圆跟矩形共用两个对角点，只有画笔
//  额外背着一串轨迹点。
//
//  导出用「离屏渲染一个 flipped 视图」而不是直接往 CGBitmapContext 里画：后者要
//  自己管 CTM 翻转和文字方向（本机探针实测：identity 下 draw 正立、加翻转反而倒，
//  而 NSString 又跟着 NSGraphicsContext 的 flipped 状态走），而视图这条路的方向
//  已经被 ScreenshotOverlayRenderTests 验过一遍，注解和底图共用它才不会错位。
//

import AppKit
import CoreGraphics

/// 用户在工具条上选的字。
public enum ScreenshotTool: Int, CaseIterable {
    case rect, ellipse, arrow, pen, text, mosaic, number
}

/// 一条画好的注解。不可变：撤销就是 `removeLast`，没有中间态要维护。
public struct ScreenshotAnnotation {
    public let tool: ScreenshotTool
    public let color: NSColor
    /// 点为单位；合成时随视图缩放自动变成像素宽度。
    public let lineWidth: CGFloat
    /// 矩形/椭圆/马赛克 = 拖选的两个对角；箭头 = 起点；文字/序号 = 锚点；画笔 = 轨迹第一点。
    public let start: CGPoint
    /// 画笔 = 轨迹最后一点。
    public let end: CGPoint
    /// 画笔的整条轨迹（含首尾）；其余工具为空，几何一律看 `start`/`end`。
    public let points: [CGPoint]
    public let text: String
    public let number: Int

    public init(tool: ScreenshotTool, color: NSColor, lineWidth: CGFloat, start: CGPoint,
                end: CGPoint? = nil, points: [CGPoint] = [], text: String = "", number: Int = 0) {
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.start = points.first ?? start
        self.end = points.last ?? end ?? start
        self.points = points
        self.text = text
        self.number = number
    }

    /// 拖出来的框。拖拽方向不限，先归一化成左上原点矩形；画笔取整条轨迹的包围盒。
    public var rect: CGRect {
        Self.boundingBox(of: points.isEmpty ? [start, end] : points)
    }

    /// 文字和序号的大小跟着线宽走：工具条上只有「粗细节」一组控件，
    /// 再给字号单独来一组就变成两层菜单了。
    public var fontSize: CGFloat { max(13, lineWidth * 4) }
    public var badgeRadius: CGFloat { max(11, lineWidth * 2.5) }

    /// 实际会占到的范围，用来判断「这条要不要画、有没有落在选区里」。
    /// `rect` 对文字和序号不够用：它们的 start 只是一个锚点。
    public var dirtyRect: CGRect {
        switch tool {
        case .text:
            return CGRect(x: rect.minX, y: rect.minY,
                          width: CGFloat(text.count) * fontSize * 0.72 + fontSize,
                          height: fontSize * 1.3)
        case .number:
            return CGRect(x: start.x - badgeRadius, y: start.y - badgeRadius,
                          width: badgeRadius * 2, height: badgeRadius * 2)
        case .pen:
            // 描边以路径为中心，包围盒不放心半根线宽就会贴着选区边缘磨掉一圈。
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        default:
            return rect
        }
    }

    // MARK: - 画笔轨迹

    /// 轨迹点之间的最小间距：一次拖动能报上几百个点，全收进点列会把一条随手线变成
    /// 上千个线段，绘制、撤销、导出三条路径都跟着变慢，而肉眼看不出区别。
    public static let penMinDistance: CGFloat = 2

    /// 轨迹又拖到一个点：离上一点不到 `penMinDistance` 的丢弃。抽稀只在这一处做，
    /// 于是进到点列里的点永远干净，绘制侧不用再判。
    public static func penPath(byAppending point: CGPoint, to points: [CGPoint]) -> [CGPoint] {
        guard let last = points.last else { return [point] }
        return hypot(point.x - last.x, point.y - last.y) < penMinDistance ? points : points + [point]
    }

    /// 拖动中的画笔换一条：结构体不可变，点列只能整条换掉。
    public func extendingPen(to point: CGPoint) -> ScreenshotAnnotation {
        ScreenshotAnnotation(tool: tool, color: color, lineWidth: lineWidth, start: start,
                             points: Self.penPath(byAppending: point, to: points))
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var edges = (minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for point in points.dropFirst() {
            edges.minX = min(edges.minX, point.x)
            edges.minY = min(edges.minY, point.y)
            edges.maxX = max(edges.maxX, point.x)
            edges.maxY = max(edges.maxY, point.y)
        }
        return CGRect(x: edges.minX, y: edges.minY,
                      width: edges.maxX - edges.minX, height: edges.maxY - edges.minY)
    }

    /// 在**当前**图形上下文（假定是 flipped 视图的上下文）里画自己。
    public func draw(shot: ScreenshotFrame) {
        switch tool {
        case .rect:
            strokeOutline { NSBezierPath(rect: $0) }
        case .ellipse:
            strokeOutline { NSBezierPath(ovalIn: $0) }
        case .arrow:
            drawArrow()
        case .pen:
            drawPen()
        case .text:
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: color,
            ]
            NSAttributedString(string: text, attributes: attributes).draw(at: start)
        case .mosaic:
            drawMosaic(shot: shot)
        case .number:
            drawBadge()
        }
    }

    // MARK: - 各工具画法

    /// 框类工具共用的一条路径：内缩半个线宽 —— 描边以路径为中心，不缩就会有一半糊到选区外。
    private func strokeOutline(_ path: (CGRect) -> NSBezierPath) {
        color.setStroke()
        let outline = path(rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        outline.lineWidth = lineWidth
        outline.stroke()
    }

    /// 沿点列描一条。圆头 + 圆角转折：默认 Butt 端点在拐角处会豁出缺口，
    /// 手写的圈看着像被咬过。
    private func drawPen() {
        guard points.count > 1 else { return }
        color.setStroke()
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawArrow() {
        color.setStroke()
        color.setFill()
        let head = max(9, lineWidth * 4)
        let angle = atan2(end.y - start.y, end.x - start.x)
        // 杆只画到头部起点：粗线的圆头会把三角头糊成一坨。
        let shaft = CGPoint(x: end.x - cos(angle) * head * 0.8,
                            y: end.y - sin(angle) * head * 0.8)
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: shaft)
        line.lineWidth = lineWidth
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        line.stroke()

        let triangle = NSBezierPath()
        triangle.move(to: end)
        triangle.line(to: barb(angle + .pi - 0.45, head))
        triangle.line(to: barb(angle + .pi + 0.45, head))
        triangle.close()
        triangle.fill()
    }

    private func barb(_ angle: CGFloat, _ length: CGFloat) -> CGPoint {
        CGPoint(x: end.x + cos(angle) * length, y: end.y + sin(angle) * length)
    }

    private func drawMosaic(shot: ScreenshotFrame) {
        guard let tile = ScreenshotMosaic.tile(from: shot.image, viewRect: rect, scale: shot.scale) else { return }
        let context = NSGraphicsContext.current
        let previous = context?.imageInterpolation
        // 关掉插值才会看见方块；平滑插值打出来的只是一团糊。
        context?.imageInterpolation = .none
        NSImage(cgImage: tile, size: rect.size).draw(in: rect)
        context?.imageInterpolation = previous ?? .default
    }

    private func drawBadge() {
        let box = CGRect(x: start.x - badgeRadius, y: start.y - badgeRadius,
                         width: badgeRadius * 2, height: badgeRadius * 2)
        color.setFill()
        NSBezierPath(ovalIn: box).fill()
        let label = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.boldSystemFont(ofSize: badgeRadius),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
    }
}

/// 像素化：缩小 1/block 再关插值放大回去。均值由降采样顺手做掉，不自己遍历像素。
enum ScreenshotMosaic {
    /// 方块边长按**像素**算：打码的效果取决于分辨率，跟用户拖了多少点无关。
    static let blockSize: CGFloat = 12

    static func tile(from image: CGImage, viewRect: CGRect, scale: CGFloat) -> CGImage? {
        let pixel = CGRect(x: viewRect.minX * scale, y: viewRect.minY * scale,
                           width: viewRect.width * scale, height: viewRect.height * scale)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let region = pixel.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1,
              let source = image.cropping(to: region) else { return nil }
        let width = max(1, Int(region.width / blockSize))
        let height = max(1, Int(region.height / blockSize))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        // 这里**不能**加翻转：/tmp 上的探针实测 identity 下 `draw` 就是正立的，
        // translate+scale(1,-1) 反而把小块画倒了。
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

/// 把「选区那块底图 + 落在其中的注解」烘成一张最终图。
public enum ScreenshotComposer {
    public static func compose(shot: ScreenshotFrame, selection: CGRect,
                               annotations: [ScreenshotAnnotation]) -> CGImage? {
        guard selection.width > 0, selection.height > 0 else { return nil }
        // 整屏铺一遍再裁，而不是裁完再画：注解本来就是整屏视图坐标，这样三条绘制
        // 路径（屏上遮罩、预览、导出）用的是同一个坐标空间，不会各算各的。
        let view = ScreenshotExportView(frame: NSRect(origin: .zero, size: shot.pointSize))
        view.shot = shot
        view.annotations = annotations
        // 渲染之前把视图挂到一扇从没上屏的窗上：不挂窗时 AppKit 的 focus 上下文不完整，
        // 文字类注解会缺笔画（离屏取证实测）。orderOut 保证不会闪一下。
        let host = ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: shot.pointSize))
        host.contentView = view
        host.orderOut(nil)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let rendered = bitmap.cgImage else { return nil }

        // 裁切矩形按**渲染结果**的实际比例算，不照抄 shot.scale：离屏位图每点对多少
        // 像素由那块屏的 backing scale 决定，两者不一致时（缩放分辨率、非 Retina 外接
        // 屏）照抄就会裁到别处去。
        let ratioX = CGFloat(rendered.width) / shot.pointSize.width
        let ratioY = CGFloat(rendered.height) / shot.pointSize.height
        let rect = CGRect(x: (selection.minX * ratioX).rounded(.down),
                          y: (selection.minY * ratioY).rounded(.down),
                          width: ceil(selection.width * ratioX),
                          height: ceil(selection.height * ratioY))
            .intersection(CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let cut = rendered.cropping(to: rect.integral) else { return nil }
        return cut
    }
}

/// 只用来导出的离屏视图：1:1 铺底图，注解按视图坐标直接画在上面。
private final class ScreenshotExportView: NSView {
    var shot: ScreenshotFrame?
    var annotations: [ScreenshotAnnotation] = []

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let shot else { return }
        NSImage(cgImage: shot.image, size: bounds.size).draw(in: bounds)
        for annotation in annotations {
            annotation.draw(shot: shot)
        }
    }
}
