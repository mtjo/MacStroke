//
//  RuleStore.swift
//  MacStroke
//
//  Persistent storage for gesture matching rules.
//  Supports CRUD operations, filter matching, and JSON serialization.
//

import Foundation
import GestureEngine
import RuleEngine
import Storage

/// A rule store that manages gesture rules with persistence.
@available(macOS 13.0, *)
public final class RuleStore: ObservableObject {
    /// All loaded rules.
    @Published public var rules: [Rule] = []

    /// The file URL for persistent storage.
    private let storageURL: URL

    /// Create a new rule store.
    /// - Parameter storageURL: Path to the JSON rules file (defaults to ~/Library/Application Support/MacStroke/rules.json)
    public init(storageURL: URL? = nil) {
        let url: URL
        if let storageURL = storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.storageURL = appSupport.appendingPathComponent("MacStroke/rules.json")
        }
        self.rules = []
        load()
    }

    /// All rules.
    public var allRules: [Rule] {
        rules
    }

    /// Enabled rules only.
    public var enabledRules: [Rule] {
        rules.filter { $0.isEnabled }
    }

    /// The number of enabled rules.
    public var enabledRuleCount: Int {
        rules.filter { $0.isEnabled }.count
    }

    /// Get a rule by name.
    public func rule(named name: String) -> Rule? {
        rules.first { $0.name == name }
    }

    /// Add a rule.
    /// - Parameter rule: The rule to add.
    public func add(_ rule: Rule) {
        rules.append(rule)
        save()
    }

    /// Update a rule.
    /// - Parameter rule: The rule to update (must have a name).
    /// - Returns: The updated rule, or nil if not found.
    @discardableResult
    public func update(_ rule: Rule) -> Rule? {
        if let index = rules.firstIndex(where: { $0.name == rule.name }) {
            rules[index] = rule
            save()
            return rules[index]
        }
        return nil
    }

    /// Remove a rule by name.
    /// - Parameter name: The rule name to remove.
    /// - Returns: The removed rule, or nil if not found.
    @discardableResult
    public func remove(named name: String) -> Rule? {
        if let index = rules.firstIndex(where: { $0.name == name }) {
            let removed = rules.remove(at: index)
            save()
            return removed
        }
        return nil
    }

    /// Match a stroke against rules, with optional bundle ID filtering.
    /// - Parameters:
    ///   - stroke: The stroke to test
    ///   - bundleID: The current application's bundle ID
    /// - Returns: The matching rule and its similarity score, or nil if no match.
    public func match(stroke: Stroke, bundleID: String? = nil) -> (rule: Rule, score: Double)? {
        // Use RuleEngine's match method
        // Create a temporary rule engine with our rules
        let engine = RuleEngine()
        engine.add(contentsOf: rules)
        return engine.match(stroke: stroke, bundleID: bundleID)
    }

    /// Whether any enabled rule's filter matches the given bundle ID
    /// (original: `appSuitedRule:` — gates whether the gesture UI is shown).
    public func appSuitedRule(bundleID: String) -> Bool {
        let engine = RuleEngine()
        engine.add(contentsOf: rules)
        return engine.appSuitedRule(bundleID: bundleID)
    }

    /// Save rules to disk.
    public func save() {
        do {
            let data = try JSONEncoder().encode(rules)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[RuleStore] Failed to save rules: \(error)")
        }
    }

    /// Load rules from disk.
    public func load() {
        do {
            let data = try Data(contentsOf: storageURL)
            rules = try JSONDecoder().decode([Rule].self, from: data)
            if rules.isEmpty {
                print("[RuleStore] Existing rules file is empty, loading default rules")
                rules = RuleStore.defaultRules()
                save()
            }
        } catch {
            print("[RuleStore] No existing rules file found, starting with default rules: \(error)")
            rules = RuleStore.defaultRules()
            save()
        }
    }

    /// Default rules matching the original MacStroke preset configuration
    /// (RulesList.m `reInit`). Shortcut key codes are Carbon virtual key codes;
    /// modifier flags are CGEventFlags raw values.
    public static func defaultRules() -> [Rule] {
        let gestures = GestureTemplateProvider.shared.allTemplatesIncludingReversed()
        let templateByName = Dictionary(uniqueKeysWithValues: gestures.map { ($0.name, $0.stroke) })

        // CGEventFlags raw values for keyboard modifiers.
        let cmd: UInt = 0x100000
        let shift: UInt = 0x20000
        let control: UInt = 0x40000
        let option: UInt = 0x80000
        // Carbon virtual key codes.
        let keyLeftArrow: UInt16 = 123
        let keyRightArrow: UInt16 = 124
        let keyPageUp: UInt16 = 116
        let keyPageDown: UInt16 = 121
        let keyM: UInt16 = 46
        let keyF: UInt16 = 3
        let keyQ: UInt16 = 12
        let keyW: UInt16 = 13
        let keyV: UInt16 = 9
        let keyA: UInt16 = 0
        let keyLeftBracket: UInt16 = 33
        let keyRightBracket: UInt16 = 30

        func rule(
            name: String,
            description: String,
            gesture: String,
            action: RuleAction,
            note: String,
            filter: String = "*",
            filterType: String = "wildcard"
        ) -> Rule {
            let stroke = templateByName[gesture] ?? templateByName["A Shape"]!
            return Rule(
                name: name,
                description: description,
                template: GestureTemplate(from: stroke, name: gesture),
                minSimilarityScore: 30.0,
                action: action,
                note: note,
                isEnabled: true,
                triggerOnEveryMatch: false,
                filter: filter,
                filterType: filterType
            )
        }

        return [
            rule(
                name: "Password",
                description: "Input password",
                gesture: "P Shape Revered",
                action: .password("12345678"),
                note: "input password"
            ),
            rule(
                name: "Email",
                description: "Input e-mail",
                gesture: "M Shape",
                action: .text("mtjo.net@gmail.com"),
                note: "input e-mail"
            ),
            rule(
                name: "Back",
                description: "Navigate back",
                gesture: "\u{2190}",
                action: .shortcut(keyCode: keyLeftArrow, flags: cmd),
                note: "Back"
            ),
            rule(
                name: "Next",
                description: "Navigate next",
                gesture: "\u{2192}",
                action: .shortcut(keyCode: keyRightArrow, flags: cmd),
                note: "Next"
            ),
            rule(
                name: "MinSizeAll",
                description: "Minimize all windows",
                gesture: "\u{2198}",
                action: .shortcut(keyCode: keyM, flags: cmd | option),
                note: "Min Size All Windows"
            ),
            rule(
                name: "MinSize",
                description: "Minimize window",
                gesture: "\u{2199}",
                action: .shortcut(keyCode: keyM, flags: cmd),
                note: "Min Size Windows"
            ),
            rule(
                name: "FullScreen",
                description: "Toggle full screen",
                gesture: "\u{2197}",
                action: .shortcut(keyCode: keyF, flags: cmd | control),
                note: "Full screen"
            ),
            rule(
                name: "Exit",
                description: "Exit app",
                gesture: "L Shape Revered",
                action: .shortcut(keyCode: keyQ, flags: cmd),
                note: "Exit App"
            ),
            rule(
                name: "CloseTab",
                description: "Close tab",
                gesture: "L Shape",
                action: .shortcut(keyCode: keyW, flags: cmd),
                note: "Close Tab"
            ),
            rule(
                name: "Paste",
                description: "Paste",
                gesture: "V Shape",
                action: .shortcut(keyCode: keyV, flags: cmd),
                note: "Paste"
            ),
            rule(
                name: "SelectAll",
                description: "Select all",
                gesture: "A Shape",
                action: .shortcut(keyCode: keyA, flags: cmd),
                note: "SelectALL"
            ),
            rule(
                name: "PageUp",
                description: "Page up",
                gesture: "I Shape Revered",
                action: .shortcut(keyCode: keyPageUp, flags: 0),
                note: "PageUp"
            ),
            rule(
                name: "PageDown",
                description: "Page down",
                gesture: "I Shape",
                action: .shortcut(keyCode: keyPageDown, flags: 0),
                note: "PageDown"
            ),
            rule(
                name: "PrevTab",
                description: "Previous tab",
                gesture: "T Shape Revered",
                action: .shortcut(keyCode: keyLeftBracket, flags: shift | cmd),
                note: "Prev Tab"
            ),
            rule(
                name: "NextTab",
                description: "Next tab",
                gesture: "F Shape Revered",
                action: .shortcut(keyCode: keyRightBracket, flags: shift | cmd),
                note: "Next Tab"
            ),
        ]
    }

    /// Check if a rule name already exists.
    /// - Parameter name: The rule name to check.
    /// - Returns: true if a rule with this name exists.
    public func exists(named name: String) -> Bool {
        rules.contains { $0.name == name }
    }
}