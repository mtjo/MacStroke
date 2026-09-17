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
    @Published public var isEnabled: Bool {
        didSet { storage.setBool(isEnabled, forKey: .isEnabled) }
    }
    @Published public var showIconInStatusBar: Bool {
        didSet { storage.setBool(showIconInStatusBar, forKey: .showIconInStatusBar) }
    }
    @Published public var launchAtLogin: Bool {
        didSet { storage.setBool(launchAtLogin, forKey: .launchAtLogin) }
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

    // MARK: - Gesture recognition
    @Published public var minimumPoints: Int {
        didSet { storage.setInt(minimumPoints, forKey: .minimumPoints) }
    }
    @Published public var minSimilarityScore: Double {
        didSet { storage.setDouble(minSimilarityScore, forKey: .minSimilarityScore) }
    }
    @Published public var enableGestureMinScore: Bool {
        didSet { storage.setBool(enableGestureMinScore, forKey: .enableGestureMinScore) }
    }
    @Published public var showGestureNote: Bool {
        didSet { storage.setBool(showGestureNote, forKey: .showGestureNote) }
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

    // MARK: - Drawing
    @Published public var disableMousePath: Bool {
        didSet { storage.setBool(disableMousePath, forKey: .disableMousePath) }
    }
    @Published public var lineColorHex: String {
        didSet { storage.setString(lineColorHex, forKey: .lineColorHex) }
    }
    @Published public var lineWidth: Double {
        didSet { storage.setDouble(lineWidth, forKey: .lineWidth) }
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
    @Published public var clipboardLimitTop: Int {
        didSet { storage.setInt(clipboardLimitTop, forKey: .clipboardLimitTop) }
    }
    @Published public var clipboardLimitTotal: Int {
        didSet { storage.setInt(clipboardLimitTotal, forKey: .clipboardLimitTotal) }
    }
    @Published public var clipboardSaveDays: Int {
        didSet { storage.setInt(clipboardSaveDays, forKey: .clipboardSaveDays) }
    }
    @Published public var enableHistoryClipboard: Bool {
        didSet { storage.setBool(enableHistoryClipboard, forKey: .enableHistoryClipboard) }
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
        self.isEnabled = storage.getBoolOptional(forKey: .isEnabled) ?? StorageDefaults.isEnabled
        self.showIconInStatusBar = storage.getBoolOptional(forKey: .showIconInStatusBar) ?? StorageDefaults.showIconInStatusBar
        self.launchAtLogin = storage.getBoolOptional(forKey: .launchAtLogin) ?? StorageDefaults.launchAtLogin
        self.showUIInWhateverApp = storage.getBoolOptional(forKey: .showUIInWhateverApp) ?? StorageDefaults.showUIInWhateverApp
        self.blockFilter = storage.getStringOptional(forKey: .blockFilter) ?? StorageDefaults.blockFilter
        self.whiteListMode = storage.getBoolOptional(forKey: .whiteListMode) ?? StorageDefaults.whiteListMode
        self.whiteList = storage.getStringOptional(forKey: .whiteList) ?? StorageDefaults.whiteList
        self.language = storage.getStringOptional(forKey: .language) ?? "en"
        self.minimumPoints = storage.getIntOptional(forKey: .minimumPoints) ?? StorageDefaults.minimumPoints
        self.minSimilarityScore = storage.getDoubleOptional(forKey: .minSimilarityScore) ?? StorageDefaults.minSimilarityScore
        self.enableGestureMinScore = storage.getBoolOptional(forKey: .enableGestureMinScore) ?? StorageDefaults.enableGestureMinScore
        self.showGestureNote = storage.getBoolOptional(forKey: .showGestureNote) ?? StorageDefaults.showGestureNote
        self.noteRetentionTime = storage.getIntOptional(forKey: .noteRetentionTime) ?? StorageDefaults.noteRetentionTime
        self.notePosition = storage.getIntOptional(forKey: .notePosition) ?? StorageDefaults.notePosition
        self.noteBackgroundAlpha = storage.getDoubleOptional(forKey: .noteBackgroundAlpha) ?? StorageDefaults.noteBackgroundAlpha
        self.noteFontName = storage.getStringOptional(forKey: .noteFontName) ?? StorageDefaults.noteFontName
        self.noteFontSize = storage.getDoubleOptional(forKey: .noteFontSize) ?? StorageDefaults.noteFontSize
        self.showNoteIcon = storage.getBoolOptional(forKey: .showNoteIcon) ?? StorageDefaults.showNoteIcon
        self.disableMousePath = storage.getBoolOptional(forKey: .disableMousePath) ?? StorageDefaults.disableMousePath
        self.lineColorHex = storage.getStringOptional(forKey: .lineColorHex) ?? StorageDefaults.lineColorHex
        self.lineWidth = storage.getDoubleOptional(forKey: .lineWidth) ?? StorageDefaults.lineWidth
        self.enableRightClickMenu = storage.getBoolOptional(forKey: .enableRightClickMenu) ?? StorageDefaults.enableRightClickMenu
        self.enableNewFile = storage.getBoolOptional(forKey: .enableNewFile) ?? StorageDefaults.enableNewFile
        self.enableOpenInTerminal = storage.getBoolOptional(forKey: .enableOpenInTerminal) ?? StorageDefaults.enableOpenInTerminal
        self.enableCopyFilePath = storage.getBoolOptional(forKey: .enableCopyFilePath) ?? StorageDefaults.enableCopyFilePath
        self.clipboardLimitTop = storage.getIntOptional(forKey: .clipboardLimitTop) ?? StorageDefaults.clipboardLimitTop
        self.clipboardLimitTotal = storage.getIntOptional(forKey: .clipboardLimitTotal) ?? StorageDefaults.clipboardLimitTotal
        self.clipboardSaveDays = storage.getIntOptional(forKey: .clipboardSaveDays) ?? StorageDefaults.clipboardSaveDays
        self.enableHistoryClipboard = storage.getBoolOptional(forKey: .enableHistoryClipboard) ?? true
        self.autoCheckUpdates = storage.getBoolOptional(forKey: .autoCheckUpdates) ?? StorageDefaults.autoCheckUpdates
        self.showToast = storage.getBoolOptional(forKey: .showToast) ?? StorageDefaults.showToast
        self.clipboardHistoryLimit = storage.getIntOptional(forKey: .clipboardHistoryLimit) ?? StorageDefaults.clipboardHistoryLimit
    }

    /// Save current preferences to storage immediately.
    public func save() {
        storage.synchronize()
    }

    /// Reset all preferences to their default values.
    public func resetToDefaults() {
        storage.setBool(StorageDefaults.isEnabled, forKey: .isEnabled)
        storage.setBool(StorageDefaults.showIconInStatusBar, forKey: .showIconInStatusBar)
        storage.setBool(StorageDefaults.launchAtLogin, forKey: .launchAtLogin)
        storage.setBool(StorageDefaults.showUIInWhateverApp, forKey: .showUIInWhateverApp)
        storage.setString(StorageDefaults.blockFilter, forKey: .blockFilter)
        storage.setBool(StorageDefaults.whiteListMode, forKey: .whiteListMode)
        storage.setString(StorageDefaults.whiteList, forKey: .whiteList)
        storage.setString("en", forKey: .language)
        storage.setInt(StorageDefaults.minimumPoints, forKey: .minimumPoints)
        storage.setDouble(StorageDefaults.minSimilarityScore, forKey: .minSimilarityScore)
        storage.setBool(StorageDefaults.enableGestureMinScore, forKey: .enableGestureMinScore)
        storage.setBool(StorageDefaults.showGestureNote, forKey: .showGestureNote)
        storage.setInt(StorageDefaults.noteRetentionTime, forKey: .noteRetentionTime)
        storage.setInt(StorageDefaults.notePosition, forKey: .notePosition)
        storage.setDouble(StorageDefaults.noteBackgroundAlpha, forKey: .noteBackgroundAlpha)
        storage.setString(StorageDefaults.noteFontName, forKey: .noteFontName)
        storage.setDouble(StorageDefaults.noteFontSize, forKey: .noteFontSize)
        storage.setBool(StorageDefaults.showNoteIcon, forKey: .showNoteIcon)
        storage.setBool(StorageDefaults.disableMousePath, forKey: .disableMousePath)
        storage.setString(StorageDefaults.lineColorHex, forKey: .lineColorHex)
        storage.setDouble(StorageDefaults.lineWidth, forKey: .lineWidth)
        storage.setBool(StorageDefaults.enableRightClickMenu, forKey: .enableRightClickMenu)
        storage.setBool(StorageDefaults.enableNewFile, forKey: .enableNewFile)
        storage.setBool(StorageDefaults.enableOpenInTerminal, forKey: .enableOpenInTerminal)
        storage.setBool(StorageDefaults.enableCopyFilePath, forKey: .enableCopyFilePath)
        storage.setInt(StorageDefaults.clipboardLimitTop, forKey: .clipboardLimitTop)
        storage.setInt(StorageDefaults.clipboardLimitTotal, forKey: .clipboardLimitTotal)
        storage.setInt(StorageDefaults.clipboardSaveDays, forKey: .clipboardSaveDays)
        storage.setBool(true, forKey: .enableHistoryClipboard)
        storage.setBool(StorageDefaults.autoCheckUpdates, forKey: .autoCheckUpdates)
        storage.setBool(StorageDefaults.showToast, forKey: .showToast)
        storage.setInt(StorageDefaults.clipboardHistoryLimit, forKey: .clipboardHistoryLimit)
        storage.synchronize()
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
            styleMask: [.titled, .closable, .miniaturizable],
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