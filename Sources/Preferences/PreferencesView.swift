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

extension AppleScriptItem: Identifiable { }

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
        case .rightClickMenu: return "menubar.arrow.up.rectangle"
        case .clipboard: return "doc.on.clipboard"
        case .about: return "info.circle"
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
    @StateObject private var ruleStore = RuleStore()
    @State private var showingRuleEditor = false
    @State private var editingRule: Rule?
    @State private var scripts: [AppleScriptItem] = []
    @State private var showingScriptEditor = false
    @State private var editingScript: AppleScriptItem?
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
            // Sidebar / Tab bar
            VStack(spacing: 0) {
                ForEach(PreferencesTab.allCases, id: \.self) { tab in
                    TabButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
                    )
                }
                Spacer()
            }
            .frame(width: 180)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content area
            ScrollView {
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
                        AppleScriptTabView(
                            scripts: $scripts,
                            showingScriptEditor: $showingScriptEditor,
                            editingScript: $editingScript
                        )
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
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 600, minHeight: 550)
        }
        .id(languageRevision)
        .onReceive(NotificationCenter.default.publisher(for: .languageDidChange)) { _ in
            languageRevision += 2
        }
        .frame(minWidth: 820, minHeight: 620)
        .sheet(isPresented: $showingRuleEditor) {
            RuleEditorView(
                ruleStore: ruleStore,
                editingRule: editingRule,
                onDismiss: { showingRuleEditor = false; editingRule = nil }
            )
        }
        .sheet(isPresented: $showingScriptEditor) {
            ScriptEditorView(
                scripts: $scripts,
                editingScript: editingScript,
                onDismiss: {
                    showingScriptEditor = false
                    editingScript = nil
                    scripts = AppleScriptsList.sharedAppleScriptsList.getAllScripts()
                }
            )
        }
        .onAppear {
            rightClickApps = RightClicksList.shared.allApps()
            scripts = AppleScriptsList.sharedAppleScriptsList.getAllScripts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macStrokeRuleStoreDidChange)) { _ in
            // A screen-drawn gesture was recorded into a rule — refresh.
            ruleStore.load()
        }
    }
}

/// Tab button in the sidebar.
struct TabButton: View {
    let tab: PreferencesTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 24)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .accentColor : .primary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // MARK: General Group
            GroupBox(L("General")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L("Show Icon In Status Bar"), isOn: Binding(
                        get: { viewModel.showIconInStatusBar },
                        set: { newValue in
                            viewModel.showIconInStatusBar = newValue
                            NotificationCenter.default.post(
                                name: .showIconInStatusBarDidChange, object: newValue)
                        }
                    ))
                    Toggle(L("Open Preferences Window at Startup"), isOn: $viewModel.openPrefOnStartup)
                    Toggle(L("Auto Start at Login"), isOn: Binding(
                        get: { launchController.isEnabled },
                        set: { enabled in
                            launchController.setEnabled(enabled)
                            viewModel.launchAtLogin = enabled
                        }
                    ))
                    Toggle(L("Enable MacStroke"), isOn: Binding(
                        get: { viewModel.isEnabled },
                        set: { newValue in
                            viewModel.isEnabled = newValue
                            NotificationCenter.default.post(
                                name: .macStrokeEnabledDidChange, object: newValue)
                        }
                    ))

                    HStack {
                        Text(L("Language:"))
                        Picker(L("Language"), selection: $viewModel.language) {
                            Text(L("English")).tag("en")
                            Text(L("简体中文")).tag("zh-Hans")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // MARK: Gesture Group
            GroupBox(L("Gesture")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L("Show Gesture In Whatever App"), isOn: $viewModel.showUIInWhateverApp)
                    Toggle(L("Disable Mouse Path"), isOn: $viewModel.disableMousePath)

                    HStack {
                        Text(L("Line color:"))
                        ColorPicker("", selection: $viewModel.lineColor)
                            .frame(width: 60)
                    }

                    HStack {
                        Text(L("Min Score:"))
                        Slider(value: $viewModel.minSimilarityScore, in: 70...99, step: 1)
                            .frame(width: 200)
                        Text("\(Int(viewModel.minSimilarityScore))")
                            .frame(width: 30, alignment: .trailing)
                    }

                    Toggle(L("Gesture Min Score"), isOn: $viewModel.enableGestureMinScore)
                }
            }
            .frame(maxWidth: .infinity)

            // MARK: Note Group
            GroupBox(L("Note")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L("Show Gesture Note"), isOn: $viewModel.showGestureNote)
                    Toggle(L("Show Icon"), isOn: $viewModel.showNoteIcon)

                    HStack {
                        Text(L("Font:"))
                        Text(viewModel.noteFontName)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 120, alignment: .leading)
                        Button(L("Choose")) { openFontPanel() }
                            .buttonStyle(.bordered)
                        Text(L("FontSize"))
                        Stepper("", value: $viewModel.noteFontSize, in: 8...96, step: 1)
                            .labelsHidden()
                            .frame(width: 60)
                    }

                    HStack {
                        Text(L("Background Apha:"))
                        Slider(value: $viewModel.noteBackgroundAlpha, in: 0.1...1.0, step: 0.05)
                            .frame(width: 160)
                        Text(String(format: "%.2f", viewModel.noteBackgroundAlpha))
                            .frame(width: 40, alignment: .trailing)
                    }

                    HStack {
                        Text(L("Retention Time:"))
                        Stepper(value: $viewModel.noteRetentionTime, in: 1...60, step: 1) {
                            Text("\(viewModel.noteRetentionTime)s")
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    HStack {
                        Text(L("Postion:"))
                        Picker("", selection: $viewModel.notePosition) {
                            Text(L("Follow The Mouse")).tag(0)
                            Text(L("Center In Screen")).tag(1)
                            Text(L("Right Top")).tag(2)
                            Text(L("Right Bottom")).tag(3)
                            Text(L("Left Top")).tag(4)
                            Text(L("Left Bottom")).tag(5)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // MARK: Bottom Buttons (Import, Export, Reset Defaults)
            HStack {
                Button(L("Import")) { importPreferences() }
                    .buttonStyle(.bordered)
                Button(L("Export")) { exportPreferences() }
                    .buttonStyle(.bordered)
                Button(L("Reset Defaults")) { resetDefaults() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct RulesTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @ObservedObject var ruleStore: RuleStore
    @Binding var showingRuleEditor: Bool
    @Binding var editingRule: Rule?
    @State private var selectedPresetGesture: PresetGesture? = nil
    @State private var selectedRuleForPreset: String? = nil
    @State private var showingPresetPicker: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header with buttons
            HStack {
                SectionHeader(L("Gesture Rules"))
                Spacer()

                Picker(L("Preset Gesture"), selection: $selectedPresetGesture) {
                    Text(L("None")).tag(PresetGesture?.none)
                    ForEach(PresetGesture.allCases, id: \.self) { gesture in
                        Text(gesture.rawValue).tag(gesture as PresetGesture?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)

                Button(L("Apply to Selected")) {
                    if let gesture = selectedPresetGesture, let ruleName = selectedRuleForPreset,
                       let idx = ruleStore.rules.firstIndex(where: { $0.name == ruleName }) {
                        let oldRule = ruleStore.rules[idx]
                        let provider = GestureTemplateProvider.shared
                        let stroke = provider.template(for: gesture)
                        let newTemplate = GestureTemplate(from: stroke, name: gesture.rawValue)
                        let newRule = Rule(
                            name: oldRule.name,
                            description: oldRule.description,
                            template: newTemplate,
                            minSimilarityScore: oldRule.minSimilarityScore,
                            action: oldRule.action,
                            note: oldRule.note,
                            isEnabled: oldRule.isEnabled,
                            triggerOnEveryMatch: oldRule.triggerOnEveryMatch,
                            filter: oldRule.filter,
                            filterType: oldRule.filterType
                        )
                        ruleStore.update(newRule)
                        selectedRuleForPreset = nil
                        selectedPresetGesture = nil
                    }
                }
                .buttonStyle(.bordered)
                .disabled(selectedPresetGesture == nil || selectedRuleForPreset == nil)

                Button(L("Draw Gesture")) {
                    drawGestureForSelectedRule()
                }
                .buttonStyle(.bordered)
                .disabled(selectedRuleForPreset == nil)

                Button(L("Add Rule")) {
                    editingRule = nil
                    showingRuleEditor = true
                }
                .buttonStyle(.borderedProminent)

                Button(L("Reset to Defaults")) {
                    ruleStore.rules = RuleStore.defaultRules()
                    ruleStore.save()
                }
                .buttonStyle(.bordered)

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
                    }
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }

            Text(L("tips: Click a gesture thumbnail to select the rule, then use a preset or \"Draw Gesture\"."))
                .font(.caption)
                .foregroundColor(.secondary)

            // Rules list
            if ruleStore.rules.isEmpty {
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
            } else {
                Table(ruleStore.rules) {
                    TableColumn(L("Enabled")) { rule in
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { newValue in
                                let newRule = Rule(
                                    name: rule.name,
                                    description: rule.description,
                                    template: rule.template,
                                    minSimilarityScore: rule.minSimilarityScore,
                                    action: rule.action,
                                    note: rule.note,
                                    isEnabled: newValue,
                                    triggerOnEveryMatch: rule.triggerOnEveryMatch,
                                    filter: rule.filter,
                                    filterType: rule.filterType
                                )
                                ruleStore.update(newRule)
                            }
                        ))
                        .labelsHidden()
                    }
                    .width(60)

                    TableColumn(L("Trigger on Every Match")) { rule in
                        Toggle("", isOn: Binding(
                            get: { rule.triggerOnEveryMatch },
                            set: { newValue in
                                let newRule = Rule(
                                    name: rule.name,
                                    description: rule.description,
                                    template: rule.template,
                                    minSimilarityScore: rule.minSimilarityScore,
                                    action: rule.action,
                                    note: rule.note,
                                    isEnabled: rule.isEnabled,
                                    triggerOnEveryMatch: newValue,
                                    filter: rule.filter,
                                    filterType: rule.filterType
                                )
                                ruleStore.update(newRule)
                            }
                        ))
                        .labelsHidden()
                    }
                    .width(110)

                    TableColumn(L("Type")) { rule in
                        Text(actionTypeLabel(for: rule.action))
                            .font(.system(size: 12))
                    }
                    .width(100)

                    TableColumn(L("Gesture")) { rule in
                        DrawGestureView(
                            points: rule.template.points,
                            ruleIndex: ruleStore.rules.firstIndex(where: { $0.name == rule.name }) ?? 0,
                            showsAddButton: false
                        )
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedRuleForPreset = rule.name
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(selectedRuleForPreset == rule.name ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .width(80)

                    TableColumn(L("Name")) { rule in
                        Text(rule.name)
                            .font(.system(size: 13))
                    }
                    .width(min: 150, max: 200)

                    TableColumn(L("Description")) { rule in
                        Text(rule.description)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 200, max: 300)

                    TableColumn(L("Action")) { rule in
                        ActionBadge(action: rule.action)
                    }
                    .width(140)

                    TableColumn(L("App Filter")) { rule in
                        if rule.filter.isEmpty {
                            Text(L("All Apps"))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                Text(rule.filterType == "regex" ? "🔍" : "✱")
                                Text(rule.filter)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                    .width(min: 150, max: 200)

                    TableColumn("") { rule in
                        HStack(spacing: 8) {
                            Button {
                                editingRule = rule
                                showingRuleEditor = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)

                            Button(role: .destructive) {
                                ruleStore.remove(named: rule.name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .width(80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 400, maxHeight: .infinity)
            }
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

    /// Enter screen-recording mode for the selected rule: close the
    /// preferences window and ask the AppDelegate to capture the next
    /// right-button gesture (original: preSetRuleGestureAtIndex flow).
    private func drawGestureForSelectedRule() {
        guard let ruleName = selectedRuleForPreset else { return }
        let alert = NSAlert()
        alert.messageText = L("Draw Gesture!")
        alert.informativeText = L("You can draw a gesture anywhere on the screen, or select the preset gesture below.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Ok"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(
                name: .macStrokeRecordGesture,
                object: nil,
                userInfo: ["ruleName": ruleName]
            )
        }
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

extension AppleScriptTabView {
    private func exportScripts() {
        let panel = NSSavePanel()
        panel.title = L("Export Scripts")
        panel.allowedContentTypes = [.json]
        panel.allowedFileTypes = ["json"]

        guard let keyWindow = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: keyWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(AppleScriptsList.sharedAppleScriptsList.getAllScripts())
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert.showError(NSError(domain: "MacStroke", code: 1, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]))
            }
        }
    }

    private func importScripts() {
        let panel = NSOpenPanel()
        panel.title = L("Import Scripts")
        panel.allowedContentTypes = [.json]
        panel.allowedFileTypes = ["json"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        guard let keyWindow = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: keyWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let importedScripts = try decoder.decode([AppleScriptItem].self, from: data)
                for script in importedScripts {
                    _ = AppleScriptsList.sharedAppleScriptsList.addScript(name: script.name, source: script.source)
                }
                scripts = AppleScriptsList.sharedAppleScriptsList.getAllScripts()
            } catch {
                NSAlert.showError(NSError(domain: "MacStroke", code: 2, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]))
            }
        }
    }
}

struct ActionBadge: View {
    let action: RuleAction

    var body: some View {
        let (label, color) = actionLabelAndColor
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private var actionLabelAndColor: (String, Color) {
        switch action {
        case .applescript: return (L("Apple Script"), .orange)
        case .keyPress, .shortcut: return (L("Hot Key"), .blue)
        case .mouseClick: return (L("Mouse Click"), .purple)
        case .copyToClipboard: return (L("Copy Text"), .green)
        case .text: return (L("Text"), .teal)
        case .password: return (L("Password"), .red)
        case .none: return (L("None"), .gray)
        }
    }
}

struct RuleEditorView: View {
    @ObservedObject var ruleStore: RuleStore
    let editingRule: Rule?
    let onDismiss: () -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var gestureName = ""
    @State private var minSimilarityScore = 30.0
    @State private var actionType: RuleActionType = .shortcut
    @State private var shortcutKey = ""
    @State private var appleScriptSource = ""
    @State private var copyText = ""
    @State private var mouseClickX = 0
    @State private var mouseClickY = 0
    @State private var note = ""
    @State private var isEnabled = true
    @State private var filter = ""
    @State private var filterType = "wildcard"
    @State private var triggerOnEveryMatch = false
    @State private var availableGestures: [(name: String, stroke: Stroke)] = []

    enum RuleActionType: String, CaseIterable {
        case shortcut = "Hot Key"
        case applescript = "Apple Script"
        case text = "Text"
        case password = "Password"
        case mouseClick = "Mouse Click"
        case none = "None"

        var label: String {
            L(rawValue)
        }

        var icon: String {
            switch self {
            case .shortcut: return "keyboard"
            case .applescript: return "curlybraces"
            case .text: return "doc.on.clipboard"
            case .password: return "key.fill"
            case .mouseClick: return "mousepointer"
            case .none: return "minus.circle"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(editingRule == nil ? L("Add Rule") : L("Edit Rule"))
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 20) {
                GroupBox(L("Basic Info")) {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent(L("Rule Name")) {
                            TextField(L("Rule Name"), text: $name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 300)
                        }
                        LabeledContent(L("Description")) {
                            TextField(L("Description"), text: $description)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 300)
                        }
                    }
                }

                GroupBox(L("Gesture Trigger")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(L("Gesture")) {
                                Picker(L("Gesture"), selection: $gestureName) {
                                    ForEach(availableGestures, id: \.name) { gesture in
                                        Text(gesture.name).tag(gesture.name)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 200)
                            }

                            if availableGestures.isEmpty {
                                Text(L("No templates"))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else {
                                GestureTemplatePreview(
                                    stroke: gestureFromTemplate(named: gestureName),
                                    ruleIndex: availableGestures.firstIndex(where: { $0.name == gestureName }) ?? 0,
                                    onRequestPresetGesture: { index in
                                        // Handle preset gesture request
                                    }
                                )
                                .frame(width: 60, height: 60)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Min Similarity Score"))
                            Slider(value: $minSimilarityScore, in: 0...100, step: 1)
                            Text("\(Int(minSimilarityScore))%")
                                .frame(width: 40)
                        }
                    }
                }

                GroupBox(L("App Filter (optional)")) {
                    HStack {
                        TextField(L("Bundle ID filter (e.g. com.apple.*)"), text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                        Picker("", selection: $filterType) {
                            Text(L("Wildcard")).tag("wildcard")
                            Text(L("Regex")).tag("regex")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                }

                GroupBox(L("Action")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(L("Action Type"), selection: $actionType) {
                            ForEach(RuleActionType.allCases, id: \.self) { type in
                                Label(type.label, systemImage: type.icon).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)

                        Group {
                            switch actionType {
                            case .shortcut:
                                HStack {
                                    Text(L("Key Combination"))
                                    ShortcutRecorder(text: $shortcutKey, onShortcutChanged: { shortcutKey = $0 })
                                        .frame(width: 150, height: 24)
                                }
                            case .applescript:
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(L("AppleScript Source"))
                                    TextEditor(text: $appleScriptSource)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(minHeight: 120)
                                        .border(Color.secondary.opacity(0.2))
                                }
                            case .text:
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(L("Text to input"))
                                    TextEditor(text: $copyText)
                                        .frame(minHeight: 80)
                                        .border(Color.secondary.opacity(0.2))
                                }
                            case .password:
                                HStack {
                                    Text(L("Password (will be masked)"))
                                    SecureField(L("Password"), text: $copyText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 200)
                                }
                            case .mouseClick:
                                HStack {
                                    Text(L("X:"))
                                    TextField("X", value: $mouseClickX, formatter: NumberFormatter())
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                    Text(L("Y:"))
                                    TextField("Y", value: $mouseClickY, formatter: NumberFormatter())
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                }
                            case .none:
                                EmptyView()
                            }
                        }
                    }
                }

                GroupBox(L("Notification")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(L("Enabled"), isOn: $isEnabled)
                        Toggle(L("Trigger on every match"), isOn: $triggerOnEveryMatch)
                        LabeledContent(L("Notification text")) {
                            TextField(L("Notification text"), text: $note)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 300)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(L("Cancel"), action: onDismiss)
                Button(editingRule == nil ? L("Add") : L("Save")) {
                    saveRule()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || gestureName.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 600)
        .onAppear {
            availableGestures = GestureTemplateProvider.shared.allTemplatesIncludingReversed()
            if let rule = editingRule {
                populateFromRule(rule)
            } else {
                gestureName = availableGestures.first?.name ?? ""
            }
        }
    }

    private func populateFromRule(_ rule: Rule) {
        name = rule.name
        description = rule.description
        gestureName = rule.template.name
        minSimilarityScore = rule.minSimilarityScore
        note = rule.note
        isEnabled = rule.isEnabled
        triggerOnEveryMatch = rule.triggerOnEveryMatch
        filter = rule.filter
        filterType = rule.filterType

        switch rule.action {
        case .keyPress(let key):
            actionType = .shortcut
            shortcutKey = key
        case .shortcut(let keyCode, let flags):
            actionType = .shortcut
            shortcutKey = "keyCode=\(keyCode), flags=\(flags)"
        case .applescript(let source):
            actionType = .applescript
            appleScriptSource = source
        case .copyToClipboard(let text):
            actionType = .text
            copyText = text
        case .text(let text):
            actionType = .text
            copyText = text
        case .password(let text):
            actionType = .password
            copyText = text
        case .mouseClick(let x, let y):
            actionType = .mouseClick
            mouseClickX = x
            mouseClickY = y
        case .none:
            actionType = .none
        }
    }

    /// Returns the Stroke for the gesture template with the given name.
    private func gestureFromTemplate(named name: String) -> Stroke? {
        return availableGestures.first { $0.name == name }?.stroke
    }

    private func saveRule() {
        let template = availableGestures.first { $0.name == gestureName }.map { GestureTemplate(from: $0.stroke, name: $0.name) } ?? GestureTemplate(points: [], name: gestureName)

        let action: RuleAction
        switch actionType {
        case .shortcut:
            if let combined = parseShortcutKey(shortcutKey) {
                action = .shortcut(keyCode: combined.keyCode, flags: combined.flags)
            } else {
                action = .keyPress(shortcutKey)
            }
        case .applescript:
            action = .applescript(appleScriptSource)
        case .text:
            action = .text(copyText)
        case .password:
            action = .password(copyText)
        case .mouseClick:
            action = .mouseClick(x: mouseClickX, y: mouseClickY)
        case .none:
            action = .none
        }

        let rule = Rule(
            name: name,
            description: description,
            template: template,
            minSimilarityScore: minSimilarityScore,
            action: action,
            note: note,
            isEnabled: isEnabled,
            triggerOnEveryMatch: triggerOnEveryMatch,
            filter: filter,
            filterType: filterType
        )

        if editingRule != nil {
            ruleStore.update(rule)
        } else {
            ruleStore.add(rule)
        }
    }

    private func parseShortcutKey(_ raw: String) -> (keyCode: UInt16, flags: UInt)? {
        // Expect format "keyCode=X, flags=Y"
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

struct AppleScriptTabView: View {
    @Binding var scripts: [AppleScriptItem]
    @Binding var showingScriptEditor: Bool
    @Binding var editingScript: AppleScriptItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                SectionHeader(L("AppleScripts"))
                Spacer()
                Button(L("Add Script")) {
                    editingScript = nil
                    showingScriptEditor = true
                }
                .buttonStyle(.borderedProminent)

                Menu {
                    ForEach(AppleScriptExamples.examples, id: \.name) { example in
                        Button(example.name) {
                            _ = AppleScriptsList.sharedAppleScriptsList.addScript(name: example.name, source: example.source)
                            scripts = AppleScriptsList.sharedAppleScriptsList.getAllScripts()
                        }
                    }
                } label: {
                    Label(L("Load Example"), systemImage: "plus.square.on.square")
                }
                .menuStyle(.borderlessButton)

                Button(L("Export Scripts…")) {
                    exportScripts()
                }
                .buttonStyle(.bordered)

                Button(L("Import Scripts…")) {
                    importScripts()
                }
                .buttonStyle(.bordered)
            }

            if scripts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(L("No AppleScripts defined"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(L("Click \"Add Script\" or \"Load Example\" to get started"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                Table(scripts) {
                    TableColumn(L("Name")) { script in
                        Text(script.name)
                            .font(.system(size: 13))
                    }
                    .width(min: 200, max: 300)

                    TableColumn(L("Source Preview")) { script in
                        Text(script.source.prefix(80).replacingOccurrences(of: "\n", with: " ") + (script.source.count > 80 ? "…" : ""))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 250, max: 400)

                    TableColumn(L("Created")) { script in
                        Text(script.createTime, style: .date)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .width(120)

                    TableColumn("") { script in
                        HStack(spacing: 8) {
                            Button {
                                editingScript = script
                                showingScriptEditor = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)

                            Button {
                                openInExternalEditor(script: script)
                            } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .buttonStyle(.borderless)

                            Button(role: .destructive) {
                                AppleScriptsList.sharedAppleScriptsList.removeScript(id: script.id)
                                scripts = AppleScriptsList.sharedAppleScriptsList.getAllScripts()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .width(120)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 400)
            }
        }
    }
}

private func openInExternalEditor(script: AppleScriptItem) {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MacStrokeExternalEditor", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
    let fileURL = tempDir.appendingPathComponent("\(script.id).applescript")
    // Write source as plain text for the editor
    do {
        try script.source.write(to: fileURL, atomically: true, encoding: .utf8)
    } catch {
        NSAlert.showError(NSError(domain: "MacStroke", code: 3, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]))
        return
    }
    NSWorkspace.shared.open(fileURL)
}

struct ScriptEditorView: View {
    @Binding var scripts: [AppleScriptItem]
    let editingScript: AppleScriptItem?
    let onDismiss: () -> Void

    @State private var name = ""
    @State private var source = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(editingScript == nil ? L("Add AppleScript") : L("Edit AppleScript"))
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 20) {
                GroupBox(L("Script Info")) {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent(L("Name")) {
                            TextField(L("Name"), text: $name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 400)
                        }
                    }
                }

                GroupBox(L("Source Code")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $source)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 300)
                            .border(Color.secondary.opacity(0.2))
                    }
                }
            }

            HStack {
                Spacer()
                Button(L("Cancel"), action: onDismiss)
                Button(editingScript == nil ? L("Add") : L("Save")) {
                    if let editingScript = editingScript {
                        // Replace in place: remove the old entry, keep its id.
                        let id = editingScript.id
                        AppleScriptsList.sharedAppleScriptsList.removeScript(id: id)
                        let added = AppleScriptsList.sharedAppleScriptsList.addScript(name: name, source: source)
                        _ = added
                    } else {
                        AppleScriptsList.sharedAppleScriptsList.addScript(name: name, source: source)
                    }
                    scripts = AppleScriptsList.sharedAppleScriptsList.getAllScripts()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || source.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 600, height: 500)
        .onAppear {
            if let script = editingScript {
                name = script.name
                source = script.source
            }
        }
    }
}

/// Example scripts corresponding to the original's bundled .scpt examples
/// (ChromeCloseTabsToTheRight, OpenMacStrokePreferences, SearchInWeb).
struct AppleScriptExamples {
    static let examples = [
        (name: "Close Tabs To The Right In Chrome",
         source: """
         tell application "Google Chrome"
             set windowIndex to 1
             repeat with w in windows
                 set activeTabIndex to active tab index of w
                 set tabCount to count of tabs of w
                 repeat with i from tabCount to (activeTabIndex + 1) by -1
                     delete tab i of w
                 end repeat
             end repeat
         end tell
         """),
        (name: "Open MacStroke Preferences",
         source: """
         tell application "MacStroke" to activate
         """),
        (name: "Search in Web",
         source: """
         set searchURL to "https://www.google.com/search?q="
         set theClipboard to the clipboard as text
         set encodedQuery to do shell script "python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' " & quoted form of theClipboard
         open location (searchURL & encodedQuery)
         """),
    ]
}

// MARK: - Filters Tab
// Original: black/white list mode radio + two text views + apply + add.

struct FiltersTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @State private var blackListText = ""
    @State private var whiteListText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(L("Application Filters"))

            VStack(alignment: .leading, spacing: 12) {
                Picker(L("Filter Mode"), selection: $viewModel.whiteListMode) {
                    Text(L("Black list mode")).tag(false)
                    Text(L("White list mode")).tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: viewModel.whiteListMode) { _ in
                    persistLists()
                }
            }

            Text(L("Enter bundle identifiers one per line. Supports wildcards (e.g. com.jetbrains.*)"))
                .font(.caption)
                .foregroundColor(.secondary)

            SectionHeader(L("Black List"))
            TextEditor(text: $blackListText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 130)
                .border(Color.secondary.opacity(0.2))

            SectionHeader(L("White List"))
            TextEditor(text: $whiteListText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 130)
                .border(Color.secondary.opacity(0.2))

            HStack {
                Button(L("add..")) { addRunningApp(toBlackList: !viewModel.whiteListMode) }
                    .buttonStyle(.bordered)
                Button(L("Apply")) { persistLists() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }

            Text(L("Current mode: \(viewModel.whiteListMode ? "Whitelist" : "Blacklist")"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            blackListText = BlackWhiteFilter.shared.blackListText
            whiteListText = BlackWhiteFilter.shared.whiteListText
        }
    }

    private func persistLists() {
        BlackWhiteFilter.shared.blackListText = blackListText
        BlackWhiteFilter.shared.whiteListText = whiteListText
        viewModel.save()
    }

    /// Add a running app's bundle ID to the black or white list
    /// (original: AppPickerWindowController with addedToTextView).
    private func addRunningApp(toBlackList: Bool) {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !($0.bundleIdentifier ?? "").isEmpty }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }

        let alert = NSAlert()
        alert.messageText = L("Pick a running app")
        alert.alertStyle = .informational

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for app in apps {
            popup.addItem(withTitle: "\(app.localizedName ?? "") (\(app.bundleIdentifier ?? ""))")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))

        if alert.runModal() == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0,
           popup.indexOfSelectedItem < apps.count {
            let bundleID = apps[popup.indexOfSelectedItem].bundleIdentifier ?? ""
            if toBlackList {
                blackListText = appendLine(bundleID, to: blackListText)
            } else {
                whiteListText = appendLine(bundleID, to: whiteListText)
            }
            persistLists()
        }
    }

    private func appendLine(_ line: String, to text: String) -> String {
        var lines = text.split(separator: "\n").map(String.init)
        if !lines.contains(line) {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
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
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(L("Right Click Menu - App List"))

            Text(L("tips:Simulate right mouse click ,support '*' character matching. eg:'com.jetbrains.*'"))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
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
            }

            if rightClickApps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "mouse")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(L("No applications configured"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
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
                .frame(minHeight: 300)
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

    /// Pick a running app (original: AppPickerWindowController selectOne mode)
    /// and replace the selected list entry with its bundle ID.
    private func addRunningApp() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !($0.bundleIdentifier ?? "").isEmpty }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }

        let alert = NSAlert()
        alert.messageText = L("Pick a running app")
        alert.alertStyle = .informational

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for app in apps {
            popup.addItem(withTitle: "\(app.localizedName ?? "") (\(app.bundleIdentifier ?? ""))")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))

        if alert.runModal() == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0,
           popup.indexOfSelectedItem < apps.count {
            let bundleID = apps[popup.indexOfSelectedItem].bundleIdentifier ?? ""
            if !bundleID.isEmpty {
                RightClicksList.shared.add(bundleID)
                rightClickApps = RightClicksList.shared.allApps()
            }
        }
    }
}

// MARK: - RightClickMenu Tab
// Original: enable right click menu + item toggles + terminal picker.

struct RightClickMenuTabView: View {
    @ObservedObject var viewModel: UserPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(L("Finder Right-Click Menu"))

            Toggle(L("enable right click menu"), isOn: Binding(
                get: { viewModel.enableRightClickMenu },
                set: { newValue in
                    viewModel.enableRightClickMenu = newValue
                    syncToExtension()
                }
            ))

            if viewModel.enableRightClickMenu {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { viewModel.enableNewFile },
                        set: { newValue in
                            viewModel.enableNewFile = newValue
                            syncToExtension()
                        }
                    )) {
                        Label(L("new text file"), systemImage: "doc.badge.plus")
                    }
                    Toggle(isOn: Binding(
                        get: { viewModel.enableOpenInTerminal },
                        set: { newValue in
                            viewModel.enableOpenInTerminal = newValue
                            syncToExtension()
                        }
                    )) {
                        Label(L("open in terminal"), systemImage: "terminal.fill")
                    }
                    Toggle(isOn: Binding(
                        get: { viewModel.enableCopyFilePath },
                        set: { newValue in
                            viewModel.enableCopyFilePath = newValue
                            syncToExtension()
                        }
                    )) {
                        Label(L("copy file path"), systemImage: "doc.on.doc")
                    }

                    Divider()

                    HStack {
                        Text(L("Terminal"))
                        Picker("", selection: $viewModel.userTerminal) {
                            Text("Terminal").tag("Terminal")
                            Text("Iterm").tag("iTerm")
                        }
                        .pickerStyle(.radioGroup)
                        .frame(width: 160)
                    }

                    HStack {
                        Button(L("Re-enable Extension")) {
                            RightClickMenuManager.shared.reEnableFinderExtension()
                        }
                        .buttonStyle(.bordered)

                        Button(L("Delayed Re-enable")) {
                            RightClickMenuManager.shared.delayedEnableFinderExtension()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.leading, 16)
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
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(L("Clipboard History"))

            Toggle(L("enable history clipboard"), isOn: $viewModel.enableHistoryClipboard)

            if viewModel.enableHistoryClipboard {
                VStack(alignment: .leading, spacing: 16) {
                    // Storage mode: local file vs RAM
                    HStack {
                        Text(L("storage:"))
                        Picker("", selection: $viewModel.clipoardStroageLocal) {
                            Text(L("local")).tag(true)
                            Text(L("ram")).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                    .frame(height: 30)

                    Text(L("Storage limit"))
                        .font(.headline)

                    HStack {
                        Toggle(L("Limit top records:"), isOn: $viewModel.enableLimitTop)
                        Stepper(value: $viewModel.limitTop, in: 1...9999) {
                            Text("\(viewModel.limitTop)")
                                .frame(width: 50, alignment: .trailing)
                        }
                        .disabled(!viewModel.enableLimitTop)
                    }

                    HStack {
                        Toggle(L("Limit total records:"), isOn: $viewModel.enableLimitTotal)
                        Stepper(value: $viewModel.limitTotal, in: 1...999999) {
                            Text("\(viewModel.limitTotal)")
                                .frame(width: 60, alignment: .trailing)
                        }
                        .disabled(!viewModel.enableLimitTotal)
                    }

                    HStack {
                        Toggle(L("Limit save days:"), isOn: $viewModel.enableLimitSaveDays)
                        Stepper(value: $viewModel.limitSaveDays, in: 1...9999) {
                            Text("\(viewModel.limitSaveDays)")
                                .frame(width: 50, alignment: .trailing)
                        }
                        .disabled(!viewModel.enableLimitSaveDays)
                    }

                    Divider()

                    // Global shortcut to show clipboard history list
                    HStack {
                        Text(L("keyboard shortcut:"))
                        ShortcutRecorder(
                            text: $viewModel.historyCilpboardListShortcut,
                            onShortcutChanged: { viewModel.historyCilpboardListShortcut = $0 }
                        )
                        .frame(width: 200, height: 28)
                    }

                    Button(L("show history clipboard")) {
                        showHistoryList()
                    }
                    .buttonStyle(.bordered)

                    Divider()

                    HStack {
                        Button(L("Clear History")) {
                            confirmThen(L("Are you sure to clear all history clipboard records?")) {
                                HistoryClipboardManager().clearHistoryList()
                            }
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)

                        Button(L("Clear Pinned")) {
                            confirmThen(L("Are you sure to clear all top records?")) {
                                HistoryClipboardManager().clearTop()
                            }
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)

                        Button(L("Clear All")) {
                            confirmThen(L("Are you sure to clear all top records and history clipboard records?")) {
                                HistoryClipboardManager().clearAll()
                            }
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)

                        Spacer()
                    }
                }
                .padding(.leading, 16)
            }

            SectionHeader(L("Current Status"))
            let manager = HistoryClipboardManager()
            HStack {
                Text(L("Pinned items") + ": \(manager.topCount)")
                Spacer()
                Text(L("Total items") + ": \(manager.getCount(isTop: false))")
            }
            .font(.caption)
            .foregroundColor(.secondary)
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

struct AboutTabView: View {
    @ObservedObject var viewModel: UserPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .frame(width: 128, height: 128)

                Text(L("MacStroke"))
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text(L("Version") + ": \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Text(L("Author: mtjo.net@gmail.com"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Toggle(L("Automatically Check for Updates"), isOn: $viewModel.autoCheckUpdates)
                Button(L("Check Now")) {
                    NotificationCenter.default.post(name: .macStrokeCheckForUpdates, object: nil)
                }
                .buttonStyle(.bordered)
            }

            Divider()

            SectionHeader(L("Links"))
            HStack(spacing: 20) {
                Link(L("GitHub Repository"), destination: URL(string: "https://github.com/mtjo/MacStroke")!)
                Link(L("issues"), destination: URL(string: "https://github.com/mtjo/MacStroke/issues")!)
            }

            Spacer()
        }
    }
}

// MARK: - Shared Components

struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.primary)
    }
}
