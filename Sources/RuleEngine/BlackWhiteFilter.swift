//
//  BlackWhiteFilter.swift
//  MacStroke
//
//  Black/white list filter for app bundle ID matching.
//  Supports wildcard patterns (e.g. com.jetbrains.*) and regex.
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
    /// Supports wildcard patterns (e.g. com.jetbrains.* matches com.jetbrains.Xcode)
    /// and regex patterns (strings starting with "regex:").
    public func match(bundleName: String) -> Bool {
        let patterns = inWhiteListMode ? whiteList : blackList
        return match(bundleName: bundleName, against: patterns)
    }

    /// Check if bundleName matches any pattern in the list.
    private func match(bundleName: String, against patterns: [String]) -> Bool {
        let lowercased = bundleName.lowercased()
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("regex:") {
                let regexPattern = String(trimmed.dropFirst(6))
                if matchRegex(regexPattern, against: lowercased) { return true }
            } else if trimmed.contains("*") {
                if matchWildcard(trimmed.lowercased(), against: lowercased) { return true }
            } else {
                if lowercased == trimmed.lowercased() { return true }
            }
        }
        return false
    }

    /// Wildcard matching: * matches any sequence of characters.
    private func matchWildcard(_ pattern: String, against text: String) -> Bool {
        let patternParts = pattern.components(separatedBy: "*")
        if patternParts.isEmpty { return true }
        if !text.hasPrefix(patternParts[0].lowercased()) { return false }
        var remaining = text.dropFirst(patternParts[0].count)
        for i in 1..<patternParts.count {
            if let range = remaining.range(of: patternParts[i].lowercased()) {
                remaining = remaining.dropFirst(range.lowerBound.utf16Offset(in: remaining))
                remaining = remaining.dropFirst(patternParts[i].count)
            } else if i == patternParts.count - 1 {
                return false
            }
        }
        return true
    }

    /// Regex matching using NSRegularExpression.
    private func matchRegex(_ pattern: String, against text: String) -> Bool {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(location: 0, length: text.utf16.count)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        } catch {
            return false
        }
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
