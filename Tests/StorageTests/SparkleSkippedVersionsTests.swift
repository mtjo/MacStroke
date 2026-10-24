// 关于页「恢复提醒」那条链路的落盘侧：Sparkle 记「跳过这个版本」的那三个默认键，
// 读要读对、清要清真、而且**只清这三格**。
//
// 为什么判据取 UserDefaults 里真正落盘的东西而不是内存值：这一格压根不走我们的 Storage，
// 写它的是 Sparkle（`SPUSkippedUpdate.skipUpdate:host:`），读它的也是 Sparkle
// （`SPUSkippedUpdate.skippedUpdateForHost:`，每次现读、不缓存）。我们只是替用户把这三格
// 抹掉 —— 抹错格子（比如顺手清了 `SULastCheckTime`）比抹不干净更糟，下一次自动检查的
// 节奏就被动了。
//
// 三条各咬一种坏：
// - 键名写错一个字母 → 页面显示「已清除」，而 Sparkle 那边还跳着（用户看到的症状是
//   「按了恢复提醒，更新还是不来」）
// - 只认 String → 从原版（ObjC + Sparkle 1.x）升上来的机器上那一格可能是数字，
//   页面显示「无」、按钮灰着，实际一直跳着 —— 这次报上来的正是「冒号后面是空的」这一类
// - 清的时候多手 → 把别的 Sparkle 键一起抹了
import XCTest
import Foundation
@testable import Storage

final class SparkleSkippedVersionsTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.SparkleSkippedVersions"

    override func setUp() {
        super.setUp()
        suite().removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        suite().removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    // MARK: - 键名：照抄 Sparkle，不许改

    /// 这三个字符串是 Sparkle 写死的（`Sparkle/SUConstants.m` 里
    /// `SUSkippedMinorVersionKey = @"SUSkippedVersion"`）。我们这边一旦拼错，
    /// 症状是「点了恢复、页面也说清掉了，更新却永远不来」—— 最难查的那种。
    func testKeyNamesMatchSparklesOwnConstants() {
        XCTAssertEqual(SparkleSkippedVersions.minorKey, "SUSkippedVersion")
        XCTAssertEqual(SparkleSkippedVersions.majorKey, "SUSkippedMajorVersion")
        XCTAssertEqual(SparkleSkippedVersions.majorSubreleaseVersionKey, "SUSkippedMajorSubreleaseVersion")
        XCTAssertEqual(SparkleSkippedVersions.allKeys,
                       ["SUSkippedVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion"])
    }

    // MARK: - 读

    func testNothingSkippedReadsEmpty() {
        XCTAssertEqual(SparkleSkippedVersions.versions(in: suite()), [])
    }

    /// 三格各写一个版本号，读回来是三个，且顺序 = allKeys 的顺序（普通版在前）。
    func testReadsEveryKeyInOrder() {
        let defaults = suite()
        defaults.set("3.2.0", forKey: SparkleSkippedVersions.minorKey)
        defaults.set("4.0.0", forKey: SparkleSkippedVersions.majorKey)
        defaults.set("4.0.1", forKey: SparkleSkippedVersions.majorSubreleaseVersionKey)
        XCTAssertEqual(SparkleSkippedVersions.versions(in: defaults), ["3.2.0", "4.0.0", "4.0.1"])
    }

    /// 大版本那一档 Sparkle 会同时写两格（`skipUpdate:` 里 majorUpgrade 分支），
    /// 两格值常常是同一个号 —— 页面上报一次就够，「4.0.0, 4.0.0」看着像跳了两个版本。
    func testDuplicateVersionsCollapse() {
        let defaults = suite()
        defaults.set("4.0.0", forKey: SparkleSkippedVersions.majorKey)
        defaults.set("4.0.0", forKey: SparkleSkippedVersions.majorSubreleaseVersionKey)
        XCTAssertEqual(SparkleSkippedVersions.versions(in: defaults), ["4.0.0"])
    }

    /// 老机器上那一格可能是数字（原版 Sparkle 1.x 存的）。只认 String 的话读回来是空，
    /// 页面显示「无」、按钮还灰着 —— 用户以为没跳过任何东西，而自动检查确实一直跳过它。
    func testLegacyNumericValueStillCountsAsSkipped() {
        let defaults = suite()
        defaults.set(NSNumber(value: 3200), forKey: SparkleSkippedVersions.minorKey)
        XCTAssertEqual(SparkleSkippedVersions.versions(in: defaults), ["3200"],
                       "数字也要读出来，否则这一格在页面上是隐形的")
    }

    /// 空串 = 这一格没内容（我们自己的恢复路径清完就是把它抹掉；万一别处落了个空串，
    /// 不能显示成「已跳过的版本：（空）」。
    func testEmptyStringIsNotAVersion() {
        let defaults = suite()
        defaults.set("", forKey: SparkleSkippedVersions.minorKey)
        XCTAssertEqual(SparkleSkippedVersions.versions(in: defaults), [])
    }

    /// 类型不对（被别的程序写坏了）时宁可当没跳过，也不要把 `(...)` 这种描述串当版本号显示。
    func testUnexpectedTypeIsIgnored() {
        let defaults = suite()
        defaults.set(["not", "a", "version"], forKey: SparkleSkippedVersions.minorKey)
        XCTAssertEqual(SparkleSkippedVersions.versions(in: defaults), [])
    }

    // MARK: - 清

    func testClearRemovesAllThreeAndReportsThem() {
        let defaults = suite()
        defaults.set("3.2.0", forKey: SparkleSkippedVersions.minorKey)
        defaults.set("4.0.0", forKey: SparkleSkippedVersions.majorKey)
        defaults.set("4.0.1", forKey: SparkleSkippedVersions.majorSubreleaseVersionKey)

        let cleared = SparkleSkippedVersions.clear(in: defaults)

        XCTAssertEqual(cleared, ["3.2.0", "4.0.0", "4.0.1"], "报给页面的必须是真清掉的那几版")
        for key in SparkleSkippedVersions.allKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) 没清掉")
        }
        XCTAssertEqual(SparkleSkippedVersions.versions(in: defaults), [])
    }

    /// 「本来就没有」和「清掉了」是两件事：前者不能报「已清除 的跳过记录」，
    /// 那等于把没发生过的事说成发生过。
    func testClearReportsNothingWhenNothingWasSkipped() {
        let defaults = suite()
        defaults.set("3.2.0", forKey: "SULastCheckTime")   // 别的键，不该进报告
        XCTAssertEqual(SparkleSkippedVersions.clear(in: defaults), [])
    }

    /// 恢复跳过记录不该动 Sparkle 的其它状态：检查时间、是否自动下载、更新组号
    /// 一旦被抹掉，等于顺手改了用户的检查节奏 —— 症状是「我没动过设置，怎么更新行为变了」。
    func testClearLeavesOtherSparkleKeysAlone() {
        let defaults = suite()
        defaults.set("3.2.0", forKey: SparkleSkippedVersions.minorKey)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(stamp, forKey: "SULastCheckTime")
        defaults.set(true, forKey: "SUAutomaticallyUpdate")
        defaults.set(306_691_336, forKey: "SUUpdateGroupIdentifier")
        defaults.set("keepme", forKey: "clipboardHistoryLimit")

        SparkleSkippedVersions.clear(in: defaults)

        XCTAssertEqual(defaults.object(forKey: "SULastCheckTime") as? Date, stamp)
        XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "SUUpdateGroupIdentifier") as? Int, 306_691_336)
        XCTAssertEqual(defaults.string(forKey: "clipboardHistoryLimit"), "keepme")
    }

    /// 数字那格也要真的被抹掉：`removeObject` 对任何类型都成立，但若哪天改成
    /// 「按类型分别清」，这一格就会漏 —— 页面显示「无」而 Sparkle 还跳着。
    func testClearRemovesTheLegacyNumericValue() {
        let defaults = suite()
        defaults.set(NSNumber(value: 3_20_0), forKey: SparkleSkippedVersions.minorKey)
        XCTAssertEqual(SparkleSkippedVersions.clear(in: defaults), ["3200"])
        XCTAssertNil(defaults.object(forKey: SparkleSkippedVersions.minorKey))
    }
}
