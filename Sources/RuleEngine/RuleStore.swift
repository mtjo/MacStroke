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

    /// Default rules matching the original MacStroke preset configuration.
    public static func defaultRules() -> [Rule] {
        let gestures = GestureTemplateProvider.shared.allTemplates()
        let templateByName = Dictionary(uniqueKeysWithValues: gestures.map { ($0.name, $0.stroke) })

        func rule(
            name: String,
            description: String,
            gesture: String,
            action: RuleAction,
            note: String,
            filter: String = "",
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
                filter: filter,
                filterType: filterType
            )
        }

        return [
            rule(
                name: "Password",
                description: "Input password",
                gesture: "P Shape",
                action: .copyToClipboard("12345678"),
                note: "Input password"
            ),
            rule(
                name: "Email",
                description: "Input e-mail",
                gesture: "M Shape",
                action: .copyToClipboard("mtjo.net@gmail.com"),
                note: "Input e-mail"
            ),
            rule(
                name: "Back",
                description: "Navigate back",
                gesture: "←",
                action: .keyPress("←"),
                note: "Back"
            ),
            rule(
                name: "Next",
                description: "Navigate next",
                gesture: "→",
                action: .keyPress("→"),
                note: "Next"
            ),
            rule(
                name: "Min Size All Windows",
                description: "Minimize all windows",
                gesture: "↘",
                action: .keyPress("m"),
                note: "Min Size All Windows"
            ),
            rule(
                name: "Min Size Windows",
                description: "Minimize window",
                gesture: "↙",
                action: .keyPress("m"),
                note: "Min Size Windows"
            ),
            rule(
                name: "Full Screen",
                description: "Toggle full screen",
                gesture: "↗",
                action: .keyPress("f"),
                note: "Full screen"
            ),
            rule(
                name: "Exit",
                description: "Exit app",
                gesture: "L Shape",
                action: .keyPress("q"),
                note: "Exit App"
            ),
            rule(
                name: "Close Tab",
                description: "Close tab",
                gesture: "L Shape",
                action: .keyPress("w"),
                note: "Close Tab"
            ),
            rule(
                name: "Paste",
                description: "Paste",
                gesture: "V Shape",
                action: .keyPress("v"),
                note: "Paste"
            ),
            rule(
                name: "Select All",
                description: "Select all",
                gesture: "A Shape",
                action: .keyPress("a"),
                note: "SelectALL"
            ),
            rule(
                name: "Page Up",
                description: "Page up",
                gesture: "I Shape",
                action: .keyPress("pageup"),
                note: "PageUp"
            ),
            rule(
                name: "Page Down",
                description: "Page down",
                gesture: "I Shape",
                action: .keyPress("pagedown"),
                note: "PageDown"
            ),
            rule(
                name: "Previous Tab",
                description: "Previous tab",
                gesture: "T Shape",
                action: .keyPress("["),
                note: "Prev Tab"
            ),
            rule(
                name: "Next Tab",
                description: "Next tab",
                gesture: "F Shape",
                action: .keyPress("]"),
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