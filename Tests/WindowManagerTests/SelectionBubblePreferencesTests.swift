//
//  SelectionBubblePreferencesTests.swift
//
//  划词气泡（移植版新增，侧栏独立一页）的偏好侧取证。判据一律取「另一份 UserPreferences
//  从同一个库里读回来」和「App 层那份快照比出来变没变」，不读页面自己的状态 ——
//  监听是 App 层按 UserDefaults 变化比对快照来起停的，界面状态和库不一致时，
//  用户看到的是开关开着、实际却是没挂监听。
//
//  渲染那三条取的是**位图差值**，不读 `disabled` 状态：一个 SwiftUI 控件说自己禁用了
//  和它画出来是灰的是两件事，用户看的只有后者。三条各咬一种坏：
//  - **M56** 总开关只灰自己那一行，其余不跟着灰 → 整页差值必须比「只关一格」大几倍
//  - **M57** 四格共用一份绑定 → 关掉任意两格渲出来的图必须两两互不相同
//  - **M58** 手动那条把整页灰掉 → 它的差值必须明显小于「关掉总开关」那一次
//  三条都以「另一档状态」当参照物，不数绝对阈值。这个套路是从 M52 那一回学来的：
//  当时只看「整页有没有差」，开关自己那一小块的差把「滑杆没灰」整个盖掉，变异跑完全绿。
//
//  默认值、快捷键、延迟那几条不是新坏，是独立页改版后各归各的用例，编号沿用 plan §6 那张表：
//  M48 默认改成开、M49 默认快捷键写坏、M50 延迟无视库里的值、M51 脏延迟界面照原样显示、
//  M53 滑杆步长、M54 关着仍占键位、M55 快照漏项；本次另加 **M63** 滑杆把秒当毫秒（界面显示 0）。
//

import XCTest
import AppKit
import SwiftUI
import Storage
import EventCapture
import SelectionPopup
@testable import Preferences

final class SelectionBubblePreferencesTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.SelectionBubble"
    private static let exportDir = "/tmp/macstroke-selection-bubble-check"
    private static let pageSize = NSSize(width: 760, height: 1600)

    override func setUp() {
        super.setUp()
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func isolatedSuite() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    private func makePrefs() -> UserPreferences {
        UserPreferences(storage: makeStorage())
    }

    private func makeStorage() -> PreferencesStorage {
        PreferencesStorage(defaults: isolatedSuite())
    }

    /// 把界面上那几颗开关一次摆成一种状态，用例只写「哪一格和默认不一样」。
    /// 走 `UserPreferences` 而不是直接写库：要连 `didSet` 那段写盘一起验，
    /// 少接一根线就是「界面动了库没动」。
    ///
    /// `autoPaste` 故意**不给默认 true**：这颗开关出厂是关的，让它在这里默认开着，
    /// 上面那两条「整页差值」判据的参照物就悄悄变了（第七轮加这一行时踩过一次）。
    @discardableResult
    private func apply(master: Bool = true, autoPop: Bool = true, manual: Bool = true,
                       copy: Bool = true, search: Bool = true, translate: Bool = true,
                       speak: Bool = true, autoPaste: Bool = false) -> UserPreferences {
        let prefs = makePrefs()
        prefs.enableSelectionPopup = master
        prefs.selectionPopupAutoPop = autoPop
        prefs.selectionPopupShortcutEnabled = manual
        prefs.selectionPopupActionCopy = copy
        prefs.selectionPopupActionSearch = search
        prefs.selectionPopupActionTranslate = translate
        prefs.selectionPopupActionSpeak = speak
        prefs.selectionPopupAutoPaste = autoPaste
        return prefs
    }

    // MARK: - 默认值（总开关必须是关的）

    func testOffByDefault() {
        let prefs = makePrefs()
        XCTAssertFalse(prefs.enableSelectionPopup, "默认必须关着：原版没有这个功能，装完不该发现自己划字会弹")
        XCTAssertEqual(prefs.selectionPopupReadDelay, StorageDefaults.selectionPopupReadDelay)
        XCTAssertEqual(prefs.selectionPopupShortcut, StorageDefaults.selectionPopupShortcut)
        // 其余那八项默认开：门只有总开关那一道。这里任何一项默认被翻成关，表现都是
        // 「用户兴冲冲打开开关，结果还是不弹」，而且页面上看着一切正常。
        XCTAssertTrue(prefs.selectionPopupAutoPop)
        XCTAssertTrue(prefs.selectionPopupShortcutEnabled)
        XCTAssertTrue(prefs.selectionPopupActionCopy)
        XCTAssertTrue(prefs.selectionPopupActionSearch)
        XCTAssertTrue(prefs.selectionPopupActionTranslate)
        XCTAssertTrue(prefs.selectionPopupActionSpeak)
        // 搜索那两栏：默认 Google（= 这一格写死那一家，升级完行为不许变）、自定义模板空着。
        XCTAssertEqual(prefs.selectionPopupSearchEngine, StorageDefaults.selectionPopupSearchEngine)
        XCTAssertEqual(prefs.selectionPopupSearchEngine, "google")
        XCTAssertEqual(prefs.selectionPopupSearchCustomURL, "")
        // 自动补 ⌘V 默认关：这一手是「替用户往他的前台窗口投按键」，和总开关同等待遇。
        XCTAssertFalse(prefs.selectionPopupAutoPaste, "自动贴默认必须是关")
        XCTAssertFalse(SelectionBubbleSettings.current(from: makeStorage()).enabled)
        // 把其余条件全摆成「就差这一颗」的样子：功能开着、搜索格开着（上面已验默认开）、
        // 选的还是一家不吃 URL 预填的页 —— 这时候唯一拦住那一手的必须是那颗出厂的关。
        prefs.enableSelectionPopup = true
        prefs.selectionPopupSearchEngine = "doubao"
        XCTAssertTrue(SelectionBubbleSettings.current(from: makeStorage()).searchTarget.copiesTextFirst,
                      "豆包这一家不吃预填，摆出来的才是「就差这一颗」的那种配法")
        XCTAssertFalse(SelectionBubbleSettings.current(from: makeStorage()).searchAutoPaste,
                       "只靠默认值就自动贴：上面那句默认关等于没关")
    }

    /// App 层是把库里那串**直接**喂给 `ShortcutMonitor` 的：串解析不出来走的是「停掉监听」
    /// 那一支，表现是快捷键永久哑掉、界面上却一切正常。「到底是哪两个修饰键」由
    /// SelectionBubbleSettingsTests 钉，这里只钉「那只 monitor 真挂得上」。
    func testDefaultShortcutFeedsTheMonitor() throws {
        let parsed = try XCTUnwrap(
            ShortcutMonitor.parseShortcut(makePrefs().selectionPopupShortcut),
            "默认串解析不出来：手动唤出那只 monitor 根本不会挂上")
        XCTAssertEqual(parsed.0, 11, "B 键的键码")
    }

    // MARK: - 写库

    /// 页面上每一项都要落到自己的键上，另一份实例从库里读回来还得一致（App 层读的是库，不是这个对象）。
    /// 这条同时钉住「毫秒落盘、不是档位序号」和「四格一格一键」。
    func testEveryFieldLandsInTheStore() {
        let prefs = makePrefs()
        prefs.enableSelectionPopup = true
        prefs.selectionPopupAutoPop = false
        prefs.selectionPopupShortcutEnabled = false
        prefs.selectionPopupShortcut = "keyCode=7, flags=1572864"
        prefs.selectionPopupReadDelay = 400
        prefs.selectionPopupActionCopy = false
        prefs.selectionPopupActionSearch = false
        prefs.selectionPopupActionTranslate = false
        prefs.selectionPopupActionSpeak = false
        prefs.selectionPopupSearchEngine = "perplexity"
        prefs.selectionPopupSearchCustomURL = "https://wiki.corp/?s={query}"
        prefs.selectionPopupAutoPaste = true

        let suite = isolatedSuite()
        XCTAssertTrue(suite.bool(forKey: StorageKey.enableSelectionPopup.rawValue))
        XCTAssertFalse(suite.bool(forKey: StorageKey.selectionPopupAutoPop.rawValue))
        XCTAssertFalse(suite.bool(forKey: StorageKey.selectionPopupShortcutEnabled.rawValue))
        XCTAssertEqual(suite.string(forKey: StorageKey.selectionPopupShortcut.rawValue),
                       "keyCode=7, flags=1572864")
        XCTAssertEqual(suite.integer(forKey: StorageKey.selectionPopupReadDelay.rawValue), 400,
                       "存的是毫秒，不是档位序号")
        for key in [StorageKey.selectionPopupActionCopy, .selectionPopupActionSearch,
                    .selectionPopupActionTranslate, .selectionPopupActionSpeak] {
            XCTAssertFalse(suite.bool(forKey: key.rawValue), "\(key.rawValue) 没写进库")
        }
        // 引擎存的是**能读懂的 id**（不是序号）：装机出问题时 `defaults read` 一眼看出选了谁，
        // 而且往表中间加一家不会把已存的值顶歪。
        XCTAssertEqual(suite.string(forKey: StorageKey.selectionPopupSearchEngine.rawValue), "perplexity")
        XCTAssertEqual(suite.string(forKey: StorageKey.selectionPopupSearchCustomURL.rawValue),
                       "https://wiki.corp/?s={query}")
        XCTAssertTrue(suite.bool(forKey: StorageKey.selectionPopupAutoPaste.rawValue))

        let reread = makePrefs()
        XCTAssertTrue(reread.enableSelectionPopup)
        XCTAssertFalse(reread.selectionPopupAutoPop)
        XCTAssertFalse(reread.selectionPopupShortcutEnabled)
        XCTAssertEqual(reread.selectionPopupShortcut, "keyCode=7, flags=1572864")
        XCTAssertEqual(reread.selectionPopupReadDelay, 400)
        XCTAssertEqual([reread.selectionPopupActionCopy, reread.selectionPopupActionSearch,
                        reread.selectionPopupActionTranslate, reread.selectionPopupActionSpeak],
                       [false, false, false, false])
        XCTAssertEqual(reread.selectionPopupSearchEngine, "perplexity")
        XCTAssertEqual(reread.selectionPopupSearchCustomURL, "https://wiki.corp/?s={query}")
        XCTAssertTrue(reread.selectionPopupAutoPaste)
    }

    /// 库里存了个认不出的引擎 id（手改 plist、或从别处导入的偏好）：**页面显示的那一家必须就是
    /// 实际在跑的那一家**。两边各退各的会出现「下拉里是一片空白、点开搜索其实走的是 Google」，
    /// 用户只会以为这一页坏了。
    func testAnUnreadableEngineIdShowsTheEngineThatActuallyRuns() {
        isolatedSuite().set("googgle", forKey: StorageKey.selectionPopupSearchEngine.rawValue)
        let shown = makePrefs().selectionPopupSearchEngine
        XCTAssertEqual(SelectionBubbleSearchEngine.from(rawValue: shown),
                       SelectionBubbleSearchEngine.current(in: makeStorage()),
                       "界面认的那一家和消费端认的那一家不是同一家")
        XCTAssertTrue(SelectionBubbleSearchEngine.allCases.contains { $0.rawValue == shown },
                      "界面里那一家必须在下拉中有对应的一行，不然画出来是一条空白")
    }

    /// App 层的起停判据就是这份快照（`UserDefaults` 通知很密，只有快照变了才重喂）。
    /// 每一项单独变都必须让快照变，漏一项就是「界面上改了、功能没跟着改」。
    func testSnapshotChangesForEverySingleField() {
        let base = SelectionBubbleSettings.current(from: makeStorage())
        func changed(_ file: StaticString = #file, _ line: UInt = #line, _ edit: (UserPreferences) -> Void) {
            isolatedSuite().removePersistentDomain(forName: Self.suiteName)
            let prefs = makePrefs()
            edit(prefs)
            XCTAssertNotEqual(SelectionBubbleSettings.current(from: makeStorage()), base,
                              "这一项单独变没被比出来：改了界面不动功能", file: file, line: line)
        }
        changed { $0.enableSelectionPopup = true }
        changed { $0.selectionPopupAutoPop = false }
        changed { $0.selectionPopupShortcutEnabled = false }
        changed { $0.selectionPopupShortcut = "keyCode=7, flags=1572864" }
        changed { $0.selectionPopupReadDelay = 600 }
        changed { $0.selectionPopupActionCopy = false }
        changed { $0.selectionPopupActionSearch = false }
        changed { $0.selectionPopupActionTranslate = false }
        changed { $0.selectionPopupActionSpeak = false }
        changed { $0.selectionPopupSearchEngine = "bing" }
        changed { $0.selectionPopupSearchCustomURL = "https://wiki.corp/?s={query}" }
        changed { $0.selectionPopupCopyFallback = false }
        changed { $0.selectionPopupAutoPaste = true }

        // 什么也没改时快照必须相等，否则每次无关的 UserDefaults 通知都会把左键监听拆了再挂
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
        XCTAssertEqual(SelectionBubbleSettings.current(from: makeStorage()),
                       SelectionBubbleSettings.current(from: makeStorage()))
    }

    func testDelayRoundTripsMillisecondsToSeconds() {
        let prefs = makePrefs()
        prefs.selectionPopupReadDelay = 400
        XCTAssertEqual(SelectionBubbleSettings.current(from: makeStorage()).readDelay, 0.4,
                       accuracy: 0.0001, "落盘毫秒、消费端秒：换算错一位就是延迟差千倍")
        // 界面拿的是毫秒那份：这一句错一位，滑杆上显示的就是 0。
        XCTAssertEqual(SelectionBubbleSettings.current(from: makeStorage()).readDelayMilliseconds, 400)
        XCTAssertEqual(makePrefs().selectionPopupReadDelay, 400)
    }

    // MARK: - 存量脏值

    /// 导入过别人的偏好 plist 的人可能带一个越界的延迟进来。界面和消费端必须退到同一个数，
    /// 而且不能连坐没坏的开关。
    func testGarbageDelayFallsBackOnBothSides() {
        for garbage in [0, -5, 999_999] {
            isolatedSuite().removePersistentDomain(forName: Self.suiteName)
            isolatedSuite().set(garbage, forKey: StorageKey.selectionPopupReadDelay.rawValue)
            isolatedSuite().set(true, forKey: StorageKey.enableSelectionPopup.rawValue)

            XCTAssertEqual(makePrefs().selectionPopupReadDelay, StorageDefaults.selectionPopupReadDelay,
                           "脏值 \(garbage)：界面要显示退回后的数")
            XCTAssertEqual(SelectionBubbleSettings.current(from: makeStorage()).readDelay,
                           TimeInterval(StorageDefaults.selectionPopupReadDelay) / 1000,
                           accuracy: 0.0001, "脏值 \(garbage)：实际跑的必须是同一个数")
            XCTAssertTrue(makePrefs().enableSelectionPopup, "延迟写坏不该把开关一起改掉")
        }
    }

    /// 偏好页那根滑杆的步长取自模块常量：默认值和上下限都要落在格子上，否则用户滑不到边界、
    /// 也滑不回默认。步长和阈值只要有一头被改，这里就得红。
    func testSliderGridReachesTheDocumentedRange() {
        let range = SelectionBubbleSettings.readDelayMillisecondsRange
        let step = SelectionBubbleSettings.readDelayStepMilliseconds
        XCTAssertEqual(range.lowerBound % step, 0, "下限要落在步长格子上")
        XCTAssertEqual(range.upperBound % step, 0, "上限要落在步长格子上")
        XCTAssertEqual(StorageDefaults.selectionPopupReadDelay % step, 0, "默认值要落在格子上")
        XCTAssertTrue(range.contains(StorageDefaults.selectionPopupReadDelay))
    }

    // MARK: - 侧栏位置

    /// 这一页必须在侧栏里能直接点到，而且要排在关于之前 —— 前面三页的位置用例都按相邻序号
    /// 断言，所以它只能插在靠近锁屏和关于之间。
    func testThePageSitsBeforeAboutInTheSidebar() {
        let tabs = PreferencesTab.allCases
        guard let proximity = tabs.firstIndex(of: .proximityLock),
              let bubble = tabs.firstIndex(of: .selectionBubble),
              let about = tabs.firstIndex(of: .about) else {
            return XCTFail("侧栏缺少靠近锁屏/划词气泡/关于其中一项")
        }
        XCTAssertEqual(bubble, proximity + 1, "划词气泡紧跟在靠近锁屏后面")
        XCTAssertEqual(about, bubble + 1, "关于页仍然排在最后")
        XCTAssertEqual(tabs.count, about + 1)
        XCTAssertEqual(PreferencesTab.selectionBubble.rawValue, "selectionBubble",
                       "外部入口只传 rawValue，键名一改跳页就断")
        XCTAssertFalse(PreferencesTab.selectionBubble.title.isEmpty)
        XCTAssertFalse(PreferencesTab.selectionBubble.systemImage.isEmpty)
    }

    // MARK: - 页面渲染

    /// 总开关关掉要**整页**跟着灰：除它自己以外每一行都得画成不可用。
    /// 判据是两版差值，而且拿「只关掉一格」的差值当尺子 —— 只有一行在动的那种坏，
    /// 光看「有没有差」是看不出来的（同一个坑 M52 踩过一次）。
    func testMasterSwitchGreysTheWholePageNotJustItsOwnRow() throws {
        apply(master: true)
        let on = try renderPage(name: "page-master-on")
        apply(master: false)
        let off = try renderPage(name: "page-master-off")
        apply(master: true, translate: false)
        let oneCell = try renderPage(name: "page-one-cell-off")

        let masterDiff = try changedPixels(on, off, name: "master")
        let cellDiff = try changedPixels(on, oneCell, name: "one cell")
        XCTAssertGreaterThan(masterDiff.ink, 1_000, "这一页几乎没画出来，差值不作数")
        XCTAssertGreaterThan(cellDiff.changed, 20, "关掉翻译那一格，画面上没任何东西在动")
        XCTAssertGreaterThan(masterDiff.changed, cellDiff.changed * 3,
                             "总开关的差值不比单格大几倍：说明它只动了自己那一行，其余没灰")
    }

    /// 四格必须是四行各管各的：四个开关接成同一份绑定时，关掉任意两格渲出来的图会**一模一样**
    /// （都是同一行在动），这比「有没有差」更直接。
    func testEachCellSwitchIsItsOwnRow() throws {
        var shots: [(SelectionBubbleAction, NSBitmapImageRep)] = []
        apply()
        let base = try renderPage(name: "page-cells-base")
        for (index, action) in SelectionBubbleAction.allCases.enumerated() {
            isolatedSuite().removePersistentDomain(forName: Self.suiteName)
            // 只关掉这一格，其余三格保持开着。
            var flags = [true, true, true, true]
            flags[index] = false
            apply(copy: flags[0], search: flags[1], translate: flags[2], speak: flags[3])
            shots.append((action, try renderPage(name: "page-cell-off-\(action.rawValue)")))
        }
        for (action, shot) in shots {
            XCTAssertGreaterThan(try changedPixels(base, shot, name: action.rawValue).changed, 20,
                                 "关掉 \(action.rawValue) 那一格没有任何可见变化")
        }
        for first in shots {
            for second in shots where first.0 != second.0 {
                // 两两互不相同：接线接串了才会出现两张一模一样的图。
                XCTAssertGreaterThan(try changedPixels(first.1, second.1, name: "pairwise").changed, 20,
                                     "关掉 \(first.0.rawValue) 和关掉 \(second.0.rawValue) 画出来一样：四行共用了绑定")
            }
        }
    }

    /// 「手动快捷键唤出」单独关掉，只该影响快捷键那一块：自动弹和四格都不许跟着灰。
    /// 反过来的坏（一关就把整页灰了）用户只会以为划词气泡坏了。
    func testManualTriggerOnlyGreysTheShortcutRow() throws {
        apply()
        let on = try renderPage(name: "page-manual-on")
        apply(manual: false)
        let off = try renderPage(name: "page-manual-off")
        apply(master: false)
        let allOff = try renderPage(name: "page-manual-all-off")

        let manualDiff = try changedPixels(on, off, name: "manual")
        let masterDiff = try changedPixels(on, allOff, name: "manual vs master")
        XCTAssertGreaterThan(manualDiff.changed, 20, "关掉手动那一条画面没动静：那格开关没接线")
        XCTAssertLessThan(manualDiff.changed, masterDiff.changed / 2,
                          "只关手动一条却比关掉总开关动得还多：灰错地方了")
    }

    /// 下拉点了另一家，页面上必须**看得见那一家名字换了**（闭着的下拉只画选中的那一个字，
    /// 所以这一条比的就是那个字）。接线接错的坏法是：库里改了、下拉还显示 Google，
    /// 用户以为没点上又点一次 —— 而消费端读的是库，实际跑的已经是必应，两边不一致最难查。
    func testTheEnginePickerShowsTheChosenEngine() throws {
        apply().selectionPopupSearchEngine = "google"
        let google = try renderPage(name: "page-engine-google")
        apply().selectionPopupSearchEngine = "bing"
        let bing = try renderPage(name: "page-engine-bing")
        apply().selectionPopupSearchEngine = "doubao"
        let doubao = try renderPage(name: "page-engine-doubao")

        XCTAssertGreaterThan(try changedPixels(google, bing, name: "google vs bing").changed, 20,
                             "换成必应，下拉上那个字没动：绑定没接上")
        XCTAssertGreaterThan(try changedPixels(bing, doubao, name: "bing vs doubao").changed, 20,
                             "换成豆包和换成必应画出来一样：下拉只认一个值")
        // 换一家不许把别人的行顶掉：整页高度必须一致（布局重排 = 有人把行藏起来了）。
        XCTAssertEqual(google.pixelsHigh, doubao.pixelsHigh)
    }

    /// 自定义那一栏只在选了「自定义」时亮起来，且**没填成一个网址时要有那句黄字**。
    /// 三版互比：挡三种坏 —— 文本框永远可编辑（灰错地方）、黄字压根没画、
    /// 以及黄字常驻（填好了也说没填）。
    func testTheCustomURLRowLightsUpOnlyForTheCustomEngine() throws {
        apply().selectionPopupSearchEngine = "google"
        let preset = try renderPage(name: "page-engine-preset")
        apply().selectionPopupSearchEngine = "custom"
        let empty = try renderPage(name: "page-engine-custom-empty")
        apply().selectionPopupSearchEngine = "custom"
        apply().selectionPopupSearchCustomURL = "https://wiki.corp/?s={query}"
        let filled = try renderPage(name: "page-engine-custom-filled")

        XCTAssertGreaterThan(try changedPixels(preset, empty, name: "自定义 + 空").changed, 20,
                             "选了自定义，那一栏和提示都没动静：两行没接线")
        XCTAssertGreaterThan(try changedPixels(empty, filled, name: "空 → 填好").changed, 20,
                             "填好网址后那句「还在退回默认那一家」的黄字没消失")
        // 第三条只数 URL 那一行：没选自定义时它必须是灰的。整页那两条判据挡不住「常驻可编辑」
        // —— 那种坏里下拉、黄字、下面两块的位移照样都在动，差值照样过阈值。
        XCTAssertGreaterThan(try changedPixels(preset, empty, name: "只看 URL 那一行",
                                               band: Self.urlRowBand).changed, 20,
                             "没选自定义时那一栏没灰：文本框的可用条件没看下拉当前选的是哪家")
    }

    /// 摆一页：搜索引擎钉成那一家不吃预填的、开关按 `autoPaste` 摆、快捷键按 `shortcut` 写。
    /// 每次都把引擎和快捷键**显式**写一遍：`apply` 不清库，前一个用例留下的值会悄悄参与
    /// 后一次比较（M132 那次全绿就是因为忘了钉 —— 差的其实是被遗留的那一项）。
    @discardableResult
    private func renderState(_ name: String, autoPaste: Bool,
                             shortcut: String = StorageDefaults.selectionPopupShortcut,
                             engine: String = "doubao", search: Bool = true) throws -> NSBitmapImageRep {
        let prefs = apply(search: search, autoPaste: autoPaste)
        prefs.selectionPopupSearchEngine = engine
        prefs.selectionPopupShortcut = shortcut
        return try renderPage(name: name)
    }

    /// 「自动补 ⌘V」那一行要跟着**搜索那一格**灰：它只服务搜索格，格子关了没有任何页面被打开，
    /// 这一行亮着也只是让人拨一颗什么都不会发生的开关。
    ///
    /// 两条判据各咬一种第七轮的坏法：
    ///  - 新行忘了接 `.disabled`（搜索格关了这里还能拨，拨完不生效）；
    ///  - 接错成只看总开关（那是「灰错地方」，格子关了这里却暗着、开关开着页面却灰）。
    /// 第一条判据先给带子定位：拨这颗开关自己必须在带子里看得见，否则第二条的红解释不了。
    func testTheAutoPasteRowGreysWithTheSearchCell() throws {
        let off = try renderState("page-autopaste-row-off", autoPaste: false)
        let on = try renderState("page-autopaste-row-on", autoPaste: true)
        let searchOff = try renderState("page-autopaste-row-search-off", autoPaste: true, search: false)

        XCTAssertGreaterThan(try changedPixels(off, on, name: "带子自检",
                                               band: Self.autoPasteRowBand).changed, 20,
                             "拨这颗开关在带子里看不见：带子没罩住那一行，下面那条判据不作数")
        XCTAssertGreaterThan(try changedPixels(on, searchOff, name: "关掉搜索格",
                                               band: Self.autoPasteRowBand).changed, 20,
                             "关掉搜索那一格，自动贴那行没灰：它的可用条件没接搜索格")
        // 带子的**上下沿**各钉一条：只动这颗开关时，卡片以下那一带不许有动静（否则
        // belowEngineBand 还罩着这一行，「有没有那句黄字」的判据能靠滑块自己动一下蒙过去）。
        XCTAssertLessThan(try changedPixels(off, on, name: "开关不动下面的区块",
                                            band: Self.belowEngineBand).changed, 20,
                          "belowEngineBand 的下界还在自动贴那一行上面：带子随新行往下挪过没有？")
    }

    /// 气泡快捷键录成**单纯 ⌘V** 时，那一手会被拆环的闸整个挡掉（`searchAutoPaste` 最后一条）。
    /// 界面必须说破：开关明明拨开着、却一次都不生效 —— 判据是引擎卡片下面**多出一行黄字**，
    /// 于是「读不到选区时」「读取延迟」两块被顶下去。
    ///
    /// 三条判据合起来才咬得住：
    ///  - 有/无黄字（同时给带子定位：这一带真的会被多出来的一行顶动）；
    ///  - 开关关着时同样换快捷键，这一带**不许**动（黄字是条件的，不是常驻的；也证明
    ///    快捷键录制框自己那一行的变化不会漏进这一带 —— 它在带子之上）。
    func testAPlainCommandVShortcutWarnsBelowTheEngineCard() throws {
        let plainV = "keyCode=9, flags=1048576"
        let clean = try renderState("page-vwarn-on-clean", autoPaste: true)
        let warned = try renderState("page-vwarn-on-plainv", autoPaste: true, shortcut: plainV)
        let warnedOff = try renderState("page-vwarn-off-plainv", autoPaste: false, shortcut: plainV)
        let cleanOff = try renderState("page-vwarn-off-clean", autoPaste: false)

        XCTAssertGreaterThan(try changedPixels(clean, warned, name: "黄字顶下去",
                                               band: Self.belowEngineBand).changed, 20,
                             "快捷键录成单纯 ⌘V 时那句黄字没画出来（或带子跑偏）：开关开着却一次不生效，页面上看不出来")
        // 同一条判据换个轴再走一遍：快捷键钉死成单纯 ⌘V，只动那颗开关。
        // 这一带里唯一在动的就是那句黄字（开关自己那一行在卡片里、在带子之上），
        // 所以这条同时是带子的定位 —— 顶不下去就是带子没罩住下面的区块。
        XCTAssertGreaterThan(try changedPixels(warned, warnedOff, name: "开关一关黄字就撤",
                                               band: Self.belowEngineBand).changed, 20,
                             "这句黄字不跟着那颗开关走：常驻的话上面两条判据都不作数")
        XCTAssertLessThan(try changedPixels(cleanOff, warnedOff, name: "开关关着不该有黄字",
                                            band: Self.belowEngineBand).changed, 20,
                          "开关没开也把那句说出来了：而且证明快捷键录制框那一行的变化不会漏进这一带")
        // 反向钉带子的上沿：多出那句黄字不该把**卡片里**那一行也顶动（顶动了说明
        // autoPasteRowBand 的下界还压在卡片底下，上面那条「开关不动下面的区块」就不作数了）。
        XCTAssertLessThan(try changedPixels(clean, warned, name: "黄字不顶卡片里的行",
                                            band: Self.autoPasteRowBand).changed, 20,
                          "带子下界还罩着卡片外面：两条带子的边界要各自量过")
    }

    /// 一次比对的两种计数：整页画了多少有内容的点，和两版之间差了多少个点。
    /// `band` 是**页高比例**区间（不是像素）：同一页在 1x 离屏位图里是 1600 高，挂到 Retina 屏上
    /// 渲出来就是 3200 高，写死像素的判据换台机器就飘。分带是为了躲开 M52 那个坑 ——
    /// 整页差值会被旁边那块「本来就该动」的东西盖掉，只看「有没有差」等于没看。
    private struct Diff { let ink: Int; let changed: Int }

    /// 引擎区块（区块标题 + 下拉 + 两句提示 + 自定义 URL 框）。
    /// 实测 1x：下拉那一行 y 788…792（0.4925…0.495），URL 框那一行 y 892…900。
    private static let engineBand = 0.47 ... 0.57
    /// **只有自定义 URL 那一行**（实测文本框画在 y 892…900）。分这么细是为了咬「那一栏常驻可编辑」
    /// 这种坏：整页看过去下拉、黄字、下面两块的位移全在动，那一行灰没灰根本数不出来（M52 那个坑）。
    private static let urlRowBand = 0.54 ... 0.58
    /// 「自动补 ⌘V」那一行（实测开关滑块画在 y 980…996 = 0.6125…0.6225）。
    /// 上界 0.64 卡在卡片底部以下、黄字起点（y 1112）以上 —— 带子只罩这一行，
    /// 「搜索格关了它没灰」才不会被旁边那一句黄字顶出来的位移蒙对。
    private static let autoPasteRowBand = 0.60 ... 0.64
    /// 引擎卡片**以下**（那句黄字 + 代按 ⌘C、读取延迟两块）。实测卡片底下第一处内容画在 y 1112。
    /// 第七轮往卡片里加了自动贴那一行（y 980…996），这一带的下界必须跟着往下挪 —— 停在 0.59
    /// 的话带子会一并罩住那颗开关，「有黄字 vs 没黄字」那条判据就能靠滑块自己动一下蒙过去。
    private static let belowEngineBand = 0.69 ... 1.0

    private func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                               name: String, band: ClosedRange<Double>? = nil) throws -> Diff {
        XCTAssertEqual(a.pixelsWide, b.pixelsWide, "\(name)：两版宽度不一样，说明布局被重排了")
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh, "\(name)：两版高度不一样，说明布局被重排了")
        let lo = Int((band?.lowerBound ?? 0) * Double(a.pixelsHigh))
        let hi = Int((band?.upperBound ?? 1) * Double(a.pixelsHigh))
        var ink = 0
        var changed = 0
        for y in stride(from: lo, to: min(hi, a.pixelsHigh), by: 2) {
            for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                guard let left = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let right = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if left.alphaComponent > 0.01 { ink += 1 }
                let delta = max(abs(left.redComponent - right.redComponent),
                                abs(left.greenComponent - right.greenComponent),
                                abs(left.blueComponent - right.blueComponent))
                if delta > 0.03 { changed += 1 }
            }
        }
        return Diff(ink: ink, changed: changed)
    }

    /// 关掉「搜索」那一格，引擎那一整块必须跟着灰：那块东西只服务于搜索格，格子关了还让人改引擎，
    /// 改完以为生效了、实际上一格都不弹。
    /// **两次相比必须是「只有搜索格不一样」**：这一带的东西只有下拉选中那一家会在 y 788…792 动，
    /// 所以中间那一步换过引擎之后，比较前得把它钉回同一家 —— 忘了钉就是 M132 那一回：
    /// 变异把 `canUseEngineRow` 改成只看总开关（引擎区块再也不灰），用例照样全绿，
    /// 因为那两次比的是「google 开着」和「bing 关着」，差的其实是下拉上那个字。
    /// 第一条判据先给带子定位（换一家引擎的差必须落在带内），带子跑偏下面那条就不作数。
    func testTurningOffTheSearchCellGreysTheEngineBlock() throws {
        let pinnedEngine = "bing"
        apply().selectionPopupSearchEngine = pinnedEngine
        let on = try renderPage(name: "page-band-on")
        apply().selectionPopupSearchEngine = "doubao"
        let otherEngine = try renderPage(name: "page-band-other-engine")
        apply().selectionPopupSearchEngine = pinnedEngine
        apply(search: false)
        let searchOff = try renderPage(name: "page-band-search-off")

        // 定位完之后先确认这一条不是空跑：同一家、同一条引擎行，搜索格开着与关着必须看得出灰。
        XCTAssertGreaterThan(try changedPixels(on, otherEngine, name: "带子自检",
                                               band: Self.engineBand).changed, 20,
                             "换一家引擎的差没落在引擎带子里：带子跑偏了，下面那条判据不作数")
        XCTAssertGreaterThan(try changedPixels(on, searchOff, name: "关掉搜索格",
                                               band: Self.engineBand).changed, 20,
                             "关掉搜索那一格，引擎区块没灰：那一块的可用条件没接搜索格")
    }

    /// 「填好网址之后页面必须回到原来的高度」。那句黄字是插在卡片后面的一行，填好了还不撤，
    /// 下面的「代按 ⌘C」「读取延迟」两块会永久往下顶一格。
    /// 整页差值分不出这件事（黄字自己那一块本来就在动），所以只数**引擎区块以下**那一段：
    /// 空着时必须被顶下去（这条同时给带子定位），填好后必须归位。
    func testFillingInTheURLRestoresTheRestOfThePage() throws {
        apply().selectionPopupSearchEngine = "google"
        let preset = try renderPage(name: "page-shift-preset")
        apply().selectionPopupSearchEngine = "custom"
        let empty = try renderPage(name: "page-shift-empty")
        apply().selectionPopupSearchEngine = "custom"
        apply().selectionPopupSearchCustomURL = "https://wiki.corp/?s={query}"
        let filled = try renderPage(name: "page-shift-filled")

        XCTAssertGreaterThan(try changedPixels(preset, empty, name: "空 URL 顶下去",
                                               band: Self.belowEngineBand).changed, 20,
                             "选了自定义又没填，黄字没把下面两块顶下去：带子跑偏，或那句压根没画")
        XCTAssertLessThan(try changedPixels(preset, filled, name: "填好后归位",
                                            band: Self.belowEngineBand).changed, 20,
                          "填好网址了那句黄字还挂着：下面的区块没回到原位")
    }

    @discardableResult
    private func renderPage(name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: SelectionBubbleTabView(viewModel: makePrefs()))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.pageSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: Self.pageSize)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        host.needsDisplay = true

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "这一页渲不出位图：窗口没挂上视图树")
        host.cacheDisplay(in: host.bounds, to: rep)
        try export(rep, name: name)
        return rep
    }

    private func export(_ rep: NSBitmapImageRep, name: String) throws {
        try FileManager.default.createDirectory(atPath: Self.exportDir,
                                                withIntermediateDirectories: true)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(Self.exportDir)/\(name).png"))
    }
}
