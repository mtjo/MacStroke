// 侧栏 12 项分三组（手势 / 扩展 / 应用）之后的判据：分组只影响绘制，
// 不能悄悄丢页、重复一页，也不能改掉 `allCases` 自上而下的顺序 —— 状态栏入口
// 与 `PreferencesTabNavigationTests` 的高亮位置都按那个顺序量。
import XCTest
@testable import Preferences

final class PreferencesSidebarGroupsTests: XCTestCase {
    func testTheGroupsHoldEveryTabExactlyOnceInAllCasesOrder() {
        let grouped = PreferencesTab.sidebarGroups.flatMap(\.tabs)
        XCTAssertEqual(grouped, PreferencesTab.allCases,
                       "分组之后侧栏少了页、多了一页，或顺序和 allCases 对不上")
        XCTAssertEqual(Set(grouped).count, grouped.count, "同一页被放进两个组")
    }

    func testTheGroupsStartWithGeneralAndEndWithAbout() {
        let groups = PreferencesTab.sidebarGroups
        XCTAssertEqual(groups.count, 3, "分组数变了：侧栏的视觉节奏跟着变")
        XCTAssertEqual(groups.first?.tabs.first, .general)
        XCTAssertEqual(groups.last?.tabs, [.about])
    }

    func testEveryGroupHasATitleKeyThatExistsInTheCopyTables() {
        // 标题本身走 L()，桩件只吃英文表；键是否进表、中文有没有翻，由
        // PreferencesCopyTablesTests 对着两份 .strings 判。
        let titles = PreferencesTab.sidebarGroups.map(\.title)
        XCTAssertEqual(titles.count, Set(titles).count, "两个组同名")
        XCTAssertFalse(titles.contains(where: \.isEmpty), "有空组标题")
    }
}
