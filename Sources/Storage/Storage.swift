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
    case showIconInStatusBar = "showIconInStatusBar"
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
    case minSimilarityScore = "minScore"
    case enableGestureMinScore = "enableGestureMinScore"
    case showGestureNote = "showGestureNote"

    // Gesture trigger buttons
    // 移植版扩展（issue #53）：原版只监听右键，连 DefaultPreferences.plist 里都
    // 没有按键相关的键，所以这几个键名是新造的，不需要对原版兼容。
    // customGestureButton 存 CoreGraphics 的按键编号（3 起，0 表示还没录制）。
    case enableMiddleButtonGesture = "enableMiddleButtonGesture"
    case enableSideButtonGesture = "enableSideButtonGesture"
    case enableCustomButtonGesture = "enableCustomButtonGesture"
    case customGestureButton = "customGestureButton"

    // 移植版扩展（issue #59）：按住这些修饰键时不起手。同样没有原版键名，
    // 值是逗号分隔的 token（cmd/ctrl/shift/opt/fn），空串表示不因修饰键暂停。
    case gestureSuppressedModifiers = "gestureSuppressedModifiers"

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
    // The rawValues are the original key names: the FinderSync payload is built
    // from `newFile`/`openInTerminal`/`copyFilePath`, so the UI has to write the
    // same keys (the Swift enum cases keep the longer names for readability).
    case enableRightClickMenu = "enableRightClickMenu"
    case enableNewFile = "newFile"
    case enableOpenInTerminal = "openInTerminal"
    case enableCopyFilePath = "copyFilePath"

    // Clipboard
    case enableHistoryClipboard = "enableHistoryClipboard"
    case clipoardStroageLocal = "clipoardStroageLocal"
    case historyCilpboardListShortcut = "historyCilpboardListShortcut"
    case enableLimitTotal = "enableLimitTotal"
    case limitTotal = "limitTotal"
    case enableLimitTop = "enableLimitTop"
    case limitTop = "limitTop"
    case enableLimitSaveDays = "enableLimitSaveDays"
    case limitSaveDays = "limitSaveDays"
    case userTerminal = "userTerminal"

    // Updates
    /// 原版没有自己的键：偏好窗「自动检查更新」复选框绑
    /// SUUpdater.automaticallyChecksForUpdates，值落在 Sparkle 自己的
    /// SUEnableAutomaticChecks 上。移植版早期自造了 "autoCheckUpdates" 键，
    /// 写进去的旧值会永久压掉后改的默认值（老移植版用户升上来再也不自动检查），
    /// 所以改回 Sparkle 的键，旧键在 migrateLegacyPreferenceKeys 里清掉。
    case autoCheckUpdates = "SUEnableAutomaticChecks"

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
    public static let showIconInStatusBar: Bool = true
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
    public static let minSimilarityScore: Double = 85.0
    public static let enableGestureMinScore: Bool = true
    public static let showGestureNote: Bool = true

    // Gesture trigger buttons — off by default: the shipped behaviour stays
    // right-button-only, exactly like the original.
    public static let enableMiddleButtonGesture: Bool = false
    public static let enableSideButtonGesture: Bool = false
    public static let enableCustomButtonGesture: Bool = false
    /// 0 = 尚未录制过按键。
    public static let customGestureButton: Int = 0
    /// 空 = 按住任何修饰键都照常起手，和原版一致。
    public static let gestureSuppressedModifiers: String = ""

    // Note/Toast
    public static let noteRetentionTime: Int = 1
    public static let notePosition: Int = 1              // 0鼠标 1屏幕中心 2右上...
    public static let noteBackgroundAlpha: Double = 0.5
    public static let noteFontName: String = "Monaco"
    public static let noteFontSize: Double = 40
    public static let showNoteIcon: Bool = true

    // Drawing
    public static let disableMousePath: Bool = false
    public static let lineColorHex: String = "#0000FF" // 蓝色（RRGGBB；旧默认值 "#0000FFFF" 是 ARGB 写法，会导致按 RRGGBBAA 解析成全透明）
    public static let lineWidth: Double = 4.0

    // Right-click menu
    public static let enableRightClickMenu: Bool = true
    public static let enableNewFile: Bool = true
    public static let enableOpenInTerminal: Bool = true
    public static let enableCopyFilePath: Bool = true

    // Clipboard
    public static let enableHistoryClipboard: Bool = true
    public static let clipoardStroageLocal: Bool = true
    /// Original SRShortcut default: keyCode 9 ("v") + modifierFlags 1572864 (⌘⌥).
    public static let historyCilpboardListShortcut: String = "keyCode=9, flags=1572864"
    public static let enableLimitTotal: Bool = false
    public static let limitTotal: Int = 200
    public static let enableLimitTop: Bool = true
    public static let limitTop: Int = 15
    public static let enableLimitSaveDays: Bool = true
    public static let limitSaveDays: Int = 7
    public static let userTerminal: String = "Terminal"

    // Updates
    // 原版默认为 true（复选框绑 SUUpdater.automaticallyChecksForUpdates，原版
    // Info.plist 里也没有 SUEnableAutomaticChecks，即走 Sparkle 的默认开）。
    // build_app.sh 生成的 Info.plist 同写 SUEnableAutomaticChecks=true，两处一致。
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
        StorageKey.showIconInStatusBar.rawValue: StorageDefaults.showIconInStatusBar,
        StorageKey.showUIInWhateverApp.rawValue: StorageDefaults.showUIInWhateverApp,
        StorageKey.blockFilter.rawValue: StorageDefaults.blockFilter,
        StorageKey.whiteListMode.rawValue: StorageDefaults.whiteListMode,
        StorageKey.whiteList.rawValue: StorageDefaults.whiteList,
        StorageKey.language.rawValue: StorageDefaults.language,
        StorageKey.openPrefOnStartup.rawValue: StorageDefaults.openPrefOnStartup,
        StorageKey.mergeConsecutiveIdenticalGestures.rawValue: StorageDefaults.mergeConsecutiveIdenticalGestures,
        StorageKey.defaultLineColor.rawValue: StorageDefaults.defaultLineColor,
        StorageKey.defaultNoteColor.rawValue: StorageDefaults.defaultNoteColor,
        StorageKey.minSimilarityScore.rawValue: StorageDefaults.minSimilarityScore,
        StorageKey.enableGestureMinScore.rawValue: StorageDefaults.enableGestureMinScore,
        StorageKey.showGestureNote.rawValue: StorageDefaults.showGestureNote,
        StorageKey.enableMiddleButtonGesture.rawValue: StorageDefaults.enableMiddleButtonGesture,
        StorageKey.enableSideButtonGesture.rawValue: StorageDefaults.enableSideButtonGesture,
        StorageKey.enableCustomButtonGesture.rawValue: StorageDefaults.enableCustomButtonGesture,
        StorageKey.customGestureButton.rawValue: StorageDefaults.customGestureButton,
        StorageKey.gestureSuppressedModifiers.rawValue: StorageDefaults.gestureSuppressedModifiers,
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
        StorageKey.clipoardStroageLocal.rawValue: StorageDefaults.clipoardStroageLocal,
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
    // Early Swift builds stored the Finder sub-switches under "enable…"; the
    // original (and the extension payload) use the short names.
    for (legacy, key) in [
        ("enableNewFile", "newFile"),
        ("enableOpenInTerminal", "openInTerminal"),
        ("enableCopyFilePath", "copyFilePath"),
    ] {
        if defaults.object(forKey: legacy) != nil {
            if defaults.object(forKey: key) == nil {
                defaults.set(defaults.bool(forKey: legacy), forKey: key)
            }
            defaults.removeObject(forKey: legacy)
        }
    }
    // "clipoardStroageRam" only ever exists as a dead registered default in the
    // original; early Swift builds read it as a live switch, so drop any value
    // they wrote. Storage backend is decided by "clipoardStroageLocal" alone.
    defaults.removeObject(forKey: "clipoardStroageRam")

    // 早期 Swift 构建把「自动检查更新」存在自造的 "autoCheckUpdates" 键下，并且
    // 在启动时把它回写进 Sparkle 的 SUEnableAutomaticChecks。两处都留着旧值的话，
    // 默认值改再多也压不回来，所以对跑过那些构建的机器各清一次（用户可在关于页重设）。
    if defaults.object(forKey: "autoCheckUpdates") != nil {
        defaults.removeObject(forKey: "autoCheckUpdates")
        defaults.removeObject(forKey: "SUEnableAutomaticChecks")
    }
}
