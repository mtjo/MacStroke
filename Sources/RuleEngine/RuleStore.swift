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
        } catch {
            print("[RuleStore] No existing rules file found, starting fresh: \(error)")
            rules = []
        }
    }

    /// Check if a rule name already exists.
    /// - Parameter name: The rule name to check.
    /// - Returns: true if a rule with this name exists.
    public func exists(named name: String) -> Bool {
        rules.contains { $0.name == name }
    }
}