//
//  PresetGestureShapeTests.swift
//  MacStroke
//
//  预设手势的点序就是规则表缩略图和识别用的模板，必须与原版 PreGesture.m 的
//  y 轴朝上约定一致：V 是凹谷、A 是凸峰。曾经 V/W/Z 与四个直角用自造的
//  y 轴朝下算法生成，画出来上下颠倒（用户反馈「Paste 应该是 V」）。
//

import XCTest
@testable import GestureEngine

final class PresetGestureShapeTests: XCTestCase {

    private func points(_ gesture: PresetGesture) -> [GesturePoint] {
        gesture.template.points
    }

    func testVIsAValleyAndAIsAPeak() {
        let v = points(.letterV)
        XCTAssertEqual(v.count, 40)
        // PreGesture.m case 21：先 y-- 再 y++，中段是最低点。
        XCTAssertTrue(zip(v[0..<19], v[1..<20]).allSatisfy { $0.y > $1.y }, "V 的前半必须向下")
        XCTAssertTrue(zip(v[20..<39], v[21..<40]).allSatisfy { $0.y < $1.y }, "V 的后半必须向上")
        XCTAssertEqual(v.map(\.y).min(), v[19].y)

        let a = points(.letterA)
        // 原版 A 是「先记录再累加」，首两点重合，所以只能断言端点与峰位。
        XCTAssertLessThan(a[0].y, a[30].y, "A 的前半必须向上")
        XCTAssertGreaterThan(a[30].y, a[59].y, "A 的后半必须向下")
        XCTAssertEqual(a.map(\.y).max(), a[30].y)
    }

    func testWHasFourAlternatingLegs() {
        let w = points(.letterW)
        XCTAssertEqual(w.count, 80)
        for (block, descending) in [(0, true), (1, false), (2, true), (3, false)] {
            let slice = w[(block * 20)..<(block * 20 + 20)]
            let deltas = zip(slice, slice.dropFirst()).map { $1.y - $0.y }
            XCTAssertEqual(deltas.allSatisfy { $0 < 0 }, descending, "W 的第 \(block + 1) 段方向不对")
        }
    }

    func testZIsTopBarDiagonalBottomBar() {
        let z = points(.letterZ)
        XCTAssertEqual(z.count, 60)
        XCTAssertTrue(Set(z[0..<20].map(\.y)).count == 1, "Z 的顶横必须水平")
        XCTAssertTrue(zip(z[0..<19], z[1..<20]).allSatisfy { $0.x < $1.x }, "Z 的顶横必须向右")
        XCTAssertTrue(zip(z[20..<39], z[21..<40]).allSatisfy { $0.x > $1.x && $0.y > $1.y },
                      "Z 的斜线必须往左下")
        XCTAssertTrue(Set(z[40..<60].map(\.y)).count == 1, "Z 的底横必须水平")
        XCTAssertGreaterThan(z[0].y, z[59].y, "顶横要在底横之上（y 轴朝上）")
    }

    func testBoxCornersDrawTheVerticalLegFirst() {
        // PreGesture.m cases 30-33：20 点竖笔 + 15 点横笔。
        let corner = points(.boxTopLeft)
        XCTAssertEqual(corner.count, 35)
        XCTAssertTrue(Set(corner[0..<20].map(\.x)).count == 1, "┏ 的竖笔必须垂直")
        XCTAssertTrue(zip(corner[0..<19], corner[1..<20]).allSatisfy { $0.y < $1.y }, "┏ 的竖笔向上")
        XCTAssertTrue(Set(corner[20..<35].map(\.y)).count == 1, "┏ 的横笔必须水平")
        XCTAssertTrue(zip(corner[20..<34], corner[21..<35]).allSatisfy { $0.x < $1.x }, "┏ 的横笔向右")

        let mirrored = points(.boxBottomRight)
        XCTAssertTrue(zip(mirrored[0..<19], mirrored[1..<20]).allSatisfy { $0.y > $1.y }, "┛ 的竖笔向下")
        XCTAssertTrue(zip(mirrored[20..<34], mirrored[21..<35]).allSatisfy { $0.x > $1.x }, "┛ 的横笔向左")
    }

    func testArrowStrokesMatchOriginalLengthAndAxis() {
        // cases 34-37：35 点单轴 1pt 步进。
        let left = points(.arrowLeftSymbol)
        XCTAssertEqual(left.count, 35)
        XCTAssertTrue(Set(left.map(\.y)).count == 1)
        XCTAssertLessThan(left[34].x, left[0].x, "← 必须向左")

        let up = points(.arrowUpSymbol)
        XCTAssertEqual(up.count, 35)
        XCTAssertTrue(Set(up.map(\.x)).count == 1)
        XCTAssertGreaterThan(up[34].y, up[0].y, "↑ 必须向上")

        // cases 26-29：40 点双轴 1pt 步进。
        let downLeft = points(.arrowDownLeft)
        XCTAssertEqual(downLeft.count, 40)
        XCTAssertLessThan(downLeft[39].x, downLeft[0].x, "↙ 必须向左")
        XCTAssertLessThan(downLeft[39].y, downLeft[0].y, "↙ 必须向下")

        let upRight = points(.arrowUpRight)
        XCTAssertGreaterThan(upRight[39].x, upRight[0].x, "↗ 必须向右")
        XCTAssertGreaterThan(upRight[39].y, upRight[0].y, "↗ 必须向上")
    }

    func testReversedTemplateIsThePointOrderFlipped() {
        let v = points(.letterV)
        let reversed = GestureTemplateProvider.shared.reversedTemplate(for: .letterV).points
        XCTAssertEqual(reversed.count, v.count)
        XCTAssertEqual(reversed.first?.x, v.last?.x)
        XCTAssertEqual(reversed.first?.y, v.last?.y)
    }
}
