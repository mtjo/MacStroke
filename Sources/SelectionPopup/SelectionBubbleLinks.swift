//
//  SelectionBubbleLinks.swift
//  MacStroke
//
//  四格里那两条「开网页」的：搜索、翻译。只做 URL 拼装，不发请求、不开浏览器 ——
//  拼装是纯函数，能在 `swift test` 里逐条核对；开关那一半留给控制器，装机日志里看。
//
//  为什么走网页而不是接 API：接任何翻译服务都要用户填密钥，这条功能的门槛就变成
//  「先注册一个账号」；网页那一版打开的就是浏览器里那个翻译页，认得的人一眼就懂，
//  不认得的人也不缺这一个。同理，朗读用系统自带的 `AVSpeechSynthesizer`，不装东西、
//  不要网络。
//
//  一期这里只有一条写死的 Google 模板。**现在模板进偏好页了**（`SelectionBubbleSearchEngine`
//  那张表 + 那条自选 URL），这个文件退回到它该待的位置：**只做拼装，一家都不认**。
//  认哪家、要不要先替用户复制，是 `SelectionBubbleSearchEngine.resolvedTemplate` 那一处的事。
//

import Foundation

enum SelectionBubbleLinks {
    /// 查询串占位符。
    static let queryPlaceholder = "{query}"
    static let searchTemplate = "https://www.google.com/search?q={query}"
    /// 翻译：源语言 auto，目标语言跟着系统语言走，这样中文环境划英文词是「译成中文」，
    /// 英文环境划德文词是「译成英文」，不用先问用户要哪一对。
    static let translateTemplate = "https://translate.google.com/?sl=auto&tl={lang}&op=translate&text={query}"

    /// 查询串里只留 RFC 3986 的免编码字符。用 `.urlQueryAllowed` 会把 `&` `=` `+` 也放过，
    /// 选中一段带网址的文字去搜索时就把模板后面的参数吃掉了。
    private static let queryAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    /// 这一条模板能不能把查询带进网址。**整个功能只在这一处判占位符**。
    static func prefillsQuery(_ template: String) -> Bool {
        template.contains(queryPlaceholder)
    }

    static func searchURL(_ text: String, template: String = searchTemplate) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard prefillsQuery(template) else {
            // 模板里没有占位符 —— 这一家要的就是「把页面打开」，查询由调用方在**动手之前**
            // 放进粘贴板（见 `resolvedTemplate` 那句 `copiesTextFirst`）。
            // 2.x 这里曾自作聪明地补一个 `&q={query}`：那是替用户猜他要的参数名，
            // 猜错的后果是「页面打开了、字没进去、也没人替他复制」，三头落空。
            // 空模板连页面都没有，返回 nil 让控制器打那行「拼不出链接」，
            // 而不是去开一枚 about:blank —— 正常路径到不了这里（`resolvedTemplate`
            // 认不过的自定义 URL 会退回默认引擎），它是给将来加格子的人留的地板。
            guard !template.isEmpty else { return nil }
            return URL(string: template)
        }
        return URL(string: template.replacingOccurrences(of: queryPlaceholder, with: encoded(trimmed)))
    }

    static func translateURL(_ text: String, targetLanguage: String,
                             template: String = translateTemplate) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let string = template
            .replacingOccurrences(of: "{lang}", with: encoded(targetLanguage))
            .replacingOccurrences(of: queryPlaceholder, with: encoded(trimmed))
        return URL(string: string)
    }

    /// 系统语言 → Google 的语言码（`zh` + 地区 = `zh-CN`）。取不到就退回英文：
    /// 那一档是翻译页默认能认的，猜错语言至少页面还在。
    ///
    /// 「语言-地区」这一对直接可用是实测来的：`Locale.language.languageCode` 已经把书写体归掉了
    /// —— `zh_Hans_CN`、`zh-Hans-CN` 交回来的都是 `zh` + `CN`，`zh_Hant` 交回 `zh` + `TW`
    /// （见 `SelectionBubbleLinksTests.testTargetLanguageFollowsTheLocale`）。
    /// 所以不需要自己拆 `zh-Hans` 那种串，Google 那页要的就是 `zh-CN`。
    static func targetLanguage(from locale: Locale = .current) -> String {
        guard let code = locale.language.languageCode?.identifier, !code.isEmpty else { return "en" }
        guard let region = locale.language.region?.identifier, !region.isEmpty else { return code }
        return "\(code)-\(region)"
    }
}
