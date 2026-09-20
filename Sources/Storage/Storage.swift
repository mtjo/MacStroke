//
//  Storage.swift
//  MacStroke
//
//  Persistent storage for user preferences and rules.
//  Uses UserDefaults for simple key-value storage.
//

import Foundation

/// Storage keys used by the preferences module.
public enum StorageKey: String, CaseIterable {
    // General
    case isEnabled = "isEnabled"
    case showIconInStatusBar = "showIconInStatusBar"
    case launchAtLogin = "launchAtLogin"
    case showUIInWhateverApp = "showUIInWhateverApp"
    case blockFilter = "blockFilter"
    case whiteListMode = "filterIsInWhiteMode"
    case whiteList = "whiteList"
    case language = "language"
    case openPrefOnStartup = "openPrefOnStartup"
    case mergeConsecutiveIdenticalGestures = "mergeConsecutiveIdenticalGestures"
    case defaultLineColor = "defaultLineColor"
    case defaultNoteColor = "defaultNoteColor"

    // Gesture recognition
    case minimumPoints = "minimumPoints"
    case minSimilarityScore = "minScore"
    case enableGestureMinScore = "enableGestureMinScore"
    case showGestureNote = "showGestureNote"

    // Note/Toast
    case noteRetentionTime = "noteRetetionTime"
    case notePosition = "notePostion"
    case noteBackgroundAlpha = "noteBackgroundAlpha"
    case noteFontName = "noteFontName"
    case noteFontSize = "noteFontSize"
    case showNoteIcon = "showNoteIcon"

    // Drawing
    case disableMousePath = "disableMousePath"
    case lineColorHex = "lineColorHex"
    case lineWidth = "lineWidth"

    // Right-click menu
    case enableRightClickMenu = "enableRightClickMenu"
    case enableNewFile = "enableNewFile"
    case enableOpenInTerminal = "enableOpenInTerminal"
    case enableCopyFilePath = "enableCopyFilePath"

    // Clipboard
    case clipboardLimitTop = "clipboardLimitTop"
    case clipboardLimitTotal = "clipboardLimitTotal"
    case clipboardSaveDays = "clipboardSaveDays"
    case enableHistoryClipboard = "enableHistoryClipboard"
    case clipoardStroageLocal = "clipoardStroageLocal"
    case clipoardStroageRam = "clipoardStroageRam"
    case historyCilpboardListShortcut = "historyCilpboardListShortcut"
    case enableLimitTotal = "enableLimitTotal"
    case limitTotal = "limitTotal"
    case enableLimitTop = "enableLimitTop"
    case limitTop = "limitTop"
    case enableLimitSaveDays = "enableLimitSaveDays"
    case limitSaveDays = "limitSaveDays"
    case userTerminal = "userTerminal"

    // Updates
    case autoCheckUpdates = "autoCheckUpdates"

    // Legacy (kept for compatibility)
    case showToast = "showToast"
    case clipboardHistoryLimit = "clipboardHistoryLimit"
}

/// A lightweight storage abstraction for user preferences.
public struct PreferencesStorage {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func getBool(forKey key: StorageKey) -> Bool {
        defaults.bool(forKey: key.rawValue)
    }

    public func getInt(forKey key: StorageKey) -> Int {
        defaults.integer(forKey: key.rawValue)
    }

    public func getDouble(forKey key: StorageKey) -> Double {
        defaults.double(forKey: key.rawValue)
    }

    /// Returns the boolean value for the given key, or nil if the key does not exist.
    public func getBoolOptional(forKey key: StorageKey) -> Bool? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.bool(forKey: key.rawValue)
    }

    /// Returns the integer value for the given key, or nil if the key does not exist.
    public func getIntOptional(forKey key: StorageKey) -> Int? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.integer(forKey: key.rawValue)
    }

    /// Returns the double value for the given key, or nil if the key does not exist.
    public func getDoubleOptional(forKey key: StorageKey) -> Double? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.double(forKey: key.rawValue)
    }

    public func setBool(_ value: Bool, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func setInt(_ value: Int, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func setDouble(_ value: Double, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func getString(forKey key: StorageKey) -> String? {
        defaults.string(forKey: key.rawValue)
    }

    public func getStringOptional(forKey key: StorageKey) -> String? {
        defaults.object(forKey: key.rawValue) as? String
    }

    public func setString(_ value: String, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func remove(_ key: StorageKey) {
        defaults.removeObject(forKey: key.rawValue)
    }

    public func synchronize() {
        defaults.synchronize()
    }
}

/// Default storage configuration values.
public enum StorageDefaults {
    // General
    public static let isEnabled: Bool = true
    public static let showIconInStatusBar: Bool = true
    public static let launchAtLogin: Bool = false
    public static let showUIInWhateverApp: Bool = false
    public static let blockFilter: String = ""
    public static let whiteListMode: Bool = false
    public static let whiteList: String = ""
    public static let language: String = "en"
    public static let openPrefOnStartup: Bool = true
    public static let mergeConsecutiveIdenticalGestures: Bool = false
    public static let defaultLineColor: String = "#0000ff"
    public static let defaultNoteColor: String = "#FFFFFF"

    // Gesture recognition
    public static let minimumPoints: Int = 10
    public static let minSimilarityScore: Double = 85.0
    public static let enableGestureMinScore: Bool = true
    public static let showGestureNote: Bool = true

    // Note/Toast
    public static let noteRetentionTime: Int = 1
    public static let notePosition: Int = 1              // 0鼠标 1屏幕中心 2右上...
    public static let noteBackgroundAlpha: Double = 0.5
    public static let noteFontName: String = "Monaco"
    public static let noteFontSize: Double = 40
    public static let showNoteIcon: Bool = true

    // Drawing
    public static let disableMousePath: Bool = false
    public static let lineColorHex: String = "#0000FFFF" // 蓝色
    public static let lineWidth: Double = 4.0

    // Right-click menu
    public static let enableRightClickMenu: Bool = true
    public static let enableNewFile: Bool = true
    public static let enableOpenInTerminal: Bool = true
    public static let enableCopyFilePath: Bool = true

    // Clipboard
    public static let enableHistoryClipboard: Bool = true
    public static let clipboardLimitTop: Int = 15
    public static let clipboardLimitTotal: Int = 200
    public static let clipboardSaveDays: Int = 7
    public static let clipoardStroageLocal: Bool = true
    public static let clipoardStroageRam: Bool = false
    public static let historyCilpboardListShortcut: String = "keyCode=9, flags=393216" // ^⇧V
    public static let enableLimitTotal: Bool = false
    public static let limitTotal: Int = 200
    public static let enableLimitTop: Bool = true
    public static let limitTop: Int = 15
    public static let enableLimitSaveDays: Bool = true
    public static let limitSaveDays: Int = 7
    public static let userTerminal: String = "Terminal"

    // Updates
    public static let autoCheckUpdates: Bool = true

    // Legacy (keep for compatibility)
    public static let showToast: Bool = true
    public static let clipboardHistoryLimit: Int = 50
}

/// Registers the default values for every preference key with UserDefaults
/// (the Swift counterpart of the original's
/// `registerDefaults: [DefaultPreferences.plist]`).
///
/// Must be called at app startup, **before** anything reads UserDefaults
/// directly (e.g. `HistoryClipboardManager`, `RuleEngine.match` reading
/// `minScore`) — `UserDefaults.bool`/`integer` return false/0 for keys that
/// were never written, which would otherwise disable the clipboard monitor
/// and the gesture score gate on a fresh install.
public func registerUserDefaultsDefaults() {
    let defaults: [String: Any] = [
        StorageKey.isEnabled.rawValue: StorageDefaults.isEnabled,
        StorageKey.showIconInStatusBar.rawValue: StorageDefaults.showIconInStatusBar,
        StorageKey.launchAtLogin.rawValue: StorageDefaults.launchAtLogin,
        StorageKey.showUIInWhateverApp.rawValue: StorageDefaults.showUIInWhateverApp,
        StorageKey.blockFilter.rawValue: StorageDefaults.blockFilter,
        StorageKey.whiteListMode.rawValue: StorageDefaults.whiteListMode,
        StorageKey.whiteList.rawValue: StorageDefaults.whiteList,
        StorageKey.language.rawValue: StorageDefaults.language,
        StorageKey.openPrefOnStartup.rawValue: StorageDefaults.openPrefOnStartup,
        StorageKey.mergeConsecutiveIdenticalGestures.rawValue: StorageDefaults.mergeConsecutiveIdenticalGestures,
        StorageKey.defaultLineColor.rawValue: StorageDefaults.defaultLineColor,
        StorageKey.defaultNoteColor.rawValue: StorageDefaults.defaultNoteColor,
        StorageKey.minimumPoints.rawValue: StorageDefaults.minimumPoints,
        StorageKey.minSimilarityScore.rawValue: StorageDefaults.minSimilarityScore,
        StorageKey.enableGestureMinScore.rawValue: StorageDefaults.enableGestureMinScore,
        StorageKey.showGestureNote.rawValue: StorageDefaults.showGestureNote,
        StorageKey.noteRetentionTime.rawValue: StorageDefaults.noteRetentionTime,
        StorageKey.notePosition.rawValue: StorageDefaults.notePosition,
        StorageKey.noteBackgroundAlpha.rawValue: StorageDefaults.noteBackgroundAlpha,
        StorageKey.noteFontName.rawValue: StorageDefaults.noteFontName,
        StorageKey.noteFontSize.rawValue: StorageDefaults.noteFontSize,
        StorageKey.showNoteIcon.rawValue: StorageDefaults.showNoteIcon,
        StorageKey.disableMousePath.rawValue: StorageDefaults.disableMousePath,
        StorageKey.lineColorHex.rawValue: StorageDefaults.lineColorHex,
        StorageKey.lineWidth.rawValue: StorageDefaults.lineWidth,
        StorageKey.enableRightClickMenu.rawValue: StorageDefaults.enableRightClickMenu,
        StorageKey.enableNewFile.rawValue: StorageDefaults.enableNewFile,
        StorageKey.enableOpenInTerminal.rawValue: StorageDefaults.enableOpenInTerminal,
        StorageKey.enableCopyFilePath.rawValue: StorageDefaults.enableCopyFilePath,
        StorageKey.enableHistoryClipboard.rawValue: StorageDefaults.enableHistoryClipboard,
        StorageKey.clipboardLimitTop.rawValue: StorageDefaults.clipboardLimitTop,
        StorageKey.clipboardLimitTotal.rawValue: StorageDefaults.clipboardLimitTotal,
        StorageKey.clipboardSaveDays.rawValue: StorageDefaults.clipboardSaveDays,
        StorageKey.clipoardStroageLocal.rawValue: StorageDefaults.clipoardStroageLocal,
        StorageKey.clipoardStroageRam.rawValue: StorageDefaults.clipoardStroageRam,
        StorageKey.historyCilpboardListShortcut.rawValue: StorageDefaults.historyCilpboardListShortcut,
        StorageKey.enableLimitTotal.rawValue: StorageDefaults.enableLimitTotal,
        StorageKey.limitTotal.rawValue: StorageDefaults.limitTotal,
        StorageKey.enableLimitTop.rawValue: StorageDefaults.enableLimitTop,
        StorageKey.limitTop.rawValue: StorageDefaults.limitTop,
        StorageKey.enableLimitSaveDays.rawValue: StorageDefaults.enableLimitSaveDays,
        StorageKey.limitSaveDays.rawValue: StorageDefaults.limitSaveDays,
        StorageKey.userTerminal.rawValue: StorageDefaults.userTerminal,
        StorageKey.autoCheckUpdates.rawValue: StorageDefaults.autoCheckUpdates,
        StorageKey.showToast.rawValue: StorageDefaults.showToast,
        StorageKey.clipboardHistoryLimit.rawValue: StorageDefaults.clipboardHistoryLimit,
        // Right-click menu keys as read by the FinderSync extension.
        "newFile": StorageDefaults.enableNewFile,
        "openInTerminal": StorageDefaults.enableOpenInTerminal,
        "copyFilePath": StorageDefaults.enableCopyFilePath,
    ]
    UserDefaults.standard.register(defaults: defaults)

    migrateLegacyPreferenceKeys()
}

/// One-time migration of early Swift-port key names to the original MacStroke
/// keys (the StorageKey rawValues now match the original, so re-registering
/// under the new name is enough; old values are moved only if actually written).
private func migrateLegacyPreferenceKeys() {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: "minSimilarityScore") != nil {
        if defaults.object(forKey: "minScore") == nil {
            defaults.set(defaults.double(forKey: "minSimilarityScore"), forKey: "minScore")
        }
        defaults.removeObject(forKey: "minSimilarityScore")
    }
    if defaults.object(forKey: "whiteListMode") != nil {
        if defaults.object(forKey: "filterIsInWhiteMode") == nil {
            defaults.set(defaults.bool(forKey: "whiteListMode"), forKey: "filterIsInWhiteMode")
        }
        defaults.removeObject(forKey: "whiteListMode")
    }
    for (legacy, key) in [("noteRetentionTime", "noteRetetionTime"), ("notePosition", "notePostion")] {
        if defaults.object(forKey: legacy) != nil {
            if defaults.object(forKey: key) == nil {
                defaults.set(defaults.integer(forKey: legacy), forKey: key)
            }
            defaults.removeObject(forKey: legacy)
        }
    }
}