//
//  Localization.swift
//  MacStroke
//
//  Lightweight localization helpers shared across targets.
//

import Foundation

/// Notification posted when the user selects a different UI language.
/// Preferences windows and live views listen for this to refresh their text.
public extension Notification.Name {
    static let languageDidChange = Notification.Name("MacStrokeLanguageDidChange")
    static let macStrokeEnabledDidChange = Notification.Name("MacStrokeEnabledDidChange")
    static let showIconInStatusBarDidChange = Notification.Name("ShowIconInStatusBarDidChange")
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
    NotificationCenter.default.post(name: .languageDidChange, object: nil)
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

/// Returns the bundle to use for localized strings based on the current
/// `AppleLanguages` setting.
///
/// This is needed because `Bundle.localizedString` may not refresh
/// immediately when `AppleLanguages` changes, especially when the app
/// is launched via `swift run` and resources live in a sibling bundle.
/// By loading the `.lproj` directory explicitly we ensure the latest
/// language is used right away.
@inline(__always)
public func preferredLanguageBundle() -> Bundle {
    let fallback = appResourceBundle()

    guard let appleLanguages = UserDefaults.standard.stringArray(forKey: "AppleLanguages") else {
        return fallback
    }

    // Build a case-insensitive map of available lproj directories.
    var available: [String: Bundle] = [:]
    if let contents = try? FileManager.default.contentsOfDirectory(
        at: fallback.bundleURL,
        includingPropertiesForKeys: nil
    ) {
        for entry in contents where entry.pathExtension == "lproj" {
            if let bundle = Bundle(url: entry) {
                available[entry.deletingPathExtension().lastPathComponent.lowercased()] = bundle
            }
        }
    }

    for language in appleLanguages {
        let normalized = language.lowercased()
        if let bundle = available[normalized] {
            return bundle
        }
        // Also try the base language (e.g. "zh-Hans" -> "zh").
        let base = normalized.components(separatedBy: "-").first ?? normalized
        if let bundle = available[base] {
            return bundle
        }
    }

    return fallback
}

/// Returns the localized string for `key`, falling back to `key` itself.
///
/// This always reads from the **main bundle**, which is important for
/// extension targets (FinderSync, RightClickMenu) whose own bundle would
/// not contain the app's `Localizable.strings` table.
@inline(__always)
public func L(_ key: String, comment: String = "") -> String {
    let bundle = preferredLanguageBundle()
    return bundle.localizedString(forKey: key, value: nil, table: nil)
}

/// Convenience wrapper around `String(format:)` + localization.
@inline(__always)
public func LFormat(_ key: String, comment: String = "", _ args: CVarArg...) -> String {
    let format = preferredLanguageBundle().localizedString(forKey: key, value: nil, table: nil)
    return String(format: format, args)
}
