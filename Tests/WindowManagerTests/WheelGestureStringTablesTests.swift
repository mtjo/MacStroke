//
//  WheelGestureStringTablesTests.swift
//  MacStroke
//
//  issue #75 的**文案表**侧取证：滚轮那一段的两张表（`en.lproj` 与 `zh-Hans.lproj`）都要成立。
//
//  为什么单独一个文件、而且直接读资源而不是走 `L()`：桩件里 `UserDefaults` 的
//  `AppleLanguages = ("zh-Hans-CN")`，`L()`（`Sources/Storage/Localization.swift:109-137`）先找
//  `zh-hans-cn`、再取 base `zh`，两跳都命不中，最后兜底 **en** —— 也就是说走 `L()` 的那批用例
//  从头到尾只验过英文表，中文表里少一条键、或者页名跟另一页撞了，离线一律看不出来
//  （反向变异 P11 打在中文表上全绿，就是这个原因，不是判据弱）。
//  这里不改 `AppleLanguages`：那是整个进程的本地化，会把同一进程里后面的用例一起掰档，
//  还会写进用户的偏好域。改法是把两张 `.strings` 当**数据**读出来逐键比。
//
//  三件事各咬一种坏：
//  - 这一页（`RightClickMenu`）与「模拟右键」那页（`RightClick`）**在两张表里都不同名**，
//    且钉住 issue #75 定的那两个名字 —— 侧栏一旦同名，用户不知道滚轮配置在哪一页。
//  - 段里 16 条文案 key **两张表都有、都不等于 key 原文、都不是空串** —— 少一条就是把 key
//    原文画在页面上（代码里改 key 名而表没跟着改，是本地化最常见的一种坏）。
//  - 六档动作在同一张下拉里必须显示成**六种串** —— 撞串就是下拉里分不出来。
//

import XCTest
import Foundation
import Storage
@testable import RuleEngine

final class WheelGestureStringTablesTests: XCTestCase {

    /// 「右键增强」这一页滚轮段用到的全部文案 key（16 条）。
    /// 页面那组用例（`WheelGesturePreferencesTests`）也引用这一份，避免两处清单各漂各的。
    static let wheelCopyKeys = [
        "Wheel Gesture", "Wheel Gesture master", "Wheel Gesture master hint",
        "Wheel Gesture up row", "Wheel Gesture up hint", "Wheel Gesture down row",
        "Wheel Gesture up shortcut", "Wheel Gesture down shortcut",
        "Wheel Gesture shortcut hint", "Wheel Gesture no action warning",
        "Wheel Gesture action none", "Wheel Gesture action tab previous",
        "Wheel Gesture action tab next", "Wheel Gesture action volume up",
        "Wheel Gesture action volume down", "Wheel Gesture action custom shortcut",
    ]

    /// issue #75 定下来的那一页名字：中文「右键增强」，英文 "Right-click extras"。
    private static let goldenTitles: [String: String] = [
        "zh-Hans": "右键增强",
        "en": "Right-click extras",
    ]

    /// 两张表都要满足上面那三条口径。
    ///
    /// 资源查找走 `appResourceBundle()`：`.app` 里是 `Bundle.main`，`swift run`/桩件下是可执行文件
    /// 旁边那个 `*.bundle`（和 `L()` 用的是同一套定位，不然这边绿在那边红）。
    /// 表读不出来时**必须红**，不许 skip —— 静默 skip 等于把这一整批判据关掉。
    func testBothStringTablesKeepTheTwoRightClickPagesDistinct() throws {
        let bundle = appResourceBundle()

        for (language, expectedTitle) in Self.goldenTitles {
            let url = try XCTUnwrap(
                bundle.url(forResource: "Localizable", withExtension: "strings",
                           subdirectory: nil, localization: language),
                "\(language).lproj 那份文案表没进资源包：这条判据压根没跑")
            let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String],
                                     "\(language) 那份表读不出键值对（格式坏了）")

            XCTAssertEqual(dict["RightClickMenu"], expectedTitle,
                           "\(language) 表里这一页的名字不是 issue #75 定的那一个")
            XCTAssertNotEqual(dict["RightClickMenu"], dict["RightClick"],
                              "\(language) 表里两页同名：侧栏看不出哪一页管滚轮那一段")

            for key in Self.wheelCopyKeys {
                let value = dict[key]
                XCTAssertNotNil(value, "\(key) 没进 \(language) 表（页面上会露出 key 原文）")
                XCTAssertNotEqual(value ?? "", key,
                                  "\(key) 在 \(language) 表里的值就是 key 原文：等于没翻")
                XCTAssertFalse((value ?? "").isEmpty, "\(key) 在 \(language) 表里是空串")
            }

            let actions = Set(WheelGestureActionKind.allCases.map { dict[self.actionKey($0)] ?? "" })
            XCTAssertEqual(actions.count, WheelGestureActionKind.allCases.count,
                           "\(language) 表里有两档动作显示成同一串：下拉里分不出来")
        }
    }

    /// 中文表这一段（16 条）每条值都必须**与英文表那一份不同**。
    ///
    /// 咬的是「把 en 表整段抄进 zh 表」这种坏：键在、值也在、非空、也不等于 key 原文 ——
    /// 上一条用例四条判据一条都不会红，可中文界面上这一页就变回英文了。
    /// 判据只用两张表**互相**比，不写死任何一句中文（除了那一页的名字）。
    func testChineseTableIsNotJustTheEnglishWords() throws {
        let bundle = appResourceBundle()
        let en = try XCTUnwrap(table("en", in: bundle), "英文表没进资源包")
        let zh = try XCTUnwrap(table("zh-Hans", in: bundle), "中文表没进资源包")

        for key in Self.wheelCopyKeys {
            let english = en[key]
            let chinese = zh[key]
            XCTAssertNotNil(english, "\(key) 在英文表里就没有：另一张表怎么填都没人看得见")
            XCTAssertNotNil(chinese, "\(key) 在中文表里没有")
            if let english, let chinese {
                XCTAssertNotEqual(chinese, english,
                                  "\(key) 中文表里填的还是英文那一句：中文界面这一格没翻")
            }
        }
    }

    private func actionKey(_ kind: WheelGestureActionKind) -> String {
        switch kind {
        case .none: return "Wheel Gesture action none"
        case .tabPrevious: return "Wheel Gesture action tab previous"
        case .tabNext: return "Wheel Gesture action tab next"
        case .volumeUp: return "Wheel Gesture action volume up"
        case .volumeDown: return "Wheel Gesture action volume down"
        case .customShortcut: return "Wheel Gesture action custom shortcut"
        }
    }

    private func table(_ language: String, in bundle: Bundle) -> [String: String]? {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings",
                                   subdirectory: nil, localization: language) else { return nil }
        return NSDictionary(contentsOf: url) as? [String: String]
    }
}
