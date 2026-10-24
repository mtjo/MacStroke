//
//  SelectionBubbleSearchEngineTests.swift
//  SelectionPopupTests
//
//  「搜索走哪一家」那张表的取证。这一张表是**数据**，六家搜索 + 八家网页 AI + 一条自定义，
//  而整条功能只有**一条行为规则**：模板里有没有 `{query}`。
//  所以这里最贵的几条都不是「某家拼出来长什么样」，而是那条规则在三种来源下都成立：
//  - 搜索那六家：字进 URL，**一次都不碰粘贴板**（结果页用不着它，多写一次只是弄脏用户刚复制的东西）
//  - 网页 AI 那八家：**一律先写粘贴板**（`?q=` 那类预填官方没有文档承诺，时灵时不灵；
//    复制那一下换来的是「页面打开后 ⌘V 照样能问」，而不是「页面开了、字没进去、也没人替他复制」）
//  - 自定义那一条：没有 kind 可依据，只能看模板认不认识占位符 —— 和拼装那一头共用
//    `SelectionBubbleLinks.prefillsQuery` 这一句，两边各写一份 `contains("{query}")`
//    就会在改占位符名时只改到一处，另一处静默失效。
//
//  第二条贵的是**退回**：库里存了个认不出的 id、或者选了自定义却什么都没填，
//  两种坏都必须退回一家**能用的**，而不是「这一格压根没反应」。
//  界面上「配了但没生效」是最难查的坏 —— 用户看到的是自己配的那一家，跑的却是另一家，
//  所以退回的那一家还要和偏好页显示的同一家（两边都走 `from(rawValue:)`）。
//

import Foundation
import Storage
import XCTest
@testable import SelectionPopup

final class SelectionBubbleSearchEngineTests: XCTestCase {
    private let query = "划词 search"
    private var encoded: String { SelectionBubbleLinks.encoded(query) }

    /// 表的形状：十五行、id 唯一、除了自定义每行都有自己的 https 模板。
    /// 加一行时这条会先红提醒你补 `template`（漏补就是空串 → 那一格点开什么也没有）。
    func testTheTableHoldsFifteenRowsEachWithItsOwnTemplate() {
        XCTAssertEqual(SelectionBubbleSearchEngine.allCases.count, 15)
        XCTAssertEqual(Set(SelectionBubbleSearchEngine.allCases.map(\.rawValue)).count, 15,
                       "rawValue 撞车：存进偏好的 id 就不唯一了")
        XCTAssertEqual(Set(SelectionBubbleSearchEngine.allCases.map(\.titleKey)).count, 15,
                       "文案 key 撞车：下拉里两行会显示同一句")
        for engine in SelectionBubbleSearchEngine.allCases where engine != .custom {
            XCTAssertTrue(engine.template.hasPrefix("https://"),
                          "\(engine.rawValue) 的模板不像个网址：\(engine.template)")
            XCTAssertFalse(engine.template.hasSuffix("{query}=="), "\(engine.rawValue) 模板尾巴写坏了")
        }
        XCTAssertEqual(SelectionBubbleSearchEngine.custom.template, "",
                       "自定义那一行自己不该有模板，它看的是偏好里那一栏")
    }

    /// 分组必须把十五行**不重不漏**地分完，且顺序就是声明顺序。
    /// 页面那两个 `ForEach` 直接吃这两个数组：漏一行就是「表里加了、下拉里没有」。
    func testTheTwoGroupsPlusCustomPartitionTheTable() {
        let search = SelectionBubbleSearchEngine.searchEngines
        let ai = SelectionBubbleSearchEngine.aiEngines
        XCTAssertEqual(search.count, 6, "搜索引擎那组：Google、必应、DuckDuckGo、百度、搜狗、360")
        XCTAssertEqual(ai.count, 8, "网页 AI 那组：ChatGPT、Gemini、Copilot、Perplexity、DeepSeek、豆包、Kimi、通义")
        XCTAssertTrue(search.isEmpty || search.allSatisfy { $0.kind == .search })
        XCTAssertTrue(ai.allSatisfy { $0.kind == .ai })
        XCTAssertEqual(search + ai + [.custom], SelectionBubbleSearchEngine.allCases,
                       "下拉里的顺序就是表的声明顺序：两边对不上就是有人漏分组或改了顺序")
        // 自定义单列一类（不是塞进搜索组），否则它会在下拉第一组里冒出来一行。
        XCTAssertEqual(SelectionBubbleSearchEngine.custom.kind, .custom)
    }

    /// 默认那一家必须是 Google —— 3.1.x 时代模板写死的就是它，升级完行为不许变。
    /// 这条也是「认不出的串退回哪家」的那一处根据（`from(rawValue:)` 拿的就是这个默认值）。
    func testTheDefaultEngineIsTheOneWeUsedToHardcode() {
        XCTAssertEqual(StorageDefaults.selectionPopupSearchEngine, "google")
        XCTAssertEqual(SelectionBubbleSearchEngine.google.template, SelectionBubbleLinks.searchTemplate,
                       "表里的 Google 模板和拼装那边那份兜底模板必须一模一样")
    }

    /// 六家搜索：字**百分号编码后**进 URL，一家都不许碰粘贴板。
    /// 编码这一手在 `SelectionBubbleLinksTests` 里逐条核过，这里核的是「每家都吃这一套」——
    /// 漏一家（模板里忘了写占位符）表现是「选了它以后要点 ⌘V」，而那一家的 `copiesTextFirst`
    /// 是 false，用户什么都不会知道。
    func testEverySearchEngineCarriesTheQueryInTheURL() {
        for engine in SelectionBubbleSearchEngine.searchEngines {
            let target = engine.resolvedTemplate(customURL: "")
            XCTAssertTrue(SelectionBubbleLinks.prefillsQuery(target.template),
                          "\(engine.rawValue) 的模板里没有占位符")
            XCTAssertFalse(target.copiesTextFirst, "\(engine.rawValue) 是搜索页，不该动粘贴板")
            let url = SelectionBubbleLinks.searchURL(query, template: target.template)
            XCTAssertEqual(url?.absoluteString.contains(encoded), true,
                           "\(engine.rawValue) 没把字拼进 URL：\(url?.absoluteString ?? "nil")")
            // 参数名各家不同（q / wd / query），但**只有一个查询段**：多出来的是选中内容顶开的。
            let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
            XCTAssertEqual(items.count, 1, "\(engine.rawValue) 拼出来的查询段不止一段")
            XCTAssertEqual(items.first?.value, query, "\(engine.rawValue) 解码回来不是原样那段字")
        }
    }

    /// 八家网页 AI：**一律先把字放进粘贴板**，不管模板带不带占位符。
    /// 带占位符的那三家是「双保险」（URL 里带着、粘贴板里也放着），
    /// 因为 `?q=` 这类预填属于社区里时灵时不灵的那种，官方没有文档承诺过。
    func testEveryAIEntryCopiesTheTextFirst() {
        for engine in SelectionBubbleSearchEngine.aiEngines {
            let target = engine.resolvedTemplate(customURL: "")
            XCTAssertTrue(target.copiesTextFirst,
                          "\(engine.rawValue) 是网页 AI：不先放粘贴板，页面打开后没地方贴")
        }
        // 带占位符的那几家顺手核对字真进了 URL（预填哪天又能用了，这一手不白做）。
        for engine in SelectionBubbleSearchEngine.aiEngines where SelectionBubbleLinks.prefillsQuery(engine.template) {
            XCTAssertTrue(SelectionBubbleLinks.searchURL(query, template: engine.template)?
                              .absoluteString.contains(encoded) ?? false,
                          "\(engine.rawValue) 说好了带占位符，却没把字拼进去")
        }
    }

    /// 不吃预填的那几家（Gemini、DeepSeek、豆包、Kimi、通义）：**只打开那一页，URL 一个字节都不许改**。
    /// 这条是删掉旧兜底的另一半代价：旧代码会给不带占位符的模板补一个 `&q=`，
    /// 现在不许补 —— 补了就是替用户猜参数名，猜错的样子恰好和「这一家不支持」一模一样。
    func testAIEnginesWithoutAPrefillOpenTheirOwnPageUntouched() {
        var plain: [SelectionBubbleSearchEngine] = []
        for engine in SelectionBubbleSearchEngine.aiEngines where !SelectionBubbleLinks.prefillsQuery(engine.template) {
            plain.append(engine)
            let url = SelectionBubbleLinks.searchURL(query, template: engine.resolvedTemplate(customURL: "").template)
            XCTAssertEqual(url?.absoluteString, engine.template,
                           "\(engine.rawValue) 那一页被加了查询：\(url?.absoluteString ?? "nil")")
        }
        XCTAssertEqual(plain.count, 5, "五家：Gemini、DeepSeek、豆包、Kimi、通义。数目变了说明表动过，回来核一遍")
    }

    /// 自定义填得不像个网址 —— 空、纯空白、缺 scheme —— 退回**默认那一家**，而不是退回「没模板」。
    /// 「一格配坏了、整格没反应」是最难查的坏：用户点了放大镜，浏览器什么都不开，
    /// 而他看不出自己哪一栏写坏了。
    func testCustomFallsBackToTheDefaultEngineWhenTheFieldIsNotAURL() {
        let fallback = SelectionBubbleSearchEngine.from(rawValue: StorageDefaults.selectionPopupSearchEngine)
        for garbage in ["", "   ", "not a url", "wiki.corp/search?q={query}", "://缺个host"] {
            let target = SelectionBubbleSearchEngine.custom.resolvedTemplate(customURL: garbage)
            XCTAssertEqual(target.template, fallback.template, "自定义填了 \(garbage) 的退回不对")
            XCTAssertEqual(target.copiesTextFirst, fallback.kind == .ai)
            XCTAssertNotNil(SelectionBubbleLinks.searchURL(query, template: target.template),
                            "退回了却还拼不出 URL：\(garbage)")
        }
        // 判据本身也钉一下：只认「`://` 之前有没有 scheme」，多判一条就多挡一刀
        // （`127.0.0.1:8000/?q={query}`、内网域名、把网址当参数的写法都得放过）。
        XCTAssertTrue(SelectionBubbleSearchEngine.looksLikeURL("http://127.0.0.1:8000/?q={query}"))
        XCTAssertTrue(SelectionBubbleSearchEngine.looksLikeURL("https://wiki.corp.local/s?text={query}"))
        XCTAssertTrue(SelectionBubbleSearchEngine.looksLikeURL("https://go/?u=http://x"),
                      "把网址当参数的那一类不该被第二个 :// 挡掉")
        XCTAssertFalse(SelectionBubbleSearchEngine.looksLikeURL("wiki.corp.local/s?text={query}"))
        XCTAssertFalse(SelectionBubbleSearchEngine.looksLikeURL("://缺个scheme"))
        XCTAssertFalse(SelectionBubbleSearchEngine.looksLikeURL(""))
    }

    /// 自定义那一栏的两种写法都要成立：带占位符 = 拼进 URL 且不碰粘贴板；
    /// 不带 = 只开那一页**并**先替用户复制。这就是「行为只看模板」那条规则。
    func testCustomTemplateBehaviourFollowsOnlyThePlaceholder() {
        let withPlaceholder = SelectionBubbleSearchEngine.custom
            .resolvedTemplate(customURL: "https://wiki.corp/?search={query}&fmt=1")
        XCTAssertFalse(withPlaceholder.copiesTextFirst, "写了占位符就是让 URL 带字，不该再动粘贴板")
        let url = SelectionBubbleLinks.searchURL(query, template: withPlaceholder.template)
        XCTAssertEqual(url?.absoluteString, "https://wiki.corp/?search=\(encoded)&fmt=1")

        let withoutPlaceholder = SelectionBubbleSearchEngine.custom
            .resolvedTemplate(customURL: "https://chat.corp.local/")
        XCTAssertTrue(withoutPlaceholder.copiesTextFirst, "没写占位符还不复制，就是白开一页")
        XCTAssertEqual(SelectionBubbleLinks.searchURL(query, template: withoutPlaceholder.template)?.absoluteString,
                       "https://chat.corp.local/")
        // 前后空格不算写坏：落盘的那一栏带着空格很常见（复制粘贴来的），要能吃。
        let padded = SelectionBubbleSearchEngine.custom
            .resolvedTemplate(customURL: "  https://wiki.corp/?search={query}  ")
        XCTAssertEqual(padded.template, "https://wiki.corp/?search={query}")
    }

    /// 库里那串认不出来（手改 plist、从别的版本带过来）时退回默认那一家。
    /// **界面和消费端共用这一句**，所以两边退回的是同一家 —— 页面显示一条下拉里没有的串
    /// 会画成空白，看着像页面坏了，实际坏的是偏好。
    func testAnUnreadableStoredIdFallsBackToTheDefaultEngine() {
        let expected = SelectionBubbleSearchEngine.from(rawValue: StorageDefaults.selectionPopupSearchEngine)
        for raw in [nil, "", "Google", "GOOGLE", "qux", "https://www.google.com/search?q={query}"] {
            XCTAssertEqual(SelectionBubbleSearchEngine.from(rawValue: raw), expected,
                           "存了 \(raw.map { "\"\($0)" } ?? "nil") 却没退回默认那一家")
        }
        // 认得出的原样回来：rawValue 就是存进偏好的那个 id，别改名（改了老用户的选项会退回默认）。
        XCTAssertEqual(SelectionBubbleSearchEngine.from(rawValue: "doubao"), .doubao)
        XCTAssertEqual(SelectionBubbleSearchEngine.from(rawValue: "custom"), .custom)
    }

    /// 库里读出来那一路：没存过给默认、存了认不出的串也给默认。
    /// 这一条走的是真 `PreferencesStorage`，上面那几条走的都是纯函数 —— 两边都要有，
    /// 只有纯函数对了、读库那一句接错键名，表现是「下拉里点了必应，实际还走 Google」。
    func testCurrentReadsTheStoredId() {
        let suiteName = "MacStrokeTests.SelectionBubbleEngine"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = PreferencesStorage(defaults: defaults)
        XCTAssertEqual(SelectionBubbleSearchEngine.current(in: storage),
                       SelectionBubbleSearchEngine.from(rawValue: StorageDefaults.selectionPopupSearchEngine))
        storage.setString("sogou", forKey: .selectionPopupSearchEngine)
        XCTAssertEqual(SelectionBubbleSearchEngine.current(in: storage), .sogou)
        storage.setString("nope", forKey: .selectionPopupSearchEngine)
        XCTAssertEqual(SelectionBubbleSearchEngine.current(in: storage), .google, "脏串要退回默认那一家")
    }
}
