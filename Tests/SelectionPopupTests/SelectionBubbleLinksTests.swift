//
//  SelectionBubbleLinksTests.swift
//  SelectionPopupTests
//
//  四格里那两条「开网页」的链接拼装。只验拼串，不发请求、不开浏览器 ——
//  浏览器一开就收不回来，所以真开那一句留给装机日志核对。
//
//  最贵的一条是**选中一段带 `&` `=` 的文字**（网址、查询串、代码）：
//  那两位要是被放过，模板后面的 `&op=translate` 就被吃掉了，翻译页打开是空的、
//  搜索页搜出半截串。界面上只会表现为「点了没反应」，从日志看不出为什么。
//

import Foundation
import XCTest
@testable import SelectionPopup

final class SelectionBubbleLinksTests: XCTestCase {
    /// 普通 ASCII：整串照拼，空格变 %20。
    func testPlainQueryIsPercentEncodedIntoTheTemplate() {
        XCTAssertEqual(SelectionBubbleLinks.searchURL("hello world")?.absoluteString,
                       "https://www.google.com/search?q=hello%20world")
    }

    /// 中文要按 UTF-8 逐字节编码（`划词` = E5 88 92 / E8 AF 8D）。
    /// 这一条也顺手钉住「没有用 ASCII 转写」：写成拼音就是搜不到。
    func testChineseSurvivesAsUTF8Bytes() {
        XCTAssertEqual(SelectionBubbleLinks.searchURL("划词")?.absoluteString,
                       "https://www.google.com/search?q=%E5%88%92%E8%AF%8D")
    }

    /// 带网址的选中内容：`&` `=` `+` `?` 一位都不许漏过去。
    func testSelectedTextCarryingAmpersandsCannotEatTheTemplate() {
        let encoded = SelectionBubbleLinks.encoded("a&b=c+d?e")
        XCTAssertEqual(encoded, "a%26b%3Dc%2Bd%3Fe")
        let search = SelectionBubbleLinks.searchURL("a&b=c+d?e")?.absoluteString
        XCTAssertEqual(search, "https://www.google.com/search?q=a%26b%3Dc%2Bd%3Fe")
        // 拼完仍然只剩一个 `?` 和一段查询：多出来的 `?` 就是被选中内容顶开的。
        XCTAssertEqual(search?.filter { $0 == "?" }.count, 1)
        XCTAssertEqual(search?.split(separator: "?").count, 2)
    }

    /// 翻译那一条有两个参数，串味更难发现：目标语言码被选中内容盖掉，页面就翻成别的语言。
    func testTranslateKeepsItsOwnLanguageParameterAheadOfTheQuery() {
        let url = SelectionBubbleLinks.translateURL("rock&roll", targetLanguage: "zh-CN")?.absoluteString
        XCTAssertEqual(url, "https://translate.google.com/?sl=auto&tl=zh-CN&op=translate&text=rock%26roll")
        let parts = URLComponents(string: url ?? "")?.queryItems ?? []
        XCTAssertEqual(parts.first { $0.name == "tl" }?.value, "zh-CN", "语言码不能被查询串顶掉")
        XCTAssertEqual(parts.first { $0.name == "op" }?.value, "translate")
        XCTAssertEqual(parts.first { $0.name == "text" }?.value, "rock&roll", "解码回来该是原样那段字")
    }

    /// 只有 RFC 3986 的免编码字符原样留着，其余全过百分号。
    func testOnlyUnreservedCharactersPassThrough() {
        XCTAssertEqual(SelectionBubbleLinks.encoded("A-z_9.~"), "A-z_9.~")
        XCTAssertEqual(SelectionBubbleLinks.encoded("#%/:;,"), "%23%25%2F%3A%3B%2C")
    }

    /// 空串和不选中等于没做事：返回 nil，控制器那一头会打一行「拼不出链接」。
    func testEmptyTextYieldsNoURL() {
        XCTAssertNil(SelectionBubbleLinks.searchURL(""))
        XCTAssertNil(SelectionBubbleLinks.searchURL("   \n "))
        XCTAssertNil(SelectionBubbleLinks.translateURL("", targetLanguage: "en"))
    }

    /// 首尾空白不该进链接：搜索引擎自己会裁，但把 %20 塞进 URL 会让装机日志看不出弹的是哪段。
    func testLeadingAndTrailingSpaceIsStrippedBeforeEncoding() {
        XCTAssertEqual(SelectionBubbleLinks.searchURL("  hi  ")?.absoluteString,
                       "https://www.google.com/search?q=hi")
    }

    /// 模板里没有占位符 = 这一家要的就是「把页面打开」，**一个字都不许往 URL 里塞**。
    ///
    /// 2.x 这里曾自作聪明地补 `&q={query}`（替用户猜参数名）。那条兜底删掉的理由写在
    /// `SelectionBubbleSearchEngine` 文件头：猜错的后果是「页面打开了、字没进去、
    /// 也没人替他复制」，而「要不要先替他复制」由模板认不认识占位符说了算 ——
    /// 判据在 `prefillsQuery` 那一处，`resolvedTemplate` 据此决定要不要先动粘贴板。
    func testTemplateWithoutThePlaceholderJustOpensThePage() {
        XCTAssertEqual(SelectionBubbleLinks.searchURL("hi", template: "https://e.com/s")?.absoluteString,
                       "https://e.com/s")
        XCTAssertEqual(SelectionBubbleLinks.searchURL("hi", template: "https://e.com/s?fmt=1")?.absoluteString,
                       "https://e.com/s?fmt=1")
        // 空白模板也拼不出 URL：控制器那一头会打一行「拼不出链接」，而不是开一枚 about:blank。
        XCTAssertNil(SelectionBubbleLinks.searchURL("hi", template: ""))
    }

    /// `prefillsQuery` 是**唯一**那条「认不认识占位符」的判据，两边（引擎表、拼装）都引它。
    /// 各写一份 `contains("{query}")` 的话，将来改占位符名就只有一处改，另一处静默失效。
    func testPrefillsQueryIsTheSinglePlaceholderCheck() {
        XCTAssertTrue(SelectionBubbleLinks.prefillsQuery("https://e.com/s?q={query}"))
        XCTAssertFalse(SelectionBubbleLinks.prefillsQuery("https://e.com/s?q="))
        XCTAssertFalse(SelectionBubbleLinks.prefillsQuery(""))
        // 大写不算：占位符是这里写死的小写串，模板里手打的 {QUERY} 就是不认。
        XCTAssertFalse(SelectionBubbleLinks.prefillsQuery("https://e.com/s?q={QUERY}"))
        // 认占位符 ⇔ 拼得出的 URL 里带上了那段字（两条判据必须同进同退）。
        XCTAssertTrue(SelectionBubbleLinks.prefillsQuery(SelectionBubbleLinks.searchTemplate))
        XCTAssertTrue(SelectionBubbleLinks.searchURL("hi")?.absoluteString.contains("hi") ?? false)
        XCTAssertFalse(SelectionBubbleLinks.prefillsQuery("https://chat.deepseek.com/"))
        XCTAssertEqual(SelectionBubbleLinks.searchURL("hi", template: "https://chat.deepseek.com/")?.absoluteString,
                       "https://chat.deepseek.com/")
    }

    /// 语言码跟着系统语言走：中文环境划英文词是「译成中文」，不用先问用户要哪一对。
    /// 实测 `Locale.language.languageCode` 已经把书写体归掉了（`zh_Hans_CN` 给的是 `zh` + `CN`），
    /// 所以「语言-地区」拼出来正好是 Google 那页认的码；繁体那档跟着地区出 `zh-TW`。
    func testTargetLanguageFollowsTheLocale() {
        XCTAssertEqual(SelectionBubbleLinks.targetLanguage(from: Locale(identifier: "zh_CN")), "zh-CN")
        XCTAssertEqual(SelectionBubbleLinks.targetLanguage(from: Locale(identifier: "zh_Hans_CN")), "zh-CN")
        XCTAssertEqual(SelectionBubbleLinks.targetLanguage(from: Locale(identifier: "zh_Hant_TW")), "zh-TW")
        XCTAssertEqual(SelectionBubbleLinks.targetLanguage(from: Locale(identifier: "en_US")), "en-US")
        // 只有语言、没有地区的那一档：拼不出「语言-地区」就交回裸码（Google 那页也认 `fr`）。
        // 这一条**故意不写死成 "fr-FR"**：`Locale(identifier: "fr")` 到底给不给 region 是 Foundation
        // 的事 —— 本机 2026-10-22 那次 CommandLineTools 更新之前给 "FR"，之后给 nil，实现两种都算对。
        // 判据只钉「跟着 region 走」这一件事，把 Foundation 的归一化留在判据外面；
        // 写死的那一句就是典型的「今天绿、明天红」用例，红的原因跟我们的代码无关。
        let bare = Locale(identifier: "fr")
        XCTAssertEqual(SelectionBubbleLinks.targetLanguage(from: bare),
                       bare.language.region == nil ? "fr" : "fr-FR",
                       "没有地区时该交回裸语言码")
        // 空标识符：某些 Foundation 版本连语言码都不给，那时候兜底成 "en"。
        // 唯一不许的是交回空串 —— 空串进 URL 的 `to=` 参数，翻译页会自己猜，猜什么都不如猜英文。
        XCTAssertTrue(!SelectionBubbleLinks.targetLanguage(from: Locale(identifier: "")).isEmpty,
                      "空标识符也得有一个能用的码")
        // 认不出的语言原样交回：拼错语言顶多页面自己换个默认，不至于打不开。
        XCTAssertEqual(SelectionBubbleLinks.targetLanguage(from: Locale(identifier: "xx_YY")), "xx-YY")
        // 这台机器上真在跑的那个语言必须拼得出一码（Google 的码都是小写-大写）。
        XCTAssertTrue(SelectionBubbleLinks.targetLanguage().range(of: #"^[a-z]{2}(-[A-Z]{2})?$"#,
                                                                options: .regularExpression) != nil,
                      "系统语言拼出的码不像样：\(SelectionBubbleLinks.targetLanguage())")
    }

    /// 控制器剩下的那条转发钉一下，免得两边模板分家。
    /// **搜索那一格不在这里**：它的模板来自偏好（`settings.searchTarget`），控制器里
    /// 压根没有一份写死的搜索模板可分家 —— 曾经有的那条 `searchURL` 转发已随表一起删掉。
    func testControllerForwardsToTheSameBuilder() {
        XCTAssertNotNil(SelectionBubbleController.translateURL("划词"))
        XCTAssertEqual(SelectionBubbleController.translateURL("划词"),
                       SelectionBubbleLinks.translateURL("划词",
                                                         targetLanguage: SelectionBubbleLinks.targetLanguage()))
    }
}
