// 这一轮偏好窗口改动的文案表取证：分组标题、撤销条、四个页面的说明、三处
// 选择提示、图标按钮的可访问名，以及四个带单位的标签（旧表里 "Postion:"、
// "Background Apha:" 是拼错的，分数和时长两行则没写单位）。
//
// 走数据而不是走 `L()`：桩件里 `L()` 只吃英文表，中文表少一条键离线看不出来。
// 读表方式与 WheelGestureStringTablesTests 相同（`appResourceBundle()`）。
import XCTest
import Foundation
import Storage

final class PreferencesCopyTablesTests: XCTestCase {

    /// 两张表都必须有、且非空。
    static let copyKeys = [
        // 侧栏分组
        "Gestures", "Extensions", "Application",
        // 撤销条与确认框
        "Undo", "Settings restored to defaults.",
        "Reset Defaults?", "All settings here will return to their defaults. Rules and AppleScripts are not affected.",
        "Reset",
        "Clear all the rules?", "All rules cleared.",
        "Load default rules?", "All current rules will be replaced by the built-in defaults.",
        "Default rules loaded.",
        // 选择提示
        "Select a rule first, then try again.",
        "Select an app row first, then try again.",
        "Select an AppleScript first!",
        // 图标按钮的可访问名与悬停提示
        "Add rule", "Remove rule", "Add app", "Remove app",
        "Add AppleScript", "Remove AppleScript",
        // 页面说明
        "General page hint", "Rules page hint", "AppleScript page hint",
        "Filters page hint", "Clipboard page hint",
        // 带单位的标签
        "Require Minimum Score", "Match Score (%):",
        "Position:", "Background Alpha:", "Retention Time (s):",
    ]

    private func table(_ language: String, in bundle: Bundle) -> [String: String]? {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings",
                                   subdirectory: nil, localization: language) else { return nil }
        return NSDictionary(contentsOf: url) as? [String: String]
    }

    func testBothTablesCarryEveryKeyThisRoundAdded() throws {
        let bundle = appResourceBundle()
        for language in ["en", "zh-Hans"] {
            let dict = try XCTUnwrap(table(language, in: bundle),
                                     "\(language) 那份文案表没进资源包：这条判据压根没跑")
            for key in Self.copyKeys {
                let value = dict[key]
                XCTAssertNotNil(value, "\(key) 没进 \(language) 表（页面上会露出 key 原文）")
                XCTAssertFalse((value ?? "").isEmpty, "\(key) 在 \(language) 表里是空串")
            }
        }
    }

    func testTheChineseTableIsNotACopyOfTheEnglishOne() throws {
        let bundle = appResourceBundle()
        let en = try XCTUnwrap(table("en", in: bundle), "英文表没进资源包")
        let zh = try XCTUnwrap(table("zh-Hans", in: bundle), "中文表没进资源包")
        for key in Self.copyKeys {
            guard let english = en[key], let chinese = zh[key] else {
                XCTFail("\(key) 缺一条，两张表没法比")
                continue
            }
            XCTAssertNotEqual(chinese, english,
                              "\(key) 中文表里填的还是英文那一句：中文界面这一格没翻")
        }
    }

    /// 拼错的旧键不许再回来 —— 回来就意味着页面上又会出现 "Postion:" /
    /// "Background Apha:" 这类原文，或者代码里有人把标签改回旧 key。
    func testTheTypoCopiedLabelsAreGoneFromBothTables() throws {
        let bundle = appResourceBundle()
        for language in ["en", "zh-Hans"] {
            let dict = try XCTUnwrap(table(language, in: bundle))
            for typo in ["Postion:", "Background Apha:"] {
                XCTAssertNil(dict[typo], "\(language) 表里又出现了拼错的键 \(typo)")
            }
        }
    }

    /// 侧栏分组的三个标题彼此不同 —— 用户得能一眼分出「手势 / 扩展 / 应用」。
    func testTheSidebarGroupTitlesAreDistinctInBothTables() throws {
        let bundle = appResourceBundle()
        for language in ["en", "zh-Hans"] {
            let dict = try XCTUnwrap(table(language, in: bundle))
            let titles = ["Gestures", "Extensions", "Application"].compactMap { dict[$0] }
            XCTAssertEqual(titles.count, 3, "\(language) 表缺分组标题")
            XCTAssertEqual(Set(titles).count, 3, "\(language) 表里两个组同名：\(titles)")
        }
    }
}
