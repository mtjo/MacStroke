//
 //  PreferencesView.swift
 //  MacStroke
 //
 //  SwiftUI-based tabbed preferences UI for MacStroke.
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

extension AppleScriptItem: Identifiable {
    // Already has UUID id
}

/// Preferences window content with tabbed interface.
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
                    case .appleScript:
                        AppleScriptTabView(
                            scripts: $scripts,
                            showingScriptEditor: $showingScriptEditor,
                            editingScript: $editingScript
                        )
                    case .filters:
                        FiltersTabView(viewModel: viewModel)
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
                        AboutTabView()
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 600, minHeight: 550)
        }
        .id(languageRevision)
        .onReceive(NotificationCenter.default.publisher(for: .languageDidChange)) { _ in
            languageRevision += 1
        }
        .frame(minWidth: 780, minHeight: 600)
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
                onDismiss: { showingScriptEditor = false; editingScript = nil }
            )
        }
        .onAppear {
            loadScripts()
            loadRightClickApps()
        }
        .onChange(of: selectedTab) { newTab in
            if newTab == .appleScript {
                loadScripts()
            } else if newTab == .rightClick {
                loadRightClickApps()
            }
        }
    }

    private func loadScripts() {
        scripts = AppleScriptsList.sharedAppleScriptsList.getAllScripts()
    }

    private func loadRightClickApps() {
        rightClickApps = RightClicksList.shared.allApps()
    }
}

/// Tab enumeration for the preferences window.
enum PreferencesTab: CaseIterable {
    case general
    case rules
    case appleScript
    case filters
    case rightClick
    case rightClickMenu
    case clipboard
    case about

    var title: String {
        switch self {
        case .general: return L("General")
        case .rules: return L("Rules")
        case .appleScript: return L("AppleScript")
        case .filters: return L("Filters")
        case .rightClick: return L("Right Click")
        case .rightClickMenu: return L("RightClickMenu")
        case .clipboard: return L("Clipboard")
        case .about: return L("About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .rules: return "list.bullet.rectangle"
        case .appleScript: return "curlybraces"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .rightClick: return "mouse"
        case .rightClickMenu: return "menubar.rectangle"
        case .clipboard: return "doc.on.clipboard"
        case .about: return "info.circle"
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

struct GeneralTabView: View {
    @ObservedObject var viewModel: UserPreferences
    // Use the shared LaunchAtLoginController singleton from EventCapture
    @StateObject private var launchController = LaunchAtLoginController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(L("General"))

            VStack(alignment: .leading, spacing: 16) {
                Toggle(L("Enable MacStroke"), isOn: $viewModel.isEnabled)
                Toggle(L("Show icon in status bar"), isOn: $viewModel.showIconInStatusBar)
                Toggle(L("Launch at login"), isOn: Binding(
                    get: { launchController.isEnabled },
                    set: { enabled in
                        launchController.setEnabled(enabled)
                        viewModel.launchAtLogin = enabled
                    }
                ))
                Toggle(L("Show UI in any application"), isOn: $viewModel.showUIInWhateverApp)
            }

            SectionHeader(L("Language"))

            Picker(L("Language"), selection: $viewModel.language) {
                Text(L("English")).tag("en")
                Text(L("简体中文")).tag("zh-Hans")
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            SectionHeader(L("Version"))

            HStack {
                Text(L("Version"))
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    .foregroundColor(.secondary)
                Text(L("Build") + " \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")")
                    .foregroundColor(.secondary)
            }
        }
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

                Button(L("Add Rule")) {
                    editingRule = nil
                    showingRuleEditor = true
                }
                .buttonStyle(.borderedProminent)

                Button(L("Reset to Defaults")) {
                    ruleStore.rules = []
                    ruleStore.save()
                }
                .buttonStyle(.bordered)

                Button(L("Clear All")) {
                    ruleStore.rules.removeAll()
                    ruleStore.save()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }

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
                                    filter: rule.filter,
                                    filterType: rule.filterType
                                )
                                ruleStore.update(newRule)
                            }
                        ))
                        .labelsHidden()
                    }
                    .width(60)

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
        case .applescript: return (L("AppleScript"), .orange)
        case .keyPress: return (L("Shortcut"), .blue)
        case .mouseClick: return (L("Mouse Click"), .purple)
        case .copyToClipboard: return (L("Copy Text"), .green)
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
    @State private var availableGestures: [(name: String, stroke: Stroke)] = []

    enum RuleActionType: String, CaseIterable {
        case shortcut = "Shortcut"
        case applescript = "AppleScript"
        case text = "Copy Text"
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
                                    TextField("e.g. ⌘⇧N", text: $shortcutKey)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 150)
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
                                    Text(L("Text to Copy"))
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
                        Toggle(L("Show notification on match"), isOn: $isEnabled)
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
            availableGestures = GestureTemplateProvider.shared.allTemplates()
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
        filter = rule.filter
        filterType = rule.filterType

        switch rule.action {
        case .keyPress(let key):
            actionType = .shortcut
            shortcutKey = key
        case .applescript(let source):
            actionType = .applescript
            appleScriptSource = source
        case .copyToClipboard(let text):
            if text.contains("password") || text.count > 20 {
                actionType = .password
            } else {
                actionType = .text
            }
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
    /// - Parameter name: The name of the gesture template.
    /// - Returns: The Stroke if found, nil otherwise.
    private func gestureFromTemplate(named name: String) -> Stroke? {
        return availableGestures.first { $0.name == name }?.stroke
    }

    private func saveRule() {
        let template = availableGestures.first { $0.name == gestureName }.map { GestureTemplate(from: $0.stroke, name: $0.name) } ?? GestureTemplate(points: [], name: gestureName)

        let action: RuleAction
        switch actionType {
        case .shortcut:
            action = .keyPress(shortcutKey)
        case .applescript:
            action = .applescript(appleScriptSource)
        case .text, .password:
            action = .copyToClipboard(copyText)
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
            filter: filter,
            filterType: filterType
        )

        if editingRule != nil {
            ruleStore.update(rule)
        } else {
            ruleStore.add(rule)
        }
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
                    Label(L("Add Example"), systemImage: "plus.square.on.square")
                }
                .menuStyle(.borderlessButton)
            }

            if scripts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(L("No AppleScripts defined"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(L("Click \"Add Script\" or \"Add Example\" to get started"))
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
                        Text(script.source.prefix(80).replacingOccurrences(of: "\n", with: " ") + "…")
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

                            Button(role: .destructive) {
                                AppleScriptsList.sharedAppleScriptsList.removeScript(id: script.id)
                                scripts = AppleScriptsList.sharedAppleScriptsList.getAllScripts()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .width(80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 400)
            }
        }
    }
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
                        AppleScriptsList.sharedAppleScriptsList.removeScript(id: editingScript.id)
                        AppleScriptsList.sharedAppleScriptsList.addScript(name: name, source: source)
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

struct AppleScriptExamples {
    static let examples = [
        (name: "Show Notification", source: "display notification \"Hello from MacStroke\" with title \"MacStroke\""),
        (name: "Open URL", source: "open location \"https://github.com\""),
        (name: "Run Shell Command", source: "do shell script \"echo 'Hello' > ~/Desktop/test.txt\""),
        (name: "Activate App", source: "tell application \"Finder\" to activate"),
        (name: "Get Clipboard", source: "the clipboard as text"),
        (name: "Set Clipboard", source: "set the clipboard to \"Hello World\""),
    ]
}

// MARK: - Filters Tab

struct FiltersTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @State private var blockFilterText = ""
    @State private var whiteListText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(L("Application Filters"))

            VStack(alignment: .leading, spacing: 12) {
                Picker(L("Filter Mode"), selection: $viewModel.whiteListMode) {
                    Text(L("Blacklist Mode (block listed apps)")).tag(false)
                    Text(L("Whitelist Mode (only allow listed apps)")).tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            SectionHeader(L("Blocklist"))
            Text(L("Enter bundle identifiers to block (one per line). Supports wildcards (e.g. com.jetbrains.*)"))
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $blockFilterText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .border(Color.secondary.opacity(0.2))
                .onChange(of: blockFilterText) { newValue in viewModel.blockFilter = newValue }

            SectionHeader(L("Allowlist"))
            Text(L("Enter bundle identifiers to allow (one per line). Only used in whitelist mode."))
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $whiteListText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .border(Color.secondary.opacity(0.2))
                .onChange(of: whiteListText) { newValue in viewModel.whiteList = newValue }

            HStack {
                Button(L("Add Running App…")) {
                    // TODO: Show running apps picker
                }
                .buttonStyle(.bordered)

                Button(L("Apply")) {
                    viewModel.save()
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }

            SectionHeader(L("Preview"))
            Text(L("Current mode: \(viewModel.whiteListMode ? "Whitelist" : "Blacklist")"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            blockFilterText = viewModel.blockFilter
            whiteListText = viewModel.whiteList
        }
    }
}

// MARK: - Right Click Tab

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

            Text(L("Configure which applications show the MacStroke right-click menu. Supports wildcards (e.g. com.jetbrains.*)"))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                TextField(L("Bundle ID (e.g. com.apple.finder)"), text: $newRightClickApp)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
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
}

// MARK: - RightClickMenu Tab

struct RightClickMenuTabView: View {
    @ObservedObject var viewModel: UserPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(L("Finder Right-Click Menu"))

            Toggle(L("Enable Finder right-click menu extension"), isOn: $viewModel.enableRightClickMenu)

            if viewModel.enableRightClickMenu {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Menu Items"))
                        .font(.headline)

                    Toggle(isOn: $viewModel.enableNewFile) {
                        Label(L("New Text File"), systemImage: "doc.badge.plus")
                    }
                    Toggle(isOn: $viewModel.enableOpenInTerminal) {
                        Label(L("Open in Terminal"), systemImage: "terminal.fill")
                    }
                    Toggle(isOn: $viewModel.enableCopyFilePath) {
                        Label(L("Copy File Path"), systemImage: "doc.on.doc")
                    }

                    Divider()

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

            SectionHeader(L("Terminal Preference"))
            HStack {
                Text(L("Default Terminal App:"))
                TextField(L("Terminal"), text: Binding(
                    get: { UserDefaults.standard.string(forKey: "userTerminal") ?? "Terminal" },
                    set: { UserDefaults.standard.set($0, forKey: "userTerminal") }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }
    }
}

// MARK: - Clipboard Tab

struct ClipboardTabView: View {
    @ObservedObject var viewModel: UserPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(L("Clipboard History"))

            Toggle(L("Enable clipboard history"), isOn: $viewModel.enableHistoryClipboard)

            if viewModel.enableHistoryClipboard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(L("Pinned items limit"))
                        Spacer()
                        Stepper(value: $viewModel.clipboardLimitTop, in: 1...200) {
                            Text("\(viewModel.clipboardLimitTop)")
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    HStack {
                        Text(L("Total history limit"))
                        Spacer()
                        Stepper(value: $viewModel.clipboardLimitTotal, in: 10...5000, step: 10) {
                            Text("\(viewModel.clipboardLimitTotal)")
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    HStack {
                        Text(L("Keep history for (days)"))
                        Spacer()
                        Stepper(value: $viewModel.clipboardSaveDays, in: 1...365) {
                            Text("\(viewModel.clipboardSaveDays)")
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    Divider()

                    HStack {
                        Button(L("Clear History")) {
                            HistoryClipboardManager().clearHistoryList()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)

                        Button(L("Clear Pinned")) {
                            HistoryClipboardManager().clearTop()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)

                        Button(L("Clear All")) {
                            HistoryClipboardManager().clearAll()
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
                Text("Pinned items: \(manager.topCount)")
                Spacer()
                Text("Total items: \(manager.getCount(isTop: false))")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }
}

// MARK: - About Tab

struct AboutTabView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .frame(width: 128, height: 128)

                Text(L("MacStroke"))
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text(L("Version") + " \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Text(L("Build") + " \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)

            Divider()

            SectionHeader(L("About"))
            Text(L("MacStroke is a gesture recognition utility for macOS that lets you trigger actions by drawing mouse gestures."))
                .font(.body)

            SectionHeader(L("Links"))
            HStack(spacing: 20) {
                Link(L("GitHub Repository"), destination: URL(string: "https://github.com/mtjo/MacStroke")!)
                Link(L("Report an Issue"), destination: URL(string: "https://github.com/mtjo/MacStroke/issues")!)
            }

            SectionHeader(L("License"))
            Text(L("MIT License - Copyright © 2024"))
                .font(.caption)
                .foregroundColor(.secondary)

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