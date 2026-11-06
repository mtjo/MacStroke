//
//  ScreenshotRaiseWindowTests.swift
//
//  「智能吸附时把光标下的窗口提到最前」（2026-11-05 用户要求，默认开）的接线取证。
//
//  真提窗要 AX 和一个 GUI 会话，桩件里没有；真正要用用例钉住的是两道偏好闸和
//  「只提被压住的那一扇」这个判定 —— 关吸附、关提窗时一下都不许碰（否则截图会顺手
//  切掉用户的前台 App），没被压住时也不许碰（切了前台画面却一模一样）。
//  判据走 ScreenshotController.raiseWindowUnderPointer 这个静态门，提窗动作由用例
//  注入并记账。
//

import AppKit
import XCTest

@testable import Screenshot

final class ScreenshotRaiseWindowTests: XCTestCase {
    private let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private let pointer = CGPoint(x: 300, y: 300)

    private func settings(snap: Bool = true, raise: Bool = true) -> ScreenshotSettings {
        ScreenshotSettings(autoSave: false, directory: directory, snapToWindows: snap,
                           raiseWindowBeforeCapture: raise, magnifier: true, magnification: 8,
                           defaultTool: nil)
    }

    private func window(_ bounds: CGRect, pid: pid_t, number: Int, layer: Int = 0) -> ScreenshotProbeWindow {
        ScreenshotProbeWindow(globalBounds: bounds, layer: layer, alpha: 1,
                              isOwnProcess: false, isCapturable: true,
                              pid: pid, windowNumber: number)
    }

    /// 同层压着的关系：cover 在前、covered 在后，光标只落在 covered 里（cover 压住它左上那角）。
    /// cover 若也包住光标，它自己就是用户眼前那扇，提它没有意义 —— 那是另一条用例。
    private var coveredPair: [ScreenshotProbeWindow] {
        [window(CGRect(x: 0, y: 0, width: 250, height: 250), pid: 200, number: 20),
         window(CGRect(x: 200, y: 200, width: 400, height: 300), pid: 100, number: 10)]
    }

    func testCoveredWindowIsRaisedExactlyOnce() {
        var raised: [Int] = []
        let target = ScreenshotController.raiseWindowUnderPointer(
            settings: settings(), pointer: pointer, windows: coveredPair) {
                raised.append($0.windowNumber)
            }
        XCTAssertEqual(raised, [10], "被压住的那一扇要提，且只提一次")
        XCTAssertEqual(target?.windowNumber, 10)
    }

    /// 吸附关掉时截图侧连窗口表都不取：没有「光标下是哪扇窗」，提窗更没目标。
    func testNothingHappensWhenSnappingIsOff() {
        var raised = 0
        let target = ScreenshotController.raiseWindowUnderPointer(
            settings: settings(snap: false), pointer: pointer, windows: coveredPair) { _ in raised += 1 }
        XCTAssertNil(target)
        XCTAssertEqual(raised, 0)
    }

    func testNothingHappensWhenTheRaisePreferenceIsOff() {
        var raised = 0
        let target = ScreenshotController.raiseWindowUnderPointer(
            settings: settings(raise: false), pointer: pointer, windows: coveredPair) { _ in raised += 1 }
        XCTAssertNil(target)
        XCTAssertEqual(raised, 0, "关掉这一档的用户明确不要「截图顺手切前台」")
    }

    func testNothingIsRaisedWhenTheWindowIsAlreadyInFront() {
        var raised = 0
        let frontFirst = Array(coveredPair.reversed())
        let target = ScreenshotController.raiseWindowUnderPointer(
            settings: settings(), pointer: pointer, windows: frontFirst) { _ in raised += 1 }
        XCTAssertNil(target)
        XCTAssertEqual(raised, 0)
    }

    /// 鼠标换算：主屏上就是把 y 从「离屏底」翻成「离屏顶」；副屏在主屏上方时 AppKit
    /// 给的 y 大于主屏高度，翻完是负值 —— 与 CGWindowList 的口径一致。
    func testPointerConversionFlipsAroundTheMainScreenTop() {
        XCTAssertEqual(ScreenshotController.globalPoint(fromAppKit: CGPoint(x: 120, y: 80), mainTop: 1080),
                       CGPoint(x: 120, y: 1000))
        XCTAssertEqual(ScreenshotController.globalPoint(fromAppKit: CGPoint(x: 300, y: 1180), mainTop: 1080),
                       CGPoint(x: 300, y: -100), "主屏上方的副屏，CG 坐标是负数")
    }
}
