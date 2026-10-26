//
//  BlackWhiteFilter.swift
//  MacStroke
//
//  Black/white list filter for app bundle ID matching.
//  Patterns use the original's `LIKE` semantics (`*` and `?`, whole-string).
//

import Foundation

/// Thread-safe singleton for black/white list filtering.
public final class BlackWhiteFilter: @unchecked Sendable {

    /// Shared singleton instance.
    public static let shared = BlackWhiteFilter()

    private let lock = NSLock()

    /// 名单与模式那三格的实际键名。它们不在 `StorageKey` 里（RuleEngine 不依赖 Storage），
    /// 用的是原版同名三格；集中在这里是因为迁移也要写同样这几格，两处各写一遍迟早写成两种样子。
    ///
    /// 标 internal 而不是 private：`BlackWhiteFilterTests.testFilterAndStorageAgreeOnKeyNames`
    /// 要把这几格和 `StorageKey` 的原始值逐字对上（偏好页读写的键名和这里必须一模一样，
    /// 对不上的表现就是用户名单「凭空变空」—— issue #76 同一个症状的另一条路）。
    /// `@testable import` 够用，不是公开 API。
    static let blackListKey = "filterBlackList"
    static let whiteListKey = "filterWhiteList"
    static let whiteListModeKey = "filterIsInWhiteMode"
    /// 2.x 那一坨黑名单的旧键：`"com.a|com.b"`，一根竖线分家，没有模式可言。
    static let legacyBlockFilterKey = "blockFilter"

    /// Whether whitelist mode is active. When true, only whitelisted apps pass;
    /// when false, all apps pass except blacklisted ones.
    private var inWhiteListMode: Bool {
        get { UserDefaults.standard.bool(forKey: BlackWhiteFilter.whiteListModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: BlackWhiteFilter.whiteListModeKey); UserDefaults.standard.synchronize() }
    }

    /// Blacklist items stored as an array of pattern strings.
    private var blackList: [String] {
        get { UserDefaults.standard.stringArray(forKey: BlackWhiteFilter.blackListKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: BlackWhiteFilter.blackListKey); UserDefaults.standard.synchronize() }
    }

    /// Whitelist items stored as an array of pattern strings.
    private var whiteList: [String] {
        get { UserDefaults.standard.stringArray(forKey: BlackWhiteFilter.whiteListKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: BlackWhiteFilter.whiteListKey); UserDefaults.standard.synchronize() }
    }

    /// 一行一个的名单文本 → 要存进库的那个数组（逐行去空格、空行丢掉）。
    /// `split(separator:)` 默认就不吐真空段（`"a\n\nb"` 出来两条）；后面那道 `filter`
    /// 管的是**整行只有空格**那种 —— 它是 trim 之后才变空的，少一道就真留在名单里，
    /// 页面上是一片看不出所以然的空白。
    static func splitListText(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Plain-text blacklist with one pattern per line (UI binding).
    public var blackListText: String {
        get { blackList.joined(separator: "\n") }
        set {
            lock.lock()
            defer { lock.unlock() }
            blackList = BlackWhiteFilter.splitListText(newValue)
        }
    }

    /// Plain-text whitelist with one pattern per line (UI binding).
    public var whiteListText: String {
        get { whiteList.joined(separator: "\n") }
        set {
            lock.lock()
            defer { lock.unlock() }
            whiteList = BlackWhiteFilter.splitListText(newValue)
        }
    }

    private init() {}

    /// Whether to hook mouse events for the given bundle ID.
    /// In whitelist mode, only whitelisted apps pass.
    /// In blacklist mode, all apps pass except blacklisted ones.
    public func shouldHookMouseEventForApp(_ bundleName: String) -> Bool {
        if inWhiteListMode {
            return match(bundleName: bundleName, against: whiteList)
        } else {
            return !match(bundleName: bundleName, against: blackList)
        }
    }

    /// Match a bundle ID against the configured lists.
    /// Returns true if the bundle ID matches any pattern.
    /// Original `bundleName:fitWithRules:`: every list item is a `LIKE` pattern
    /// (`*` / `?`, whole-string, case-folded) — no regex support.
    public func match(bundleName: String) -> Bool {
        let patterns = inWhiteListMode ? whiteList : blackList
        return match(bundleName: bundleName, against: patterns)
    }

    /// Check if bundleName matches any pattern in the list.
    private func match(bundleName: String, against patterns: [String]) -> Bool {
        wildcardArray(bundleName, patterns: patterns, ignoreCase: true)
    }

    /// 旧键里那份**真正写过**的 2.x 名单；没有就返回 nil（这时候迁移一个字都不动）。
    ///
    /// 判据不能是 `string(forKey:) != nil` —— issue #76 就栽在这句上。`blockFilter`
    /// 曾被 `registerUserDefaultsDefaults()` 注册成 `""`，而注册表里的值对
    /// `string(forKey:)` 一样可见，`removeObject` 又只删得掉真正写进磁盘的那一份 ——
    /// 于是「有旧值要迁」每次启动都成立，每次启动都拿那份空的把 `filterBlackList`
    /// 重写成零条、把模式按成黑名单。用户看到的正是「添加的应用重启后消失，黑名单空了」。
    /// 两道一起挡：Storage 那边这格不再有注册值（回到原版 plist 的形状，它没有这一键），
    /// 这里又只认非空（2.x 自己写过一份空名单的情况）。
    static func legacyBlockFilterValue(in defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: BlackWhiteFilter.legacyBlockFilterKey), !raw.isEmpty else { return nil }
        return raw
    }

    /// Migrate from old "blockFilter" UserDefaults key（原版 `AppDelegate.m:239-243` 那一步）。
    ///
    /// 只在旧键真写过、且那份非空时动手（见 `legacyBlockFilterValue`），动完删掉旧键 ——
    /// 删掉不会再触发第二次。`defaults` 给私有 suite 时读写都落在这一份上，
    /// 用例才能拿真语义跑而不碰用户自己的名单。
    /// - Parameter defaults: 读旧键、写名单的那一份库，默认是 App 自己的 `UserDefaults.standard`。
    public func compatibleProcedureWithPreviousVersion(defaults: UserDefaults = .standard) {
        guard let legacy = BlackWhiteFilter.legacyBlockFilterValue(in: defaults) else { return }
        let migrated = BlackWhiteFilter.splitListText(legacy.replacingOccurrences(of: "|", with: "\n"))
        // 2.x 只有黑名单一种口径，所以迁完模式落黑名单（原版就是 isInWhiteListMode = NO）。
        defaults.set(false, forKey: BlackWhiteFilter.whiteListModeKey)
        defaults.set(migrated, forKey: BlackWhiteFilter.blackListKey)
        defaults.removeObject(forKey: BlackWhiteFilter.legacyBlockFilterKey)
        defaults.synchronize()
        NSLog("[BlockFilterMigration] 旧键 blockFilter 里迁进黑名单 %d 条，模式落到黑名单", migrated.count)
    }
}
