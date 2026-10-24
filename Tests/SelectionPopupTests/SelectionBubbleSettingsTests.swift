//
//  SelectionBubbleSettingsTests.swift
//  SelectionPopupTests
//
//  偏好快照的取证。总开关默认必须是**关**：这一条是「每次划完词往屏幕上放一个浮窗」，
//  用户没点头之前一次都不该发生（和靠近锁屏同等待遇）。
//  读进来的值也可能来自导入的 plist，写坏了不能变成「静默地乱弹」或者一个界面上显示不出来的延迟。
//

import Foundation
import Storage
import XCTest
@testable import SelectionPopup

final class SelectionBubbleSettingsTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.SelectionBubbleSettings"

    private var defaults: UserDefaults!
    private var storage: PreferencesStorage!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
        storage = PreferencesStorage(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    /// 出厂状态：总开关关、两条触发都开、四格都开、延迟 250ms、快捷键 ⌃⌘B。
    /// 反向变异 M（默认值被改成 true）就是这条红的：开关翻上去，等于所有人装完就中招。
    /// 其余那八项默认「开」是配套的：门只有一道，用户在页上拨哪一格都只影响那一格。
    func testFactoryDefaultIsOff() {
        XCTAssertFalse(StorageDefaults.enableSelectionPopup, "总开关默认必须是关")
        let settings = SelectionBubbleSettings.current(from: storage)
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.readDelay, 0.25)
        XCTAssertEqual(settings.shortcut, StorageDefaults.selectionPopupShortcut)
        XCTAssertTrue(settings.autoPop, "默认值给关的话，开了总开关还是不弹，看着像功能没做")
        XCTAssertTrue(settings.shortcutEnabled)
        XCTAssertEqual(settings.actions, SelectionBubbleAction.allCases)
    }

    /// 默认快捷键得是「⌃⌘ + B」那两个位都真在的串：App 层拿它喂 ShortcutMonitor，
    /// 串写坏了那一格功能整个是哑的，界面上还看不出来。
    /// 顺手核对它不和已有的三条撞车 —— 撞了就是「一个键位干两件事」，日志里看不出来，只会觉得邪门。
    func testDefaultShortcutIsControlCommandBAndCollidesWithNothing() {
        let (code, flags) = SelectionBubbleSettingsTests.parse(StorageDefaults.selectionPopupShortcut)
        XCTAssertEqual(code, 11, "B 的 Carbon 键码是 11")
        XCTAssertEqual(flags, 0x40000 | 0x100000, "⌃ = 0x40000、⌘ = 0x100000")
        let taken = [StorageDefaults.historyCilpboardListShortcut,
                     StorageDefaults.screenshotShortcut,
                     StorageDefaults.screenshotTextShortcut]
        for other in taken {
            let (otherCode, otherFlags) = SelectionBubbleSettingsTests.parse(other)
            if otherCode == code {
                XCTAssertNotEqual(otherFlags, flags, "和 \(other) 撞键位了")
            }
        }
    }

    /// "keyCode=11, flags=1310720" → (11, 1310720)。App 层那个解析器在 EventCapture 里，
    /// 本模块不依赖它，所以取证自带一份最小的。
    private static func parse(_ string: String) -> (UInt16, UInt) {
        let parts = string.split(separator: ",").map {
            $0.split(separator: "=").last.map { UInt($0.trimmingCharacters(in: .whitespaces)) ?? 0 } ?? 0
        }
        return (UInt16(parts.first ?? 0), parts.count > 1 ? parts[1] : 0)
    }

    /// 开关真能从偏好读出来（App 层就是靠这一句决定挂不挂监听）。
    func testMasterSwitchReadsBack() {
        storage.setBool(true, forKey: .enableSelectionPopup)
        XCTAssertTrue(SelectionBubbleSettings.current(from: storage).enabled)
        storage.setBool(false, forKey: .enableSelectionPopup)
        XCTAssertFalse(SelectionBubbleSettings.current(from: storage).enabled)
    }

    /// 延迟的合法区间：50…1500ms。偏好页那根滑杆的刻度从这里出发，不另写一份。
    func testReadDelayRangeMatchesMillisecondsOnTheSlider() {
        XCTAssertEqual(SelectionBubbleSettings.readDelayRange, 0.05 ... 1.5)
        XCTAssertEqual(SelectionBubbleSettings.readDelayMillisecondsRange, 50 ... 1500)
        XCTAssertEqual(SelectionBubbleSettings.clampedDelay(50), 50)
        XCTAssertEqual(SelectionBubbleSettings.clampedDelay(1500), 1500)
    }

    /// 写坏的延迟整值退回默认，不夹到边界：夹出来的 0 或 999999 在界面上显示不出来，
    /// 用户看到的是「我设了个啥」；退回 250 反而看得见、也解释得清。
    func testBrokenReadDelayFallsBackToTheDefaultRatherThanTheNearestEdge() {
        for broken in [0, -5, 49, 1501, 999_999, Int.min, Int.max] {
            XCTAssertEqual(SelectionBubbleSettings.clampedDelay(broken), 250,
                           "\(broken)ms 是坏值，该退回默认而不是夹到边界")
        }
        XCTAssertEqual(SelectionBubbleSettings.current(from: storage).readDelay, 0.25)
        storage.setInt(0, forKey: .selectionPopupReadDelay)
        XCTAssertEqual(SelectionBubbleSettings.current(from: storage).readDelay, 0.25)
        storage.setInt(800, forKey: .selectionPopupReadDelay)
        XCTAssertEqual(SelectionBubbleSettings.current(from: storage).readDelay, 0.8)
    }

    /// 快捷键串坏了不猜：原样交给 App 层，那边解析不出来会停掉监听并打日志。
    /// 这一条只保证「快照不吞掉用户写的值」，免得界面显示的和存的不是一回事。
    func testGarbageShortcutIsStoredAsWritten() {
        storage.setString("keyCode=abc, flags=xyz", forKey: .selectionPopupShortcut)
        XCTAssertEqual(SelectionBubbleSettings.current(from: storage).shortcut, "keyCode=abc, flags=xyz")
    }

    /// 三个不给偏好页铺控件的手感阈值，钉在这里：它们一改就是「该弹的时候没弹」，
    /// 只能靠装机调，所以得有一个人写的数摆着，别散在判定里当魔法数。
    func testFeelThresholdsAreTheDocumentedNumbers() {
        XCTAssertEqual(SelectionBubbleSettings.minimumTravel, 6)
        XCTAssertEqual(SelectionBubbleSettings.maximumCharacters, 2_000)
        XCTAssertEqual(SelectionBubbleSettings.autoHideAfter, 6)
        XCTAssertEqual(SelectionBubbleSettings.messagingTimeout, 0.6)
    }

    /// 「关到根上」的另一半：开关关掉时递给 App 层那只快捷键 monitor 的必须是空串 ——
    /// 空串解析不出来，`rebind` 走「停掉监听」那支。留着键位却不做事，等于把 ⌃⌘B 从前台
    /// 应用手里偷走，而用户只会以为这个键坏了。
    /// 判定不写在 `main.swift`（可执行 target 没有单测咬得进），就为了让这条能红。
    func testOffYieldsAnEmptyShortcutSoTheKeyIsNotOccupied() {
        let on = SelectionBubbleSettings(enabled: true,
                                        shortcut: StorageDefaults.selectionPopupShortcut,
                                        readDelay: 0.25)
        XCTAssertEqual(on.monitorShortcut, StorageDefaults.selectionPopupShortcut,
                       "开着时要把用户录的那个串原样递过去")
        let off = SelectionBubbleSettings(enabled: false,
                                         shortcut: StorageDefaults.selectionPopupShortcut,
                                         readDelay: 0.25)
        XCTAssertEqual(off.monitorShortcut, "", "关掉时必须给空串：非空就是继续占着键位")
    }

    // MARK: - 两条触发方式各关各的

    /// 「手动快捷键唤出」单独关掉时也要交空串，理由和总开关那一条一模一样：键位还占着、
    /// 按下去什么都不做，是最难查的那种坏。反过来「划完字自动弹出」单独关掉**不该**动这只
    /// monitor —— 两条能各关各的就是这一页拆成两行的全部理由。
    func testOnlyTheManualTriggerOwnsTheShortcutMonitor() {
        let manualOff = SelectionBubbleSettings(enabled: true,
                                                shortcut: StorageDefaults.selectionPopupShortcut,
                                                readDelay: 0.25,
                                                autoPop: true, shortcutEnabled: false)
        XCTAssertEqual(manualOff.monitorShortcut, "", "手动那条关了还占着 ⌃⌘B")
        XCTAssertFalse(manualOff.popsOnShortcut)
        XCTAssertTrue(manualOff.popsOnSelection, "自动弹不受手动那条影响")

        let autoOff = SelectionBubbleSettings(enabled: true,
                                              shortcut: StorageDefaults.selectionPopupShortcut,
                                              readDelay: 0.25,
                                              autoPop: false, shortcutEnabled: true)
        XCTAssertEqual(autoOff.monitorShortcut, StorageDefaults.selectionPopupShortcut,
                       "自动弹关掉不该把快捷键的 monitor 一起拆掉")
        XCTAssertFalse(autoOff.popsOnSelection)
        XCTAssertTrue(autoOff.popsOnShortcut)
    }

    /// 四格全关 = 读上来的字没地方摆。这时候**两条触发都不许读**：白跑一趟无障碍调用，
    /// 还会在日志里留下一句「弹气泡：0 个字符」这种看着像坏了的话。
    func testNoCellsStopsBothTriggersButLeavesTheMasterAlone() {
        let empty = SelectionBubbleSettings(enabled: true,
                                            shortcut: StorageDefaults.selectionPopupShortcut,
                                            readDelay: 0.25,
                                            actions: [])
        XCTAssertFalse(empty.hasCells)
        XCTAssertFalse(empty.popsOnSelection)
        XCTAssertFalse(empty.popsOnShortcut)
        // monitorShortcut 不看 actions：那只 monitor 占不占键位只由两条开关决定，
        // 格子关着时按下去只是不弹，不至于连键都哑。
        XCTAssertEqual(empty.monitorShortcut, StorageDefaults.selectionPopupShortcut)
    }

    // MARK: - 四格各自的开关

    /// 默认四格全开（总开关才是那一道门）；关掉任意一格，读回来的 `actions` 少一格，
    /// 而**顺序不变** —— 勾选先后决定格子顺序的话，气泡每次弹出来位置都在跳。
    func testActionsDefaultOnAndKeepTheEnumOrder() {
        let fresh = SelectionBubbleSettings.current(from: storage)
        XCTAssertEqual(fresh.actions, SelectionBubbleAction.allCases, "出厂四格全开，顺序照枚举")

        storage.setBool(false, forKey: .selectionPopupActionTranslate)
        storage.setBool(false, forKey: .selectionPopupActionCopy)
        XCTAssertEqual(SelectionBubbleSettings.current(from: storage).actions, [.search, .speak],
                       "关掉的两格要没影，剩下两格还得按枚举顺序排")
    }

    /// 一格一个键：漏接一根线，界面上那颗开关拨了没反应（这一条就是防那个的）。
    func testEveryActionHasItsOwnStorageKeyAndDefault() {
        let keys = SelectionBubbleAction.allCases.map(\.storageKey)
        XCTAssertEqual(Set(keys).count, keys.count, "四格共用一个键 = 关一格关四格")
        for action in SelectionBubbleAction.allCases {
            XCTAssertTrue(action.defaultEnabled, "\(action.rawValue) 默认要开：门是总开关")
            storage.setBool(false, forKey: action.storageKey)
            XCTAssertEqual(SelectionBubbleSettings.current(from: storage).actions,
                           SelectionBubbleAction.allCases.filter { $0 != action },
                           "只关 \(action.rawValue) 时少的必须只有它自己")
            storage.setBool(true, forKey: action.storageKey)
        }
    }

    /// 文案 key 也得一格一条：四格标题撞成同一句，偏好页那四行就分不出谁是谁（气泡上的
    /// 无障碍标签同样用这个 key，撞了一起糊）。
    func testActionTitleAndHintKeysAreDistinct() {
        let titles = SelectionBubbleAction.allCases.map(\.titleKey)
        let hints = SelectionBubbleAction.allCases.map(\.hintKey)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(Set(hints).count, hints.count)
        for action in SelectionBubbleAction.allCases {
            XCTAssertFalse(action.symbol.isEmpty)
        }
    }

    // MARK: - 搜索走哪一家

    /// 快照要把库里那一家和那一栏**原样**递给消费端（`searchTarget`）。
    /// 这一条走的是真 `PreferencesStorage`：纯函数那几条在 `SelectionBubbleSearchEngineTests`
    /// 里逐家核过，这里只核「读库到递出去」那一根线有没有接错键名 —— 接错的表现是
    /// 「下拉里点了必应，气泡还开 Google」，界面上完全看不出来。
    func testSearchTargetFollowsTheEngineInTheStore() {
        XCTAssertEqual(SelectionBubbleSettings.current(from: storage).searchTarget.template,
                       SelectionBubbleSearchEngine.google.template, "没存过就走默认那一家")

        storage.setString("baidu", forKey: .selectionPopupSearchEngine)
        var target = SelectionBubbleSettings.current(from: storage).searchTarget
        XCTAssertEqual(target.template, SelectionBubbleSearchEngine.baidu.template)
        XCTAssertFalse(target.copiesTextFirst, "百度是搜索结果页，不该动粘贴板")

        storage.setString("doubao", forKey: .selectionPopupSearchEngine)
        target = SelectionBubbleSettings.current(from: storage).searchTarget
        XCTAssertEqual(target.template, SelectionBubbleSearchEngine.doubao.template)
        XCTAssertTrue(target.copiesTextFirst, "豆包那一页不吃 URL 预填，得先替用户放进粘贴板")

        storage.setString("kimi", forKey: .selectionPopupSearchEngine)
        storage.setString("https://wiki.corp/?s={query}", forKey: .selectionPopupSearchCustomURL)
        target = SelectionBubbleSettings.current(from: storage).searchTarget
        XCTAssertEqual(target.template, SelectionBubbleSearchEngine.kimi.template,
                       "没选自定义时那一栏一个字都不许参与")
    }

    /// 选了自定义 + 那一栏的各种写法：能用就用，不能用退回默认那一家（不是退回「空模板」）。
    func testSearchTargetWithTheCustomEngine() {
        storage.setString("custom", forKey: .selectionPopupSearchEngine)
        for broken in ["", "   ", "不是网址"] {
            storage.setString(broken, forKey: .selectionPopupSearchCustomURL)
            let target = SelectionBubbleSettings.current(from: storage).searchTarget
            XCTAssertEqual(target.template, SelectionBubbleSearchEngine.google.template,
                           "自定义填了 \(broken.isEmpty ? "空" : broken) 应当退回默认那一家")
        }
        storage.setString("https://wiki.corp/?s={query}", forKey: .selectionPopupSearchCustomURL)
        var target = SelectionBubbleSettings.current(from: storage).searchTarget
        XCTAssertEqual(target.template, "https://wiki.corp/?s={query}")
        XCTAssertFalse(target.copiesTextFirst)

        storage.setString("https://ai.corp.local/chat", forKey: .selectionPopupSearchCustomURL)
        target = SelectionBubbleSettings.current(from: storage).searchTarget
        XCTAssertEqual(target.template, "https://ai.corp.local/chat")
        XCTAssertTrue(target.copiesTextFirst, "自定义不带占位符 = 只要打开那一页，那就得先放粘贴板")
    }

    /// 两家一格一键：引擎和自定义模板各存各的键，改一个不许动另一个。
    /// 共用一键的坏法很隐蔽 —— 下拉里选完自定义，之前存的模板就被当成 id 认不出来了。
    func testEngineAndCustomTemplateHaveTheirOwnKeys() {
        XCTAssertNotEqual(StorageKey.selectionPopupSearchEngine.rawValue,
                          StorageKey.selectionPopupSearchCustomURL.rawValue)
        storage.setString("so360", forKey: .selectionPopupSearchEngine)
        storage.setString("https://wiki.corp/?s={query}", forKey: .selectionPopupSearchCustomURL)
        let settings = SelectionBubbleSettings.current(from: storage)
        XCTAssertEqual(settings.searchEngine, .so360)
        XCTAssertEqual(settings.searchCustomURL, "https://wiki.corp/?s={query}")
        // 只改引擎，那一栏必须原样还在（切回别家再切回自定义时不必重打一遍）。
        storage.setString("google", forKey: .selectionPopupSearchEngine)
        XCTAssertEqual(SelectionBubbleSettings.current(from: storage).searchCustomURL,
                       "https://wiki.corp/?s={query}")
    }

    /// 库里存了个认不出的 id（手改 plist / 从别的版本带过来）：快照退回默认那一家，
    /// 而且 `Equatable` 要比得出来 —— App 层是按快照差异决定重不重挂监听的。
    func testUnreadableEngineIdStillProducesADifferentSnapshot() {
        let base = SelectionBubbleSettings.current(from: storage)
        storage.setString("nope", forKey: .selectionPopupSearchEngine)
        XCTAssertEqual(SelectionBubbleSettings.current(from: storage).searchEngine, .google)
        XCTAssertEqual(SelectionBubbleSettings.current(from: storage), base,
                       "脏串退回的和出厂的一样，快照不该被它搅动")
        storage.setString("bing", forKey: .selectionPopupSearchEngine)
        XCTAssertNotEqual(SelectionBubbleSettings.current(from: storage), base,
                          "换了一家没被比出来：改了下拉不动功能")
    }

    // MARK: - 打开之后自动补那一次 ⌘V

    /// 出厂必须是**关**：这一手是我们往用户的前台窗口里投按键，而且是投进一个我们看不见
    /// 光标落在哪儿的网页。和总开关、代按 ⌘C 同等待遇 —— 没点头之前一次都不该发生。
    ///
    /// 反向变异（默认值翻成 true）由这一条咬住。顺带钉「它有自己的键」和「它进得了
    /// Equatable」：App 层 `main.swift` 是按整份快照的差异决定重不重挂监听、重不重造控制器的，
    /// 漏进比较的话装机时拨了开关要等下次启动才生效，界面上看着是「开关坏了」。
    func testAutoPasteIsOffByDefaultAndHasItsOwnKey() {
        XCTAssertFalse(StorageDefaults.selectionPopupAutoPaste, "自动贴默认必须是关")
        // 一格一键：和代按 ⌘C 那一颗共用键名的话，「开自动贴」会顺手把代按关掉 ——
        // 界面上两颗开关看着各动各的，库里其实是一根线（同「两家一格一键」那一条的理由）。
        XCTAssertNotEqual(StorageKey.selectionPopupAutoPaste.rawValue,
                          StorageKey.selectionPopupCopyFallback.rawValue)
        let fresh = SelectionBubbleSettings.current(from: storage)
        XCTAssertFalse(fresh.autoPasteAfterOpen, "没存过 = 出厂那一份")
        XCTAssertEqual(fresh.searchTarget.copiesTextFirst,
                       SelectionBubbleSearchEngine.google.resolvedTemplate(customURL: "").copiesTextFirst)

        storage.setBool(true, forKey: .selectionPopupAutoPaste)
        let on = SelectionBubbleSettings.current(from: storage)
        XCTAssertTrue(on.autoPasteAfterOpen)
        XCTAssertEqual(on.copyFallbackEnabled, fresh.copyFallbackEnabled,
                       "开自动贴把「代按 ⌘C」也改了：两颗开关共用了一个键名")
        XCTAssertNotEqual(on, fresh, "换了这个开关，快照要比得出来（App 层靠差异重建）")
        // 只动这一颗：其余那十三个数不许跟着变（接错键的话在这里会红）。
        var expected = fresh
        expected.autoPasteAfterOpen = true
        XCTAssertEqual(on, expected, "自动贴串到了别的键上")
    }

    /// 「排不排这一手」的四道闸，一闸一条：每道单独都能把这一手整个拦掉。
    /// 这是本功能最要紧的一张表 —— 少一条就是「在用户没打算填的框里打了一句莫名其妙的话」。
    ///
    /// 其中最容易被写坏的是 `copiesTextFirst`：Google / 百度那六家**没往粘贴板写过东西**，
    /// 这时候补 ⌘V 贴出去的是用户先前自己复制的别人的内容。曾经有人把它理解成
    /// 「开了自动贴就每家有贴」，这条用例就是把那个理解钉死。
    func testEveryAutoPasteGuardBlocksItAlone() {
        func probe(enabled: Bool = true, actions: [SelectionBubbleAction] = SelectionBubbleAction.allCases,
                   autoPaste: Bool = true, engine: SelectionBubbleSearchEngine = .doubao,
                   shortcut: String = StorageDefaults.selectionPopupShortcut) -> Bool {
            SelectionBubbleSettings(enabled: enabled, shortcut: shortcut, readDelay: 0.25,
                                    actions: actions, searchEngine: engine,
                                    autoPasteAfterOpen: autoPaste).searchAutoPaste
        }
        XCTAssertTrue(probe(), "该上场的时候没上场：豆包 + 全开 + 用户点头")
        XCTAssertFalse(probe(enabled: false), "总开关关掉还投按键")
        XCTAssertFalse(probe(actions: []), "四格全关还投按键")
        XCTAssertFalse(probe(autoPaste: false), "用户没点头还投按键")
        XCTAssertFalse(probe(engine: .bing), "那一家的字在 URL 里、没写粘贴板，不该贴")
        XCTAssertFalse(probe(engine: .google), "同上")
        // 单纯 ⌘C（8）不是 ⌘V（9）：那组配法要拦的是「代按 ⌘C」那一路，不该顺手把 ⌘V 也拦掉。
        XCTAssertFalse(probe(shortcut: "keyCode=9, flags=1048576"), "气泡快捷键录成单纯 ⌘V 时必须拆环")
        XCTAssertTrue(probe(shortcut: StorageDefaults.historyCilpboardListShortcut),
                      "粘贴板历史那组 ⌥⌘V 不会自激（修饰键不是只剩 ⌘），不该跟着一起拦掉")
        XCTAssertTrue(probe(shortcut: "keyCode=37, flags=1048576"),
                      "单纯 ⌘L 之类不相干的键位不该误伤")
    }

    /// 自定义那一栏决定这一手上不上场 —— 判据是模板带不带 `{query}`，**不是**「选的是哪一家」。
    /// 和「要不要写粘贴板」共用同一条规则，所以这里连那一条一起钉：两处各判一遍迟早对不上。
    func testAutoPasteFollowsTheTemplateRatherThanTheBrand() {
        func autoPaste(_ template: String) -> Bool {
            SelectionBubbleSettings(enabled: true, shortcut: StorageDefaults.selectionPopupShortcut,
                                    readDelay: 0.25, searchEngine: .custom, searchCustomURL: template,
                                    autoPasteAfterOpen: true).searchAutoPaste
        }
        XCTAssertTrue(autoPaste("https://ai.corp.local/chat"), "不带占位符 = 靠粘贴板，那就该补 ⌘V")
        XCTAssertFalse(autoPaste("https://wiki.corp/?s={query}"), "带占位符 = URL 已经吃进去了")
        // 那一栏坏掉时退回默认那一家（Google），这一手跟着不上场 —— 不是「退回空模板然后乱贴」。
        XCTAssertFalse(autoPaste("不是网址"))
    }

    /// 到点那一刻的两道闸：四种组合都要有答复，而且**同时不过时报粘贴板那一条**。
    ///
    /// 顺序不是随便排的：粘贴板里换了东西还照投，等于把别人的内容打进一个他没打算填的框，
    /// 比「贴到我们自己窗口」（顶多这一下没效果）更坏。日志里那句「为什么这次没贴」
    /// 是装机唯一的凭据，所以这里的顺序会被 `autoPasteLogLine` 直接引用。
    func testPasteGateAnswersFourCombinationsWithThePasteboardFirst() {
        XCTAssertEqual(SelectionBubbleSettings.pasteGate(pasteboardStillHoldsOurText: true,
                                                        frontIsOurOwnApp: false), .inject)
        XCTAssertEqual(SelectionBubbleSettings.pasteGate(pasteboardStillHoldsOurText: false,
                                                        frontIsOurOwnApp: false), .pasteboardChanged)
        XCTAssertEqual(SelectionBubbleSettings.pasteGate(pasteboardStillHoldsOurText: true,
                                                        frontIsOurOwnApp: true), .frontIsOurs)
        XCTAssertEqual(SelectionBubbleSettings.pasteGate(pasteboardStillHoldsOurText: false,
                                                        frontIsOurOwnApp: true), .pasteboardChanged,
                       "两道都不过时报粘贴板那一条：那是更坏的错法")
    }

    /// 只有「单纯 ⌘V」这一组会命中：修饰键比的是标准那四位的**全套**，和 `ShortcutMonitor`
    /// 同一套口径（录制框会把左右侧那些设备位一并存进来，严格相等比不出「看起来一样」）。
    /// 默认那组 ⌃⌘B 和粘贴板历史那组 ⌥⌘V 都不该命中 —— 误伤了就是「功能看着能开，其实永远不上场」。
    func testPlainCommandVMatchesOnlyBareCommandV() {
        XCTAssertEqual(SelectionCopyReader.pasteKeyCode, 9, "V 的 Carbon 键码是 9")
        XCTAssertTrue(SelectionBubbleSettings.isPlainCommandV("keyCode=9, flags=1048576"))
        // 录制框会把「左边那枚 ⌘」这类设备位一并存进 flags，掩掉标准四位之外的那半仍要认。
        XCTAssertTrue(SelectionBubbleSettings.isPlainCommandV("keyCode=9, flags=1048584"))
        for notPlain in ["keyCode=9, flags=1572864",        // ⌥⌘V（粘贴板历史那组的默认值）
                         "keyCode=9, flags=1310720",        // ⌃⌘V（气泡默认那组用的就是这两个位）
                         "keyCode=9, flags=1179648",        // ⇧⌘V（截图取字那组的修饰键）
                         "keyCode=9, flags=262144",         // 只有 ⌃，连 ⌘ 都没有
                         "keyCode=9, flags=0",              // 裸按 V
                         "keyCode=8, flags=1048576",        // 单纯 ⌘C：那是另一路的环
                         "keyCode=37, flags=1048576",       // 单纯不相干的键位
                         "", "keyCode=abc, flags=xyz", "keyCode=9"] {
            XCTAssertFalse(SelectionBubbleSettings.isPlainCommandV(notPlain), "\(notPlain) 不该命中")
        }
        XCTAssertFalse(SelectionBubbleSettings.isPlainCommandV(StorageDefaults.selectionPopupShortcut),
                       "默认那组 ⌃⌘B 把自己拦掉的话，这一手永远上不了场")
    }

    /// 等待时长是个手感阈值，不给偏好页铺控件（理由见字段注释），但得有个数摆着：
    /// 有人把它当魔法数改成一秒一秒往上加，装机时「有时贴上有时贴不上」就没法解释了。
    /// 上限之外还有 `autoHideAfter`（气泡 6 秒自收）—— 1.2 秒必须落在它里面，否则
    /// 「用快捷键唤出的那一次」会先收掉再贴，成了一件谁也没要求的事。
    func testAutoPasteDelayIsTheDocumentedNumberInsideTheBubbleLifetime() {
        XCTAssertEqual(SelectionBubbleSettings.autoPasteDelay, 1.2)
        XCTAssertLessThan(SelectionBubbleSettings.autoPasteDelay, SelectionBubbleSettings.autoHideAfter)
        XCTAssertGreaterThan(SelectionBubbleSettings.autoPasteDelay,
                             SelectionBubbleSettings.current(from: storage).readDelay,
                             "比读取延迟还短的话，字还没读出来就先贴了")
    }
}
