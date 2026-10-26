// issue #76（过滤规则中黑名单无法持久化）：用户报的是「黑名单模式，添加的应用会在
// 重启后消失，黑名单空了」。写库那条路（偏好页 Apply）一直是对的，丢名单的是**启动时
// 那一次 2.x 旧键迁移**：旧键 `blockFilter` 被 `registerUserDefaultsDefaults()` 注册成了
// `""`，而注册表里的值对 `string(forKey:)` 一样可见、`removeObject` 又只能删掉真正写进
// 磁盘的那一份 —— 于是「旧键有值」每次启动都成立，每次启动都把 `filterBlackList` 重写成
// 空数组、把模式按成黑名单。原版只在 DefaultPreferences.plist 里注册了 33 个键，
// `blockFilter` 不在其中，所以原版那句 `if (s)` 是安全的；移植版多注册了这一条就中招。
//
// 用例一律跑在私有 suite 上：这里判的是用户自己那两份名单，拿 `UserDefaults.standard`
// 当靶子等于拿开发机的真配置做删除实验。
//
// 还有一条踩过才知道的坑，写在这里免得下次又当成产品红：`register(defaults:)` 注册的
// 那张表在**一个进程里是全局的**，不属于某个 suite —— 本机实测 A suite 注册
// `blockFilter = ""` 之后，B suite 和 standard 的 `string(forKey:)` 一起读到那个 `""`
// （真机上只有 `main.swift` 那一次注册，没有这个问题；同进程跑多个用例才有）。
// 所以下面凡是「某个键现在有没有值」的判据都不能靠读 UserDefaults，要么判表本身
// （`registeredUserDefaultsValues()`），要么判后果（改完再跑一次，看它动不动）。
import XCTest
import Foundation
@testable import RuleEngine
import Storage

@available(macOS 13.0, *)
final class BlackWhiteFilterTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BlackWhiteFilterTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName!)
        // removePersistentDomain 只清空域，suite 建的 plist 还留在 ~/Library/Preferences，
        // 每条用例一个新 UUID 就是一跑一堆文件（同 LegacyRulesImportTests 的处理）。
        try? FileManager.default.removeItem(
            at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suiteName!).plist"))
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    /// 事故现场复刻：旧键只有一份**注册出来的**空值（磁盘上压根没写过），
    /// 用户自己的名单和模式都在库里。迁移必须当作「没有旧数据」直接返回。
    func testRegisteredEmptyLegacyKeyDoesNotWipeBlackList() {
        suite.register(defaults: [StorageKey.blockFilter.rawValue: StorageDefaults.blockFilter])
        XCTAssertEqual(suite.string(forKey: StorageKey.blockFilter.rawValue), "",
                       "前置条件：注册值要能吃进 string(forKey:) —— 这正是 issue #76 的幻影")
        suite.set(["com.apple.TextEdit", "com.google.Chrome"], forKey: "filterBlackList")
        suite.set(true, forKey: "filterIsInWhiteMode")

        BlackWhiteFilter.shared.compatibleProcedureWithPreviousVersion(defaults: suite)

        XCTAssertEqual(suite.stringArray(forKey: "filterBlackList"),
                       ["com.apple.TextEdit", "com.google.Chrome"],
                       "黑名单被启动时的幻影迁移清了：用户看到的「重启后黑名单空了」就是这个")
        XCTAssertEqual(suite.object(forKey: "filterIsInWhiteMode") as? Bool, true,
                       "模式被顺手按成黑名单：白名单模式的人重启后连模式都换了")
    }

    /// 真写过一份空的（2.x 里把名单清空过就是这种）也不许动 —— 空串没有可迁的内容，
    /// 迁一次就是一份名单被抹成零。
    func testWrittenEmptyLegacyKeyDoesNotWipeBlackList() {
        suite.set("", forKey: "blockFilter")
        suite.set(["com.apple.TextEdit"], forKey: "filterBlackList")

        BlackWhiteFilter.shared.compatibleProcedureWithPreviousVersion(defaults: suite)

        XCTAssertEqual(suite.stringArray(forKey: "filterBlackList"), ["com.apple.TextEdit"],
                       "空的旧值没什么可迁，拿它覆盖一遍等于清库")
    }

    /// 反过来：真有一份 2.x 的 `"a|b|c"` 时必须照迁（原版 `AppDelegate.m:239-243` 那一步），
    /// 迁完按黑名单模式，并把旧键删掉。旧串里故意夹一段只有空格的（2.x 那个文本框里删一半就留得下）
    /// 和一段带尾空格的，端到端也钉住拆分口径。
    func testRealLegacyBlockFilterMigratesIntoBlackList() {
        suite.set("com.a| |com.b ", forKey: "blockFilter")

        BlackWhiteFilter.shared.compatibleProcedureWithPreviousVersion(defaults: suite)

        XCTAssertEqual(suite.stringArray(forKey: "filterBlackList"), ["com.a", "com.b"],
                       "旧键里的 | 要拆成一行一个，空段丢掉、两头空格 trim")
        XCTAssertEqual(suite.object(forKey: "filterIsInWhiteMode") as? Bool, false,
                       "2.x 只有黑名单，迁完落在黑名单模式（原版就是 isInWhiteListMode = NO）")
        // 「旧键删掉了」判的是它的**后果**，不是那个键本身，三个理由（都本机实测）：
        //  1) `string(forKey:)` 会被上一条用例泄漏的注册值污染 —— 注册域在一个进程里是全局的，
        //     第一条 `register(defaults: ["blockFilter": ""])` 之后，任何 suite 删干净了也读到 `""`；
        //  2) `object(forKey:)` 一样躲不过：没写过时它答 nil，写过再删之后它把那个注册值也答出来；
        //  3) 读磁盘上那份 plist 更不行 —— cfprefsd 交出来的是过期快照：删掉的 `blockFilter` 还在文件里，
        //     新写进去的名单和模式反倒不在。
        // 于是换个可观察的口径：迁完把名单改成哨兵，再叫一次迁移。旧键真删掉了就什么都不会发生；
        // 漏删的话第二次会把 "com.a|com.b" 原样盖回来，哨兵就没了。
        suite.set(["sentinel"], forKey: "filterBlackList")
        BlackWhiteFilter.shared.compatibleProcedureWithPreviousVersion(defaults: suite)
        XCTAssertEqual(suite.stringArray(forKey: "filterBlackList"), ["sentinel"],
                       "旧键要删掉，否则下次启动再迁一遍（第二次把哨兵盖回旧名单就是漏删）")
    }

    /// 幂等：连跑三次（等价于重启三次）第二、三次一个字节都不许动。
    /// 这一条是「重启即丢」这类回归的正判据 —— 一次不算红，稳定不动才算修好。
    func testMigrationIsIdempotentAcrossRestarts() {
        suite.set("com.a|com.b", forKey: "blockFilter")
        let filter = BlackWhiteFilter.shared
        filter.compatibleProcedureWithPreviousVersion(defaults: suite)
        let firstList = suite.stringArray(forKey: "filterBlackList")
        XCTAssertEqual(firstList, ["com.a", "com.b"], "前置条件：第一次确实迁出了东西")

        filter.compatibleProcedureWithPreviousVersion(defaults: suite)
        filter.compatibleProcedureWithPreviousVersion(defaults: suite)

        XCTAssertEqual(suite.stringArray(forKey: "filterBlackList"), firstList,
                       "第二次启动就把迁好的名单抹了：这正是用户报的那一下")
        XCTAssertEqual(suite.object(forKey: "filterIsInWhiteMode") as? Bool, false)
    }

    /// 钉在源头：迁移的**来源键**不许有注册值。上面四条判据（非空）能挡住 `""`，
    /// 但挡不住「注册了一个非空的假默认值」—— 那种幻影只有这张表里不出现这个键才咬得住。
    /// 原版 plist 里没有 blockFilter，这条就是回到原版的形状。
    ///
    /// 判 `registeredUserDefaultsValues()` 这张表，不判 `UserDefaults.standard.string`：
    /// 注册域在一个进程里是全局的，本文件第一条用例刚 `register(defaults: ["blockFilter": ""])`
    /// 污染过之后，standard 读到的是那个 `""`，跟产品里注册不注册没关系（本机实测）。
    /// 真机启动只有 `main.swift` 那一次注册，没有这个污染源 —— 所以判表才是判产品。
    func testLegacyMigrationSourceKeyIsNotRegistered() {
        XCTAssertFalse(registeredUserDefaultsValues().keys.contains(StorageKey.blockFilter.rawValue),
                       "旧键进了注册表 = 每次启动都以为有旧数据要迁（issue #76 的根）")
        // 顺带钉住调用链：注册函数用的就是这张表，不然上面那条判的是另一套值。
        XCTAssertTrue(registeredUserDefaultsValues().keys.contains(StorageKey.whiteListMode.rawValue),
                      "表里连常规键都没有 = registerUserDefaultsDefaults() 不吃这张表了，上面那条判空也白判")
    }

    /// 拆分口径是一份纯函数：偏好页那两个文本框（`blackListText` / `whiteListText` 的 setter）
    /// 和 2.x 迁移用的是同一只手，所以这一条一次钉住两处。上面几条判的是端到端，
    /// 这里判的是「一行一个、空行丢掉、两头去空格」这条规则本身 —— 分隔符写错、空段不丢、
    /// 空格不 trim 都在这里红，不用等装机。
    func testSplitListTextIsOnePatternPerLine() {
        XCTAssertEqual(BlackWhiteFilter.splitListText("com.a\ncom.b"), ["com.a", "com.b"])
        XCTAssertEqual(BlackWhiteFilter.splitListText(" com.a \n\ncom.b\n"), ["com.a", "com.b"],
                       "空行要丢、两头空格要 trim：否则名单里混进一条空白项，看着就像没配")
        // F06 那一趟反向变异就是从这条缝里跑掉的：`split(separator:"\n")` 默认已经不吐真空段，
        // 所以「空行」这一手只能靠**整行只有空格**的输入来判 —— 那种段是 trim 之后才变空的，
        // 少一道 `.filter` 就真留在名单里了（用户在页面上看到的是一片空白的一行）。
        XCTAssertEqual(BlackWhiteFilter.splitListText("com.a\n \t\ncom.b"), ["com.a", "com.b"],
                       "整行只有空格的那种也要丢掉：split 只跳真空段，空格段是 trim 之后才空的")
        XCTAssertEqual(BlackWhiteFilter.splitListText(""), [])
        XCTAssertEqual(BlackWhiteFilter.splitListText("com.a,com.b"), ["com.a,com.b"],
                       "只按行拆：逗号是原版 LIKE 模式串里的普通字符，不该再拆一层")
    }

    /// 键名对齐：偏好页那一头走 `StorageKey`，过滤器这一头走本文件上面的字面量常量
    /// （RuleEngine 不依赖 Storage，两边各写一遍），编译期没有任何东西拦得住改名字。
    /// 改坏任何一边，用户看到的都是同一个症状 —— 名单凭空变空（issue #76 报的就是这个症状，
    /// 只是这次的因由是幻影迁移）。这几格和原版同名，所以判据直接钉原版的字面量。
    func testFilterAndStorageAgreeOnKeyNames() {
        XCTAssertEqual(BlackWhiteFilter.blackListKey, "filterBlackList", "原版同名那一格，偏好页与迁移都写它")
        XCTAssertEqual(BlackWhiteFilter.whiteListKey, "filterWhiteList", "同上")
        XCTAssertEqual(BlackWhiteFilter.whiteListModeKey, StorageKey.whiteListMode.rawValue,
                       "模式那格必须和偏好页单选写的那一格是同一格")
        XCTAssertEqual(BlackWhiteFilter.legacyBlockFilterKey, StorageKey.blockFilter.rawValue,
                       "迁移来源键要和 Storage 那条读回退用的是同一格")
    }
}
