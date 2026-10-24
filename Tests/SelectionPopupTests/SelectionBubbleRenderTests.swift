//
//  SelectionBubbleRenderTests.swift
//  SelectionPopupTests
//
//  气泡长什么样 —— 离屏渲染取证，套路照 `Tests/ScreenshotTests/ScreenshotRenderTests.swift`：
//  把视图画进一张 bitmap 再逐点验，不截屏、不枚举窗口（那两条在开发机上都会把人拽开，
//  而且判据取自「屏幕上恰好有什么」就等于取自运气）。
//
//  四块关注点，编号接在控制器那套之后：
//  - **M39 每格只认自己**：格子对象、格子位置、点击命中三者必须对得上同一个人。
//    `buildCells()` 里那个闭包捕获的是循环里的 `item`，写错成固定下标（注解条上真栽过）
//    就会出现「点复制把朗读念出来了」，而这条除了渲染没有别的办法验。
//  - **M40 底衬跟随系统外观**：明暗两档各渲一张，只比「两档确实不同」，不钉死哪档亮 ——
//    钉死了就把苹果哪天调调色板变成我们的用例红。参照物来回换过三次（见 project memory），
//    所以这一条刻意不写「深色档一定是 0.18」。
//  - **M41 图标真画出来了**：每格里和底衬明显不同的像素要有足够多个。这里咬的是「有没有画」，
//    **咬不到「画的是不是那个 symbol」**（模板图取不到时源码会退化成问号，那也是一堆像素）；
//    图标选得对不对只能装机肉眼核。
//  - **M42 是胶囊不是方条**：圆角半径 = 高度一半，所以在 y=0.25h 那一行，最左边那一列必须是
//    透明的、往里几个点才有着色。矩形条会在这里露出直角。
//  - **M43 按下要看得见**：同一点「按下前后」两渲相比。判据取自差值而不是取自某个绝对色 ——
//    quaternaryLabel 那档很淡，绝对阈值在两档外观下会给出不同结论。
//
//  y 方向验不出翻转：格子高度 == 胶囊高度（`cellFrame` 那个 `(size.height - cellSize.height)/2`
//  现在是 0），视图上下都没有留白，翻转与不翻转算出来的窗口坐标落在同一片。所以命中取证只做
//  横向。这一条写在这儿，免得后人以为纵向翻转过关了。
//
//  `SelectionBubblePanel` 那扇真窗不在这里验：`swift test` 进程里没有 NSApplication 撑着，
//  开面板不可靠，而且面板的六项属性已经被 M37 钉在 `SelectionBubbleWindowConfig` 的值上。
//  每张图顺手导出到 /tmp，肉眼再核一遍方向和对齐。
//

import AppKit
import XCTest

@testable import SelectionPopup

final class SelectionBubbleRenderTests: XCTestCase {
    private var exportDirectory: URL {
        URL(fileURLWithPath: "/tmp/macstroke-selection-bubble-check", isDirectory: true)
    }

    private enum RenderFailure: Error {
        case noBitmap, noPNGData
    }

    /// 一格的尺寸，和尺子同源（用例不许自己写死 34x30，那等于把被测常量当判据）。
    private let cell = SelectionBubbleLayout.cellSize
    private let edge = SelectionBubbleLayout.edgePadding

    // MARK: - M39 每格只认自己

    /// 四格的顺序和 id：取证按 id 核对，文案会随语言变，这个不会。
    func testCellsAreBuiltInDocumentedOrder() {
        let view = SelectionBubbleView(items: SelectionBubbleItem.defaultItems)
        XCTAssertEqual(view.cellIDs, ["copy", "search", "translate", "speak"])
        XCTAssertEqual(view.bounds.size, SelectionBubbleLayout.capsuleSize(cellCount: 4))
    }

    /// 格子清单只能来自「偏好页上开着的那几格」：关掉翻译和复制之后，气泡上不该还留着它们
    /// （留着就是「关了还能点到」），胶囊也不该还按四格算宽（那样右边是一块空白）。
    func testOnlyTheCellsTheUserLeftOnGetBuilt() {
        let two = SelectionBubbleView(items: SelectionBubbleItem.items(for: [.search, .speak]))
        XCTAssertEqual(two.cellIDs, ["search", "speak"])
        XCTAssertEqual(two.bounds.size, SelectionBubbleLayout.capsuleSize(cellCount: 2),
                       "两格还按四格算宽，右边就是一块点不到的空白")

        let none = SelectionBubbleView(items: SelectionBubbleItem.items(for: []))
        XCTAssertTrue(none.cellIDs.isEmpty, "四格全关时不许留一格空的")
    }

    /// 格子对象 ↔ 尺子给的位置 ↔ 点上去触发的 id，三者必须指同一个。
    /// 这条是「点复制却念出声」那一类捕获错位唯一的拦网。
    func testEachCellFiresOnlyItsOwnAction() throws {
        let view = SelectionBubbleView(items: SelectionBubbleItem.defaultItems)
        attach(view, size: view.bounds.size)
        let count = SelectionBubbleItem.defaultItems.count
        let cells = view.subviews.compactMap { $0 as? SelectionBubbleCell }
        XCTAssertEqual(cells.count, count, "四格没都挂上")

        for (index, expected) in view.cellIDs.enumerated() {
            let target = try XCTUnwrap(cells[safe: index])
            XCTAssertEqual(target.item.id, expected, "第 \(index) 格拿错了 item")
            XCTAssertEqual(target.frame, SelectionBubbleLayout.cellFrame(index: index, cellCount: count),
                           "第 \(index) 格摆错了位置")

            var fired: [String] = []
            view.onAction = { fired.append($0) }
            // 事件坐标是**窗口**坐标（视图 flipped、正好铺满窗口，所以要翻一次 y）。
            // 点在格子中心，等价于用户那一下真按在这格里。
            try fireMouseUp(on: target, view: view)
            XCTAssertEqual(fired, [expected], "点第 \(index) 格应该只触发 \(expected)")
        }
    }

    /// 横向命中：两格之间那条缝的两侧各归谁，必须一左一右分清楚。
    /// 格子是**挨着**铺的（`cellFrame` 里没有间隔），所以 `maxX` 就是下一格的 `minX`。
    /// 写错一格偏移、或者把 rect 判成「含右端点」，这条就会红。
    func testClicksNearTheBorderSplitToTheRightOwner() throws {
        let view = SelectionBubbleView(items: SelectionBubbleItem.defaultItems)
        attach(view, size: view.bounds.size)
        let cells = view.subviews.compactMap { $0 as? SelectionBubbleCell }
        guard cells.count == 4 else { return XCTFail("四格没都挂上") }

        for index in 0 ..< 3 {
            let left = cells[index]
            let right = cells[index + 1]
            XCTAssertEqual(left.frame.maxX, right.frame.minX, "两格之间该是紧挨着的")
            let border = left.frame.maxX
            var fired: [String] = []
            view.onAction = { fired.append($0) }

            try fireMouseUp(at: NSPoint(x: border - 1, y: left.frame.midY), view: view, on: left)
            XCTAssertEqual(fired, [left.item.id], "x=\(border - 1) 在第 \(index) 格里，该归它")

            fired = []
            try fireMouseUp(at: NSPoint(x: border + 1, y: right.frame.midY), view: view, on: right)
            XCTAssertEqual(fired, [right.item.id], "x=\(border + 1) 已经在第 \(index + 1) 格里")

            // 反向：同一笔点交给**错的那一格**，它必须不认。
            fired = []
            try fireMouseUp(at: NSPoint(x: border + 1, y: left.frame.midY), view: view, on: left)
            XCTAssertTrue(fired.isEmpty, "x=\(border + 1) 不在第 \(index) 格的矩形里，它不该认")
        }
    }

    /// 落在胶囊外（左右两端的留白）不该算点中了谁。
    func testClickOutsideEveryCellFiresNothing() throws {
        let view = SelectionBubbleView(items: SelectionBubbleItem.defaultItems)
        attach(view, size: view.bounds.size)
        let cells = view.subviews.compactMap { $0 as? SelectionBubbleCell }
        var fired: [String] = []
        view.onAction = { fired.append($0) }
        for target in cells {
            try fireMouseUp(at: NSPoint(x: edge / 2, y: cell.height / 2), view: view, on: target)
        }
        XCTAssertTrue(fired.isEmpty, "留白处不属于任何一格，四格都不该认这一下")
    }

    // MARK: - M40/M41/M42/M43 渲染色

    func testBodyColourFollowsSystemAppearance() throws {
        let dark = try capsule(appearance: .darkAqua, name: "capsule-dark.png")
        let light = try capsule(appearance: .aqua, name: "capsule-light.png")
        let d = try XCTUnwrap(body(dark))
        let l = try XCTUnwrap(body(light))

        // 只咬「两档确实翻了」，不咬谁亮谁暗。
        XCTAssertGreaterThan(abs(luminance(d) - luminance(l)), 0.15,
                             "底衬没跟着明暗翻档：亮 \(luminance(l)) 暗 \(luminance(d))")
        // 半透明那一档（0.96）也得真落进图里，否则下面所有取点都只是在比背景。
        XCTAssertGreaterThan(d.alphaComponent, 0.9)
        XCTAssertGreaterThan(l.alphaComponent, 0.9)
    }

    func testGlyphsAreVisibleInBothAppearances() throws {
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let shot = try capsule(appearance: name, name: "glyphs-\(name.rawValue).png")
            let background = try XCTUnwrap(body(shot), "取不到底衬色，后面的比较没有参照物")
            let cells = shot.view.subviews.compactMap { $0 as? SelectionBubbleCell }
            XCTAssertEqual(cells.count, 4)
            for (index, target) in cells.enumerated() {
                let ink = inkPixels(in: shot.bitmap, view: shot.view, frame: target.frame, unlike: background)
                XCTAssertGreaterThanOrEqual(ink.count, 20,
                                            "第 \(index) 格（\(target.item.id)）只渲出 \(ink.count) 个墨色像素：图标没画出来")
                // 墨色必须**比底衬更实**：图标是被 tint 成 labelColor 的，两档外观下都比底衬暗/亮。
                XCTAssertGreaterThan(ink.contrast, 0.15,
                                     "第 \(index) 格的墨色太接近底衬（\(ink.contrast)），等于看不见")
            }
        }
    }

    /// 圆角：在 y=0.25h 那一行，最左一列必须透明，往里几格才有底衬。
    /// 半径 15、内缩 0.5 → 该行的左沿在 x≈2.8，所以取 0 和 6 两点刚好一边一侧。
    func testBubbleIsACapsuleNotARectangle() throws {
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let shot = try capsule(appearance: name, name: "capsule-\(name.rawValue).png")
            let y = shot.view.bounds.height * 0.25
            let corner = try XCTUnwrap(sample(shot, x: 0, y: y))
            XCTAssertLessThan(corner.alphaComponent, 0.02,
                              "圆角外侧还上了色（α=\(corner.alphaComponent)）：画的是直角矩形")
            let inside = try XCTUnwrap(sample(shot, x: 6, y: y))
            XCTAssertGreaterThan(inside.alphaComponent, 0.5,
                                 "圆角内侧没着色：整条胶囊压根没画底")
            // 上沿正中是胶囊该有的直边，别被这一句误判成矩形。
            let middle = try XCTUnwrap(sample(shot, x: shot.view.bounds.width / 2, y: y))
            XCTAssertGreaterThan(middle.alphaComponent, 0.5)
        }
    }

    /// 按下态：同一位置按前后相比。
    /// 取点落在「按下色块之内、图标之外」，所以差值只能来自那一块按下底。
    func testPressedCellPaintsItsOwnBackground() throws {
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let plain = try capsule(appearance: name, name: "press-\(name.rawValue)-off.png")
            let pressedView = SelectionBubbleView(items: SelectionBubbleItem.defaultItems)
            pressedView.appearance = NSAppearance(named: name)
            attach(pressedView, size: pressedView.bounds.size)
            guard let first = pressedView.subviews.compactMap({ $0 as? SelectionBubbleCell }).first else {
                return XCTFail("四格没都挂上")
            }
            first.mouseDown(with: try event(.leftMouseDown, at: .zero))
            let pressed = Shot(view: pressedView,
                               bitmap: try render(pressedView, name: "press-\(name.rawValue)-on.png"))

            let probe = NSPoint(x: SelectionBubbleLayout.cellFrame(index: 0, cellCount: 4).minX + 4,
                                y: cell.height / 2)
            let off = try XCTUnwrap(sample(plain, x: probe.x, y: probe.y))
            let on = try XCTUnwrap(sample(pressed, x: probe.x, y: probe.y))
            // 按之前这里就是底衬本身（这一格证明取点没蹭到图标）。
            XCTAssertEqual(sum(off), sum(try XCTUnwrap(body(plain))), accuracy: 0.02,
                           "取点蹭到了别的东西，下面的差值说明不了按下态")
            XCTAssertGreaterThan(abs(sum(off) - sum(on)), 0.05,
                                 "按下后这一块没变（\(sum(off)) → \(sum(on))）：点下去看不见反馈")
        }
    }

    // MARK: - 辅助

    /// 一次渲染的成品：视图 + 位图 + 缩放（这机器的 backing scale 可能是 1 也可能是 2，
    /// 取点一律从「点」换算到「像素」，别假设 1:1）。
    private struct Shot {
        let view: SelectionBubbleView
        let bitmap: NSBitmapImageRep
        var scale: CGFloat { CGFloat(bitmap.pixelsWide) / max(view.bounds.width, 1) }
    }

    /// 墨色统计：数量和「离底衬有多远」的最大通道差。
    private struct Ink {
        let count: Int
        let contrast: CGFloat
    }

    private func capsule(appearance: NSAppearance.Name, name: String) throws -> Shot {
        let view = SelectionBubbleView(items: SelectionBubbleItem.defaultItems)
        view.appearance = NSAppearance(named: appearance)
        attach(view, size: view.bounds.size)
        return Shot(view: view, bitmap: try render(view, name: name))
    }

    /// 挂到一扇窗上再渲染：不挂窗时 AppKit 的 focus 上下文不完整，文字/图标类绘制会缺笔画
    /// （同一个结论在截图那套取证里先踩过）。这扇窗始终不上屏，只是给视图一个坐标系。
    private func attach(_ view: NSView, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
    }

    @discardableResult
    private func render(_ view: NSView, name: String) throws -> NSBitmapImageRep {
        view.needsDisplay = true
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RenderFailure.noBitmap
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try export(bitmap, name: name)
        return bitmap
    }

    private func export(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderFailure.noPNGData
        }
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let url = exportDirectory.appendingPathComponent(name)
        try data.write(to: url)
        NSLog("%@", "[SelectionPopupTests] 渲染结果：\(url.path)")
    }

    /// 视图坐标（flipped，左上原点）→ 位图像素。位图的像素原点也是左上，两者对得上。
    private func sample(_ shot: Shot, x: CGFloat, y: CGFloat) -> NSColor? {
        let px = Int(x * shot.scale)
        let py = Int(y * shot.scale)
        guard px >= 0, py >= 0, px < shot.bitmap.pixelsWide, py < shot.bitmap.pixelsHigh else { return nil }
        return shot.bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
    }

    /// 底衬取样点：胶囊左端的留白正中 —— 只有底，蹭不到任何一格图标。
    private func body(_ shot: Shot) -> NSColor? {
        sample(shot, x: 5, y: shot.view.bounds.height / 2)
    }

    /// 一格里的墨色像素：在该格范围内、和底衬通道差大于 0.08、且不接近透明的。
    private func inkPixels(in bitmap: NSBitmapImageRep, view: NSView,
                           frame: NSRect, unlike background: NSColor) -> Ink {
        let scale = CGFloat(bitmap.pixelsWide) / max(view.bounds.width, 1)
        var count = 0
        var worst: CGFloat = 0
        let x0 = Int((frame.minX + 2) * scale), x1 = Int((frame.maxX - 2) * scale)
        let y0 = Int(2 * scale), y1 = Int((view.bounds.height - 2) * scale)
        for py in y0 ..< max(y0, y1) {
            for px in x0 ..< max(x0, x1) {
                guard px >= 0, py >= 0, px < bitmap.pixelsWide, py < bitmap.pixelsHigh,
                      let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5 else { continue }
                let gap = max(abs(color.redComponent - background.redComponent),
                              abs(color.greenComponent - background.greenComponent),
                              abs(color.blueComponent - background.blueComponent))
                if gap > 0.08 {
                    count += 1
                    worst = max(worst, gap)
                }
            }
        }
        return Ink(count: count, contrast: worst)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    private func sum(_ color: NSColor) -> CGFloat {
        color.redComponent + color.greenComponent + color.blueComponent
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        let made = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)
        return try XCTUnwrap(made, "合成不出一笔鼠标事件，这一格没法点")
    }

    /// 把「视图里某个矩形的中心」换算成窗口坐标再点下去。
    /// `SelectionBubbleCell.mouseUp` 用的是 `convert(locationInWindow, from: nil)`，
    /// 所以这里必须交窗口坐标 —— 视图是 flipped 的，y 要翻一次。
    private func fireMouseUp(on target: SelectionBubbleCell, view: SelectionBubbleView) throws {
        try fireMouseUp(at: NSPoint(x: target.frame.midX, y: target.frame.midY), view: view, on: target)
    }

    private func fireMouseUp(at viewPoint: NSPoint, view: SelectionBubbleView,
                             on target: SelectionBubbleCell) throws {
        let windowPoint = NSPoint(x: viewPoint.x, y: view.bounds.height - viewPoint.y)
        target.mouseUp(with: try event(.leftMouseUp, at: windowPoint))
    }
}

private extension Array {
    /// 越界取 nil：取证用例里宁可让 `XCTUnwrap` 报「格数不对」，也不要一个越界崩溃把
    /// 整个测试进程带走（那样连导出的 PNG 都看不到）。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
