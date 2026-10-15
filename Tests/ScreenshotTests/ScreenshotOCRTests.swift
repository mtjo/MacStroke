//
//  ScreenshotOCRTests.swift
//
//  提取文字（Vision）的取证，分两层：
//
//  1. **引擎真认得出字**。判据是测试自己画上去的两行已知文本（一行中文、一行英文），
//     不是 Vision 的某个返回值。中文那一行同时是 `recognitionLanguages` 里 zh-Hans 的
//     反向对照：把语言表改成只有 en-US，这一行就认不出来。
//  2. **遮罩那条路把结果交出去，并且只交一次**。按下去那格立刻变灰（不然第二次点会让
//     Vision 同时算两遍，谁后到还不一定）；认完了结果回来才亮回去。
//
//  三条容易写错、也只有测得出来的地方：行序（剪贴板里的先后）、这块没字时会话得留着
//  （让用户换选区重按，而不是把整张图丢掉）、识别期间收窗就别再往剪贴板补写。
//

import AppKit
import XCTest

@testable import Screenshot

final class ScreenshotOCRTests: XCTestCase {
    private enum DrawingFailure: Error { case noBitmap }

    /// 画在图上的两行，自上而下。带数字是为了给引擎一条最稳的判据。
    private let topLine = "提取文字 4242"
    private let bottomLine = "HELLO 7788"

    /// 视图尺寸：够宽，注解条（756pt）能在里面摆下而不影响判定。
    private let shotSize = NSSize(width: 900, height: 600)
    /// 两行字所在的块（视图是 flipped 的，y 从上往下）。
    private let textBlock = CGRect(x: 0, y: 0, width: 620, height: 200)

    // MARK: - 引擎

    func testRecognizesTheDrawnLinesTopToBottom() throws {
        switch ScreenshotOCR.text(from: try textImage()) {
        case .lines(let lines):
            XCTAssertEqual(lines.count, 2, "画了两行就该认出两行；拿到 \(lines)")
            XCTAssertTrue(lines[0].contains("提取文字"), "第一行该是上面那行中文，实际 \(lines[0])")
            XCTAssertTrue(lines[0].contains("4242"), "中文行里的数字不能丢，实际 \(lines[0])")
            XCTAssertTrue(lines[1].contains("HELLO"), "第二行该是下面那行英文，实际 \(lines[1])")
            XCTAssertTrue(lines[1].contains("7788"), "英文行里的数字不能丢，实际 \(lines[1])")
        case .nothing:
            XCTFail("白底黑字 40pt 都认不出字，说明压根没跑起来")
        case .failed(let reason):
            XCTFail("识别失败：\(reason)")
        }
    }

    /// 一块没有字的地方：要答 `nothing`，不能答 `lines([])` 之外的花样，也不能报错。
    func testBlankRegionReportsNothing() throws {
        let image = try textImage()
        let cut = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 380, width: 620, height: 200)))
        guard case .nothing = ScreenshotOCR.text(from: cut) else {
            XCTFail("空白块应该报「没字」")
            return
        }
    }

    // MARK: - 遮罩那条路

    func testExtractTextDeliversLinesAndGatesTheCell() throws {
        let view = try editingView(selection: textBlock)
        var delivered: ScreenshotTextOutcome?
        let done = expectation(description: "结果交回上层")
        view.onText = { outcome in
            delivered = outcome
            done.fulfill()
        }
        view.toolbar?.onOCR?()
        // 按下这一刻就该灭：结果还没回来，此时再点一次是叠第二次识别。
        // 只问「ocr 灭没灭」—— 没注解时 undo/redo 本来就是灭的，别把它们算进来。
        XCTAssertEqual(view.toolbar?.disabledElementsOnBar.filter { $0 == "ocr" }, ["ocr"])
        XCTAssertTrue(view.ocrRunning)

        wait(for: [done], timeout: 20)

        XCTAssertFalse(view.toolbar?.disabledElementsOnBar.contains("ocr") ?? true,
                       "认完了那格要能再按")
        XCTAssertFalse(view.ocrRunning)
        guard case .lines(let lines)? = delivered else {
            XCTFail("选区里明明有两行字，交回来的却是 \(String(describing: delivered))")
            return
        }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("提取文字"), "行序要自上而下")
    }

    /// 认不出字不等于会话结束：遮罩得留着，让用户换个选区再按一次。
    func testNothingFoundKeepsTheOverlayUp() throws {
        let view = try editingView(selection: CGRect(x: 0, y: 400, width: 620, height: 180))
        var delivered: ScreenshotTextOutcome?
        let done = expectation(description: "空手而归也要回话")
        view.onText = { outcome in
            delivered = outcome
            done.fulfill()
        }
        view.toolbar?.onOCR?()
        wait(for: [done], timeout: 20)

        guard case .nothing? = delivered else {
            XCTFail("这块没字，该报 nothing，实际 \(String(describing: delivered))")
            return
        }
        XCTAssertNotNil(view.window, "没认出字不该把整个截图会话收掉")
        XCTAssertFalse(view.ocrRunning)
    }

    /// 识别在后台跑的这几百毫秒里用户 Esc 收窗了：结果不能再往剪贴板里塞。
    func testLateResultIsDroppedOnceTheOverlayIsGone() throws {
        let view = try editingView(selection: textBlock)
        var delivered = false
        view.onText = { _ in delivered = true }
        view.toolbar?.onOCR?()
        // 摘掉窗口归属：主线程接下来让给 run loop 之前，回调不可能已经跑完，
        // 所以这里判定的「会话已经没了」是确定的，不靠时序运气。
        view.removeFromSuperview()

        let never = expectation(description: "收窗之后不该再回调")
        never.isInverted = true
        wait(for: [never], timeout: 5)
        XCTAssertFalse(delivered, "会话结束后还写剪贴板，用户会以为见鬼了")
    }

    // MARK: - 辅助

    /// 一帧「定格好的屏幕」+ 已经进编辑态的遮罩视图，挂在窗上（不挂窗文字会缺笔画）。
    private func editingView(selection: CGRect) throws -> ScreenshotSelectionView {
        let frame = try XCTUnwrap(ScreenshotFrame(image: try textImage(), pointSize: shotSize))
        let view = ScreenshotSelectionView(shot: frame)
        view.selection = selection
        let window = ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: shotSize))
        window.contentView = view
        view.enterEditing()
        return view
    }

    /// 白底两行黑字。位图上下文是左下原点，所以第一行 y 给大 —— 那才是画面上方那行。
    private func textImage() throws -> CGImage {
        let width = Int(shotSize.width)
        let height = Int(shotSize.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            throw DrawingFailure.noBitmap
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        for (index, line) in [topLine, bottomLine].enumerated() {
            (line as NSString).draw(at: NSPoint(x: 24, y: CGFloat(height - 90 - index * 80)),
                                    withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.cgImage, "位图拿不到 CGImage")
    }
}
