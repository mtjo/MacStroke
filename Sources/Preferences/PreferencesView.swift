//
//  PreferencesView.swift
//  MacStroke
//
//  SwiftUI-based tabbed preferences UI for MacStroke.
//  Tab layout mirrors the original AppPrefsWindowController.setupToolbar:
//  General, Rules, Filters, AppleScript, RightClick, RightClickMenu,
//  Clipboard, About.
//

import SwiftUI
import AppKit
import WebKit
import Storage
import RuleEngine
import AppleScriptRunner
import RightClickMenu
import GestureEngine
import EventCapture

// MARK: - Identifiable Conformance

extension Rule: Identifiable {
    public var id: String { name }
}

// MARK: - Preferences Tab Enumeration

/// Original MacStroke preferences tab enumeration (8 tabs, matching
/// AppPrefsWindowController.setupToolbar) plus the port's Remote Control page.
/// The raw value is the key external entry points (status bar menu) use to ask
/// for a page, so it must stay stable.
public enum PreferencesTab: String, CaseIterable {
    case general
    case rules
    case filters
    case appleScript
    case rightClick
    case rightClickMenu
    case clipboard
    // 移植版新增页（超出原版）：手机小程序远程控制，放在粘贴板与关于之间。
    case remoteControl
    // 移植版新增页（超出原版）：截图的落地方式，跟在远程控制后面。
    // 移植版新增页（超出原版）：截图、滚动截图、录屏的落地方式，跟在远程控制后面。
    // 页名和状态栏那一条用同一个 key（截图/录屏），两处不一致会让人以为偏好里少了一页。
    case screenshot
    // 移植版新增页（超出原版）：蓝牙靠近锁屏，跟在截图后面。
    case proximityLock
    // 移植版新增页（超出原版）：划词气泡。排在所有新增页之后、关于之前 ——
    // 前三条侧栏位置用例（远程控制/截图/靠近锁屏）都按相邻序号断言，插进它们中间会连带改测试。
    case selectionBubble
    case about

    var title: String {
        switch self {
        case .general: return L("General")
        case .rules: return L("Rules")
        case .filters: return L("Filters")
        case .appleScript: return L("AppleScript")
        case .rightClick: return L("RightClick")
        case .rightClickMenu: return L("RightClickMenu")
        case .clipboard: return L("Clipboard")
        case .remoteControl: return L("Remote Control")
        case .screenshot: return L("Screenshot or record")
        case .proximityLock: return L("Proximity Lock")
        case .selectionBubble: return L("Selection Bubble")
        case .about: return L("About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .rules: return "waveform"
        case .filters: return "line.3.horizontal.decrease"
        case .appleScript: return "curlybraces"
        case .rightClick: return "mouse"
        case .rightClickMenu: return "list.bullet.rectangle"
        case .clipboard: return "doc.on.clipboard"
        case .remoteControl: return "dot.radiowaves.left.and.right"
        case .screenshot: return "camera.viewfinder"
        case .proximityLock: return "antenna.radiowaves.left.and.right"
        case .selectionBubble: return "bubble.left"
        case .about: return "info.circle"
        }
    }

    /// Bundle image shipped by the original preferences toolbar
    /// (AppPrefsWindowController.setupToolbar), used when no SF Symbol of the
    /// same meaning renders on this system.
    var iconResourceName: String? {
        switch self {
        case .rightClick: return "RightClick"
        default: return nil
        }
    }
}

// MARK: - Check-for-updates notification (handled by the AppDelegate)

public extension Notification.Name {
    /// Ask the AppDelegate (which owns the Sparkle updater) to check for updates.
    static let macStrokeCheckForUpdates = Notification.Name("MacStrokeCheckForUpdates")
    /// Ask the AppDelegate to enter gesture-recording mode for the named rule
    /// (userInfo: ["ruleName": String]).
    static let macStrokeRecordGesture = Notification.Name("MacStrokeRecordGesture")
    /// Leave gesture-recording mode without storing anything.
    static let macStrokeCancelRecordGesture = Notification.Name("MacStrokeCancelRecordGesture")
    /// A screen-drawn stroke finished; userInfo carries ["ruleName": String,
    /// "points": [GesturePoint]] so an open rule editor can capture it too.
    static let macStrokeGestureDidRecord = Notification.Name("MacStrokeGestureDidRecord")
    /// Sparkle update settings changed in the About tab.
    static let macStrokeUpdateSettingsDidChange = Notification.Name("MacStrokeUpdateSettingsDidChange")
    /// Ask the AppDelegate to open the clipboard history window (Clipboard tab
    /// "show history clipboard", original `showHistoryCilpboardList:`).
    static let macStrokeShowHistoryClipboard = Notification.Name("MacStrokeShowHistoryClipboard")
    /// Ask the preferences window to show one page (object: `PreferencesTab.rawValue`).
    static let macStrokeShowPreferencesTab = Notification.Name("MacStrokeShowPreferencesTab")
    /// Ask the AppDelegate to forget the versions the user chose "Skip this
    /// version" for, and to re-arm the scheduled check (About tab).
    static let macStrokeRestoreSkippedUpdate = Notification.Name("MacStrokeRestoreSkippedUpdate")
}

/// Original feedback channel for confirmations and guards: a banner-style
/// `NSUserNotification` titled "MacStroke". The preferences window never uses a
/// modal alert for these, so the user can keep working without dismissing it.
func postMacStrokeNotification(_ text: String) {
    let notification = NSUserNotification()
    notification.title = "MacStroke"
    notification.informativeText = text
    notification.soundName = NSUserNotificationDefaultSoundName
    NSUserNotificationCenter.default.deliver(notification)
}

// MARK: - Shortcut Recorder SwiftUI Wrapper

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var text: String
    var onShortcutChanged: ((String) -> Void)?
    /// Records a modifier combination only, committed when the keys are
    /// released (the gesture-suppression row, issue #59).
    var modifiersOnly = false
    @Environment(\.colorScheme) private var colorScheme

    /// The scheme this page is actually drawing in, translated for the AppKit view.
    /// SwiftUI hands a representable its own appearance and on macOS 26/27 that one
    /// tracks the system setting, not the page, which made the recorder render with
    /// dark colours on a light window.
    private var hostAppearance: NSAppearance? {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.drawAppearance = hostAppearance
        view.modifiersOnly = modifiersOnly
        // Show the persisted shortcut (e.g. the ⌘V default) right away.
        if let parsed = Self.parse(text) {
            view.keyCode = parsed.keyCode
            view.flags = parsed.flags
        }
        view.onShortcutChanged = { code, flags in
            text = "keyCode=\(code), flags=\(flags)"
            onShortcutChanged?(text)
        }
        // 置空写成空串：`"keyCode=0, flags=0"` 能解析成一个真实的键（0 就是 A），
        // 快捷键监听会照挂，那等于把用户的 A 键全局吞掉。空串解析不出任何东西，
        // 消费端（AppDelegate / WindowManager）走的是「停掉监听」那条分支。
        view.onClear = {
            text = ""
            onShortcutChanged?("")
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.modifiersOnly = modifiersOnly
        if nsView.drawAppearance?.name != hostAppearance?.name {
            nsView.drawAppearance = hostAppearance
        }
        // Sync external changes (reset to defaults etc.) into the view
        // while the user is not actively recording.
        guard !nsView.isRecording else { return }
        let parsed = Self.parse(text)
        // 解析不出来就是「已清除」，视图里那份旧值也得跟着抹掉；只认有值的那条分支
        // 会让清除后的框继续显示 ⌘⇧A，而偏好里已经存了空串。
        let keyCode = parsed?.keyCode ?? 0
        let flags = parsed?.flags ?? 0
        if nsView.keyCode != keyCode || nsView.flags != flags {
            nsView.keyCode = keyCode
            nsView.flags = flags
        }
    }

    /// Parse a "keyCode=X, flags=Y" string.
    static func parse(_ raw: String) -> (keyCode: UInt16, flags: UInt)? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        let pattern = #"keyCode=(\d+),\s*flags=(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let keyCodeRange = Range(match.range(at: 1), in: cleaned),
              let flagsRange = Range(match.range(at: 2), in: cleaned),
              let keyCodeInt = Int(String(cleaned[keyCodeRange])),
              let flagsInt = Int(String(cleaned[flagsRange]))
        else { return nil }
        return (UInt16(keyCodeInt), UInt(flagsInt))
    }
}

// MARK: - Root View

public struct PreferencesView: View {
    @ObservedObject var viewModel: UserPreferences
    @State private var selectedTab: PreferencesTab = .general
    @StateObject private var ruleStore = RuleStore.shared
    @ObservedObject private var scriptList = AppleScriptsList.sharedAppleScriptsList
    @State private var rightClickApps: [String] = []
    /// Bumped whenever the UI language changes so the whole view tree
    /// re-renders with the new localized strings.
    @State private var languageRevision = 0

    public init(viewModel: UserPreferences, initialTab: PreferencesTab = .general) {
        self.viewModel = viewModel
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Sidebar (macOS System Settings style)
            VStack(spacing: 1) {
                ForEach(PreferencesTab.allCases, id: \.self) { tab in
                    TabButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
                    )
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .frame(width: SettingsChrome.sidebarWidth, alignment: .leading)
            .background(SettingsChrome.sidebarBackground)

            Divider()

            // Each page supplies its own chrome (scrolling form vs. table that
            // must fill the viewport).
            Group {
                switch selectedTab {
                case .general:
                    GeneralTabView(viewModel: viewModel)
                case .rules:
                    RulesTabView(viewModel: viewModel, ruleStore: ruleStore)
                case .filters:
                    FiltersTabView(viewModel: viewModel)
                case .appleScript:
                    AppleScriptTabView(scriptList: scriptList)
                case .rightClick:
                    RightClickTabView(rightClickApps: $rightClickApps)
                case .rightClickMenu:
                    RightClickMenuTabView(viewModel: viewModel)
                case .clipboard:
                    ClipboardTabView(viewModel: viewModel)
                case .remoteControl:
                    RemoteControlTabView(viewModel: viewModel)
                case .screenshot:
                    ScreenshotTabView(viewModel: viewModel)
                case .proximityLock:
                    ProximityLockTabView(viewModel: viewModel)
                case .selectionBubble:
                    SelectionBubbleTabView(viewModel: viewModel)
                case .about:
                    AboutTabView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 620)
        .id(languageRevision)
        .onReceive(NotificationCenter.default.publisher(for: .languageDidChange)) { _ in
            languageRevision += 2
        }
        .frame(minWidth: 820, minHeight: 620)
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            rightClickApps = RightClicksList.shared.allApps()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macStrokeRuleStoreDidChange)) { _ in
            // A screen-drawn gesture was recorded into a rule — refresh.
            ruleStore.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macStrokeShowPreferencesTab)) { note in
            guard let key = note.object as? String, let tab = PreferencesTab(rawValue: key) else { return }
            selectedTab = tab
        }
    }
}

/// Sidebar entry, styled like a System Settings row: rounded accent
/// highlight with white content when selected.
struct TabButton: View {
    let tab: PreferencesTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20, height: 20)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .white : .primary)
    }

    @ViewBuilder
    private var icon: some View {
        if let name = tab.iconResourceName, let nsImage = NSImage(named: name) {
            Image(nsImage: sidebarIconImage(nsImage))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: tab.systemImage)
        }
    }
}

/// The original's toolbar PNGs are flat black glyphs, which disappear on the dark
/// sidebar. Marked as a template the image is just a mask, so it takes the row's
/// text colour (primary, or white on the selected highlight).
func sidebarIconImage(_ image: NSImage) -> NSImage {
    guard let copy = image.copy() as? NSImage else {
        image.isTemplate = true
        return image
    }
    copy.isTemplate = true
    return copy
}

// MARK: - General Tab
// Original General tab: app toggles, language, gesture recognition settings,
// note (toast) settings, drawing settings, import/export, reset defaults.

// MARK: - General Tab
// Mirrors the original AppPrefsWindowController General tab layout exactly:
// Box groups (top to bottom): General -> Gesture -> Note -> Import/Export/Reset buttons
// 划词气泡原来是常规页最后一段，这一版挪成侧栏独立一页（`SelectionBubbleTabView`）：
// 它要配的东西有九项，留在常规页底部会把导入/导出/重置顶出可视区，也更难被找到。

struct GeneralTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @StateObject private var launchController = LaunchAtLoginController.shared

    var body: some View {
        SettingsPage {
            // MARK: General (original xib order: enable / open prefs /
            // auto start / status bar icon / language)
            SettingsSection(title: L("General Settings")) {
                SettingsCard {
                    SettingsRow(L("Enable MacStroke")) {
                        TrailingSwitch(isOn: Binding(
                            get: { viewModel.isEnabled },
                            set: { newValue in
                                viewModel.isEnabled = newValue
                                NotificationCenter.default.post(
                                    name: .macStrokeEnabledDidChange, object: newValue)
                            }
                        ))
                    }
                    RowDivider()
                    SettingsRow(L("Open Preferences Window at Startup")) {
                        TrailingSwitch(isOn: $viewModel.openPrefOnStartup)
                    }
                    RowDivider()
                    SettingsRow(L("Auto Start at Login")) {
                        TrailingSwitch(isOn: Binding(
                            get: { launchController.isEnabled },
                            set: { enabled in
                                // 原版只调 addToLoginItems/removeFromLoginItems，不落任何偏好键
                                launchController.setEnabled(enabled)
                            }
                        ))
                    }
                    RowDivider()
                    SettingsRow(L("Show Icon In Status Bar")) {
                        TrailingSwitch(isOn: Binding(
                            get: { viewModel.showIconInStatusBar },
                            set: { newValue in
                                viewModel.showIconInStatusBar = newValue
                                NotificationCenter.default.post(
                                    name: .showIconInStatusBarDidChange, object: newValue)
                            }
                        ))
                    }
                    RowDivider()
                    SettingsRow(L("Language:")) {
                        // Original is an editable NSComboBox (width 81) whose
                        // items are the raw locale codes added in code.
                        Picker(L("Language"), selection: $viewModel.language) {
                            Text("en").tag("en")
                            Text("zh-Hans").tag("zh-Hans")
                        }
                        .labelsHidden()
                        .frame(width: 81)
                        .onChange(of: viewModel.language) { _ in
                            postMacStrokeNotification(L("Restart MacStroke to take effect"))
                        }
                    }
                }
            }

            // MARK: Gesture
            SettingsSection(title: L("Gesture")) {
                SettingsCard {
                    SettingsRow(L("Gesture Min Score")) {
                        TrailingSwitch(isOn: $viewModel.enableGestureMinScore)
                    }
                    RowDivider()
                    SettingsRow(L("Min Score:")) {
                        HStack(spacing: 8) {
                            Text("\(Int(viewModel.minSimilarityScore))")
                                .foregroundColor(.secondary)
                                .frame(width: 26, alignment: .trailing)
                            Slider(value: $viewModel.minSimilarityScore, in: 70...99, step: 1)
                                .frame(width: 210)
                        }
                    }
                    RowDivider()
                    SettingsRow(L("Disable Mouse Path")) {
                        TrailingSwitch(isOn: $viewModel.disableMousePath)
                    }
                    RowDivider()
                    SettingsRow(L("Show Gesture In Whatever App")) {
                        TrailingSwitch(isOn: $viewModel.showUIInWhateverApp)
                    }
                    // 手势起手键（issue #53）：一个录制框，默认右键，也就是原版的
                    // 唯一起手键。AppDelegate 每事件现读偏好，录完不用重启即生效。
                    RowDivider()
                    SettingsRow(L("Gesture Trigger Button")) {
                        MouseButtonRecorder(buttonNumber: $viewModel.gestureTriggerButton)
                    }
                    // 按住修饰键时不起手（issue #59）：一个开关配一个只录修饰键的
                    // 快捷键框，录到什么组合就避让什么，含它的组合键同样让位。
                    RowDivider()
                    SettingsRow(L("Hold Modifiers To Skip Gesture")) {
                        TrailingSwitch(isOn: $viewModel.enableGestureSuppression) {
                            ShortcutRecorder(
                                text: viewModel.suppressedModifiersBinding(),
                                modifiersOnly: true
                            )
                            .frame(width: 130, height: 24)
                        }
                    }
                    // 画完一条却没匹配上时不再弹右键菜单（issue #73）：一个开关，默认关
                    // = 原版行为。只认「真的画了一条」，纯右键单击照常弹菜单。
                    RowDivider()
                    SettingsRow(L("Skip Menu When Gesture Unmatched")) {
                        TrailingSwitch(isOn: $viewModel.swallowUnmatchedGesture)
                    }
                    RowDivider()
                    SettingsRow(L("Line color:")) {
                        ColorWellField(color: $viewModel.lineColor)
                            .frame(width: 100, height: 18)
                    }
                }
            }

            // MARK: Note
            SettingsSection(title: L("Note")) {
                SettingsCard {
                    SettingsRow(L("Show Gesture Note")) {
                        TrailingSwitch(isOn: $viewModel.showGestureNote)
                    }
                    RowDivider()
                    SettingsRow(L("Font:")) {
                        HStack(spacing: 8) {
                            // Original binds these two fields read-only; the
                            // font panel is the only way to change them.
                            Text(viewModel.noteFontName)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text("\(Int(viewModel.noteFontSize))")
                                .foregroundColor(.secondary)
                            Button(L("Choose")) { openFontPanel() }
                        }
                    }
                    RowDivider()
                    SettingsRow(L("Show Icon")) {
                        TrailingSwitch(isOn: $viewModel.showNoteIcon)
                    }
                    RowDivider()
                    SettingsRow(L("Postion:")) {
                        Picker("", selection: $viewModel.notePosition) {
                            Text(L("Follow The Mouse")).tag(0)
                            Text(L("Center In Screen")).tag(1)
                            Text(L("Right Top")).tag(2)
                            Text(L("Right Bottom")).tag(3)
                            Text(L("Left Top")).tag(4)
                            Text(L("Left Bottom")).tag(5)
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    RowDivider()
                    SettingsRow(L("Background Apha:")) {
                        Slider(value: $viewModel.noteBackgroundAlpha, in: 0...0.7, step: 0.05)
                            .frame(width: 210)
                    }
                    RowDivider()
                    SettingsRow(L("Retention Time:")) {
                        HStack(spacing: 8) {
                            Text(String(format: "%.0f", viewModel.noteRetentionTime))
                                .foregroundColor(.secondary)
                                .frame(width: 26, alignment: .trailing)
                            Slider(value: Binding(
                                get: { Double(viewModel.noteRetentionTime) },
                                set: { viewModel.noteRetentionTime = Int($0) }
                            ), in: 1...4, step: 1)
                            .frame(width: 210)
                        }
                    }
                }
            }

            // MARK: Selection bubble（划词气泡）
            // 这一页整块挪到侧栏独立一页了（见 `SelectionBubbleTabView`）：一条功能要配的是
            // 「总开关 + 两条触发方式 + 四格各自开关」，塞在常规页底部会把导入/导出/重置顶下去，
            // 而常规页本来就是原版最满的一页。

            // MARK: Import / Export / Reset (original: buttons under the Note box)
            HStack(spacing: 12) {
                Spacer()
                Button(L("Import")) { importPreferences() }
                Button(L("Export")) { exportPreferences() }
                Button(L("Reset Defaults")) { resetDefaults() }
            }
        }
        .onAppear {
            // System Settings can change the login item while we run, so
            // re-read the state instead of keeping the launch-time snapshot.
            launchController.refreshState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MacStrokeNoteFontDidChange"))) { _ in
            let defaults = UserDefaults.standard
            if let name = defaults.string(forKey: "noteFontName") {
                viewModel.noteFontName = name
            }
            viewModel.noteFontSize = defaults.double(forKey: "noteFontSize")
            if let noteColor = defaults.string(forKey: "defaultNoteColor") {
                viewModel.defaultNoteColor = noteColor
            }
        }
    }

    private func openFontPanel() {
        let fontManager = NSFontManager.shared
        fontManager.target = FontPanelObserver.shared
        if let current = NSFont(name: viewModel.noteFontName, size: CGFloat(viewModel.noteFontSize)) {
            fontManager.setSelectedFont(current, isMultiple: false)
        }
        fontManager.fontPanel(true)?.makeKeyAndOrderFront(self)
        // Original comment: "must setup color AFTER displayed or it will keeps
        // black" — this is what lets the panel's colour well edit the note colour.
        // "NSColor" is NSForegroundColorAttributeName — the same key the panel
        // hands back to setColor(_:forAttribute:).
        fontManager.setSelectedAttributes(
            ["NSColor": NSColor(viewModel.noteColor)],
            isMultiple: false)
    }

    private func exportPreferences() {
        let panel = NSSavePanel()
        panel.title = L("Export")
        panel.allowedContentTypes = [.propertyList]
        panel.allowedFileTypes = ["plist"]
        panel.nameFieldStringValue = "MacStrokePreferences.plist"

        guard let keyWindow = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: keyWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // The rules and the scripts have to ride along: they are the
                // configuration, and they are not in the preferences domain
                // (issue #69 — the old export was a few kilobytes of toggles).
                let payload = ConfigurationBackup.payload(
                    domainValues: UserDefaults.standard.dictionaryRepresentation(),
                    rules: try RuleStore.shared.configurationJSON(),
                    scripts: try AppleScriptsList.sharedAppleScriptsList.configurationJSON())
                try (payload as NSDictionary).write(to: url)
                postMacStrokeNotification(L("Export succeeded"))
            } catch {
                NSAlert.showError(error)
            }
        }
    }

    private func importPreferences() {
        let panel = NSOpenPanel()
        panel.title = L("Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.propertyList]
        panel.allowedFileTypes = ["plist"]

        guard let keyWindow = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: keyWindow) { response in
            guard response == .OK, let url = panel.url,
                  let imported = NSDictionary(contentsOf: url) as? [String: Any] else { return }
            // Rules and scripts first: they are the half that can fail, and a
            // backup that does not parse should leave the settings alone too.
            do {
                try ConfigurationBackup.apply(imported,
                                              ruleStore: RuleStore.shared,
                                              scriptList: AppleScriptsList.sharedAppleScriptsList)
            } catch {
                NSAlert.showError(error)
                return
            }
            let defaults = UserDefaults.standard
            for (key, value) in ConfigurationBackup.domainValues(from: imported) {
                defaults.set(value, forKey: key)
            }
            defaults.synchronize()
            postMacStrokeNotification(L("Restart MacStroke to take effect"))
        }
    }

    /// Original resetDefaults: only re-applies DefaultPreferences.plist and lets
    /// the bound rows refresh. No confirmation, and the language, login item and
    /// black/white filter lists are deliberately untouched.
    private func resetDefaults() {
        viewModel.resetToDefaults()
    }
}

/// Receives font-panel change callbacks and mirrors them into UserDefaults
/// (original: changeFont: writing noteFontName / noteFontSize, and
/// setColor:forAttribute: writing noteColor when the panel's own color
/// attribute changes).
final class FontPanelObserver: NSObject {
    static let shared = FontPanelObserver()

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender = sender else { return }
        let font = sender.convert(NSFont.systemFont(ofSize: NSFont.systemFontSize))
        UserDefaults.standard.set(font.fontName, forKey: "noteFontName")
        UserDefaults.standard.set(Double(font.pointSize), forKey: "noteFontSize")
        NotificationCenter.default.post(name: NSNotification.Name("MacStrokeNoteFontDidChange"), object: nil)
    }

    @objc func setColor(_ color: NSColor, forAttribute attribute: String) {
        guard attribute == "NSColor" else { return }
        UserDefaults.standard.set(Color(nsColor: color).hexString, forKey: "defaultNoteColor")
        NotificationCenter.default.post(name: NSNotification.Name("MacStrokeNoteFontDidChange"), object: nil)
    }
}

// MARK: - Rules Tab

struct RulesTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @ObservedObject var ruleStore: RuleStore
    @State private var selectedRow = -1

    var body: some View {
        SettingsFillingPage {
            // Original: one view-based table fills the pane and every cell hosts
            // a live control — there is no rule editor window.
            RulesTable(store: ruleStore, selectedRow: $selectedRow,
                       onDrawGesture: drawGesture(row:))
                .frame(maxHeight: .infinity)
                .settingsListCard()

            // Bottom bar (original: + - Pick a running app ... Defaults Clear)
            HStack(spacing: 8) {
                Button(action: addRule) {
                    Image(systemName: "plus")
                }

                Button(action: removeRule) {
                    Image(systemName: "minus")
                }

                Button(L("Pick a running app")) {
                    guard selectedRow != -1 else { return needRuleSelection() }
                    pickAppForSelectedRule()
                }

                Spacer()

                Button(L("Defaults")) {
                    ruleStore.rules = RuleStore.defaultRules()
                    ruleStore.save()
                }

                Button(L("Clear")) {
                    let alert = NSAlert()
                    alert.messageText = L("warning!")
                    alert.informativeText = L("Are you sure you want to clear all the rules?")
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: L("Ok"))
                    alert.addButton(withTitle: L("Cancel"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        ruleStore.rules.removeAll()
                        ruleStore.save()
                        selectedRow = -1
                    }
                }
                .foregroundColor(.red)
            }
        }
    }

    /// Original `addShortcutRule:`: append a rule whose every field is the
    /// "Double click Modify" placeholder, then reload. Names are not unique, so
    /// the table addresses rows by index exactly like the original does.
    private func addRule() {
        let placeholder = RulesTable.Coordinator.placeholder
        var spare = RuleSpareActions()
        spare.text = placeholder
        spare.password = placeholder
        ruleStore.rules.append(
            Rule(
                name: placeholder,
                description: placeholder,
                template: GestureTemplate(points: [], name: placeholder),
                action: .shortcut(keyCode: 0, flags: 0),
                note: placeholder,
                filter: "*",
                spareActions: spare
            )
        )
        ruleStore.save()
    }

    /// Original `removeRule:`: with no selected row it only posts the toast.
    private func removeRule() {
        guard ruleStore.rules.indices.contains(selectedRow) else { return needRuleSelection() }
        ruleStore.rules.remove(at: selectedRow)
        ruleStore.save()
    }

    /// Enter screen-recording mode for the given rule and show the original
    /// "Draw Gesture!" alert with its preset-gesture combo box
    /// (AppPrefsWindowController.m preSetRuleGestureAtIndex / alertModal…).
    /// Original removeRule:/pickBtnDidClick: guard: a NSUserNotification toast,
    /// not a disabled button.
    private func needRuleSelection() {
        postMacStrokeNotification(L("Select a filter first!"))
    }

    /// The table hands over a row index (original `preSetRuleGestureAtIndex:`);
    /// the recording plumbing still addresses rules by name.
    private func drawGesture(row: Int) {
        guard ruleStore.rules.indices.contains(row) else { return }
        drawGesture(ruleStore.rules[row].name)
    }

    private func drawGesture(_ ruleName: String) {
        GestureRecordFlow.record(ruleName: ruleName, store: ruleStore)
    }

    /// Original bottom-bar button: multi-select running apps (AppPickerWindow-
    /// Controller) and write the "|"-joined result (each entry followed by a
    /// pipe) through `setWildFilter:atIndex:`, which also forces the filter type
    /// back to wildcard. Picking nothing clears the filter.
    private func pickAppForSelectedRule() {
        guard ruleStore.rules.indices.contains(selectedRow) else { return }
        let oldRule = ruleStore.rules[selectedRow]

        let preselected = Set(oldRule.filter
            .components(separatedBy: CharacterSet(charactersIn: "|\n"))
            .filter { !$0.isEmpty })

        guard let picked = AppPickerPanel.pick(title: L("Pick a running app"), preselected: preselected) else { return }

        ruleStore.rules[selectedRow] = Rule(
            name: oldRule.name,
            description: oldRule.description,
            template: oldRule.template,
            minSimilarityScore: oldRule.minSimilarityScore,
            action: oldRule.action,
            note: oldRule.note,
            isEnabled: oldRule.isEnabled,
            triggerOnEveryMatch: oldRule.triggerOnEveryMatch,
            filter: picked.map { "\($0)|" }.joined(),
            filterType: "wildcard",
            spareActions: oldRule.spareActions
        )
        ruleStore.save()
    }
}

extension NSAlert {
    static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        if let nsError = error as NSError? {
            alert.informativeText = nsError.localizedFailureReason ?? ""
        }
        alert.alertStyle = .critical
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}


// MARK: - AppleScript Tab
//
// Original pane (Preferences.xib "AppleScript"): an editable single-column title
// table 225pt wide on the left, the selected script's source in a bordered field
// on the right, and "+" "-" / "Load Example" / "Edit in External Editor" below.
// AppPrefsWindowController.m:460-567 is the behaviour reference.

struct AppleScriptTabView: View {
    @ObservedObject var scriptList: AppleScriptsList
    /// Single selection (original table has multipleSelection=NO)
    @State private var selectedId: UUID?
    /// Live external-editor session (original's isEditing + currentScriptId/Path)
    @State private var externalSession: ExternalScriptSession?

    init(scriptList: AppleScriptsList, selectedId: UUID? = nil) {
        self.scriptList = scriptList
        _selectedId = State(initialValue: selectedId)
    }

    var body: some View {
        SettingsFillingPage {
            HStack(alignment: .top, spacing: 12) {
                titleTable
                    .frame(width: 225)
                    .settingsListCard()
                VStack(spacing: 8) {
                    sourceEditor
                    buttonBar
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scripts: [AppleScriptItem] { scriptList.getAllScripts() }

    private var selectedIndex: Int? {
        selectedId.flatMap { scriptList.index(of: $0) }
    }

    private var isEditingExternally: Bool { externalSession != nil }

    private var titleTable: some View {
        AppleScriptTitleTable(scriptList: scriptList,
                              selectedId: $selectedId,
                              enabled: !isEditingExternally)
    }

    private var sourceEditor: some View {
        AppleScriptSourceField(
            text: Binding(
                get: { selectedIndex.map { scriptList.script(at: $0) } ?? "" },
                set: { newValue in
                    if let index = selectedIndex { scriptList.setScript(at: index, newValue) }
                }),
            enabled: selectedIndex != nil && !isEditingExternally,
            onCommit: { _ in scriptList.save() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var buttonBar: some View {
        HStack(spacing: 6) {
            Button("+") { createScript() }
                .disabled(isEditingExternally)
            Button("-") { removeSelected() }
                .disabled(selectedIndex == nil || isEditingExternally)
            Spacer()
            Menu(L("Load Example")) {
                ForEach(AppleScriptExample.all) { example in
                    Button(example.title) { load(example) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isEditingExternally)
            Button(isEditingExternally ? L("Stop") : L("Edit in External Editor")) {
                toggleExternalEditor()
            }
        }
    }

    /// Original createAppleScript: — append a blank script and select it.
    private func createScript() {
        selectedId = scriptList.addScript(name: "New AppleScript", source: "").id
    }

    /// Original exampleAppleScriptSelected: — copy the bundled example's source
    /// into a new script and select it.
    private func load(_ example: AppleScriptExample) {
        selectedId = scriptList.addScript(name: example.title, source: example.source).id
    }

    /// Original removeAppleScript: — re-select min(index, count-1), and reload
    /// the rules table so its script pickers drop the dead reference.
    private func removeSelected() {
        guard let index = selectedIndex else { return }
        scriptList.remove(at: index)
        let remaining = scripts
        selectedId = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        NotificationCenter.default.post(name: .macStrokeRuleStoreDidChange, object: nil)
    }

    private struct ExternalScriptSession {
        let id: UUID
        let path: String
    }
    /// Original editAppleScriptInExternalEditor: — the first click dumps the
    /// source into $TMPDIR/<id>/MacStroke.applescript and opens it in whatever
    /// app owns .applescript files; "Stop" reads the file back.
    private func toggleExternalEditor() {
        if let session = externalSession {
            externalSession = nil
            guard let content = try? String(contentsOfFile: session.path, encoding: .utf8),
                  let index = scriptList.index(of: session.id) else { return }
            scriptList.setScript(at: index, content, notify: true)
            scriptList.save()
            return
        }

        guard let index = selectedIndex else {
            // Original still fires the notification because its button never disables.
            postMacStrokeNotification(L("Select a AppleScript first!"))
            return
        }

        let id = scriptList.id(at: index)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("MacStroke.applescript")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try? scriptList.script(at: index).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
        externalSession = ExternalScriptSession(id: id, path: url.path)
    }
}

/// The original AppleScript list is a **headerless** view-based `NSTableView`
/// (Preferences.xib:1015 has no `headerView`) whose cells are inline-editable
/// borderless text fields (`tableViewForAppleScripts:`). SwiftUI's `Table`
/// cannot drop its header row on macOS 13, so this is the AppKit equivalent.
/// Titles commit through `control:textShouldEndEditing:`, i.e. only when the
/// field editor closes, and key off the table's selected row.
private struct AppleScriptTitleTable: NSViewRepresentable {
    @ObservedObject var scriptList: AppleScriptsList
    @Binding var selectedId: UUID?
    let enabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(scriptList: scriptList, selectedId: $selectedId)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Title"))
        column.width = 200
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 19
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let coordinator = context.coordinator
        coordinator.table = tableView
        coordinator.ids = scriptList.getAllScripts().map(\.id)
        tableView.reloadData()

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tableView = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.selectedId = $selectedId
        tableView.isEnabled = enabled
        // Reload only when rows appear or vanish: reloading while a cell field
        // is being typed into would throw away the field editor.
        let ids = scriptList.getAllScripts().map(\.id)
        if coordinator.ids != ids {
            coordinator.ids = ids
            tableView.reloadData()
        }
        let row = selectedId.flatMap { scriptList.index(of: $0) } ?? -1
        if tableView.selectedRow != row {
            if row >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        let scriptList: AppleScriptsList
        var selectedId: Binding<UUID?>
        var ids: [UUID] = []
        weak var table: NSTableView?

        init(scriptList: AppleScriptsList, selectedId: Binding<UUID?>) {
            self.scriptList = scriptList
            self.selectedId = selectedId
        }

        func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let textField = NSTextField()
            textField.isEditable = true
            textField.isBordered = false
            textField.drawsBackground = false
            textField.lineBreakMode = .byTruncatingMiddle
            textField.cell?.isScrollable = true
            textField.cell?.wraps = false
            textField.delegate = self
            textField.identifier = NSUserInterfaceItemIdentifier("Title")
            textField.stringValue = row < scriptList.count ? scriptList.title(at: row) : ""
            return textField
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            selectedId.wrappedValue = table.selectedRow >= 0 ? scriptList.id(at: table.selectedRow) : nil
        }

        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            guard let table, table.selectedRow >= 0,
                  let field = control as? NSTextField else { return true }
            // Original writes by selected row, not by the edited row.
            scriptList.setTitle(at: table.selectedRow, field.stringValue)
            scriptList.save()
            return true
        }
    }
}

/// The original source box is a **single-line** bezelled `NSTextField`
/// (identifier "Apple Script", 545x358 in the xib) stretched to fill the pane:
/// long scripts scroll horizontally rather than wrap, and it is disabled until
/// a row is selected. Edits commit when the field editor closes.
private struct AppleScriptSourceField: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.isEditable = true
        field.drawsBackground = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        // The original pins this field to a 358pt tall bezel; an NSTextField's
        // intrinsic height would otherwise make SwiftUI keep it a single strip.
        field.setContentHuggingPriority(.init(1), for: .vertical)
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        field.placeholderString = L("Enter AppleScript here")
        field.isEnabled = enabled
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void = { _ in }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onCommit(field.stringValue)
        }
    }
}

/// The three examples the original bundles and lists under "Load Example"
/// (AppPrefsWindowController.m:49-57; sources are the shipped .applescript files).
/// Titles stay untranslated, exactly like the original's hardcoded strings.
struct AppleScriptExample: Identifiable {
    let id: String
    let title: String
    let source: String

    static let all: [AppleScriptExample] = [
        AppleScriptExample(
            id: "ChromeCloseTabsToTheRight",
            title: "Close Tabs To The Right In Chrome",
            source: """
            tell application "Google Chrome"
                set i to 1
                set tabsToDelete to {}

                repeat with t in (tabs of (first window))
                    if i is greater than (active tab index of (first window)) then
                        set beginning of tabsToDelete to t
                    end if
                    set i to i + 1
                end repeat

                repeat with t in tabsToDelete
                    close t
                end repeat
            end tell
            """),
        AppleScriptExample(
            id: "OpenMacStrokePreferences",
            title: "Open MacStroke Preferences",
            source: """
            tell application "MacStroke"
                openPreferences
            end tell
            """),
        AppleScriptExample(
            id: "SearchInWeb",
            title: "Search in Web",
            source: """
            tell application "System Events" to keystroke "c" using {command down}
            delay 0.3 -- prolong or shorten it if needed
            try
                    set theData to (the clipboard as text)
                    -- for Baidu, use http://www.baidu.com/s?word=
                    -- for Google, use http://www.googe.com/search?q=
                    -- for Bing, use http://www.bing.com/search?q=
                    set theData to "http://www.baidu.com/s?word=" & quoted form of theData
                    do shell script "open " & theData
            on error
                    display notification "Format not yet supported"
            end try
            """),
    ]
}


// MARK: - Filters Tab
// Original: two always-visible plain text views side by side (black / white
// list), one radio plus an "add.." button above each, and "apply rules" at the
// bottom right. Only "apply rules" writes to UserDefaults; the radio writes the
// mode immediately.

struct FiltersTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @State private var blackListText = ""
    @State private var whiteListText = ""

    var body: some View {
        SettingsFillingPage {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ModeRadio(title: L("Black list mode"), on: !viewModel.whiteListMode) {
                            viewModel.whiteListMode = false
                        }
                        .fixedSize()
                        Button(L("add..")) { addRunningApps(whiteList: false) }
                        Spacer()
                    }
                    FilterTextView(text: $blackListText, active: !viewModel.whiteListMode)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ModeRadio(title: L("White list mode"), on: viewModel.whiteListMode) {
                            viewModel.whiteListMode = true
                        }
                        .fixedSize()
                        Button(L("add..")) { addRunningApps(whiteList: true) }
                        Spacer()
                    }
                    FilterTextView(text: $whiteListText, active: viewModel.whiteListMode)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack {
                Spacer()
                Button(L("apply rules")) { applyRules() }
            }
        }
        .onAppear {
            blackListText = BlackWhiteFilter.shared.blackListText
            whiteListText = BlackWhiteFilter.shared.whiteListText
        }
    }

    /// Original `filterViewApplyClicked:`: both text views go through the
    /// trim/drop-empty-lines setter, then the stored lists are read back so the
    /// editor shows exactly what was persisted.
    private func applyRules() {
        BlackWhiteFilter.shared.blackListText = blackListText
        BlackWhiteFilter.shared.whiteListText = whiteListText
        blackListText = BlackWhiteFilter.shared.blackListText
        whiteListText = BlackWhiteFilter.shared.whiteListText
    }

    /// Original `addedToTextView` picker mode: nothing is pre-checked, and OK
    /// appends `previous\n<bundle id>` per checked row — no dedup, no apply.
    private func addRunningApps(whiteList: Bool) {
        guard let picked = AppPickerPanel.pick(title: L("Pick a running app")),
              !picked.isEmpty else { return }
        for bundleID in picked {
            if whiteList { whiteListText += "\n" + bundleID } else { blackListText += "\n" + bundleID }
        }
    }
}

/// One radio of the original pair. AppKit can't group radios across separate
/// representables, so the checked state is driven from the model, mirroring
/// `refreshFilterRadioAndTextViewState`.
private struct ModeRadio: NSViewRepresentable {
    let title: String
    let on: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(radioButtonWithTitle: title,
                              target: context.coordinator,
                              action: #selector(Coordinator.clicked))
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = on ? .on : .off
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }
}

/// The original's colour control is a plain `NSColorWell`, 100×18 in the xib
/// (`lineColorWell`). SwiftUI's `ColorPicker` keeps its own small square whatever
/// frame it is handed, so the row stuck out from the switches beside it.
struct ColorWellField: NSViewRepresentable {
    @Binding var color: Color

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        // Minimal: the colour fills the whole 100pt with no palette chip, which is
        // how the classic well in the xib reads.
        well.colorWellStyle = .minimal
        well.color = NSColor(color)
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.color = $color
        let next = NSColor(color)
        if well.color != next { well.color = next }
    }

    func makeCoordinator() -> Coordinator { Coordinator(color: $color) }

    final class Coordinator: NSObject {
        var color: Binding<Color>

        init(color: Binding<Color>) { self.color = color }

        @objc func colorChanged(_ sender: NSColorWell) {
            color.wrappedValue = Color(nsColor: sender.color)
        }
    }
}

/// Plain (non-rich) multi-line editor, 14pt system font like the original text
/// views. The active list gets a white background, the inactive one the window
/// background color.
private struct FilterTextView: NSViewRepresentable {
    @Binding var text: String
    let active: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        let background = active ? NSColor.white : NSColor.windowBackgroundColor
        textView.drawsBackground = true
        textView.backgroundColor = background
        scroll.drawsBackground = true
        scroll.backgroundColor = background
    }
}

// MARK: - Right Click Tab
// Original RithtClick pane: tips label on top, a headerless single-column table
// whose cells are inline-editable, and "+" / "-" / "Pick a running app" below.

struct RightClickTabView: View {
    @Binding var rightClickApps: [String]
    @State private var selectedRow = -1

    var body: some View {
        SettingsFillingPage {
            Text(L("tips:Simulate right mouse click ,support '*' character matching. eg:'com.jetbrains.*'"))
                .font(.caption)
                .foregroundColor(.secondary)

            RightClicksTable(apps: $rightClickApps, selectedRow: $selectedRow)
                .frame(maxHeight: .infinity)
                .settingsListCard()

            HStack(spacing: 8) {
                Button(action: addRow) {
                    Image(systemName: "plus")
                }
                Button(action: removeRow) {
                    Image(systemName: "minus")
                }
                Spacer()
                Button(L("Pick a running app")) { pickApp() }
            }
        }
    }

    /// Original `createRightClick:`: append the literal placeholder "appname",
    /// save, reload and select the new last row.
    private func addRow() {
        RightClicksList.shared.add("appname")
        rightClickApps = RightClicksList.shared.allApps()
        selectedRow = RightClicksList.shared.count - 1
    }

    /// Original `removeRightClick:`: silently does nothing when no row is
    /// selected, otherwise removes and keeps the selection index in range.
    private func removeRow() {
        guard selectedRow != -1 else { return }
        RightClicksList.shared.remove(at: selectedRow)
        rightClickApps = RightClicksList.shared.allApps()
        if !rightClickApps.isEmpty {
            selectedRow = min(selectedRow, rightClickApps.count - 1)
        }
    }

    /// Original `rightClickPickBtnDidClick:`: needs a selected row, and the
    /// picked app *replaces* that row (`rightClickPickCallback:atIndex:`).
    private func pickApp() {
        guard selectedRow != -1 else {
            postMacStrokeNotification(L("Select a filter first!"))
            return
        }
        guard let picked = AppPickerPanel.pick(title: L("Pick a running app"), singleSelection: true),
              let bundleID = picked.first else { return }
        RightClicksList.shared.setAppname(at: selectedRow, appname: bundleID)
        rightClickApps = RightClicksList.shared.allApps()
    }
}

/// Headerless single-column list with an editable borderless text field per
/// row, like `tableViewForRightClicks:`. Commits follow the original and key
/// off the table's selected row rather than the edited cell.
private struct RightClicksTable: NSViewRepresentable {
    @Binding var apps: [String]
    @Binding var selectedRow: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Appname"))
        column.width = 600
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 19
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        context.coordinator.tableView = tableView
        context.coordinator.apps = apps
        context.coordinator.onSelectionChange = { selectedRow = tableView.selectedRow }
        context.coordinator.onCommit = { row, text in
            RightClicksList.shared.setAppname(at: row, appname: text)
            apps = RightClicksList.shared.allApps()
        }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tableView = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.onSelectionChange = { selectedRow = tableView.selectedRow }
        coordinator.onCommit = { row, text in
            RightClicksList.shared.setAppname(at: row, appname: text)
            apps = RightClicksList.shared.allApps()
        }
        // Reload only on real content changes: reloading while a cell is being
        // edited would tear down the field editor on every selection change.
        if coordinator.apps != apps {
            coordinator.apps = apps
            tableView.reloadData()
        }
        if tableView.selectedRow != selectedRow {
            if selectedRow >= 0 && selectedRow < apps.count {
                tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var apps: [String] = []
        var onSelectionChange: () -> Void = {}
        var onCommit: (Int, String) -> Void = { _, _ in }
        weak var tableView: NSTableView?

        func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let textField = NSTextField()
            textField.isEditable = true
            textField.isBordered = false
            textField.drawsBackground = false
            textField.lineBreakMode = .byTruncatingMiddle
            textField.cell?.isScrollable = true
            textField.cell?.wraps = false
            textField.delegate = self
            textField.tag = row
            textField.stringValue = apps[row]
            return textField
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            onSelectionChange()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField, let tableView else { return }
            onCommit(tableView.selectedRow, textField.stringValue)
        }
    }
}

// MARK: - RightClickMenu Tab
// Original: enable right click menu + item toggles + terminal picker.

struct RightClickMenuTabView: View {
    @ObservedObject var viewModel: UserPreferences

    var body: some View {
        SettingsPage {
            // Original: one untitled box; the master checkbox has no `enabled`
            // binding, so it is always live.
            SettingsCard {
                SettingsRow(L("enable right click menu")) {
                    TrailingSwitch(isOn: Binding(
                        get: { viewModel.enableRightClickMenu },
                        set: { newValue in
                            viewModel.enableRightClickMenu = newValue
                            syncToExtension()
                        }
                    ))
                }
            }

            // Original: the three sub-checkboxes each bind `enabled` to the
            // master toggle; the terminal popup has no such binding and stays
            // clickable even when the menu is off.
            SettingsCard {
                SettingsRow(L("new text file")) {
                    TrailingSwitch(isOn: Binding(
                        get: { viewModel.enableNewFile },
                        set: { newValue in
                            viewModel.enableNewFile = newValue
                            syncToExtension()
                        }
                    ))
                    .disabled(!viewModel.enableRightClickMenu)
                }
                RowDivider()
                SettingsRow(L("open in terminal")) {
                    Picker("", selection: Binding(
                        get: { viewModel.userTerminal },
                        set: { newValue in
                            viewModel.userTerminal = newValue
                            syncToExtension()
                        }
                    )) {
                        Text("Terminal").tag("Terminal")
                        Text("Iterm").tag("Iterm")
                    }
                    .labelsHidden()
                    .fixedSize()

                    TrailingSwitch(isOn: Binding(
                        get: { viewModel.enableOpenInTerminal },
                        set: { newValue in
                            viewModel.enableOpenInTerminal = newValue
                            syncToExtension()
                        }
                    ))
                    .disabled(!viewModel.enableRightClickMenu)
                }
                RowDivider()
                SettingsRow(L("copy file path")) {
                    TrailingSwitch(isOn: Binding(
                        get: { viewModel.enableCopyFilePath },
                        set: { newValue in
                            viewModel.enableCopyFilePath = newValue
                            syncToExtension()
                        }
                    ))
                    .disabled(!viewModel.enableRightClickMenu)
                }
            }
            .padding(.leading, 22)
        }
    }

    /// Original: every toggle on this page re-runs `initRightClickMenu`, which
    /// re-registers the notification handlers, re-schedules the delayed
    /// pluginkit enable (10s / 120s) and pushes flags + titles to the extension.
    private func syncToExtension() {
        RightClickMenuManager.shared.reinitFinderSyncExtension()
    }
}

// MARK: - Clipboard Tab
// Original: enable + storage mode + storage limits + shortcut + show list.
// Every control stays visible and is only greyed out (the xib binds `enabled`
// to enableHistoryClipboard / clipoardStroageLocal / the matching limit switch).

struct ClipboardTabView: View {
    @ObservedObject var viewModel: UserPreferences

    /// Original AppPrefsWindowController.m:139-158 gives each limit field its
    /// own formatter: top 1…9999, total 1…999999, save days 1…9999. Anything
    /// outside (or non-numeric) fails to parse, so the preference never changes.
    private static func limitFormatter(minimum: Int, maximum: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: minimum)
        formatter.maximum = NSNumber(value: maximum)
        return formatter
    }

    private static let limitTopFormatter = limitFormatter(minimum: 1, maximum: 9_999)
    private static let limitTotalFormatter = limitFormatter(minimum: 1, maximum: 999_999)
    private static let limitSaveDaysFormatter = limitFormatter(minimum: 1, maximum: 9_999)

    private var featureOn: Bool { viewModel.enableHistoryClipboard }
    private var limitsOn: Bool { featureOn && viewModel.clipoardStroageLocal }

    var body: some View {
        SettingsPage {
            SettingsCard {
                SettingsRow(L("enable history clipboard")) {
                    TrailingSwitch(isOn: $viewModel.enableHistoryClipboard)
                }
                RowDivider()
                SettingsRow(L("storage:")) {
                    Picker("", selection: $viewModel.clipoardStroageLocal) {
                        Text(L("ram")).tag(false)
                        Text(L("local")).tag(true)
                    }
                    .labelsHidden()
                    .frame(width: 68)
                    .disabled(!featureOn)
                }
            }

            SettingsSection(title: L("Storage limit")) {
                SettingsCard {
                    SettingsRow(L("Limit top records:")) {
                        TrailingSwitch(isOn: $viewModel.enableLimitTop) {
                            limitField($viewModel.limitTop, width: 40,
                                       formatter: Self.limitTopFormatter,
                                       enabled: limitsOn && viewModel.enableLimitTop)
                        }
                        .disabled(!limitsOn)
                    }
                    RowDivider()
                    SettingsRow(L("Limit total records:")) {
                        TrailingSwitch(isOn: $viewModel.enableLimitTotal) {
                            limitField($viewModel.limitTotal, width: 60,
                                       formatter: Self.limitTotalFormatter,
                                       enabled: limitsOn && viewModel.enableLimitTotal)
                        }
                        .disabled(!limitsOn)
                    }
                    RowDivider()
                    SettingsRow(L("Limit save days:")) {
                        TrailingSwitch(isOn: $viewModel.enableLimitSaveDays) {
                            limitField($viewModel.limitSaveDays, width: 40,
                                       formatter: Self.limitSaveDaysFormatter,
                                       enabled: limitsOn && viewModel.enableLimitSaveDays)
                        }
                        .disabled(!limitsOn)
                    }
                }
            }

            // Original: "keyboard shortcut:" and "show history clipboard" are
            // siblings of the Storage limit box, not rows inside it.
            SettingsCard {
                SettingsRow(L("keyboard shortcut:")) {
                    ShortcutRecorder(
                        text: $viewModel.historyCilpboardListShortcut,
                        onShortcutChanged: { viewModel.historyCilpboardListShortcut = $0 }
                    )
                    .frame(width: 200, height: 28)
                    .disabled(!featureOn)
                }
            }

            SettingsCard {
                SettingsActionRow {
                    Button(L("show history clipboard")) {
                        showHistoryList()
                    }
                    .disabled(!featureOn)
                    // Moved out of the history panel: the panel is search + list
                    // only, so the original's three clear buttons live here.
                    Button(L("clearTop")) {
                        confirm(L("Are you sure to clear all top records?")) {
                            HistoryClipboardManager().clearTop()
                        }
                    }
                    .disabled(!featureOn)
                    Button(L("clear")) {
                        confirm(L("Are you sure to clear all history clipboard records?")) {
                            HistoryClipboardManager().clearHistoryList()
                        }
                    }
                    .disabled(!featureOn)
                    Button(L("clearAll")) {
                        confirm(L("Are you sure to clear all top records and history clipboard records?")) {
                            HistoryClipboardManager().clearAll()
                        }
                    }
                    .disabled(!featureOn)
                }
            }
        }
    }

    /// Original confirmation sheet from the history clipboard window.
    private func confirm(_ informative: String, action: () -> Void) {
        let alert = NSAlert()
        alert.messageText = L("warning!")
        alert.informativeText = informative
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Ok"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    private func limitField(_ value: Binding<Int>, width: CGFloat,
                            formatter: NumberFormatter, enabled: Bool) -> some View {
        TextField("", value: value, formatter: formatter)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .frame(width: width)
            .disabled(!enabled)
    }

    private func showHistoryList() {
        // The window lives in this same process; the original simply runs
        // showHistoryCilpboardList: through the responder chain.
        NotificationCenter.default.post(name: .macStrokeShowHistoryClipboard, object: nil)
    }
}

// MARK: - About Tab
// Original: version, author, issues link, Sparkle update controls.

/// Original About pane (Preferences.xib "About", 800x519): the two update
/// checkboxes, the version / author rows and the README.html web view that
/// fills the rest of the page. 移植版在此页另加三项：检查节奏、发现新版时的温和
/// 提醒开关、以及「跳过此版本」的恢复入口。
struct AboutTabView: View {
    @ObservedObject var viewModel: UserPreferences
    /// Sparkle's own user-default key (original bound the checkbox to
    /// SUUpdater.automaticallyDownloadsUpdates).
    @AppStorage("SUAutomaticallyUpdate") private var automaticallyDownloadsUpdates = false

    private var versionString: String {
        // 版本号只在 build_app.sh 的 APP_VERSION 里维护，这里不设备份值，避免两处漂移。
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// 检查节奏给的三个档，都是 Sparkle 认的秒数（最小 3600，再小会被夹住）。
    private static let checkIntervalOptions: [(titleKey: String, seconds: Double)] = [
        ("Every Day", 86400),
        ("Every 12 Hours", 43200),
        ("Every Hour", 3600),
    ]

    var body: some View {
        SettingsFillingPage {
            SettingsCard {
                SettingsRow(L("Automatically Check for Updates")) {
                    TrailingSwitch(isOn: $viewModel.autoCheckUpdates)
                }
                .onChange(of: viewModel.autoCheckUpdates) { _ in
                    NotificationCenter.default.post(name: .macStrokeUpdateSettingsDidChange, object: nil)
                }
                RowDivider()
                SettingsRow(L("Check Interval:")) {
                    Picker("", selection: checkIntervalBinding) {
                        ForEach(Self.checkIntervalOptions, id: \.seconds) { option in
                            Text(L(option.titleKey)).tag(option.seconds)
                        }
                        // 手改过 defaults 的用户可能停在别的秒数上，给个能显示出来的选项，
                        // 不然弹出框会是空的，看不出当前值。
                        if !Self.checkIntervalOptions.contains(where: { $0.seconds == viewModel.updateCheckInterval }) {
                            Text(L("Custom") + ": \(Int(viewModel.updateCheckInterval))s")
                                .tag(viewModel.updateCheckInterval)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(!viewModel.autoCheckUpdates)
                }
                RowDivider()
                SettingsRow(L("Automatically Download Updates")) {
                    TrailingSwitch(isOn: $automaticallyDownloadsUpdates)
                }
                .onChange(of: automaticallyDownloadsUpdates) { _ in
                    NotificationCenter.default.post(name: .macStrokeUpdateSettingsDidChange, object: nil)
                }
                RowDivider()
                SettingsRow(L("Remind Me When a New Version Is Found")) {
                    TrailingSwitch(isOn: $viewModel.enableUpdateReminder)
                }
            }

            SettingsCard {
                SettingsRow(L("Version:")) {
                    HStack(spacing: 8) {
                        Text(versionString)
                            .foregroundColor(.secondary)
                        Button(L("Check Now")) {
                            NotificationCenter.default.post(name: .macStrokeCheckForUpdates, object: nil)
                        }
                        Button(L("issues")) {
                            if let url = URL(string: "https://github.com/mtjo/MacStroke/issues") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                RowDivider()
                SettingsRow(L("Author: mtjo.net@gmail.com"))
                RowDivider()
                SettingsRow(L("Skipped Versions")) {
                    Button(L("Restore Skipped Versions")) {
                        NotificationCenter.default.post(name: .macStrokeRestoreSkippedUpdate, object: nil)
                    }
                }
            }

            READMEWebView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .settingsListCard()
        }
    }

    /// 改节奏要通知 AppDelegate：Sparkle 只认 `SPUUpdater.updateCheckInterval` 这个
    ///  setter，它才会重排定时器；直接写 UserDefaults 的话值虽然被 Sparkle 读到，
    /// 当前那一轮的定时器还要等到下次检查才换。
    private var checkIntervalBinding: Binding<Double> {
        Binding(
            get: { viewModel.updateCheckInterval },
            set: {
                viewModel.updateCheckInterval = $0
                NotificationCenter.default.post(name: .macStrokeUpdateSettingsDidChange, object: nil)
            }
        )
    }
}

// MARK: - Shared Components
//
// Visual language follows macOS System Settings: a sidebar with rounded
// selection highlight, a gray page, and white rounded cards that hold
// label-left / control-right rows separated by full-width dividers.

enum SettingsChrome {
    /// Width of the sidebar column.
    static let sidebarWidth: CGFloat = 216
    /// Max width of the centered content column.
    static let contentWidth: CGFloat = 680
    static let cornerRadius: CGFloat = 8

    static func dynamic(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(calibratedWhite: isDark ? dark : light, alpha: 1)
        })
    }

    static let sidebarBackground = dynamic(light: 0.93, dark: 0.11)
    static let pageBackground = dynamic(light: 0.96, dark: 0.14)
    static let cardBackground = dynamic(light: 1.0, dark: 0.21)
    static let cardBorder = Color.primary.opacity(0.08)
}

/// Page container for form tabs: scrolls, centers the content column and
/// paints the System Settings background.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .frame(maxWidth: SettingsChrome.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(SettingsChrome.pageBackground)
    }
}

/// Page container for tabs whose table must fill the viewport (no scrolling).
struct SettingsFillingPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .background(SettingsChrome.pageBackground)
    }
}

/// A bold group title above a card.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .padding(.leading, 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rounded container holding rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity)
        .background(SettingsChrome.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsChrome.cornerRadius, style: .continuous)
                .strokeBorder(SettingsChrome.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cornerRadius, style: .continuous))
    }
}

/// One row inside a card: title on the leading edge, control on the trailing edge.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var titleWidth: CGFloat? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, titleWidth: CGFloat? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.titleWidth = titleWidth
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: titleWidth, alignment: .leading)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

/// Divider between rows of a card.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

/// Card row that only hosts actions (buttons), leading-aligned.
struct SettingsActionRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}

extension View {
    /// Wraps a table/list so it reads as a System Settings card.
    func settingsListCard() -> some View {
        background(SettingsChrome.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsChrome.cornerRadius, style: .continuous)
                    .strokeBorder(SettingsChrome.cardBorder, lineWidth: 1)
            )
    }
}

/// Trailing switch for a row (System Settings puts the label on the left).
struct TrailingSwitch<Extra: View>: View {
    var isOn: Binding<Bool>
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(spacing: 10) {
            extra()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

extension TrailingSwitch where Extra == EmptyView {
    init(isOn: Binding<Bool>) {
        self.isOn = isOn
        self.extra = { EmptyView() }
    }
}

struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.primary)
    }
}

// MARK: - README 网页（原版 About 页内嵌 README.html，AppPrefsWindowController.m:126）

/// 原版用的是同进程 WebView（xib 里的 webView outlet）。那颗类在 macOS 27 SDK 里
/// 已经连头文件一起删掉了（`WebKit.framework/Headers/Web/` 整个不在），所以这里只能
/// 用 WKWebView：代价是拉起 WebContent 子进程、首次打开 About 慢一下。
private struct READMEWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        if let url = Bundle.main.url(forResource: "README", withExtension: "html"),
           let body = try? String(contentsOf: url, encoding: .utf8) {
            webView.loadHTMLString(body, baseURL: url)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
