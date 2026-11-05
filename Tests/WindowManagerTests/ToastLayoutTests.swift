//
//  ToastLayoutTests.swift
//  MacStroke
//
//  气泡（手势提示 / 截图结果提示）排版取证：issue #78 追加的那条「图片保存的提示有问题」。
//
//  用户给的那张截图里，「已保存 截图 2026-11-02 at 15.08.47.png」的白字**顶出了黑框**：
//  字号是偏好里的 Monaco 40（`noteFontSize`），消息带完整文件名。按原版的量法
//  （`ToastWindowController.m` 数行数用一把尺、定框宽用另一把尺、框高只按「超出两行的部分」长）
//  算出来：折行按 693pt 量出 2 行，框宽却按不折行的单行宽算成 998pt，框高仍是 80，
//  于是 label 的 y 是 −8 —— 第一行字整个画到黑框上面去。
//
//  判据分两层：
//  - **纯函数**（`metrics`）：框不超宽、文字吃得住折行预算、框高给得足、图标列让得开、
//    以及原版那条「图标关掉也照收图标宽」的怪癖。每条都对着一种坏法。
//  - **像素**：把 `makeContainer`（真机上 `show()` 装的同一只手）渲进一扇比框子大一圈的
//    画布，量白字实际落在哪 —— 只要有一个字印到黑框外就红。这一层不看布局管理器的
//    「我说行高多少」，只看画出来是什么。
//
import XCTest
import AppKit
@testable import WindowManager

final class ToastLayoutTests: XCTestCase {

    /// 用户那台机器上的那一条：Monaco 40 + 带文件名的保存提示（34 个字符，单行 865pt）。
    private static let screenshotMessage = "已保存 截图 2026-11-02 at 15.08.47.png"

    private static var userFont: NSFont {
        NSFont(name: "Monaco", size: 40) ?? .monospacedSystemFont(ofSize: 40, weight: .regular)
    }

    private static func width(of message: String, font: NSFont) -> CGFloat {
        ceil((message as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: - 纯函数：口径

    /// 用户那条消息：框不能超出上限，行数不能是 1，框高必须给两行字留位子。
    ///
    /// 旧口径在这里给出的答案是「框宽 998（>826）、框高 80、label y=−8」——
    /// 也就是截图上那个字顶出黑框。三条断言分别钉住这三种坏。
    func testTheLongScreenshotMessageFitsInsideTheBox() {
        let metrics = ToastManager.metrics(message: Self.screenshotMessage,
                                           font: Self.userFont, iconVisible: true)
        XCTAssertLessThanOrEqual(metrics.containerSize.width, 826, "框宽冲破了 maxWidth")
        XCTAssertGreaterThanOrEqual(metrics.lineCount, 2, "这串字被当成一行排了")
        XCTAssertGreaterThan(metrics.containerSize.height, 80, "框高还写死成 minHeight")

        let label = metrics.labelFrame
        XCTAssertGreaterThanOrEqual(label.minY, 0, "文字下沿掉出框底")
        XCTAssertLessThanOrEqual(label.maxY, metrics.containerSize.height, "文字顶出框上沿")
        XCTAssertLessThanOrEqual(label.maxX, metrics.containerSize.width, "文字右边出框")
    }

    /// 「一把尺」：折行用的宽度必须就是 label 真正拿到的宽度。
    ///
    /// 旧口径一个按 `maxWidth−60−73`、一个按不折行的单行宽，两边不一致才做出「框 998 宽、
    /// 文字只排一行却超高」。这一条用 label 自己的宽度重新折一次，行数必须和 metrics 给的一致。
    func testTheWrappingBudgetIsTheLabelWidth() {
        let font = Self.userFont
        for message in [Self.screenshotMessage, String(repeating: "滚", count: 60),
                        "Gesture recognized: " + String(repeating: "ab ", count: 120)] {
            let metrics = ToastManager.metrics(message: message, font: font, iconVisible: true)
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            // label cell 左右各留内边距：折行预算是 label 实宽减 `labelCellPadding`，不是实宽本身。
            let textWidth = metrics.labelFrame.width - ToastManager.labelCellPadding
            let bounding = (message as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: font])
            let linesAtLabelWidth = max(1, Int(ceil(bounding.height / lineHeight)))
            XCTAssertEqual(linesAtLabelWidth, metrics.lineCount,
                           "按 label 实宽折出 \(linesAtLabelWidth) 行，metrics 却说 \(metrics.lineCount) 行（「\(message.prefix(12))…」）")
            XCTAssertLessThanOrEqual(bounding.height, metrics.labelFrame.height + 0.5,
                                     "文字比 label 自己的格子还高")
        }
    }

    /// 默认字号 + 那条保存提示：单行格子必须把 label cell 的内边距让出来。
    ///
    /// 只按字符串宽定格子，真机上 cell 会自己折成两行、第二行又被行高裁掉 ——
    /// 文件名尾部就没了。这条是离屏 PNG 先看出来的，纯函数这一头钉住口径，
    /// 下面再渲一次钉住「整串字真的画出来了」。
    func testTheDefaultFontScreenshotToastIsNotClipped() throws {
        let font = NSFont.systemFont(ofSize: 15)
        let metrics = ToastManager.metrics(message: Self.screenshotMessage,
                                           font: font, iconVisible: true)
        let text = Self.width(of: Self.screenshotMessage, font: font)
        XCTAssertEqual(metrics.lineCount, 1, "这条消息在 15pt 下应该排得下一行")
        XCTAssertGreaterThanOrEqual(metrics.labelFrame.width, text + ToastManager.labelCellPadding,
                                    "单行格子没让出 cell 的 \(ToastManager.labelCellPadding)pt：真机上会折行并裁掉尾部")

        let container = ToastManager.makeContainer(message: Self.screenshotMessage,
                                                   metrics: metrics, font: font,
                                                   textColor: .white, backgroundAlpha: 0.8,
                                                   hiddenIcon: false)
        let margin: CGFloat = 30
        let canvas = NSView(frame: NSRect(x: 0, y: 0,
                                          width: metrics.containerSize.width + margin * 2,
                                          height: metrics.containerSize.height + margin * 2))
        container.setFrameOrigin(NSPoint(x: margin, y: margin))
        canvas.addSubview(container)
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)

        var xMin = CGFloat.greatestFiniteMagnitude
        var xMax = -CGFloat.greatestFiniteMagnitude
        var glyphPixels = 0
        for row in 0..<rep.pixelsHigh {
            for column in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: column, y: row),
                      color.alphaComponent > 0.5,
                      color.redComponent > 0.6, color.greenComponent > 0.6,
                      color.blueComponent > 0.6 else { continue }
                glyphPixels += 1
                let x = CGFloat(column) * (canvas.bounds.width / CGFloat(rep.pixelsWide))
                xMin = min(xMin, x); xMax = max(xMax, x)
            }
        }
        XCTAssertGreaterThan(glyphPixels, 300, "这条压根没渲出字")
        // 被裁掉尾部的旧样子只能画出前半截（约七成宽）；整串画出来应接近满宽。
        XCTAssertGreaterThanOrEqual(xMax - xMin, text * 0.9,
                                    "渲出来的字只有 \(xMax - xMin) 宽（整串应约 \(text)）：尾部被裁了")
    }

    /// 短消息回到原版的下限：320×80 一行，字居中且不出框。
    func testAShortMessageKeepsTheOriginalMinimumBox() {
        let metrics = ToastManager.metrics(message: "已复制", font: .systemFont(ofSize: 15),
                                           iconVisible: true)
        XCTAssertEqual(metrics.lineCount, 1)
        XCTAssertEqual(metrics.containerSize.width, 320, accuracy: 0.5)
        XCTAssertEqual(metrics.containerSize.height, 80, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(metrics.labelFrame.minY, 0)
        XCTAssertLessThanOrEqual(metrics.labelFrame.maxY, metrics.containerSize.height)
    }

    /// 图标那一列：开着图标时文字必须让开 `15 + 58`，不能压到图标底下。
    func testTheLabelStartsAfterTheIconColumn() {
        let metrics = ToastManager.metrics(message: Self.screenshotMessage,
                                           font: Self.userFont, iconVisible: true)
        XCTAssertGreaterThanOrEqual(metrics.labelFrame.minX, 15 + 58, "文字压在图标列上")
        XCTAssertGreaterThanOrEqual(metrics.iconFrame.minX, 0)
        XCTAssertEqual(metrics.iconFrame.width, 58, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(metrics.iconFrame.minY, 0, "图标掉出框底")
        XCTAssertLessThanOrEqual(metrics.iconFrame.maxY, metrics.containerSize.height, "图标顶出框上沿")
    }

    /// 原版怪癖：`showNoteIcon` 关掉后，框宽仍按图标列预留（`ToastWindowController.m` 就这么算的）。
    /// 这一条不是给怪癖辩护，是把它钉成可见的账：真改的那天，这里会红。
    func testTheIconColumnIsStillPaidForWhenTheIconIsHidden() {
        let font = NSFont.systemFont(ofSize: 15)
        // 挑一条「单行但比下限宽」的消息：太短会被 320 钳住，预留不预留都看不出差别。
        let medium = "识别到手势：向上滚动页面并显示桌面通知内容"
        let singleLine = Self.width(of: medium, font: font)
        XCTAssertGreaterThan(singleLine + 30 + 30 + 15 + 58, 320,
                             "选的消息太短，全被下限 320 钳住 —— 这条预留判据是空的")

        let hidden = ToastManager.metrics(message: medium, font: font, iconVisible: false)
        XCTAssertGreaterThanOrEqual(hidden.containerSize.width,
                                    singleLine + 30 + 30 + 15 + 58,
                                    "关掉图标就不再预留图标列（原版会留）")
        // 同一条消息开着图标时不该更宽（预留的是同一列）。
        let visible = ToastManager.metrics(message: medium, font: font, iconVisible: true)
        XCTAssertLessThanOrEqual(visible.containerSize.width, hidden.containerSize.width + 0.01)
    }

    /// 框高给足：上下各留 `labelGap`，行数越多框越高，且等差正好是一行行高。
    func testTheBoxGrowsOneLineHeightPerExtraLine() {
        let font = Self.userFont
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let two = ToastManager.metrics(message: Self.screenshotMessage, font: font, iconVisible: true)
        let long = ToastManager.metrics(message: String(repeating: "滚", count: 120),
                                       font: font, iconVisible: true)
        XCTAssertGreaterThan(long.lineCount, two.lineCount)
        XCTAssertEqual(long.containerSize.height - two.containerSize.height,
                       CGFloat(long.lineCount - two.lineCount) * lineHeight, accuracy: 1.0)
        // 文字到框子上下沿的留白不少于 12（旧口径这里是负的）。
        XCTAssertGreaterThanOrEqual(two.labelFrame.minY, 11.5)
        XCTAssertGreaterThanOrEqual(two.containerSize.height - two.labelFrame.maxY, 11.5)
        // 上下留白必须对称：只把格子往上推（`y = 框高 − 字高`）也是「看着没出框」，
        // 但长消息下沿就贴死了。
        XCTAssertEqual(two.labelFrame.minY,
                       two.containerSize.height - two.labelFrame.maxY, accuracy: 0.01)
        XCTAssertEqual(two.iconFrame.minY,
                       two.containerSize.height - two.iconFrame.maxY, accuracy: 0.01)
    }

    // MARK: - 像素：渲出来才算

    /// 把 `show()` 用的同一只手（`makeContainer`）渲进一扇大一圈的透明画布，
    /// 量白字实际落在哪一格 —— 只要有一个字印到黑框外就红。
    ///
    /// 先证明渲染真吃到了被测值（白字像素数够多、横向跨度接近整行文字），
    /// 否则「没有字出界」会因为压根没渲出字而假绿。
    func testRenderedGlyphsStayInsideTheDarkBox() throws {
        let font = Self.userFont
        let metrics = ToastManager.metrics(message: Self.screenshotMessage,
                                           font: font, iconVisible: true)
        let container = ToastManager.makeContainer(message: Self.screenshotMessage,
                                                   metrics: metrics, font: font,
                                                   textColor: .white, backgroundAlpha: 0.8,
                                                   hiddenIcon: false)
        let margin: CGFloat = 40
        let canvasSize = NSSize(width: metrics.containerSize.width + margin * 2,
                                height: metrics.containerSize.height + margin * 2)
        let canvas = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        container.setFrameOrigin(NSPoint(x: margin, y: margin))
        canvas.addSubview(container)

        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds),
                                "渲不出位图：这条判据是空的")
        canvas.cacheDisplay(in: canvas.bounds, to: rep)

        let h = CGFloat(rep.pixelsHigh)
        let scaleY = CGFloat(canvas.bounds.height) / CGFloat(rep.pixelsHigh)
        let scaleX = CGFloat(canvas.bounds.width) / CGFloat(rep.pixelsWide)
        var xMin = CGFloat.greatestFiniteMagnitude
        var xMax = -CGFloat.greatestFiniteMagnitude
        var yMin = CGFloat.greatestFiniteMagnitude
        var yMax = -CGFloat.greatestFiniteMagnitude
        var glyphPixels = 0
        for row in 0..<rep.pixelsHigh {
            for column in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: column, y: row) else { continue }
                // 白字：亮且不透明（黑框 alpha 0.8 的亮度远低于 0.5）。
                guard color.alphaComponent > 0.5,
                      color.redComponent > 0.6, color.greenComponent > 0.6,
                      color.blueComponent > 0.6 else { continue }
                glyphPixels += 1
                let x = CGFloat(column) * scaleX
                let y = canvas.bounds.height - CGFloat(row + 1) * scaleY
                xMin = min(xMin, x); xMax = max(xMax, x)
                yMin = min(yMin, y); yMax = max(yMax, y)
            }
        }

        XCTAssertTrue(glyphPixels > 3_000,
                      "渲出的白字只有 \(glyphPixels) 个像素：这条判据没吃到东西")
        let box = NSRect(origin: CGPoint(x: margin, y: margin), size: metrics.containerSize)
        XCTAssertGreaterThanOrEqual(xMin, box.minX - 2, "有字印到黑框左边外面")
        XCTAssertLessThanOrEqual(xMax, box.maxX + 2, "有字印到黑框右边外面")
        XCTAssertGreaterThanOrEqual(yMin, box.minY - 2, "有字印到黑框下沿外面")
        XCTAssertLessThanOrEqual(yMax, box.maxY + 2, "有字印到黑框上沿外面（就是用户截图那个坏法）")
        // 字要真填满框子中部：横向跨度至少吃掉可用宽度的六成，
        // 否则「框很大、字只占一小块」也会被上面的包含判据放过。
        XCTAssertGreaterThanOrEqual(xMax - xMin, metrics.labelFrame.width * 0.6,
                                    "渲出来的字比预想窄得多（判据可能没在测这条消息）")
    }

    /// 同一只手在默认字号（15）与默认那条手势提示上也得干净：小字号是旧口径「看不出坏」的那一档，
    /// 一旦有人把留白改小，这档也会顶出去。
    func testRenderedGlyphsStayInsideTheBoxAtTheDefaultFontSize() throws {
        let font = NSFont(name: "Monaco", size: 15) ?? .systemFont(ofSize: 15)
        let message = "识别到手势：上"
        let metrics = ToastManager.metrics(message: message, font: font, iconVisible: true)
        let container = ToastManager.makeContainer(message: message, metrics: metrics, font: font,
                                                   textColor: .white, backgroundAlpha: 0.8,
                                                   hiddenIcon: false)
        let margin: CGFloat = 30
        let canvas = NSView(frame: NSRect(x: 0, y: 0,
                                          width: metrics.containerSize.width + margin * 2,
                                          height: metrics.containerSize.height + margin * 2))
        container.setFrameOrigin(NSPoint(x: margin, y: margin))
        canvas.addSubview(container)

        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let box = NSRect(origin: CGPoint(x: margin, y: margin), size: metrics.containerSize)
        var outOfBox = 0
        var glyphPixels = 0
        for row in 0..<rep.pixelsHigh {
            for column in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: column, y: row),
                      color.alphaComponent > 0.5,
                      color.redComponent > 0.6, color.greenComponent > 0.6,
                      color.blueComponent > 0.6 else { continue }
                glyphPixels += 1
                let x = CGFloat(column) * (canvas.bounds.width / CGFloat(rep.pixelsWide))
                let y = canvas.bounds.height - CGFloat(row + 1) * (canvas.bounds.height / CGFloat(rep.pixelsHigh))
                if !box.insetBy(dx: -2, dy: -2).contains(NSPoint(x: x, y: y)) { outOfBox += 1 }
            }
        }
        XCTAssertGreaterThan(glyphPixels, 300, "小字号那条压根没渲出字")
        XCTAssertEqual(outOfBox, 0, "默认字号下也有 \(outOfBox) 个字像素在框外")
    }
}
