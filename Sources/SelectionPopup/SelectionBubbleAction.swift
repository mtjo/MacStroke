//
//  SelectionBubbleAction.swift
//  MacStroke
//
//  气泡上那四格的**唯一一份**定义：id、图标、文案 key、各自的偏好键、默认开不开。
//
//  为什么要单列一个文件、还要 public：偏好页要照着它铺四行开关，气泡本体要照着它摆格子，
//  控制器要照着它判断「还有没有格子可摆」。这三处各自写一遍顺序，就会出现在偏好页关掉
//  「翻译」、气泡上却还留着翻译格那类对不上的事。
//
//  顺序是**出口在最左**：复制用得最多，其次搜索、翻译，朗读在最后（它会出声，放最右不容易
//  误点）。这条顺序被取证用例按 `cellIDs` 钉住，改顺序要连测试一起改。
//

import Foundation
import Storage

/// 一格能做的一件事。rawValue 同时是气泡内部的格子 id 和日志里出现的名字，**别拿它当文案**。
public enum SelectionBubbleAction: String, CaseIterable {
    case copy
    case search
    case translate
    case speak

    /// SF Symbol 名。系统没有这个 symbol 时视图会退化成问号，好过留一块空白。
    public var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .search: return "magnifyingglass"
        case .translate: return "globe"
        case .speak: return "speaker.wave.2"
        }
    }

    /// 文案 key（图标格的无障碍标签、偏好页那一行的标题都用它）。
    public var titleKey: String { "Selection bubble \(rawValue)" }

    /// 偏好页那一行下面那行小字的 key。放在枚举里而不是写在页面里：加第五格时只要在这里
    /// 补一条，偏好页那个 `ForEach` 自动多一行 —— 漏了会在「key 必须在两份 .strings 里都有」
    /// 那条用例上红，而不是安安静静地少一行说明。
    public var hintKey: String { "Selection Bubble action \(rawValue) hint" }

    /// 这一格自己的开关存在哪个键上。
    public var storageKey: StorageKey {
        switch self {
        case .copy: return .selectionPopupActionCopy
        case .search: return .selectionPopupActionSearch
        case .translate: return .selectionPopupActionTranslate
        case .speak: return .selectionPopupActionSpeak
        }
    }

    public var defaultEnabled: Bool {
        switch self {
        case .copy: return StorageDefaults.selectionPopupActionCopy
        case .search: return StorageDefaults.selectionPopupActionSearch
        case .translate: return StorageDefaults.selectionPopupActionTranslate
        case .speak: return StorageDefaults.selectionPopupActionSpeak
        }
    }

    /// 从偏好里读出「此刻该摆哪几格」，顺序一律按 `allCases`（= 出口在最左那份），
    /// **不按勾选的先后**。否则用户先勾朗读再勾复制，格子顺序就会跟着变，气泡会跳。
    public static func enabled(in storage: PreferencesStorage = PreferencesStorage()) -> [SelectionBubbleAction] {
        allCases.filter { storage.getBoolOptional(forKey: $0.storageKey) ?? $0.defaultEnabled }
    }
}
