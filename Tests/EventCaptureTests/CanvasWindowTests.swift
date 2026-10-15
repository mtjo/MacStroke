//
//  CanvasWindowTests.swift
//  MacStroke
//
//  画布窗口对抓屏 API 必须隐身。截图的第一帧是在抬手那一刻同步抓的，而 `orderOut`
//  要等 CoreAnimation 事务提交才从窗口服务的合成里消失（实测：同一轮 runloop 里
//  hide 之后立刻 `CGDisplayCreateImage`，轨迹线一个像素都没少），所以靠先后顺序追不上，
//  只能让画布压根不参与采集。
//

import AppKit
import XCTest
@testable import EventCapture

final class CanvasWindowTests: XCTestCase {

    func testGestureCanvasIsInvisibleToScreenCapture() {
        _ = NSApplication.shared
        let window = CanvasWindow(screenFrame: NSRect(x: 0, y: 0, width: 320, height: 240))

        XCTAssertEqual(window.sharingType, .none,
                       "轨迹画布一旦被抓屏拍到，就会被冻进截图的第一帧")
    }
}
