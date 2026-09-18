//
//  Localization.swift
//  MacStroke
//
//  Lightweight localization helpers shared across targets.
//  Supports runtime language switching by loading .strings files directly
//  (avoids Bundle(url: lproj) which doesn't work for bare .lproj dirs).
//

import Foundation

/// Notification posted when the user selects a different UI language.
/// Preferences windows and live views listen for this to refresh their text.
public extension Notification.Name {
    static let languageDidChange = Notification.Name("MacStrokeLanguageDidChange")
    static let macStrokeEnabledDidChange = Notification.Name("MacStrokeEnabledDidChange")
    static let showIconInStatusBarDidChange = Notification.Name("ShowIconInStatusBarDidChange")
    /// Posted after a screen-drawn gesture has been recorded into a rule, so
    /// the preferences rule table can refresh.
    static let macStrokeRuleStoreDidChange = Notification.Name("MacStrokeRuleStoreDidChange")
}

/// Returns the bundle that should be used for localized strings and images.
///
/// For a normal macOS app `Bundle.main` already contains the resources.
/// When the executable is launched directly by `swift run`, SPM puts the
/// resources into a sibling resource bundle (e.g. `MacStroke_MacStrokeApp.bundle`).
/// This helper falls back to that bundle so image and string lookups still work.
@inline(__always)
public func appResourceBundle() -> Bundle {
    let main = Bundle.main
    if main.url(forResource: "en", withExtension: "lproj") != nil {
        return main
    }

    if let execPath = main.executablePath {
        let execURL = URL(fileURLWithPath: execPath)
        let dir = execURL.deletingLastPathComponent()
        if let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for entry in entries where entry.pathExtension == "bundle" {
                if let bundle = Bundle(url: entry),
                   bundle.url(forResource: "en", withExtension: "lproj") != nil {
                    return bundle
                }
            }
        }
    }

    return main
}

/// Cache of loaded string tables: [languageCode: [key: localizedString]]
private var _stringTablesCache: [String: [String: String]] = [:]
private let _cacheLock = NSLock()

/// Load a .strings file for the given language from the resource bundle.
/// Returns the parsed dictionary, or nil if not found.
private func loadStringTable(for language: String) -> [String: String]? {
    _cacheLock.lock()
    defer { _cacheLock.unlock() }

    // Return cached
    if let cached = _stringTablesCache[language] {
        return cached
    }

    let bundle = appResourceBundle()
    guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language) else {
        return nil
    }

    guard let dict = NSDictionary(contentsOf: url) as? [String: String] else {
        return nil
    }

    _stringTablesCache[language] = dict
    return dict
}

/// Clear the string tables cache (call when language changes).
public func clearStringTablesCache() {
    _cacheLock.lock()
    defer { _cacheLock.unlock() }
    _stringTablesCache.removeAll()
}

/// Applies the user's language preference to the running process.
///
/// - Note: Changing `AppleLanguages` in `UserDefaults` updates the
///   language used by `preferredLanguageBundle()`, so subsequent
///   `L()` / `LFormat()` calls return strings for the new language
///   immediately without restarting the app.
public func applyUserLanguage(_ language: String) {
    UserDefaults.standard.set([language], forKey: "AppleLanguages")
    UserDefaults.standard.synchronize()
    clearStringTablesCache()
    NotificationCenter.default.post(name: .languageDidChange, object: nil)
}

/// Returns the localized string for `key`, falling back to `key` itself.
///
/// This reads from the string table for the current `AppleLanguages` preference,
/// loading `.strings` files directly (works in both `.app` bundles and `swift run`).
@inline(__always)
public func L(_ key: String, comment: String = "") -> String {
    let defaults = UserDefaults.standard
    let appleLanguages = defaults.stringArray(forKey: "AppleLanguages") ?? ["en"]

    for language in appleLanguages {
        let normalized = language.lowercased()
        // Try exact match first (e.g., "zh-Hans")
        if let table = loadStringTable(for: normalized),
           let value = table[key] {
            return value
        }
        // Try base language (e.g., "zh")
        let base = normalized.components(separatedBy: "-").first ?? normalized
        if base != normalized,
           let table = loadStringTable(for: base),
           let value = table[key] {
            return value
        }
    }

    // Fallback to English
    if let table = loadStringTable(for: "en"),
       let value = table[key] {
        return value
    }

    // Ultimate fallback: return the key itself
    return key
}

/// Convenience wrapper around `String(format:)` + localization.
@inline(__always)
public func LFormat(_ key: String, comment: String = "", _ args: CVarArg...) -> String {
    let format = L(key, comment: comment)
    return String(format: format, args)
}