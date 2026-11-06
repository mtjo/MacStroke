//
//  ScreenshotSnapRaiseTests.swift
//
//  「吸附到哪扇就提哪扇」的离线取证（2026-11-05 用户修正口径：不是只在按下快捷键
//  那一刻提一次，而是光标的吸附框落到哪扇就把哪扇提到最前）。
//
//  真提窗、真重拍要 AX 与窗口服务，桩件里都没有；这里钉三件只要出错就静默坏掉的事：
//  1. 悬停只报**真窗**，且只在吸到的那扇变了时报一次（每动一下都报会让 120ms 的
//     去抖形同虚设，桌面那条整屏兜底报出去则等于拿整屏去提窗）；
//  2. 重拍之后底帧、候选表、放大镜三处一起换（放大镜自己攥着一张帧，漏了就和
//     底图错开）；
//  3. 遮罩窗不进采集（`sharingType = .none`），否则重拍会把暗底和高亮拍进底图。
//

import AppKit
import XCTest

@testable import Screenshot

final class ScreenshotSnapRaiseTests: XCTestCase {
    private let size = NSSize(width: 800, height: 500)

    // MARK: - 候选表：矩形与窗记录一一对齐

    /// 绘制要矩形、提窗要记录：两张表必须同长同序，否则悬停回调会报到隔壁那扇上。
    func testCandidatesKeepEachRecordPairedWithItsRect() {
        let screen = NSRect(origin: .zero, size: size)
        let first = probeWindow(CGRect(x: 100, y: 100, width: 300, height: 200), number: 11)
        let covered = probeWindow(CGRect(x: 200, y: 150, width: 300, height: 200), number: 12)
        let floating = probeWindow(CGRect(x: 0, y: 0, width: 300, height: 300), layer: 21, number: 13)
        let pairs = ScreenshotWindowProbe.candidates(windows: [first, covered, floating],
                                                     screenFrame: screen, mainTop: 500)
        XCTAssertEqual(pairs.map(\.window.windowNumber), [11, 12], "顺序即前后，别家的浮窗不该进来")
        XCTAssertEqual(pairs.map(\.rect), ScreenshotWindowProbe.candidateRects(
            windows: [first, covered, floating], screenFrame: screen, mainTop: 500),
                       "配对出来的矩形必须和纯矩形那张表逐项相同")
        XCTAssertEqual(pairs.map(\.rect), [CGRect(x: 100, y: 100, width: 300, height: 200),
                                           CGRect(x: 200, y: 150, width: 300, height: 200)])
    }

    // MARK: - 悬停回调

    /// 吸到某一扇时报那扇，且只报一次；在同一扇里继续移动不再报。
    func testHoverReportsTheSnappedWindowOnlyWhenItChanges() throws {
        let view = try overlay()
        let left = probeWindow(CGRect(x: 0, y: 0, width: 300, height: 300), number: 21)
        let right = probeWindow(CGRect(x: 400, y: 0, width: 300, height: 300), number: 22)
        view.windows = [left.globalBounds, right.globalBounds]
        view.snapTargets = [left, right]
        var reported: [Int] = []
        view.onSnapWindow = { reported.append($0.windowNumber) }

        view.pointerMoved(CGPoint(x: 100, y: 100))
        XCTAssertEqual(reported, [21], "吸到左边那扇就报左边")
        XCTAssertEqual(view.hover, left.globalBounds)

        view.pointerMoved(CGPoint(x: 120, y: 140))
        XCTAssertEqual(reported, [21], "还在同一扇里，不该再报一次")

        view.pointerMoved(CGPoint(x: 500, y: 100))
        XCTAssertEqual(reported, [21, 22], "吸到另一扇才报")
    }

    /// 落到桌面（候选表之外）：吸附预览兜整屏，但不报窗 —— 这不是能提的那一扇。
    func testHoverOnDesktopDoesNotReportAWindow() throws {
        let view = try overlay()
        let window = probeWindow(CGRect(x: 0, y: 0, width: 300, height: 300), number: 21)
        view.windows = [window.globalBounds]
        view.snapTargets = [window]
        var reported: [Int] = []
        view.onSnapWindow = { reported.append($0.windowNumber) }

        view.pointerMoved(CGPoint(x: 600, y: 400))
        XCTAssertEqual(reported, [])
        XCTAssertEqual(view.hover, view.bounds, "桌面上高亮整块屏，但没有窗可提")
    }

    /// 候选表与记录表不等长（上层还没来得及同步）时不能越界，也不能报到错的那扇上。
    func testHoverIgnoresRowsWithoutARecord() throws {
        let view = try overlay()
        let window = probeWindow(CGRect(x: 0, y: 0, width: 300, height: 300), number: 21)
        view.windows = [window.globalBounds, CGRect(x: 400, y: 0, width: 300, height: 300)]
        view.snapTargets = [window]
        var reported: [Int] = []
        view.onSnapWindow = { reported.append($0.windowNumber) }

        view.pointerMoved(CGPoint(x: 500, y: 100))
        XCTAssertEqual(reported, [], "第二条没有窗记录，答不出是哪一扇")
    }

    // MARK: - 重拍之后三处一起换

    func testReplaceCaptureSwapsBackdropAndCandidates() throws {
        let view = try overlay()
        let oldShot = view.shot
        let replacement = try solidFrame(.systemBlue)
        let raised = probeWindow(CGRect(x: 50, y: 60, width: 300, height: 200), number: 31)

        view.replaceCapture(replacement, windows: [raised.globalBounds], snapTargets: [raised])

        XCTAssertEqual(view.shot.image.width, replacement.image.width)
        XCTAssertEqual(view.shot.hexColor(for: CGPoint(x: 10, y: 10)),
                       replacement.hexColor(for: CGPoint(x: 10, y: 10)),
                       "底图必须换成新拍的那张")
        XCTAssertNotEqual(view.shot.hexColor(for: CGPoint(x: 10, y: 10)),
                          oldShot.hexColor(for: CGPoint(x: 10, y: 10)),
                          "两张图那一点的颜色本来就不同，判据才有分辨力")
        XCTAssertEqual(view.windows, [raised.globalBounds])
        XCTAssertEqual(view.snapTargets.map(\.windowNumber), [31])
    }

    /// 放大镜自己攥着一张帧：只换视图那处，取景和色值会停在提窗之前那张图上。
    func testReplaceCaptureAlsoMovesTheMagnifierToTheNewFrame() throws {
        let view = try overlay()
        view.magnifierEnabled = true
        // 右上象限是绿；同一尺寸的纯蓝图在这一点上必然不同。
        let point = CGPoint(x: 700, y: 100)
        view.pointerMoved(point)
        let magnifier = try XCTUnwrap(view.magnifierView, "放大镜开着就该建出来")
        let before = try XCTUnwrap(magnifier.colorText)
        let rgb = try XCTUnwrap(view.shot.rgb(for: point))
        XCTAssertGreaterThan(rgb.green, 150, "这一点在图案右上象限，本来就该是绿的")
        XCTAssertLessThan(rgb.red, 100)

        let replacement = try solidFrame(.systemBlue)
        view.replaceCapture(replacement, windows: [], snapTargets: [])

        XCTAssertEqual(magnifier.colorText, replacement.hexColor(for: point),
                       "重拍之后放大镜取的是新帧上的那一像素")
        XCTAssertNotEqual(magnifier.colorText, before, "还是旧色值就说明没换")
    }

    // MARK: - 遮罩不进采集

    func testOverlayIsExcludedFromScreenCapture() {
        let window = ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: size))
        XCTAssertEqual(window.sharingType, NSWindow.SharingType.none,
                       "重拍时遮罩自己还在屏上：不排除的话暗底和高亮会被拍进底图")
        XCTAssertEqual(window.level, NSWindow.Level(Int(CGShieldingWindowLevel())))
    }

    // MARK: - 偏好闸

    /// 悬停那条路和快捷键那条路共用同一道闸：关吸附、关提窗都一下不碰。
    func testRaiseGateRequiresBothPreferences() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        func settings(snap: Bool, raise: Bool) -> ScreenshotSettings {
            ScreenshotSettings(autoSave: false, directory: directory, snapToWindows: snap,
                               raiseWindowBeforeCapture: raise, magnifier: true, magnification: 8,
                               defaultTool: nil)
        }
        XCTAssertTrue(ScreenshotController.shouldRaiseOnSnap(settings(snap: true, raise: true)))
        XCTAssertFalse(ScreenshotController.shouldRaiseOnSnap(settings(snap: false, raise: true)))
        XCTAssertFalse(ScreenshotController.shouldRaiseOnSnap(settings(snap: true, raise: false)))
        XCTAssertFalse(ScreenshotController.shouldRaiseOnSnap(settings(snap: false, raise: false)))
    }

    // MARK: - 辅助

    private func overlay() throws -> ScreenshotSelectionView {
        let shot = try XCTUnwrap(ScreenshotFrame(image: pattern(), pointSize: size))
        let view = ScreenshotSelectionView(shot: shot)
        ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: size)).contentView = view
        return view
    }

    private func pattern() throws -> CGImage {
        // 自带一份四象限图案，不借别的用例文件里的 `QuadrantPattern`：变异执行器
        // 是**一个用例文件单独编译**的，跨文件借助手会直接编译失败（不是判据失败）。
        let width = Int(size.width), height = Int(size.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let halfW = size.width / 2
        let halfH = size.height / 2
        context.setFillColor(NSColor.red.cgColor)       // 视觉左上（CG 左下原点的上半）
        context.fill(CGRect(x: 0, y: halfH, width: halfW, height: halfH))
        context.setFillColor(NSColor.green.cgColor)     // 视觉右上
        context.fill(CGRect(x: halfW, y: halfH, width: halfW, height: halfH))
        return try XCTUnwrap(context.makeImage())
    }

    private func solidFrame(_ color: NSColor) throws -> ScreenshotFrame {
        let width = Int(size.width), height = Int(size.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(ScreenshotFrame(image: image, pointSize: size))
    }

    private func probeWindow(_ bounds: CGRect, layer: Int = 0, number: Int) -> ScreenshotProbeWindow {
        ScreenshotProbeWindow(globalBounds: bounds, layer: layer, alpha: 1,
                              isOwnProcess: false, isCapturable: true,
                              pid: 100, windowNumber: number)
    }
}
