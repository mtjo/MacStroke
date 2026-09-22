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

    /// Whether whitelist mode is active. When true, only whitelisted apps pass;
    /// when false, all apps pass except blacklisted ones.
    private var inWhiteListMode: Bool {
        get { UserDefaults.standard.bool(forKey: "filterIsInWhiteMode") }
        set { UserDefaults.standard.set(newValue, forKey: "filterIsInWhiteMode"); UserDefaults.standard.synchronize() }
    }

    /// Blacklist items stored as an array of pattern strings.
    private var blackList: [String] {
        get { UserDefaults.standard.stringArray(forKey: "filterBlackList") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "filterBlackList"); UserDefaults.standard.synchronize() }
    }

    /// Whitelist items stored as an array of pattern strings.
    private var whiteList: [String] {
        get { UserDefaults.standard.stringArray(forKey: "filterWhiteList") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "filterWhiteList"); UserDefaults.standard.synchronize() }
    }

    /// Plain-text blacklist with one pattern per line (UI binding).
    public var blackListText: String {
        get { blackList.joined(separator: "\n") }
        set {
            lock.lock()
            defer { lock.unlock() }
            blackList = newValue.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            UserDefaults.standard.set(blackList, forKey: "filterBlackList")
            UserDefaults.standard.synchronize()
        }
    }

    /// Plain-text whitelist with one pattern per line (UI binding).
    public var whiteListText: String {
        get { whiteList.joined(separator: "\n") }
        set {
            lock.lock()
            defer { lock.unlock() }
            whiteList = newValue.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            UserDefaults.standard.set(whiteList, forKey: "filterWhiteList")
            UserDefaults.standard.synchronize()
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

    /// Migrate from old "blockFilter" UserDefaults key.
    public func compatibleProcedureWithPreviousVersion() {
        if let oldBlockFilter = UserDefaults.standard.string(forKey: "blockFilter") {
            inWhiteListMode = false
            blackListText = oldBlockFilter.replacingOccurrences(of: "|", with: "\n")
            UserDefaults.standard.removeObject(forKey: "blockFilter")
            UserDefaults.standard.synchronize()
        }
    }
}
