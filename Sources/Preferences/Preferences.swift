//
//  Preferences.swift
//  MacStroke
//
//  User preferences management with SwiftUI + AppKit hybrid UI.
//  Uses PreferencesStorage for persistence.
//

import Foundation
import AppKit
import SwiftUI
import Storage

/// User preferences model - mirrors the design doc's PreferencesModel.
public final class UserPreferences: ObservableObject {
    private let storage: PreferencesStorage

    // MARK: - General
    /// Master switch. Original: `static BOOL isEnabled` in AppDelegate — it is
    /// runtime state only, re-initialised to YES on every launch and never
    /// written to UserDefaults, so the checkbox always starts ticked.
    @Published public var isEnabled: Bool = true
    @Published public var showIconInStatusBar: Bool {
        didSet { storage.setBool(showIconInStatusBar, forKey: .showIconInStatusBar) }
    }
    @Published public var showUIInWhateverApp: Bool {
        didSet { storage.setBool(showUIInWhateverApp, forKey: .showUIInWhateverApp) }
    }
    @Published public var blockFilter: String {
        didSet { storage.setString(blockFilter, forKey: .blockFilter) }
    }
    @Published public var whiteListMode: Bool {
        didSet { storage.setBool(whiteListMode, forKey: .whiteListMode) }
    }
    @Published public var whiteList: String {
        didSet { storage.setString(whiteList, forKey: .whiteList) }
    }
    @Published public var language: String {
        didSet { storage.setString(language, forKey: .language); applyUserLanguage(language) }
    }
    @Published public var openPrefOnStartup: Bool {
        didSet { storage.setBool(openPrefOnStartup, forKey: .openPrefOnStartup) }
    }
    @Published public var mergeConsecutiveIdenticalGestures: Bool {
        didSet { storage.setBool(mergeConsecutiveIdenticalGestures, forKey: .mergeConsecutiveIdenticalGestures) }
    }
    @Published public var defaultLineColor: String {
        didSet { storage.setString(defaultLineColor, forKey: .defaultLineColor) }
    }
    @Published public var defaultNoteColor: String {
        didSet { storage.setString(defaultNoteColor, forKey: .defaultNoteColor) }
    }

    // MARK: - Gesture recognition
    @Published public var minSimilarityScore: Double {
        didSet { storage.setDouble(minSimilarityScore, forKey: .minSimilarityScore) }
    }
    @Published public var enableGestureMinScore: Bool {
        didSet { storage.setBool(enableGestureMinScore, forKey: .enableGestureMinScore) }
    }
    @Published public var showGestureNote: Bool {
        didSet { storage.setBool(showGestureNote, forKey: .showGestureNote) }
    }

    // MARK: - Gesture trigger buttons
    // 移植版扩展（issue #53）：原版只有右键，这三个开关默认全关，关掉时行为与原版一致。
    @Published public var enableMiddleButtonGesture: Bool {
        didSet { storage.setBool(enableMiddleButtonGesture, forKey: .enableMiddleButtonGesture) }
    }
    @Published public var enableSideButtonGesture: Bool {
        didSet { storage.setBool(enableSideButtonGesture, forKey: .enableSideButtonGesture) }
    }
    @Published public var enableCustomButtonGesture: Bool {
        didSet { storage.setBool(enableCustomButtonGesture, forKey: .enableCustomButtonGesture) }
    }
    /// 录制到的 CoreGraphics 按键编号（3 起），0 表示还没录过。
    @Published public var customGestureButton: Int {
        didSet { storage.setInt(customGestureButton, forKey: .customGestureButton) }
    }

    // MARK: - Note/Toast
    @Published public var noteRetentionTime: Int {
        didSet { storage.setInt(noteRetentionTime, forKey: .noteRetentionTime) }
    }
    @Published public var notePosition: Int {
        didSet { storage.setInt(notePosition, forKey: .notePosition) }
    }
    @Published public var noteBackgroundAlpha: Double {
        didSet { storage.setDouble(noteBackgroundAlpha, forKey: .noteBackgroundAlpha) }
    }
    @Published public var noteFontName: String {
        didSet { storage.setString(noteFontName, forKey: .noteFontName) }
    }
    @Published public var noteFontSize: Double {
        didSet { storage.setDouble(noteFontSize, forKey: .noteFontSize) }
    }
    @Published public var showNoteIcon: Bool {
        didSet { storage.setBool(showNoteIcon, forKey: .showNoteIcon) }
    }

    @Published public var disableMousePath: Bool {
        didSet { storage.setBool(disableMousePath, forKey: .disableMousePath) }
    }
    @Published public var lineColorHex: String {
        didSet { storage.setString(lineColorHex, forKey: .lineColorHex) }
    }

    /// Computed Color wrapper for lineColorHex, used by ColorPicker.
    public var lineColor: Color {
        get { Color(hex: lineColorHex) }
        set { lineColorHex = newValue.hexString }
    }

    /// Computed Color wrapper for defaultNoteColor (original noteColor —
    /// the gesture note text color), used by ColorPicker.
    public var noteColor: Color {
        get { Color(hex: defaultNoteColor) }
        set { defaultNoteColor = newValue.hexString }
    }

    // MARK: - Right-click menu
    @Published public var enableRightClickMenu: Bool {
        didSet { storage.setBool(enableRightClickMenu, forKey: .enableRightClickMenu) }
    }
    @Published public var enableNewFile: Bool {
        didSet { storage.setBool(enableNewFile, forKey: .enableNewFile) }
    }
    @Published public var enableOpenInTerminal: Bool {
        didSet { storage.setBool(enableOpenInTerminal, forKey: .enableOpenInTerminal) }
    }
    @Published public var enableCopyFilePath: Bool {
        didSet { storage.setBool(enableCopyFilePath, forKey: .enableCopyFilePath) }
    }

    // MARK: - Clipboard
    @Published public var enableHistoryClipboard: Bool {
        didSet { storage.setBool(enableHistoryClipboard, forKey: .enableHistoryClipboard) }
    }
    @Published public var clipoardStroageLocal: Bool {
        didSet { storage.setBool(clipoardStroageLocal, forKey: .clipoardStroageLocal) }
    }
    @Published public var historyCilpboardListShortcut: String {
        didSet { storage.setString(historyCilpboardListShortcut, forKey: .historyCilpboardListShortcut) }
    }
    @Published public var enableLimitTop: Bool {
        didSet { storage.setBool(enableLimitTop, forKey: .enableLimitTop) }
    }
    @Published public var limitTop: Int {
        didSet { storage.setInt(limitTop, forKey: .limitTop) }
    }
    @Published public var enableLimitTotal: Bool {
        didSet { storage.setBool(enableLimitTotal, forKey: .enableLimitTotal) }
    }
    @Published public var limitTotal: Int {
        didSet { storage.setInt(limitTotal, forKey: .limitTotal) }
    }
    @Published public var enableLimitSaveDays: Bool {
        didSet { storage.setBool(enableLimitSaveDays, forKey: .enableLimitSaveDays) }
    }
    @Published public var limitSaveDays: Int {
        didSet { storage.setInt(limitSaveDays, forKey: .limitSaveDays) }
    }
    // MARK: - Right-click menu extras
    @Published public var userTerminal: String {
        didSet { storage.setString(userTerminal, forKey: .userTerminal) }
    }

    // MARK: - Updates
    @Published public var autoCheckUpdates: Bool {
        didSet { storage.setBool(autoCheckUpdates, forKey: .autoCheckUpdates) }
    }

    // MARK: - Legacy
    @Published public var showToast: Bool {
        didSet { storage.setBool(showToast, forKey: .showToast) }
    }
    @Published public var clipboardHistoryLimit: Int {
        didSet { storage.setInt(clipboardHistoryLimit, forKey: .clipboardHistoryLimit) }
    }

    public init(storage: PreferencesStorage = PreferencesStorage()) {
        self.storage = storage
        self.showIconInStatusBar = storage.getBoolOptional(forKey: .showIconInStatusBar) ?? StorageDefaults.showIconInStatusBar
        self.showUIInWhateverApp = storage.getBoolOptional(forKey: .showUIInWhateverApp) ?? StorageDefaults.showUIInWhateverApp
        self.blockFilter = storage.getStringOptional(forKey: .blockFilter) ?? StorageDefaults.blockFilter
        self.whiteListMode = storage.getBoolOptional(forKey: .whiteListMode) ?? StorageDefaults.whiteListMode
        self.whiteList = storage.getStringOptional(forKey: .whiteList) ?? StorageDefaults.whiteList
        self.language = storage.getStringOptional(forKey: .language) ?? "en"
        self.openPrefOnStartup = storage.getBoolOptional(forKey: .openPrefOnStartup) ?? StorageDefaults.openPrefOnStartup
        self.mergeConsecutiveIdenticalGestures = storage.getBoolOptional(forKey: .mergeConsecutiveIdenticalGestures) ?? StorageDefaults.mergeConsecutiveIdenticalGestures
        self.defaultLineColor = storage.getStringOptional(forKey: .defaultLineColor) ?? StorageDefaults.defaultLineColor
        self.defaultNoteColor = storage.getStringOptional(forKey: .defaultNoteColor) ?? StorageDefaults.defaultNoteColor
        self.minSimilarityScore = storage.getDoubleOptional(forKey: .minSimilarityScore) ?? StorageDefaults.minSimilarityScore
        self.enableGestureMinScore = storage.getBoolOptional(forKey: .enableGestureMinScore) ?? StorageDefaults.enableGestureMinScore
        self.showGestureNote = storage.getBoolOptional(forKey: .showGestureNote) ?? StorageDefaults.showGestureNote
        self.enableMiddleButtonGesture = storage.getBoolOptional(forKey: .enableMiddleButtonGesture) ?? StorageDefaults.enableMiddleButtonGesture
        self.enableSideButtonGesture = storage.getBoolOptional(forKey: .enableSideButtonGesture) ?? StorageDefaults.enableSideButtonGesture
        self.enableCustomButtonGesture = storage.getBoolOptional(forKey: .enableCustomButtonGesture) ?? StorageDefaults.enableCustomButtonGesture
        self.customGestureButton = storage.getIntOptional(forKey: .customGestureButton) ?? StorageDefaults.customGestureButton
        self.noteRetentionTime = storage.getIntOptional(forKey: .noteRetentionTime) ?? StorageDefaults.noteRetentionTime
        self.notePosition = storage.getIntOptional(forKey: .notePosition) ?? StorageDefaults.notePosition
        self.noteBackgroundAlpha = storage.getDoubleOptional(forKey: .noteBackgroundAlpha) ?? StorageDefaults.noteBackgroundAlpha
        self.noteFontName = storage.getStringOptional(forKey: .noteFontName) ?? StorageDefaults.noteFontName
        self.noteFontSize = storage.getDoubleOptional(forKey: .noteFontSize) ?? StorageDefaults.noteFontSize
        self.showNoteIcon = storage.getBoolOptional(forKey: .showNoteIcon) ?? StorageDefaults.showNoteIcon
        self.disableMousePath = storage.getBoolOptional(forKey: .disableMousePath) ?? StorageDefaults.disableMousePath
        // 存量 "#0000FFFF"（ARGB 写法蓝色）按 RRGGBBAA 解析是透明色，归一化为 "#0000FF"。
        let storedLineColor = storage.getStringOptional(forKey: .lineColorHex) ?? StorageDefaults.lineColorHex
        self.lineColorHex = storedLineColor.caseInsensitiveCompare("#0000FFFF") == .orderedSame ? "#0000FF" : storedLineColor
        self.enableRightClickMenu = storage.getBoolOptional(forKey: .enableRightClickMenu) ?? StorageDefaults.enableRightClickMenu
        self.enableNewFile = storage.getBoolOptional(forKey: .enableNewFile) ?? StorageDefaults.enableNewFile
        self.enableOpenInTerminal = storage.getBoolOptional(forKey: .enableOpenInTerminal) ?? StorageDefaults.enableOpenInTerminal
        self.enableCopyFilePath = storage.getBoolOptional(forKey: .enableCopyFilePath) ?? StorageDefaults.enableCopyFilePath
        self.enableHistoryClipboard = storage.getBoolOptional(forKey: .enableHistoryClipboard) ?? true
        self.clipoardStroageLocal = storage.getBoolOptional(forKey: .clipoardStroageLocal) ?? StorageDefaults.clipoardStroageLocal
        self.historyCilpboardListShortcut = storage.getStringOptional(forKey: .historyCilpboardListShortcut) ?? StorageDefaults.historyCilpboardListShortcut
        self.enableLimitTop = storage.getBoolOptional(forKey: .enableLimitTop) ?? StorageDefaults.enableLimitTop
        self.limitTop = storage.getIntOptional(forKey: .limitTop) ?? StorageDefaults.limitTop
        self.enableLimitTotal = storage.getBoolOptional(forKey: .enableLimitTotal) ?? StorageDefaults.enableLimitTotal
        self.limitTotal = storage.getIntOptional(forKey: .limitTotal) ?? StorageDefaults.limitTotal
        self.enableLimitSaveDays = storage.getBoolOptional(forKey: .enableLimitSaveDays) ?? StorageDefaults.enableLimitSaveDays
        self.limitSaveDays = storage.getIntOptional(forKey: .limitSaveDays) ?? StorageDefaults.limitSaveDays
        self.userTerminal = storage.getStringOptional(forKey: .userTerminal) ?? StorageDefaults.userTerminal
        self.autoCheckUpdates = storage.getBoolOptional(forKey: .autoCheckUpdates) ?? StorageDefaults.autoCheckUpdates
        self.showToast = storage.getBoolOptional(forKey: .showToast) ?? StorageDefaults.showToast
        self.clipboardHistoryLimit = storage.getIntOptional(forKey: .clipboardHistoryLimit) ?? StorageDefaults.clipboardHistoryLimit
    }

    /// Save current preferences to storage immediately.
    public func save() {
        storage.synchronize()
    }

    /// Reset preferences the way the original `resetDefaults:` does — iterate the
    /// keys of `DefaultPreferences.plist` and write each back to UserDefaults.
    /// Keys that plist does not carry are therefore left alone: language, the
    /// black/white filter lists and mode, the login item, the minimum-points
    /// threshold, the mouse-path switch, update settings and the master switch.
    public func resetToDefaults() {
        storage.setBool(StorageDefaults.showIconInStatusBar, forKey: .showIconInStatusBar)
        storage.setBool(StorageDefaults.showUIInWhateverApp, forKey: .showUIInWhateverApp)
        storage.setBool(StorageDefaults.openPrefOnStartup, forKey: .openPrefOnStartup)
        storage.setBool(StorageDefaults.mergeConsecutiveIdenticalGestures, forKey: .mergeConsecutiveIdenticalGestures)
        storage.setString(StorageDefaults.defaultLineColor, forKey: .defaultLineColor)
        storage.setString(StorageDefaults.defaultNoteColor, forKey: .defaultNoteColor)
        storage.setDouble(StorageDefaults.minSimilarityScore, forKey: .minSimilarityScore)
        storage.setBool(StorageDefaults.enableGestureMinScore, forKey: .enableGestureMinScore)
        storage.setBool(StorageDefaults.showGestureNote, forKey: .showGestureNote)
        // 原版没有这几个键，但「恢复默认」把额外触发键关掉才是用户期待的结果
        // （否则重置后中键/侧键依旧在起手，界面却显示为关）。
        storage.setBool(StorageDefaults.enableMiddleButtonGesture, forKey: .enableMiddleButtonGesture)
        storage.setBool(StorageDefaults.enableSideButtonGesture, forKey: .enableSideButtonGesture)
        storage.setBool(StorageDefaults.enableCustomButtonGesture, forKey: .enableCustomButtonGesture)
        storage.setInt(StorageDefaults.customGestureButton, forKey: .customGestureButton)
        storage.setInt(StorageDefaults.noteRetentionTime, forKey: .noteRetentionTime)
        storage.setInt(StorageDefaults.notePosition, forKey: .notePosition)
        storage.setDouble(StorageDefaults.noteBackgroundAlpha, forKey: .noteBackgroundAlpha)
        storage.setString(StorageDefaults.noteFontName, forKey: .noteFontName)
        storage.setDouble(StorageDefaults.noteFontSize, forKey: .noteFontSize)
        storage.setBool(StorageDefaults.showNoteIcon, forKey: .showNoteIcon)
        // Original MGOptionsDefine resetColors: re-derive the live colors from
        // the defaultLineColor / defaultNoteColor strings.
        storage.setString(StorageDefaults.defaultLineColor, forKey: .lineColorHex)
        storage.setBool(StorageDefaults.enableRightClickMenu, forKey: .enableRightClickMenu)
        storage.setBool(StorageDefaults.enableNewFile, forKey: .enableNewFile)
        storage.setBool(StorageDefaults.enableOpenInTerminal, forKey: .enableOpenInTerminal)
        storage.setBool(StorageDefaults.enableCopyFilePath, forKey: .enableCopyFilePath)
        storage.setString(StorageDefaults.userTerminal, forKey: .userTerminal)
        storage.setBool(StorageDefaults.enableHistoryClipboard, forKey: .enableHistoryClipboard)
        storage.setBool(StorageDefaults.clipoardStroageLocal, forKey: .clipoardStroageLocal)
        storage.setString(StorageDefaults.historyCilpboardListShortcut, forKey: .historyCilpboardListShortcut)
        storage.setBool(StorageDefaults.enableLimitTop, forKey: .enableLimitTop)
        storage.setInt(StorageDefaults.limitTop, forKey: .limitTop)
        storage.setBool(StorageDefaults.enableLimitTotal, forKey: .enableLimitTotal)
        storage.setInt(StorageDefaults.limitTotal, forKey: .limitTotal)
        storage.setBool(StorageDefaults.enableLimitSaveDays, forKey: .enableLimitSaveDays)
        storage.setInt(StorageDefaults.limitSaveDays, forKey: .limitSaveDays)
        storage.synchronize()
        reloadResetValues()
    }

    /// The original refreshes its bound controls automatically through the
    /// shared `NSUserDefaultsController`; SwiftUI holds its own copies, so push
    /// the just-written defaults back into the published properties.
    private func reloadResetValues() {
        showIconInStatusBar = storage.getBool(forKey: .showIconInStatusBar)
        showUIInWhateverApp = storage.getBool(forKey: .showUIInWhateverApp)
        openPrefOnStartup = storage.getBool(forKey: .openPrefOnStartup)
        mergeConsecutiveIdenticalGestures = storage.getBool(forKey: .mergeConsecutiveIdenticalGestures)
        defaultLineColor = storage.getString(forKey: .defaultLineColor) ?? StorageDefaults.defaultLineColor
        defaultNoteColor = storage.getString(forKey: .defaultNoteColor) ?? StorageDefaults.defaultNoteColor
        minSimilarityScore = storage.getDouble(forKey: .minSimilarityScore)
        enableGestureMinScore = storage.getBool(forKey: .enableGestureMinScore)
        showGestureNote = storage.getBool(forKey: .showGestureNote)
        enableMiddleButtonGesture = storage.getBool(forKey: .enableMiddleButtonGesture)
        enableSideButtonGesture = storage.getBool(forKey: .enableSideButtonGesture)
        enableCustomButtonGesture = storage.getBool(forKey: .enableCustomButtonGesture)
        customGestureButton = storage.getInt(forKey: .customGestureButton)
        noteRetentionTime = storage.getInt(forKey: .noteRetentionTime)
        notePosition = storage.getInt(forKey: .notePosition)
        noteBackgroundAlpha = storage.getDouble(forKey: .noteBackgroundAlpha)
        noteFontName = storage.getString(forKey: .noteFontName) ?? StorageDefaults.noteFontName
        noteFontSize = storage.getDouble(forKey: .noteFontSize)
        showNoteIcon = storage.getBool(forKey: .showNoteIcon)
        lineColorHex = storage.getString(forKey: .lineColorHex) ?? StorageDefaults.defaultLineColor
        enableRightClickMenu = storage.getBool(forKey: .enableRightClickMenu)
        enableNewFile = storage.getBool(forKey: .enableNewFile)
        enableOpenInTerminal = storage.getBool(forKey: .enableOpenInTerminal)
        enableCopyFilePath = storage.getBool(forKey: .enableCopyFilePath)
        userTerminal = storage.getString(forKey: .userTerminal) ?? StorageDefaults.userTerminal
        enableHistoryClipboard = storage.getBool(forKey: .enableHistoryClipboard)
        clipoardStroageLocal = storage.getBool(forKey: .clipoardStroageLocal)
        historyCilpboardListShortcut = storage.getString(forKey: .historyCilpboardListShortcut) ?? StorageDefaults.historyCilpboardListShortcut
        enableLimitTop = storage.getBool(forKey: .enableLimitTop)
        limitTop = storage.getInt(forKey: .limitTop)
        enableLimitTotal = storage.getBool(forKey: .enableLimitTotal)
        limitTotal = storage.getInt(forKey: .limitTotal)
        enableLimitSaveDays = storage.getBool(forKey: .enableLimitSaveDays)
        limitSaveDays = storage.getInt(forKey: .limitSaveDays)
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3: // RGB
            (r, g, b) = ((int >> 8) & 0xFF, (int >> 4) & 0xFF, int & 0xFF)
        case 6: // RRGGBB
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8: // RRGGBBAA
            (r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }

    /// Returns a hex string representation of the color (e.g. "#FF0000").
    var hexString: String {
        let cgColor = NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        cgColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "#%02lX%02lX%02lX",
            lround(r * 255),
            lround(g * 255),
            lround(b * 255)
        )
    }
}

// MARK: - AppKit bridge for SwiftUI preferences window.
public final class PreferencesWindowController: NSWindowController {
    private let viewModel: UserPreferences
    private var languageObserver: NSObjectProtocol?

    public init(viewModel: UserPreferences) {
        self.viewModel = viewModel
        super.init(window: nil)

        let hostingController = NSHostingController(
            rootView: PreferencesView(viewModel: viewModel)
        )
        hostingController.title = L("MacStroke Preferences")
        self.contentViewController = hostingController

        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window?.contentView = hostingController.view
        self.window?.center()
        self.window?.title = L("MacStroke Preferences")

        languageObserver = NotificationCenter.default.addObserver(
            forName: .languageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.window?.title = L("MacStroke Preferences")
        }
    }

    deinit {
        if let observer = languageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}