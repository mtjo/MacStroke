//
//  ScreenshotItalicTests.swift
//
//  issue #73 的收尾取证 —— beck023：「添加的文字,英文可以设置斜体,但是中文设置了不生效」。
//
//  本机取证（2026-10-24，本文件的量法：48pt、单个对称字、成品像素）把根因钉在一处：
//  `NSFontManager.convert(_:toHaveTrait: .italicFontMask)` 把系统字体换成了
//  `.SFNS-RegularItalic`（拉丁有真斜体字面，同尺量「A」＝ +4.86），可中文在这一路上是
//  **回退**到 `.PingFangUIDisplaySC-Regular` 的 —— 简中压根没有斜体字面，转换只能原样
//  把正体还回来（`PingFang SC Regular` 加 italic 之后 `fontName` 一个字符都没变，
//  同尺量「中」＝ 0.00，与正体的 0.00 一个像素都不差）。所以「开关接漏了」这条嫌疑可以排除：
//  吃到的字体名字都对，只是那张脸不会斜。
//
//  判据一律取自**成品图上的像素**，不取自字体对象：这条 bug 的观感就是「看着不斜」，
//  修没修好也只能用眼睛那把尺子量 —— 逐行求墨迹质心 x，取上 1/3 带减下 1/3 带。
//
//  两条反向对照撑起整套判据，缺一条其余全部作废：
//  ① 「不经分段」的参照渲染（`SlantProbeView` 直接拿 `font(size:bold:italic:)` 画同一串字）：
//     中文参照**量不出斜度**，这才证明斜度是这次的剪切补上的，而不是我的带子本来就有偏；
//     英文参照量得出斜度，这才证明这把尺子认得真斜体，于是「英文那侧不许变」是一条硬判据。
//  ② 正体渲染：中文/英文正体都必须 ≈0，否则上面所有的「>阈值」都是空转。
//
//  底衬和边框一个都没开：底板会把墨迹带淹掉，质心就成了量矩形的四个角。
//

import AppKit
import CoreText
import XCTest

@testable import Screenshot

/// 参照渲染用的那一小块视图：绿底 + 红字，字体**不做任何分段**，就是改动前那条路。
/// internal 而不是 private：桩件那条链上要被 `@testable` 拿到，藏起来就只剩编译期可见。
final class SlantProbeView: NSView {
    var text = ""
    var font = NSFont.systemFont(ofSize: 32)
    var color = NSColor.red

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0, green: 0.8, blue: 0, alpha: 1).setFill()
        bounds.fill()
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            .draw(at: CGPoint(x: 20, y: 30))
    }
}

final class ScreenshotItalicTests: XCTestCase {

    /// 斜差阈值。48pt 下同一把尺子量「中」：正体 0.00、不补斜的参照 0.00（＝issue #73 报的那件事）、
    /// 补斜成品 +4.67；拉丁真斜体「A」+4.86。也就是「该不斜」和「该斜」两头差出 4.7 个像素，
    /// 阈值取一个离两头都远的数才当得住判据 —— 太近会把抗锯齿的抖读成斜（正体「A」本就有
    /// 0.14 的自然偏移），太远就咬不住弱剪切。
    ///
    /// **量的是单个对称字**（「中」「A」）：一整串逐行求质心会被字形自己的宽窄差带偏 ——
    /// 「中文字标注」正体实测 −14.6、「Italic Note」正体实测 +8.3，自然偏移比剪切那 2 个像素
    /// 大一个数量级，短语级别的质心差根本读不出斜度。这条是本轮取证踩过的坑，写下免得再踩。
    private static let slantThreshold: CGFloat = 1.5
    /// 取证字号：跟着探针那批数（48pt）走，斜差才和阈值在同一档上比。
    private static let probeSize: CGFloat = 48

    // MARK: - 成品图：中文斜没斜

    /// 中文斜体必须真斜，且斜度要**超过那条不经过分段的参照** —— 参照就是用户报的 bug 本身。
    func testChineseItalicActuallySlants() throws {
        // ① 量法自证：对称字「中」的正体必须量不出斜度，量得出来就是我带子取错了。
        let upright = try slant(text: "中", italic: false)
        XCTAssertEqual(abs(upright), 0, accuracy: 0.6,
                       "正体「中」量出了斜度 \(upright)：带子取错了，本文件的判据全部作废")

        // ② 参照 = 拿 `font(size:bold:italic:)` 直接画（＝这次改动之前的画法）。
        // 它量不出斜度，正是 beck023 报的那件事；于是成品里那一点斜只能来自这次的剪切。
        let reference = try referenceSlant(text: "中", italic: true)
        XCTAssertLessThan(abs(reference), Self.slantThreshold,
                          "参照都量出 \(reference)：分段之外还有别的东西在斜，判据读不出这次改的什么")

        // ③ 成品（走真的导出链路）必须斜。
        let composed = try slant(text: "中", italic: true)
        XCTAssertGreaterThan(composed, Self.slantThreshold,
                             "勾了斜体还是不斜（issue #73）：成品 \(composed)，参照 \(reference)，正体 \(upright)")
        XCTAssertGreaterThan(composed, reference + Self.slantThreshold,
                             "成品只比参照多 \(composed - reference)：剪切等于没上")
    }

    /// 英文那半边原本就是好的，这次不许动：成品斜度要和「不剪的参照」贴在一起。
    /// 这条专门咬住「图省事给整串上剪切」那种改法 —— 那样拉丁段会在真斜体之上再叠一档剪切，
    /// 斜过头。过头多少不由注释说了算，本用例自己拿同一把尺子量出那一档：实测「A」
    /// 不剪 +4.86、再叠一档剪切 +9.03（多出的 4.2 正好是中文那一档），于是上面那条
    /// 「成品 == 参照 ±0.8」确实咬得住 —— 不是从没红过的空门。
    func testLatinItalicStillSlantsAndIsNotTouched() throws {
        let upright = try slant(text: "A", italic: false)
        XCTAssertEqual(abs(upright), 0, accuracy: 0.6, "正体「A」量出了斜度 \(upright)，量法不可信")

        let composed = try slant(text: "A", italic: true)
        XCTAssertGreaterThan(composed, Self.slantThreshold,
                             "英文斜体被这次改动弄没了：成品 \(composed)（正体 \(upright)）")

        let reference = try referenceSlant(text: "A", italic: true)
        XCTAssertGreaterThan(reference, Self.slantThreshold,
                             "参照的英文斜体量不出来（\(reference)），这把尺子不认得真斜体")
        XCTAssertEqual(composed, reference, accuracy: 0.8,
                       "拉丁段被额外剪了：成品 \(composed) vs 不剪的参照 \(reference)")

        // 反向对照：真给拉丁也上剪切，这把尺子量得出「斜过头」，上面那条相等才不是空断言。
        let shearedLatinFont = ScreenshotAnnotation.oblique(
            ScreenshotAnnotation.font(size: Self.probeSize, bold: false, italic: true), flipped: true)
        let overSlanted = try probeSlant(text: "A", font: shearedLatinFont,
                                        label: "反向对照 A 拉丁再叠一档剪切")
        XCTAssertGreaterThan(overSlanted - reference, Self.slantThreshold,
                             "给拉丁叠剪切后本尺量不出差别（\(overSlanted) vs \(reference)），"
                             + "上一条「成品 == 参照」咬不住整串上剪切那种改法")
    }

    // MARK: - 字体对象侧的三条合同

    /// 剪切矩阵只加 x←y 这一项：基线上的推进量不动，所以量宽、行高一个像素都不该变。
    /// 这条是「为什么可以只改观感、不动命中/底框/选区钳制」的凭据；哪天有人把剪切挪到
    /// 绘制前的 CTM 上，外框就得跟着重算，这儿先红。
    func testSyntheticObliqueKeepsLayoutMetrics() throws {
        for text in ["中文字标注", "Italic Note", "标注 Note 标注"] {
            let annotation = ScreenshotAnnotation(tool: .text, color: .black, lineWidth: 2,
                                                  start: .zero, text: text,
                                                  fontSize: 32, bold: true, italic: true)
            let styled = ScreenshotAnnotation.italicStyledText(text, font: annotation.textFont,
                                                               color: .black, flipped: true)
            XCTAssertEqual(styled.size().width, annotation.textSize.width, accuracy: 0.01,
                           "\(text)：剪切把排版宽度改了，底框和命中会跟着错位")
            XCTAssertEqual(styled.size().height, annotation.textSize.height, accuracy: 0.01,
                           "\(text)：剪切把行高改了")
        }
    }

    /// 分段分的是「这张脸有没有斜体字面」，不是「这个字是不是中文」：
    /// 拉丁段留在没剪切的真斜体上（matrix 是 identity），中文段才带剪切。
    func testRunsSplitByItalicFaceNotByScript() throws {
        let annotation = ScreenshotAnnotation(tool: .text, color: .black, lineWidth: 2,
                                              start: .zero, text: "AB中文字",
                                              fontSize: 32, bold: false, italic: true)
        let (plain, sheared) = try pieces(of: ScreenshotAnnotation.italicStyledText(
            "AB中文字", font: annotation.textFont, color: .black, flipped: true))
        XCTAssertEqual(plain.joined(), "AB", "拉丁段被一起剪了：\(plain.joined())")
        XCTAssertEqual(sheared.joined(), "中文字", "中文段没吃到剪切：\(sheared.joined())")
    }

    /// 没勾斜体时这个函数不插手 —— 正体那条路径要一段都不分、matrix 全单位。
    func testUprightTextGetsNoShearAtAll() throws {
        let annotation = ScreenshotAnnotation(tool: .text, color: .black, lineWidth: 2,
                                              start: .zero, text: "中文字AB",
                                              fontSize: 32, bold: true, italic: false)
        let styled = ScreenshotAnnotation.italicStyledText("中文字AB", font: annotation.textFont,
                                                           color: .black, flipped: true)
        let (plain, sheared) = try pieces(of: styled)
        XCTAssertEqual(sheared.count, 0, "正体也被剪了：\(sheared.joined())")
        XCTAssertEqual(plain.joined(), "中文字AB")
    }

    /// 剪切方向跟着 flipped 走：三条绘制路径都在 flipped 视图里，符号写反就是向左倒的倒斜体。
    /// 依据是本机成品位的两档 —— flipped + **负号**量「中」得 −4.61（和拉丁的 +4.86 反着来），
    /// flipped + 正号才同侧（本轮实测 +4.67）。位图侧由 `testChineseItalicActuallySlants`
    /// 的「成品 > 阈值」咬住，字体这两行是把同一结论写早一步，红了立刻知道是符号而不是剪切量。
    func testShearSignFollowsTheContextFlip() throws {
        let base = ScreenshotAnnotation.font(size: 32, bold: false, italic: true)
        XCTAssertGreaterThan(matrix(of: ScreenshotAnnotation.oblique(base, flipped: true)).c, 0,
                             "flipped 上下文里符号该是正的，取负号中文向左倒（实测 −4.61）")
        XCTAssertLessThan(matrix(of: ScreenshotAnnotation.oblique(base, flipped: false)).c, 0,
                          "非 flipped 上下文里符号该是负的")
        let m = matrix(of: ScreenshotAnnotation.oblique(base, flipped: true))
        XCTAssertEqual(m.a, 1, accuracy: 0.001, "只该加 x←y 一项，横向缩放被动了")
        XCTAssertEqual(m.d, 1, accuracy: 0.001, "只该加 x←y 一项，纵向缩放被动了")
        XCTAssertEqual(m.b, 0, accuracy: 0.001, "y←x 那一项被动了，字会被同时压扁")
        XCTAssertEqual(m.c, ScreenshotAnnotation.italicShear, accuracy: 0.001,
                       "剪切量不是那一个常数，观感会跟拉丁真斜体脱档")
    }

    /// 简中确实没有斜体字面 —— 整个改法的立足点。哪天系统给了 PingFang 一张斜体脸，
    /// 这儿会红，而 `italicStyledText` 那一手会自己退场（它按这张脸答不答 true 分段时间）。
    func testPingFangHasNoItalicFace() throws {
        guard let pingfang = NSFont(name: "PingFang SC Regular", size: 32) else {
            throw XCTSkip("本机没有 PingFang SC Regular，这一档判据在这台机器上没法成立")
        }
        XCTAssertEqual(NSFontManager.shared.convert(pingfang, toHaveTrait: .italicFontMask).fontName,
                       pingfang.fontName,
                       "转换后换了名字＝系统真有斜体脸，那这次的剪切就不该再加")
    }

    // MARK: - 渲染与量法

    /// 走真的导出链路（`ScreenshotComposer.compose`）量斜差。
    private func slant(text: String, italic: Bool, bold: Bool = false,
                       size: CGFloat = ScreenshotItalicTests.probeSize) throws -> CGFloat {
        let side = NSSize(width: 420, height: 200)
        let shot = try XCTUnwrap(ScreenshotFrame(
            image: try XCTUnwrap(greenBackdrop(width: Int(side.width), height: Int(side.height))),
            pointSize: side))
        let annotation = ScreenshotAnnotation(tool: .text, color: .red, lineWidth: 2,
                                              start: CGPoint(x: 20, y: 30), text: text,
                                              fontSize: size, bold: bold, italic: italic)
        let image = try XCTUnwrap(ScreenshotComposer.compose(
            shot: shot, selection: CGRect(origin: .zero, size: side), annotations: [annotation]))
        return try slant(of: NSBitmapImageRep(cgImage: image), label: "\(text) italic=\(italic)")
    }

    /// 参照：同一个字体对象直接画，不经过 `italicStyledText` 的分段 —— 也就是改动前的画法。
    private func referenceSlant(text: String, italic: Bool,
                                size: CGFloat = ScreenshotItalicTests.probeSize) throws -> CGFloat {
        try probeSlant(text: text,
                       font: ScreenshotAnnotation.font(size: size, bold: false, italic: italic),
                       label: "参照 \(text) italic=\(italic)")
    }

    /// 拿任意一张脸走一遍参照渲染（绿底 `SlantProbeView` 离屏 `cacheDisplay`）。
    /// 反向对照要用它：这把尺子量得出「过斜」这一档，才配说「不许变」。
    private func probeSlant(text: String, font: NSFont, label: String) throws -> CGFloat {
        let view = SlantProbeView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        view.text = text
        view.font = font
        // 挂到一扇从没上屏的窗上：不挂窗时 AppKit 的 focus 上下文不完整，文字会缺笔画
        //（导出链路 `ScreenshotComposer` 里同一手，注释在那儿）。
        let host = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = view
        host.orderOut(nil)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("参照渲染拿不到位图")
            return 0
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try slant(of: bitmap, label: label)
    }

    /// 逐行取墨迹，上 1/3 带的质心 x 减下 1/3 带的质心 x。
    ///
    /// 「是不是墨」比的是**两个通道谁占优**，不跟常量比绝对值：位图自己的色彩空间和 sRGB
    /// 不是一套，饱和色转一遍要偏 13%（注解条调色板那条取证就是这么定的），
    /// 拿绝对阈值会把色彩管理误差读成 bug。
    private func slant(of bitmap: NSBitmapImageRep, label: String) throws -> CGFloat {
        dump(bitmap, label: label)
        func inky(_ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent > c.greenComponent + 0.15
        }
        var rows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            var hit = false
            for x in 0..<bitmap.pixelsWide where inky(x, y) { hit = true; break }
            if hit { rows.append(y) }
        }
        guard let lo = rows.first, let hi = rows.last else {
            XCTFail("\(label)：一个墨点都没量到")
            return 0
        }
        let span = hi - lo
        XCTAssertGreaterThan(span, 8, "\(label)：墨迹只有 \(span) 行高，分不出上下带")
        func centroid(from: Int, to: Int) -> CGFloat {
            var sum = 0.0, count = 0.0
            for y in from..<to {
                for x in 0..<bitmap.pixelsWide where inky(x, y) {
                    sum += Double(x); count += 1
                }
            }
            XCTAssertGreaterThan(count, 0, "\(label)：\(from)..\(to) 这一带没有墨，带子算错了")
            return count == 0 ? 0 : CGFloat(sum / count)
        }
        // NSBitmapImageRep 的 y 从上往下（遮罩与导出视图都是 flipped），行号小的带就是字的上部。
        let value = centroid(from: lo, to: lo + span / 3) - centroid(from: hi - span / 3, to: hi)
        print("  量得 \(label)：墨迹 \(lo)..\(hi)，斜差 \(value)")
        return value
    }

    /// 按字体把串拆开：`sheared` 收带剪切的片段（x←y 那一项非零，正负由 flipped 决定），`plain` 收原样片段。
    /// 这儿只问「有没有剪切」不问方向 —— 方向另有 `testShearSignFollowsTheContextFlip` 咬，
    /// 两件事分开，红了才知道红的是哪一件。
    private func pieces(of styled: NSAttributedString) throws -> (plain: [String], sheared: [String]) {
        var plain: [String] = [], sheared: [String] = []
        let text = styled.string as NSString
        let full = NSRange(location: 0, length: text.length)
        styled.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let piece = text.substring(with: range)
            if abs(matrix(of: font).c) > 0.01 { sheared.append(piece) } else { plain.append(piece) }
        }
        return (plain, sheared)
    }

    private func matrix(of font: NSFont) -> CGAffineTransform { CTFontGetMatrix(font as CTFont) }

    /// 成品图落盘 + 把量到的数打出来：色值判据只说明「那一带偏红」，斜没斜还是要人眼过一遍。
    private func dump(_ bitmap: NSBitmapImageRep, label: String) {
        let name = label.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "=", with: "")
        let directory = URL(fileURLWithPath: "/tmp/macstroke-italic-check", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("  取证 \(label) → \(url.path)")
    }

    /// 纯绿底图。刻意不用测试里那块四象限图案：象限交界会在墨迹带里插进一条说不清的行，
    /// 上下带的行数会被它切歪。
    private func greenBackdrop(width: Int, height: Int) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor(calibratedRed: 0, green: 0.8, blue: 0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
