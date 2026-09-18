//
//  Storage.swift
//  MacStroke
//
//  Persistent storage for user preferences and rules.
//  Uses UserDefaults for simple key-value storage.
//

import Foundation

/// Storage keys used by the preferences module.
public enum StorageKey: String {
    // General
    case isEnabled = "isEnabled"
    case showIconInStatusBar = "showIconInStatusBar"
    case launchAtLogin = "launchAtLogin"
    case showUIInWhateverApp = "showUIInWhateverApp"
    case blockFilter = "blockFilter"
    case whiteListMode = "whiteListMode"
    case whiteList = "whiteList"
    case language = "language"
    case openPrefOnStartup = "openPrefOnStartup"
    case mergeConsecutiveIdenticalGestures = "mergeConsecutiveIdenticalGestures"
    case defaultLineColor = "defaultLineColor"
    case defaultNoteColor = "defaultNoteColor"

    // Gesture recognition
    case minimumPoints = "minimumPoints"
    case minSimilarityScore = "minSimilarityScore"
    case enableGestureMinScore = "enableGestureMinScore"
    case showGestureNote = "showGestureNote"

    // Note/Toast
    case noteRetentionTime = "noteRetentionTime"
    case notePosition = "notePosition"
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
    public static let defaultNoteColor: String = "#000000"

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
    public static let enableLimitTotal: Bool = false
    public static let limitTotal: Int = 200

    // Updates
    public static let autoCheckUpdates: Bool = true

    // Legacy (keep for compatibility)
    public static let showToast: Bool = true
    public static let clipboardHistoryLimit: Int = 50
}