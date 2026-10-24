//
//  SelectionBubbleSearchEngine.swift
//  MacStroke
//
//  气泡上「搜索」那一格走哪一家：六家搜索引擎 + 八家网页 AI + 一条自定义。
//
//  为什么是「一张表 + 一个模板」而不是「一家一段 if」：各家吃的查询参数名不一样
//  （`q` / `wd` / `query`），网页 AI 那几家还各家不一样、并且**官方没有承诺过 URL 预填**。
//  把差异压成一个模板，代码里就只剩一条规则，剩下的都是数据；将来某家改了参数名、
//  或者用户想加第十五行，改一行表就够，不用碰控制器。
//
//  **行为只看模板，不看名单**（这条是整个文件的前提）：
//   - 模板里有 `{query}` → 查询拼进 URL，浏览器打开就是结果页 / 已填好的提问框；
//   - 模板里没有 `{query}` → 只打开那一页，**先把选中的字写进粘贴板**，用户在页面里 ⌘V。
//  所以「这一家到底吃不吃预填」不写死在代码里，写在表里；用户从偏好页改一个字就能切换。
//
//  网页 AI 那几家为什么**默认都再复制一遍**（哪怕模板带了占位符）：社区里 ChatGPT 的
//  `?q=` 属于「有时认、有时不认、还会把参数吞掉」那一类，官方没有文档承诺；复制那一下
//  成本是三行代码和粘贴板里多一条正常记录，换来的是「这一家哪天又不认了，页面打开后
//  ⌘V 照样能问」。搜索那六家不吃这一套，是因为结果页压根不需要粘贴板，多写一次只是弄脏
//  用户刚复制的东西。
//

import Foundation
import Storage

/// 一家能问东西的网页。rawValue 就是存进偏好里的那个 id，**别改名**（改了老用户的选项会退回默认）。
public enum SelectionBubbleSearchEngine: String, CaseIterable {
    // 搜索引擎：这六家都稳定吃 URL 查询参数。
    case google
    case bing
    case duckduckgo
    case baidu
    case sogou
    case so360
    // 网页 AI：能不能预填各家不同，见上面那段。
    case chatgpt
    case copilot
    case perplexity
    case gemini
    case deepseek
    case doubao
    case kimi
    case tongyi
    /// 用偏好页那个文本框里写的模板。空的时候按 `SelectionBubbleSettings.searchTemplate` 的退回走。
    case custom

    /// 三类。只有 `.ai` 会「顺手把字复制进粘贴板」，`.search` 不会；
    /// `.custom` **单列一类**而不是算进搜索那组：它到底复制不复制要看模板里有没有占位符
    /// （`resolvedTemplate` 那一处判），把它归进任何一组都会让 `searchEngines` / `aiEngines`
    /// 这两个下拉分组多出一条不该有的行。
    public enum Kind { case search, ai, custom }

    public var kind: Kind {
        switch self {
        case .google, .bing, .duckduckgo, .baidu, .sogou, .so360: return .search
        case .chatgpt, .copilot, .perplexity, .gemini, .deepseek, .doubao, .kimi, .tongyi: return .ai
        case .custom: return .custom
        }
    }

    /// `{query}` 会被换成选中的字；**没有这个占位符 = 这一家只打开页面**。
    public var template: String {
        switch self {
        case .google: return "https://www.google.com/search?q={query}"
        case .bing: return "https://www.bing.com/search?q={query}"
        case .duckduckgo: return "https://duckduckgo.com/?q={query}"
        case .baidu: return "https://www.baidu.com/s?wd={query}"
        case .sogou: return "https://www.sogou.com/web?query={query}"
        case .so360: return "https://www.so.com/s?q={query}"
        case .chatgpt: return "https://chatgpt.com/?q={query}"
        case .copilot: return "https://copilot.microsoft.com/?q={query}"
        case .perplexity: return "https://www.perplexity.ai/search?q={query}"
        case .gemini: return "https://gemini.google.com/app"
        case .deepseek: return "https://chat.deepseek.com/"
        case .doubao: return "https://www.doubao.com/chat/"
        case .kimi: return "https://kimi.moonshot.cn/"
        case .tongyi: return "https://www.tongyi.com/"
        case .custom: return ""
        }
    }

    /// 下拉里那一个字。专有名词（Google、ChatGPT…）在两份 .strings 里写成同名，
    /// 「自定义」那一条才翻 —— 必须有条目，否则 `L()` 找不到 key 就把 key 原样画出来，
    /// 下拉里会出现一条 "Selection bubble engine google"。
    public var titleKey: String { "Selection bubble engine \(rawValue)" }

    /// 从偏好里读「此刻该走哪一家」。读到一个不认识的 id（手改过 plist、或从别的版本带过来的）
    /// 退回 `StorageDefaults.selectionPopupSearchEngine` 那一家，而不是退回 `google`：
    /// 退回到哪一家由默认值那处说了算，代码里不该有两个答案。
    public static func current(in storage: PreferencesStorage = PreferencesStorage()) -> SelectionBubbleSearchEngine {
        from(rawValue: storage.getStringOptional(forKey: StorageKey.selectionPopupSearchEngine))
    }

    /// 库里那一串 → 哪一家。**界面和消费端都走这一句**：偏好页那个下拉的 `get` 也用它，
    /// 于是「认不出的串」在两边退回同一家 —— 页面显示一条下拉里没有的串会画成空白，
    /// 看上去像页面坏了，实际坏的是偏好。
    /// nil（压根没存过）同样按默认值那一条处理。
    public static func from(rawValue raw: String?) -> SelectionBubbleSearchEngine {
        allCases.first { $0.rawValue == raw }
            ?? allCases.first { $0.rawValue == StorageDefaults.selectionPopupSearchEngine }
            ?? .google
    }

    /// 下拉里第一组（六家搜索）。**由 `kind` 筛出来，不由页面写死名单**：
    /// 表里加一家只要在声明处把 `case` 和 `template`、`kind` 补上，下拉自动多一行；
    /// 页面自己排一遍顺序的话，就会出现在表里、不在界面里那种对不上。
    public static var searchEngines: [SelectionBubbleSearchEngine] { allCases.filter { $0.kind == .search } }
    /// 下拉里第二组（八家网页 AI）。
    public static var aiEngines: [SelectionBubbleSearchEngine] { allCases.filter { $0.kind == .ai } }

    /// 这一家此刻该用的模板 + 该不该先替用户把字放进粘贴板。**整条功能唯一的判定口**，
    /// 控制器只问它，自己不再判 kind、也不再判占位符。
    ///
    /// - Parameter customURL: 偏好里那个自定义模板。只有选了 `.custom` 才看它；
    ///   选了自定义却什么都没写（或写得根本不像个网址）时退回默认那一家 —— 「一格配坏了，
    ///   整格没反应」是最难查的坏，宁可退回一家能用的。
    public func resolvedTemplate(customURL: String) -> (template: String, copiesTextFirst: Bool) {
        guard self == .custom else {
            return (template, kind == .ai)
        }
        let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeURL(trimmed) else {
            // 退回那一家由 `from` 那句算（和界面、消费端读库同一个入口），这里不再自己拼一遍。
            let fallback = Self.from(rawValue: StorageDefaults.selectionPopupSearchEngine)
            return (fallback.template, fallback.kind == .ai)
        }
        // 自定义这一条没有「它是搜索还是 AI」的信息，只能看模板：不带占位符就说明用户要的是
        // 「打开那一页」，那一段字不替他放进粘贴板就白跑一趟。
        // 判据用 `SelectionBubbleLinks.prefillsQuery` —— 和拼装那一头同一个函数，
        // 两边各写一份 `contains("{query}")` 的话，改占位符名只会改到一处，另一处静默失效。
        return (trimmed, !SelectionBubbleLinks.prefillsQuery(trimmed))
    }

    /// 「像个网址」的最低判据：**`://` 之前得真有东西**（那就是 scheme），别的都不查。
    /// 只判这一样，别在这儿做域名合法性校验 —— 用户写 `127.0.0.1:8000/?q={query}`、
    /// `mycorpdomain/search?q={query}` 都可能真能用，多判一条就多挡一刀。
    /// 也不查「`://` 只出现一次」：`https://go/?u=http://x` 这种把网址当参数的写法是真需求。
    ///
    /// **public 是给偏好页那句黄字用的**（「填了才走自定义，不然退回默认那一家」）：
    /// 页面自己再判一遍「够不够像个网址」，就会出现开关画的是 A、消费端走的是 B。
    public static func looksLikeURL(_ text: String) -> Bool {
        guard let separator = text.range(of: "://") else { return false }
        return separator.lowerBound != text.startIndex
    }
}
