// 鼠标路径颜色用的是原版那颗 NSColorWell（xib 里 100×18），SwiftUI 的
// ColorPicker 不换掉就会缩成小方块并和右侧开关错开。这里盯住写回链路：
// 选色必须落到持久化的 hex 上。
import XCTest
import AppKit
import SwiftUI
@testable import Preferences

@available(macOS 13.0, *)
final class ColorWellFieldTests: XCTestCase {
    func testPickedColorWritesBackAsHex() {
        var hex = "#0000FF"
        let coordinator = ColorWellField.Coordinator(color: Binding(
            get: { Color(hex: hex) },
            set: { hex = $0.hexString }
        ))
        let well = NSColorWell()
        well.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        coordinator.colorChanged(well)
        XCTAssertEqual(hex, "#FF0000")
    }
}
