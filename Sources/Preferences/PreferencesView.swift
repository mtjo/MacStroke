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
/// AppPrefsWindowController.setupToolbar).
enum PreferencesTab: CaseIterable {
    case general
    case rules
    case filters
    case appleScript
    case rightClick
    case rightClickMenu
    case clipboard
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
}

// MARK: - Shortcut Recorder SwiftUI Wrapper

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var text: String
    var onShortcutChanged: ((String) -> Void)?

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        // Show the persisted shortcut (e.g. the ^⇧V default) right away.
        if let parsed = Self.parse(text) {
            view.keyCode = parsed.keyCode
            view.flags = parsed.flags
        }
        view.onShortcutChanged = { code, flags in
            text = "keyCode=\(code), flags=\(flags)"
            onShortcutChanged?(text)
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        // Sync external changes (reset to defaults etc.) into the view
        // while the user is not actively recording.
        if !nsView.isRecording, let parsed = Self.parse(text) {
            if nsView.keyCode != parsed.keyCode || nsView.flags != parsed.flags {
                nsView.keyCode = parsed.keyCode
                nsView.flags = parsed.flags
            }
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
    @State private var showingRuleEditor = false
    @State private var editingRule: Rule?
    @ObservedObject private var scriptList = AppleScriptsList.sharedAppleScriptsList
    @State private var rightClickApps: [String] = []
    @State private var newRightClickApp = ""
    /// Bumped whenever the UI language changes so the whole view tree
    /// re-renders with the new localized strings.
    @State private var languageRevision = 0

    public init(viewModel: UserPreferences) {
        self.viewModel = viewModel
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
                    RulesTabView(
                        viewModel: viewModel,
                        ruleStore: ruleStore,
                        showingRuleEditor: $showingRuleEditor,
                        editingRule: $editingRule
                    )
                case .filters:
                    FiltersTabView(viewModel: viewModel)
                case .appleScript:
                    AppleScriptTabView(scriptList: scriptList)
                case .rightClick:
                    RightClickTabView(
                        viewModel: viewModel,
                        rightClickApps: $rightClickApps,
                        newRightClickApp: $newRightClickApp
                    )
                case .rightClickMenu:
                    RightClickMenuTabView(viewModel: viewModel)
                case .clipboard:
                    ClipboardTabView(viewModel: viewModel)
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
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: tab.systemImage)
        }
    }
}

// MARK: - General Tab
// Original General tab: app toggles, language, gesture recognition settings,
// note (toast) settings, drawing settings, import/export, reset defaults.

// MARK: - General Tab
// Mirrors the original AppPrefsWindowController General tab layout exactly:
// Box groups (top to bottom): General -> Gesture -> Note -> Import/Export/Reset buttons

struct GeneralTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @StateObject private var launchController = LaunchAtLoginController.shared

    private static let fontSizeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 8
        formatter.maximum = 96
        formatter.allowsFloats = false
        return formatter
    }()

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
                                launchController.setEnabled(enabled)
                                viewModel.launchAtLogin = enabled
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
                        Picker(L("Language"), selection: $viewModel.language) {
                            Text(L("English")).tag("en")
                            Text(L("简体中文")).tag("zh-Hans")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
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
                                .frame(width: 200)
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
                    RowDivider()
                    SettingsRow(L("Line color:")) {
                        ColorPicker("", selection: $viewModel.lineColor)
                            .labelsHidden()
                            .fixedSize()
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
                            Text(viewModel.noteFontName)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            TextField("", value: $viewModel.noteFontSize, formatter: Self.fontSizeFormatter)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .frame(width: 48)
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
                            .frame(width: 200)
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
                            .frame(width: 200)
                        }
                    }
                }
            }

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
        }
    }

    private func openFontPanel() {
        let fontManager = NSFontManager.shared
        fontManager.target = FontPanelObserver.shared
        if let current = NSFont(name: viewModel.noteFontName, size: CGFloat(viewModel.noteFontSize)) {
            fontManager.setSelectedFont(current, isMultiple: false)
        }
        fontManager.orderFrontFontPanel(self)
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
            let dict = UserDefaults.standard.dictionaryRepresentation()
            let ourKeys = dict.filter { key, _ in
                StorageKey.allCases.contains { $0.rawValue == key }
                    || key.hasPrefix("filter") || key == "rules" || key == "rightClicksList"
            } as [String: Any]
            do {
                try (ourKeys as NSDictionary).write(to: url)
                showNotification(L("Export succeeded"))
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
            let defaults = UserDefaults.standard
            for (key, value) in imported {
                defaults.set(value, forKey: key)
            }
            defaults.synchronize()
            showNotification(L("Restart MacStroke to take effect"))
        }
    }

    private func resetDefaults() {
        viewModel.resetToDefaults()
        BlackWhiteFilter.shared.blackListText = ""
        BlackWhiteFilter.shared.whiteListText = ""
        showNotification(L("Restart MacStroke to take effect"))
    }

    private func showNotification(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacStroke"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}

/// Receives font-panel change callbacks and mirrors them into UserDefaults
/// (original: changeFont: writing noteFontName / noteFontSize).
final class FontPanelObserver: NSObject {
    static let shared = FontPanelObserver()

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender = sender else { return }
        let font = sender.convert(NSFont.systemFont(ofSize: NSFont.systemFontSize))
        UserDefaults.standard.set(font.fontName, forKey: "noteFontName")
        UserDefaults.standard.set(Double(font.pointSize), forKey: "noteFontSize")
        NotificationCenter.default.post(name: NSNotification.Name("MacStrokeNoteFontDidChange"), object: nil)
    }
}

// MARK: - Rules Tab

/// Gesture thumbnail drawn with SwiftUI Canvas (same scaling math as
/// DrawGesture, but no NSView size-negotiation issues inside Table rows).
struct GestureThumb: View {
    let points: [GesturePoint]

    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            let width = maxX - minX
            let height = maxY - minY
            let margin: CGFloat = 6
            let availW = max(size.width - margin * 2, 1)
            let availH = max(size.height - margin * 2, 1)
            let zoom = max(width / availW, height / availH)
            guard zoom > 0 else { return }
            let fixX = (size.width - width / zoom) / 2
            let fixY = (size.height - height / zoom) / 2
            // Template points use bottom-left origin; Canvas is top-left.
            let scaled = points.map { p in
                CGPoint(x: (p.x - minX) / zoom + fixX,
                        y: size.height - ((p.y - minY) / zoom + fixY))
            }
            let segments = scaled.count - 1
            for i in 0..<segments {
                let t = CGFloat(i) / CGFloat(max(segments, 1))
                var path = Path()
                path.move(to: scaled[i])
                path.addLine(to: scaled[i + 1])
                context.stroke(
                    path,
                    with: .color(Color(red: 0.5 * t, green: 0.47 + 0.53 * t, blue: 0.9)),
                    lineWidth: 2)
            }
        }
        .frame(width: 56, height: 56)
    }
}

struct RulesTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @ObservedObject var ruleStore: RuleStore
    @Binding var showingRuleEditor: Bool
    @Binding var editingRule: Rule?
    @State private var selectedRuleID: String? = nil

    var body: some View {
        SettingsFillingPage {
            // Rules list (original: table fills the tab, button bar at bottom)
            if ruleStore.rules.isEmpty {
                SettingsCard {
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text(L("No rules defined"))
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(L("Click \"Add Rule\" to create your first gesture rule"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
            } else {
                Table(ruleStore.rules, selection: $selectedRuleID) {
                    TableColumn(L("Image")) { rule in
                        GestureThumb(points: rule.template.points)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .frame(height: 84)   // original heightOfRow: 84
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                drawGesture(rule.name)
                            }
                    }
                    .width(84)

                    TableColumn(L("Gesture")) { rule in
                        Text(rule.name)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                editingRule = rule
                                showingRuleEditor = true
                            }
                    }
                    .width(min: 98, ideal: 120)

                    TableColumn(L("Type")) { rule in
                        Text(actionTypeLabel(for: rule.action))
                            .font(.system(size: 12))
                    }
                    .width(96)

                    TableColumn(L("Action")) { rule in
                        Text(actionContentLabel(for: rule.action))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .width(104)

                    TableColumn(L("Filter")) { rule in
                        Text(rule.filter.isEmpty ? L("All Apps") : rule.filter)
                            .font(.system(size: 12))
                            .foregroundColor(rule.filter.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn(L("Description")) { rule in
                        Text(rule.note.isEmpty ? rule.description : rule.note)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 300, maxHeight: .infinity)
                .settingsListCard()
            }

            Text(L("tips: Double-click a gesture image to draw or edit its path; double-click the name to edit the rule."))
                .font(.caption)
                .foregroundColor(.secondary)

            // Bottom bar (original: + - Pick a running app ... Defaults Clear)
            HStack(spacing: 8) {
                Button {
                    editingRule = nil
                    showingRuleEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .help(L("Add Rule"))

                Button {
                    if let id = selectedRuleID {
                        ruleStore.remove(named: id)
                        selectedRuleID = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .help(L("Delete Rule"))
                .disabled(selectedRuleID == nil)

                Button(L("Pick a running app")) {
                    pickAppForSelectedRule()
                }
                .disabled(selectedRuleID == nil)

                Spacer()

                Button(L("Reset to Defaults")) {
                    ruleStore.rules = RuleStore.defaultRules()
                    ruleStore.save()
                }

                Button(L("Clear All")) {
                    let alert = NSAlert()
                    alert.messageText = L("warning!")
                    alert.informativeText = L("Are you sure you want to clear all the rules?")
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: L("Ok"))
                    alert.addButton(withTitle: L("Cancel"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        ruleStore.rules.removeAll()
                        ruleStore.save()
                        selectedRuleID = nil
                    }
                }
                .foregroundColor(.red)
            }
        }
        .sheet(isPresented: $showingRuleEditor) {
            RuleEditorView(
                ruleStore: ruleStore,
                editingRule: editingRule,
                onDismiss: { savedName in
                    showingRuleEditor = false
                    editingRule = nil
                    // Follow the row across a rename so the table keeps showing
                    // what the user just edited.
                    if let savedName { selectedRuleID = savedName }
                }
            )
        }
    }

    /// Plain action-type label for the table's Type column (original combo:
    /// Hot Key / Apple Script / Text / Password).
    private func actionTypeLabel(for action: RuleAction) -> String {
        switch action {
        case .applescript: return L("Apple Script")
        case .keyPress, .shortcut: return L("Hot Key")
        case .text, .copyToClipboard: return L("Text")
        case .password: return L("Password")
        case .mouseClick: return L("Mouse Click")
        case .none: return L("None")
        }
    }

    /// Action column shows the real action content, like the original inline
    /// cells: shortcut recorder text, script name, text value, password dots.
    private func actionContentLabel(for action: RuleAction) -> String {
        switch action {
        case .shortcut(let keyCode, let flags):
            var s = ""
            if flags & 0x100000 != 0 { s += "⌘" }
            if flags & 0x80000 != 0 { s += "⌥" }
            if flags & 0x40000 != 0 { s += "⌃" }
            if flags & 0x20000 != 0 { s += "⇧" }
            return s + ShortcutRecorderView.keyName(for: keyCode)
        case .keyPress(let key):
            return key
        case .applescript(let reference):
            if let uuid = UUID(uuidString: reference),
               let item = AppleScriptsList.sharedAppleScriptsList.getScriptById(id: uuid) {
                return item.name
            }
            if let item = AppleScriptsList.sharedAppleScriptsList.getAllScripts().first(where: { $0.source == reference }) {
                return item.name
            }
            return reference.split(separator: "\n").first.map(String.init) ?? reference
        case .text(let value), .copyToClipboard(let value):
            return value
        case .password(let value):
            return String(repeating: "•", count: min(max(value.count, 1), 8))
        case .mouseClick(let x, let y):
            return "(\(x), \(y))"
        case .none:
            return "—"
        }
    }

    /// Enter screen-recording mode for the given rule and show the original
    /// "Draw Gesture!" alert with its preset-gesture combo box
    /// (AppPrefsWindowController.m preSetRuleGestureAtIndex / alertModal…).
    private func drawGesture(_ ruleName: String) {
        NotificationCenter.default.post(
            name: .macStrokeRecordGesture,
            object: nil,
            userInfo: ["ruleName": ruleName]
        )

        let alert = NSAlert()
        alert.messageText = L("Draw Gesture!")
        alert.informativeText = L("You can draw a gesture anywhere on the screen, or select the preset gesture below.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Ok"))
        alert.addButton(withTitle: L("Cancel"))

        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 160, height: 25))
        combo.isEditable = false
        combo.completes = false
        combo.addItems(withObjectValues: Self.presetGestureTitles())
        combo.placeholderString = L("Plase Select")
        alert.accessoryView = combo

        var presetApplied = false
        let store = ruleStore
        let obs = NotificationCenter.default.addObserver(
            forName: NSComboBox.selectionDidChangeNotification,
            object: combo, queue: .main
        ) { _ in
            let idx = combo.indexOfSelectedItem
            guard idx >= 0, let title = combo.itemObjectValue(at: idx) as? String else { return }
            guard Self.applyPresetGesture(title, toRuleNamed: ruleName, store: store) else { return }
            presetApplied = true
            NotificationCenter.default.post(name: .macStrokeCancelRecordGesture, object: nil)
            Self.postGestureCompleteNotification()
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        let response = alert.runModal()
        if presetApplied { return }
        if response != .alertFirstButtonReturn {
            NotificationCenter.default.post(name: .macStrokeCancelRecordGesture, object: nil)
        }
    }

    /// Combo entries, verbatim from the original list order.
    private static func presetGestureTitles() -> [String] {
        var titles = ["←", "↑", "→", "↓", "↙", "↗", "↘", "↖"]
        for base in ["┏", "┓", "┗", "┛"] { titles += [base, base + " Revered"] }
        for scalar in 65...90 {
            let letter = String(UnicodeScalar(scalar)!)
            titles += [letter, letter + " Revered"]
        }
        return titles
    }

    /// Map a combo title ("M", "M Revered", "┏"…) to a preset template and
    /// write it into the rule (original: preGestureSelectionChanged:).
    private static func applyPresetGesture(
        _ title: String, toRuleNamed ruleName: String, store ruleStore: RuleStore
    ) -> Bool {
        let parts = title.split(separator: " ", maxSplits: 1).map(String.init)
        let base = parts[0]
        let reversed = parts.count > 1
        // Letters are stored as "X Shape"; symbol presets use the symbol itself.
        let templateName = (base.first?.isLetter ?? false)
            ? "\(base) Shape" + (reversed ? " Revered" : "")
            : base + (reversed ? " Revered" : "")
        guard let entry = GestureTemplateProvider.shared.allTemplatesIncludingReversed()
            .first(where: { $0.name == templateName }) else { return false }
        guard let idx = ruleStore.rules.firstIndex(where: { $0.name == ruleName }) else { return false }
        let old = ruleStore.rules[idx]
        let template = GestureTemplate(from: entry.stroke, name: templateName)
        let newRule = Rule(
            name: old.name,
            description: old.description,
            template: template,
            minSimilarityScore: old.minSimilarityScore,
            action: old.action,
            note: old.note,
            isEnabled: old.isEnabled,
            triggerOnEveryMatch: old.triggerOnEveryMatch,
            filter: old.filter,
            filterType: old.filterType
        )
        ruleStore.update(newRule)
        NotificationCenter.default.post(name: .macStrokeRuleStoreDidChange, object: nil)
        return true
    }

    private static func postGestureCompleteNotification() {
        let notification = NSUserNotification()
        notification.title = "MacStroke"
        notification.informativeText = L("Gesture draw complete!")
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    /// Original bottom-bar button: multi-select running apps (AppPicker-
    /// WindowController) and join their bundle IDs with "|" as the selected
    /// rule's wildcard filter.
    private func pickAppForSelectedRule() {
        guard let id = selectedRuleID,
              let idx = ruleStore.rules.firstIndex(where: { $0.name == id }) else { return }
        let oldRule = ruleStore.rules[idx]

        let preselected = Set(oldRule.filter
            .split(whereSeparator: { $0 == "|" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty })

        guard let picked = AppPickerPanel.pick(title: L("Pick a running app"), preselected: preselected),
              !picked.isEmpty else { return }

        let newRule = Rule(
            name: oldRule.name,
            description: oldRule.description,
            template: oldRule.template,
            minSimilarityScore: oldRule.minSimilarityScore,
            action: oldRule.action,
            note: oldRule.note,
            isEnabled: oldRule.isEnabled,
            triggerOnEveryMatch: oldRule.triggerOnEveryMatch,
            filter: picked.joined(separator: "|"),
            filterType: "wildcard"
        )
        ruleStore.update(newRule)
    }
}

// MARK: - Rule Import/Export Helpers

extension RulesTabView {
    private func exportRules() {
        let panel = NSSavePanel()
        panel.title = L("Export Rules")
        panel.allowedContentTypes = [.json]
        panel.allowedFileTypes = ["json"]

        guard let keyWindow = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: keyWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try JSONEncoder().encode(ruleStore.rules)
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert.showError(NSError(domain: "MacStroke", code: 1, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]))
            }
        }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.title = L("Import Rules")
        panel.allowedContentTypes = [.json]
        panel.allowedFileTypes = ["json"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        guard let keyWindow = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: keyWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let importedRules = try JSONDecoder().decode([Rule].self, from: data)
                ruleStore.rules = importedRules
                ruleStore.save()
            } catch {
                NSAlert.showError(NSError(domain: "MacStroke", code: 2, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]))
            }
        }
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

/// 规则编辑器（添加 / 编辑）。
///
/// 原版没有编辑窗口：所有字段都在规则表里就地编辑
/// （AppPrefsWindowController.m:960 起）。Swift 的 Table 单元格只读，所以统一走
/// 这个弹层，但字段集合仍与原版一致——名称(direction)、说明(note)、手势轨迹
/// (data)、过滤(filter)、类型 + 动作内容；原版没有的每规则开关（启用、最小分数、
/// 持续触发、正则、鼠标点击）一律不再提供，编辑时原样保留旧值以免丢数据。
struct RuleEditorView: View {
    @ObservedObject var ruleStore: RuleStore
    let editingRule: Rule?
    /// Called when the sheet closes; carries the saved rule's name so the table
    /// can keep the row selected across a rename.
    let onDismiss: (_ savedName: String?) -> Void

    enum RuleActionType: String, CaseIterable {
        case shortcut = "Hot Key"
        case applescript = "Apple Script"
        case text = "Text"
        case password = "Password"

        var label: String { L(rawValue) }
    }

    @State private var name = ""
    @State private var note = ""
    @State private var ruleDescription = ""
    @State private var filter = "*"
    // Kept for round-tripping only: the original has no UI for these.
    @State private var filterType = "wildcard"
    @State private var minSimilarityScore = 30.0
    @State private var isEnabled = true
    @State private var triggerOnEveryMatch = false

    @State private var templateName = ""
    @State private var strokePoints: [GesturePoint] = []
    @State private var strokeIsCustom = false
    @State private var recording = false
    @State private var availableGestures: [(name: String, stroke: Stroke)] = []

    @State private var actionType: RuleActionType = .shortcut
    @State private var shortcutKey = ""
    @State private var appleScriptId = ""
    /// Legacy rules stored the raw source instead of a script id; keep it so
    /// editing such a rule does not silently drop the action.
    @State private var appleScriptSource = ""
    @State private var textValue = ""
    @State private var passwordValue = ""
    @State private var passwordVisible = false
    @ObservedObject private var scriptList = AppleScriptsList.sharedAppleScriptsList

    private static let drawnGestureTag = "__drawn__"
    private static let noneGestureTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingRule == nil ? L("Add Rule") : L("Edit Rule"))
                .font(.system(size: 15, weight: .bold))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    basicSection
                    gestureSection
                    filterSection
                    actionSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }

            HStack(spacing: 8) {
                if let error = nameError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Spacer()
                Button(L("Cancel")) { onDismiss(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(editingRule == nil ? L("Add") : L("Save")) { saveRule() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(nameError != nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
        .onAppear(perform: loadInitialValues)
        .onReceive(NotificationCenter.default.publisher(for: .macStrokeGestureDidRecord)) { note in
            guard recording,
                  let points = note.userInfo?["points"] as? [GesturePoint] else { return }
            strokePoints = points
            strokeIsCustom = true
            templateName = Self.drawnGestureTag
            recording = false
        }
        .onDisappear {
            if recording {
                NotificationCenter.default.post(name: .macStrokeCancelRecordGesture, object: nil)
            }
        }
    }

    // MARK: Sections

    private var basicSection: some View {
        SettingsSection(title: L("Basic Info")) {
            SettingsCard {
                SettingsRow(L("Rule Name")) {
                    TextField(L("Rule Name"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                RowDivider()
                SettingsRow(L("Description")) {
                    TextField(L("Description"), text: $note)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
            }
        }
    }

    private var gestureSection: some View {
        SettingsSection(title: L("Gesture Trigger")) {
            SettingsCard {
                SettingsRow(L("Gesture")) {
                    Picker("", selection: $templateName) {
                        Text(L("Not selected")).tag(Self.noneGestureTag)
                        if strokeIsCustom {
                            Text(L("Drawn Gesture")).tag(Self.drawnGestureTag)
                        }
                        ForEach(availableGestures, id: \.name) { gesture in
                            Text(gesture.name).tag(gesture.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: templateName) { applyTemplate(named: $0) }
                }
                RowDivider()
                SettingsRow(L("Gesture Path")) {
                    HStack(spacing: 10) {
                        Text(strokePoints.isEmpty
                             ? L("No gesture drawn yet")
                             : "\(strokePoints.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        GestureThumb(points: strokePoints)
                            .frame(width: 56, height: 56)
                            .background(Color(NSColor.textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color(NSColor.separatorColor))
                            )
                        if recording {
                            Button(L("Cancel Recording")) { cancelRecording() }
                        } else {
                            Button(L("Draw On Screen")) { startRecording() }
                        }
                    }
                }
            }
            .disabled(recording)
            .overlay(alignment: .top) {
                if recording {
                    Text(L("You can draw a gesture anywhere on the screen, or select the preset gesture below."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(6)
                }
            }
        }
    }

    private var filterSection: some View {
        SettingsSection(title: L("App Filter")) {
            SettingsCard {
                SettingsRow(L("Filter")) {
                    HStack(spacing: 8) {
                        TextField("com.apple.*", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Button(L("Pick a running app")) { pickApps() }
                    }
                }
                SettingsRow(L("Filter hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        SettingsSection(title: L("Action")) {
            SettingsCard {
                SettingsRow(L("Action Type")) {
                    Picker("", selection: $actionType) {
                        ForEach(RuleActionType.allCases, id: \.self) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            switch actionType {
            case .shortcut:
                SettingsCard {
                    SettingsRow(L("Key Combination")) {
                        ShortcutRecorder(text: $shortcutKey)
                            .frame(width: 200, height: 26)
                    }
                }
            case .applescript:
                // Original: an NSComboBox of the saved scripts; the rule stores
                // the picked script's id (apple_script_id).
                SettingsCard {
                    SettingsRow(L("Apple Script")) {
                        Picker("", selection: $appleScriptId) {
                            Text("").tag("")
                            ForEach(scriptList.getAllScripts()) { script in
                                Text(script.name).tag(script.id.uuidString)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    SettingsRow(L("Load Example"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case .text:
                SettingsCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Text to input"))
                        TextEditor(text: $textValue)
                            .font(.system(size: 12))
                            .frame(height: 110)
                    }
                    .padding(12)
                }
            case .password:
                SettingsCard {
                    SettingsRow(L("Password")) {
                        HStack(spacing: 8) {
                            Group {
                                if passwordVisible {
                                    TextField(L("Password"), text: $passwordValue)
                                } else {
                                    SecureField(L("Password"), text: $passwordValue)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            Button(passwordVisible ? L("Hide") : L("Show")) {
                                passwordVisible.toggle()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameError: String? {
        if trimmedName.isEmpty { return L("Name cannot be empty") }
        if ruleStore.exists(named: trimmedName, excluding: editingRule?.name ?? "") {
            return L("Rule name already exists")
        }
        return nil
    }

    // MARK: Actions

    private func loadInitialValues() {
        availableGestures = GestureTemplateProvider.shared.allTemplatesIncludingReversed()
        guard let rule = editingRule else {
            templateName = availableGestures.first?.name ?? ""
            applyTemplate(named: templateName)
            return
        }
        name = rule.name
        note = rule.note
        ruleDescription = rule.description
        filter = rule.filter
        filterType = rule.filterType
        minSimilarityScore = rule.minSimilarityScore
        isEnabled = rule.isEnabled
        triggerOnEveryMatch = rule.triggerOnEveryMatch
        templateName = rule.template.name
        strokePoints = rule.template.points
        strokeIsCustom = !availableGestures.contains { $0.name == rule.template.name }
        if strokeIsCustom { templateName = Self.drawnGestureTag }

        switch rule.action {
        case .keyPress(let key):
            actionType = .shortcut
            shortcutKey = key
        case .shortcut(let keyCode, let flags):
            actionType = .shortcut
            shortcutKey = "keyCode=\(keyCode), flags=\(flags)"
        case .applescript(let reference):
            actionType = .applescript
            if let uuid = UUID(uuidString: reference), scriptList.index(of: uuid) != nil {
                appleScriptId = reference
            } else {
                appleScriptId = ""
                appleScriptSource = reference
            }
        case .text(let text), .copyToClipboard(let text):
            actionType = .text
            textValue = text
        case .password(let text):
            actionType = .password
            passwordValue = text
        case .mouseClick, .none:
            actionType = .shortcut
        }
    }

    /// Point the preview at the preset template picked from the menu.
    private func applyTemplate(named tag: String) {
        if tag == Self.drawnGestureTag { return }
        if tag == Self.noneGestureTag {
            strokePoints = []
            strokeIsCustom = false
            return
        }
        guard let entry = availableGestures.first(where: { $0.name == tag }) else { return }
        strokePoints = entry.stroke.points
        strokeIsCustom = false
    }

    private func startRecording() {
        recording = true
        NotificationCenter.default.post(
            name: .macStrokeRecordGesture,
            object: nil,
            userInfo: [
                "ruleName": trimmedName.isEmpty ? (editingRule?.name ?? "") : trimmedName,
                "deferStoreUpdate": true,
            ]
        )
    }

    private func cancelRecording() {
        recording = false
        NotificationCenter.default.post(name: .macStrokeCancelRecordGesture, object: nil)
    }

    /// Original: filter is a "|"-joined list of bundle IDs picked from the
    /// running apps panel (AppPickerWindowController).
    private func pickApps() {
        let preselected = Set(filter
            .split(whereSeparator: { $0 == "|" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty })
        guard let picked = AppPickerPanel.pick(title: L("Pick a running app"), preselected: preselected),
              !picked.isEmpty else { return }
        filter = picked.joined(separator: "|")
    }

    private func saveRule() {
        let template: GestureTemplate
        if strokeIsCustom, !strokePoints.isEmpty {
            template = GestureTemplate(points: strokePoints, name: editingRule?.template.name ?? "Recorded")
        } else if let entry = availableGestures.first(where: { $0.name == templateName }) {
            template = GestureTemplate(from: entry.stroke, name: entry.name)
        } else {
            template = GestureTemplate(points: strokePoints, name: templateName)
        }

        let action: RuleAction
        switch actionType {
        case .shortcut:
            if let combined = Self.parseShortcutKey(shortcutKey) {
                action = .shortcut(keyCode: combined.keyCode, flags: combined.flags)
            } else {
                action = .keyPress(shortcutKey)
            }
        case .applescript:
            // Original stores `apple_script_id`; "" keeps a legacy inline source.
            action = .applescript(appleScriptId.isEmpty ? appleScriptSource : appleScriptId)
        case .text:
            action = .text(textValue)
        case .password:
            action = .password(passwordValue)
        }

        let rule = Rule(
            name: trimmedName,
            description: ruleDescription.isEmpty ? note : ruleDescription,
            template: template,
            minSimilarityScore: minSimilarityScore,
            action: action,
            note: note,
            isEnabled: isEnabled,
            triggerOnEveryMatch: triggerOnEveryMatch,
            filter: filter.trimmingCharacters(in: .whitespacesAndNewlines),
            filterType: filterType
        )

        if let original = editingRule {
            // Renaming has to be explicit: rows are matched by their old name.
            if !ruleStore.replace(named: original.name, with: rule) {
                ruleStore.add(rule)
            }
        } else {
            ruleStore.add(rule)
        }
        onDismiss(rule.name)
    }

    /// Parse the recorder's "keyCode=X, flags=Y" text.
    static func parseShortcutKey(_ raw: String) -> (keyCode: UInt16, flags: UInt)? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
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
        Table(scripts, selection: $selectedId) {
            // Original: one editable "Title" column, header left blank.
            TableColumn("") { script in
                TextField("", text: Binding(
                    get: { scriptList.index(of: script.id).map { scriptList.title(at: $0) } ?? script.name },
                    set: { newValue in
                        if let index = scriptList.index(of: script.id) {
                            scriptList.setTitle(at: index, newValue)
                        }
                    }))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 40, ideal: 140, max: 1000)
        }
        .tableStyle(.inset)
        .disabled(isEditingExternally)
    }

    private var sourceEditor: some View {
        TextEditor(text: Binding(
            get: { selectedIndex.map { scriptList.script(at: $0) } ?? "" },
            set: { newValue in
                if let index = selectedIndex { scriptList.setScript(at: index, newValue) }
            }))
            .font(.system(size: 13))
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .settingsListCard()
            .overlay(alignment: .topLeading) {
                if selectedIndex == nil {
                    Text(L("Enter AppleScript here"))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .disabled(selectedIndex == nil || isEditingExternally)
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
            return
        }

        guard let index = selectedIndex else {
            // Original still fires the notification because its button never disables.
            let notification = NSUserNotification()
            notification.title = "MacStroke"
            notification.informativeText = L("Select a AppleScript first!")
            NSUserNotificationCenter.default.deliver(notification)
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
// Original: black/white list mode radio + two text views + apply + add.

struct FilterEntry: Identifiable {
    let index: Int
    let value: String
    var id: Int { index }
}

struct FiltersTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @State private var blackListText = ""
    @State private var whiteListText = ""
    @State private var showWhiteList = false
    @State private var selection: Set<Int> = []
    @State private var newPattern = ""
    @State private var showingPatternSheet = false

    private var currentLines: [String] {
        (showWhiteList ? whiteListText : blackListText).components(separatedBy: "\n")
    }

    private var entries: [FilterEntry] {
        currentLines.enumerated().compactMap { i, line in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : FilterEntry(index: i, value: line)
        }
    }

    var body: some View {
        SettingsFillingPage {
            SectionHeader(L("Application Filters"))

            // System-settings style list switcher (like Sound output/input).
            SettingsCard {
                Picker("", selection: $showWhiteList) {
                    Text(L("Black List")).tag(false)
                    Text(L("White List")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
            }

            Table(entries, selection: $selection) {
                TableColumn(L("Name")) { entry in
                    Text(entry.value)
                        .font(.system(size: 12, design: .monospaced))
                }
                TableColumn(L("Type")) { entry in
                    Text(Self.kind(for: entry.value))
                        .foregroundColor(.secondary)
                }
            }
            .frame(minHeight: 280, maxHeight: .infinity)
            .settingsListCard()

            HStack(spacing: 12) {
                Button(action: addRunningApp) {
                    Image(systemName: "plus")
                }
                .help(L("Pick a running app"))
                Button(action: removeSelected) {
                    Image(systemName: "minus")
                }
                .disabled(selection.isEmpty)
                Button(L("Add Pattern")) {
                    newPattern = ""
                    showingPatternSheet = true
                }

                Spacer()

                Picker(L("Filter Mode"), selection: $viewModel.whiteListMode) {
                    Text(L("Black list mode")).tag(false)
                    Text(L("White list mode")).tag(true)
                }
                .pickerStyle(.radioGroup)
                .fixedSize()
                .onChange(of: viewModel.whiteListMode) { _ in
                    persistLists()
                }

                Button(L("Apply")) { persistLists() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            blackListText = BlackWhiteFilter.shared.blackListText
            whiteListText = BlackWhiteFilter.shared.whiteListText
        }
        .sheet(isPresented: $showingPatternSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Add Pattern")).font(.headline)
                TextField("com.jetbrains.*", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                HStack {
                    Spacer()
                    Button(L("Cancel")) { showingPatternSheet = false }
                    Button(L("OK")) {
                        addPattern(newPattern.trimmingCharacters(in: .whitespaces))
                        showingPatternSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 340)
        }
    }

    /// Type column: wildcard pattern / resolved app name / unknown.
    private static func kind(for entry: String) -> String {
        if entry.contains("*") { return L("Wildcard") }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry),
           let bundle = Bundle(url: url),
           let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String {
            return name
        }
        return L("Unknown App")
    }

    private func setText(_ lines: [String]) {
        let joined = lines.joined(separator: "\n")
        if showWhiteList { whiteListText = joined } else { blackListText = joined }
        persistLists()
    }

    private func persistLists() {
        BlackWhiteFilter.shared.blackListText = blackListText
        BlackWhiteFilter.shared.whiteListText = whiteListText
        viewModel.save()
    }

    private func removeSelected() {
        let lines = currentLines.enumerated()
            .filter { !selection.contains($0.offset) }
            .map(\.element)
        selection = []
        setText(lines)
    }

    private func addPattern(_ pattern: String) {
        guard !pattern.isEmpty else { return }
        var lines = currentLines
        if !lines.contains(pattern) {
            lines.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            lines.append(pattern)
            setText(lines)
        }
    }

    /// Add running apps' bundle IDs to the visible list
    /// (original: AppPickerWindowController with addedToTextView, multi-select).
    private func addRunningApp() {
        let existing = Set(entries.map(\.value))
        guard let picked = AppPickerPanel.pick(title: L("Pick a running app"), preselected: existing),
              !picked.isEmpty else { return }
        var lines = currentLines
        for bundleID in picked where !lines.contains(bundleID) {
            lines.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            lines.append(bundleID)
        }
        setText(lines)
    }
}

// MARK: - Right Click Tab
// Original RightClick tab: RightClicksList table (apps that keep their
// native right-click menu) with pick-a-running-app.

struct RightClickAppItem: Identifiable {
    let id = UUID()
    let bundleId: String
}

struct RightClickTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @Binding var rightClickApps: [String]
    @Binding var newRightClickApp: String

    private var items: [RightClickAppItem] {
        rightClickApps.map { RightClickAppItem(bundleId: $0) }
    }

    var body: some View {
        SettingsFillingPage {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(L("Right Click Menu - App List"))
                Text(L("tips:Simulate right mouse click ,support '*' character matching. eg:'com.jetbrains.*'"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SettingsCard {
                HStack(spacing: 8) {
                    TextField(L("Bundle ID (e.g. com.apple.finder)"), text: $newRightClickApp)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                    Button {
                        addRunningApp()
                    } label: {
                        Label(L("add.."), systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                    Button(L("Add")) {
                        if !newRightClickApp.isEmpty {
                            RightClicksList.shared.add(newRightClickApp)
                            rightClickApps = RightClicksList.shared.allApps()
                            newRightClickApp = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newRightClickApp.isEmpty)
                    Spacer()
                }
                .padding(10)
            }

            if rightClickApps.isEmpty {
                SettingsCard {
                    VStack(spacing: 12) {
                        Image(systemName: "mouse")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text(L("No applications configured"))
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .padding(.vertical, 20)
                }
                .frame(maxHeight: .infinity)
            } else {
                Table(items) {
                    TableColumn(L("Bundle ID / Pattern")) { item in
                        Text(item.bundleId)
                            .font(.system(size: 13, design: .monospaced))
                    }
                    .width(min: 300, max: 500)

                    TableColumn("") { item in
                        Button(role: .destructive) {
                            RightClicksList.shared.remove(at: rightClickApps.firstIndex(of: item.bundleId) ?? 0)
                            rightClickApps = RightClicksList.shared.allApps()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(50)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(maxHeight: .infinity)
                .settingsListCard()
            }

            HStack {
                Button(L("Reset to Defaults")) {
                    RightClicksList.shared.reInit()
                    rightClickApps = RightClicksList.shared.allApps()
                }
                .buttonStyle(.bordered)

                Button(L("Clear All")) {
                    RightClicksList.shared.clear()
                    rightClickApps = RightClicksList.shared.allApps()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)

                Spacer()
            }
        }
    }

    /// Pick one running app (original: AppPickerWindowController selectOne
    /// mode) and add its bundle ID to the list.
    private func addRunningApp() {
        guard let picked = AppPickerPanel.pick(title: L("Pick a running app"), singleSelection: true),
              let bundleID = picked.first, !bundleID.isEmpty else { return }
        RightClicksList.shared.add(bundleID)
        rightClickApps = RightClicksList.shared.allApps()
    }
}

// MARK: - RightClickMenu Tab
// Original: enable right click menu + item toggles + terminal picker.

struct RightClickMenuTabView: View {
    @ObservedObject var viewModel: UserPreferences

    var body: some View {
        SettingsPage {
            SettingsSection(title: L("Finder Right-Click Menu")) {
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
            }

            // Original: sub-items stay visible and are only disabled
            // when the master toggle is off (enabled binding in the xib).
            SettingsCard {
                SettingsRow(L("new text file")) {
                    TrailingSwitch(isOn: Binding(
                        get: { viewModel.enableNewFile },
                        set: { newValue in
                            viewModel.enableNewFile = newValue
                            syncToExtension()
                        }
                    ))
                }
                RowDivider()
                SettingsRow(L("open in terminal")) {
                    TrailingSwitch(isOn: Binding(
                        get: { viewModel.enableOpenInTerminal },
                        set: { newValue in
                            viewModel.enableOpenInTerminal = newValue
                            syncToExtension()
                        }
                    )) {
                        Picker("", selection: Binding(
                            get: { viewModel.userTerminal },
                            set: { newValue in
                                viewModel.userTerminal = newValue
                                syncToExtension()
                            }
                        )) {
                            Text("Terminal").tag("Terminal")
                            Text("Iterm").tag("iTerm")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
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
                }
            }
            .padding(.leading, 22)
            .disabled(!viewModel.enableRightClickMenu)

            HStack(spacing: 12) {
                Button(L("Re-enable Extension")) {
                    RightClickMenuManager.shared.reEnableFinderExtension()
                }
                Button(L("Delayed Re-enable")) {
                    RightClickMenuManager.shared.delayedEnableFinderExtension()
                }
                Spacer()
            }
        }
    }

    /// Push the enable flags + localized menu titles to the FinderSync
    /// extension (original: onToggleRightClickMenu → initRightClickMenu).
    private func syncToExtension() {
        RightClickMenuManager.shared.syncSharedDefaultsToFinderSyncExtension()
    }
}

// MARK: - Clipboard Tab
// Original: enable + storage mode + storage limits + shortcut + show list.

struct ClipboardTabView: View {
    @ObservedObject var viewModel: UserPreferences

    var body: some View {
        SettingsPage {
            SettingsSection(title: L("Clipboard History")) {
                SettingsCard {
                    SettingsRow(L("enable history clipboard")) {
                        TrailingSwitch(isOn: $viewModel.enableHistoryClipboard)
                    }
                }
            }

            if viewModel.enableHistoryClipboard {
                SettingsCard {
                    SettingsRow(L("storage:")) {
                        Picker("", selection: $viewModel.clipoardStroageLocal) {
                            Text(L("local")).tag(true)
                            Text(L("ram")).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 200)
                    }
                }

                SettingsSection(title: L("Storage limit")) {
                    SettingsCard {
                        SettingsRow(L("Limit top records:")) {
                            TrailingSwitch(isOn: $viewModel.enableLimitTop) {
                                Stepper(value: $viewModel.limitTop, in: 1...9999) {
                                    Text("\(viewModel.limitTop)")
                                        .frame(width: 50, alignment: .trailing)
                                }
                                .disabled(!viewModel.enableLimitTop)
                            }
                        }
                        RowDivider()
                        SettingsRow(L("Limit total records:")) {
                            TrailingSwitch(isOn: $viewModel.enableLimitTotal) {
                                Stepper(value: $viewModel.limitTotal, in: 1...999999) {
                                    Text("\(viewModel.limitTotal)")
                                        .frame(width: 60, alignment: .trailing)
                                }
                                .disabled(!viewModel.enableLimitTotal)
                            }
                        }
                        RowDivider()
                        SettingsRow(L("Limit save days:")) {
                            TrailingSwitch(isOn: $viewModel.enableLimitSaveDays) {
                                Stepper(value: $viewModel.limitSaveDays, in: 1...9999) {
                                    Text("\(viewModel.limitSaveDays)")
                                        .frame(width: 50, alignment: .trailing)
                                }
                                .disabled(!viewModel.enableLimitSaveDays)
                            }
                        }
                        RowDivider()
                        SettingsRow(L("keyboard shortcut:")) {
                            ShortcutRecorder(
                                text: $viewModel.historyCilpboardListShortcut,
                                onShortcutChanged: { viewModel.historyCilpboardListShortcut = $0 }
                            )
                            .frame(width: 200, height: 28)
                        }
                    }
                }

                SettingsCard {
                    SettingsActionRow {
                        Button(L("show history clipboard")) {
                            showHistoryList()
                        }
                    }
                }

                SettingsCard {
                    SettingsActionRow {
                        Button(L("Clear History")) {
                            confirmThen(L("Are you sure to clear all history clipboard records?")) {
                                HistoryClipboardManager().clearHistoryList()
                            }
                        }
                        .foregroundColor(.red)

                        Button(L("Clear Pinned")) {
                            confirmThen(L("Are you sure to clear all top records?")) {
                                HistoryClipboardManager().clearTop()
                            }
                        }
                        .foregroundColor(.red)

                        Button(L("Clear All")) {
                            confirmThen(L("Are you sure to clear all top records and history clipboard records?")) {
                                HistoryClipboardManager().clearAll()
                            }
                        }
                        .foregroundColor(.red)
                    }
                }
            }

            let manager = HistoryClipboardManager()
            SettingsSection(title: L("Current Status")) {
                SettingsCard {
                    SettingsRow(L("Pinned items")) {
                        Text("\(manager.topCount)").foregroundColor(.secondary)
                    }
                    RowDivider()
                    SettingsRow(L("Total items")) {
                        Text("\(manager.getCount(isTop: false))").foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func showHistoryList() {
        // The window lives in the main app; ask it to open via the distributed
        // notification channel used by the global shortcut.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("MacStrokeOpenHistoryClipboard"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func confirmThen(_ message: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = L("warning!")
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Ok"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }
}

// MARK: - About Tab
// Original: version, author, issues link, Sparkle update controls.

/// Original About pane (Preferences.xib "About", 800x519): the two update
/// checkboxes, the version / author rows and the README.html web view that
/// fills the rest of the page.
struct AboutTabView: View {
    @ObservedObject var viewModel: UserPreferences
    /// Sparkle's own user-default key (original bound the checkbox to
    /// SUUpdater.automaticallyDownloadsUpdates).
    @AppStorage("SUAutomaticallyUpdate") private var automaticallyDownloadsUpdates = false

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

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
                SettingsRow(L("Automatically Download Updates")) {
                    TrailingSwitch(isOn: $automaticallyDownloadsUpdates)
                }
                .onChange(of: automaticallyDownloadsUpdates) { _ in
                    NotificationCenter.default.post(name: .macStrokeUpdateSettingsDidChange, object: nil)
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
            }

            READMEWebView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .settingsListCard()
        }
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

/// 原版用的是同进程 WebView（xib 里的 webView outlet），这里保持一致：
/// WKWebView 每次都要拉起 WebContent 子进程，首次打开 About 会卡近 1 秒。
private struct READMEWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WebView {
        let webView = WebView()
        if let url = Bundle.main.url(forResource: "README", withExtension: "html"),
           let body = try? String(contentsOf: url, encoding: .utf8) {
            webView.mainFrame.loadHTMLString(body, baseURL: url)
        }
        return webView
    }

    func updateNSView(_ nsView: WebView, context: Context) {}
}
