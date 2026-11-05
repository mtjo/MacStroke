//
//  WheelGestureStringTablesTests.swift
//  MacStroke
//
//  滚轮相关**文案表**的取证：两张表（`en.lproj` 与 `zh-Hans.lproj`）都要成立。
//
//  为什么单独一个文件、而且直接读资源而不是走 `L()`：桩件里 `UserDefaults` 的
//  `AppleLanguages = ("zh-Hans-CN")`，`L()`（`Sources/Storage/Localization.swift:109-137`）先找
//  `zh-hans-cn`、再取 base `zh`，两跳都命不中，最后兜底 **en** —— 也就是说走 `L()` 的那批用例
//  从头到尾只验过英文表，中文表里少一条键、或者页名跟另一页撞了，离线一律看不出来
//  （反向变异 P11 打在中文表上全绿，就是这个原因，不是判据弱）。
//  这里不改 `AppleLanguages`：那是整个进程的本地化，会把同一进程里后面的用例一起掰档，
//  还会写进用户的偏好域。改法是把两张 `.strings` 当**数据**读出来逐键比。
//
//  3.2.4 起「右键增强」页不再有滚轮段（两档整并进规则页），但下面三件事仍各咬一种坏：
//  - 这一页（`RightClickMenu`）与「模拟右键」那页（`RightClick`）**在两张表里都不同名**，
//    且钉住 issue #75 定的那两个名字 —— 侧栏一旦同名，用户不知道去哪一页找。
//  - 规则页还留着的滚轮方向名（`Wheel Gesture up/down row`，由手势选择面板与迁移生成的
//    规则名共用）**两张表都有、都不等于 key 原文、都不是空串** —— 少一条就是把 key 原文
//    画在页面上。issue #78 新加的十条按同一口径进表，只是其中快捷键那几条**用整句话当
//    key**（英文值天生等于 key），所以那一份只判「在不在、空不空」。
//

import XCTest
import Foundation
import Storage
@testable import RuleEngine

final class WheelGestureStringTablesTests: XCTestCase {

    /// 规则页滚轮方向名与迁移规则名共用的两条 key。
    /// 中文「上滚/下滚」、英文 "Scroll up/Scroll down"，都不等于 key 原文。
    static let wheelCopyKeys = [
        "Wheel Gesture up row", "Wheel Gesture down row",
    ]

    /// issue #78 新加的十一条：规则页那两档音量、录制框手填那一套、面板底部瞬时手势那一栏、
    /// 中键/侧键三档读法（规则页图标格与面板格子共用）与起手键冲突提醒。
    /// 不在「右键增强」那页上，所以另列一份，但两张表的判据一起过。
    ///
    /// 这一组的英文值**就是 key 原文**（快捷键那几条按本仓库的规矩用整句话当 key），
    /// 所以「值不等于 key」那一条只对上表那两条成立 —— 下面逐键判据按名单分开口径。
    static let issue78CopyKeys = [
        "Volume Up", "Volume Down",
        "Click to record · double-click for keyboard", "Type a shortcut, e.g. ⌘⇧2",
        "Pick modifiers, then click a key", "Pick the modifiers to hold",
        "Shortcut keyboard", "Type it instead…", "Done",
        "Type a shortcut first", "Can’t read “%@” as a key",
        "Add a key, not only modifiers", "Two keys in one shortcut: %@",
        "Wheel Rule Gesture Header", "Wheel Rule Gesture Hint",
        "Gesture Trigger Conflicts With Instant Rule",
        "Middle Button", "Back Button", "Forward Button",
    ]

    /// 两张表都要**有这一条、且不是空串**的全部 key。
    static var allCopyKeys: [String] { wheelCopyKeys + issue78CopyKeys }

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
                              "\(language) 表里两页同名：侧栏看不出哪一页是哪个")

            for key in Self.wheelCopyKeys {
                let value = dict[key]
                XCTAssertNotNil(value, "\(key) 没进 \(language) 表（页面上会露出 key 原文）")
                XCTAssertNotEqual(value ?? "", key,
                                  "\(key) 在 \(language) 表里的值就是 key 原文：等于没翻")
                XCTAssertFalse((value ?? "").isEmpty, "\(key) 在 \(language) 表里是空串")
            }

            for key in Self.issue78CopyKeys {
                let value = dict[key]
                XCTAssertNotNil(value, "\(key) 没进 \(language) 表（页面上会露出 key 原文）")
                XCTAssertFalse((value ?? "").isEmpty, "\(key) 在 \(language) 表里是空串")
            }
        }
    }

    /// 中文表这一整批（16 条）每条值都必须**与英文表那一份不同**。
    ///
    /// 咬的是「把 en 表整段抄进 zh 表」这种坏：键在、值也在、非空、也不等于 key 原文 ——
    /// 上一条用例四条判据一条都不会红，可中文界面上这一页就变回英文了。
    /// 判据只用两张表**互相**比，不写死任何一句中文（除了那一页的名字）。
    func testChineseTableIsNotJustTheEnglishWords() throws {
        let bundle = appResourceBundle()
        let en = try XCTUnwrap(table("en", in: bundle), "英文表没进资源包")
        let zh = try XCTUnwrap(table("zh-Hans", in: bundle), "中文表没进资源包")

        for key in Self.allCopyKeys {
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

    private func table(_ language: String, in bundle: Bundle) -> [String: String]? {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings",
                                   subdirectory: nil, localization: language) else { return nil }
        return NSDictionary(contentsOf: url) as? [String: String]
    }
}
