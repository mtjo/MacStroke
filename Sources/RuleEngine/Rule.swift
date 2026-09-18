//
//  Rule.swift
//  MacStroke
//
//  Defines a gesture matching rule with a pattern and an associated action.
//
//  A rule consists of:
//  - A template stroke (the expected gesture pattern)
//  - An action to execute when the pattern matches
//  - Optional metadata (name, description)
//

import Foundation
import GestureEngine

/// An action that can be executed when a gesture rule matches.
public enum RuleAction: Codable {
    /// Execute an AppleScript string
    case applescript(String)
    /// Simulate a key press
    case keyPress(String)
    /// Simulate a mouse click at given coordinates
    case mouseClick(x: Int, y: Int)
    /// Copy text to clipboard
    case copyToClipboard(String)
    /// Trigger a keyboard shortcut (key code + modifier flags)
    case shortcut(keyCode: UInt16, flags: UInt)
    /// Plain text action (insert text via key equivalents)
    case text(String)
    /// Password action (secure text, e.g. typed into frontmost app)
    case password(String)
    /// No action (for rules that only trigger state changes)
    case none

    private enum CodingKeys: String, CodingKey {
        case type, applescript, keyPress, mouseClickX, mouseClickY, copyToClipboard, keyCode, flags, text, password
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "applescript":
            let script = try container.decode(String.self, forKey: .applescript)
            self = .applescript(script)
        case "keyPress":
            let key = try container.decode(String.self, forKey: .keyPress)
            self = .keyPress(key)
        case "mouseClick":
            let x = try container.decode(Int.self, forKey: .mouseClickX)
            let y = try container.decode(Int.self, forKey: .mouseClickY)
            self = .mouseClick(x: x, y: y)
        case "copyToClipboard":
            let text = try container.decode(String.self, forKey: .copyToClipboard)
            self = .copyToClipboard(text)
        case "shortcut":
            let kc = try container.decode(UInt16.self, forKey: .keyCode)
            let fl = try container.decode(UInt.self, forKey: .flags)
            self = .shortcut(keyCode: kc, flags: fl)
        case "text":
            let t = try container.decode(String.self, forKey: .text)
            self = .text(t)
        case "password":
            let p = try container.decode(String.self, forKey: .password)
            self = .password(p)
        case "none":
            self = .none
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown RuleAction type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .applescript(let script):
            try container.encode("applescript", forKey: .type)
            try container.encode(script, forKey: .applescript)
        case .keyPress(let key):
            try container.encode("keyPress", forKey: .type)
            try container.encode(key, forKey: .keyPress)
        case .mouseClick(let x, let y):
            try container.encode("mouseClick", forKey: .type)
            try container.encode(x, forKey: .mouseClickX)
            try container.encode(y, forKey: .mouseClickY)
        case .copyToClipboard(let text):
            try container.encode("copyToClipboard", forKey: .type)
            try container.encode(text, forKey: .copyToClipboard)
        case .shortcut(let keyCode, let flags):
            try container.encode("shortcut", forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(flags, forKey: .flags)
        case .text(let t):
            try container.encode("text", forKey: .type)
            try container.encode(t, forKey: .text)
        case .password(let p):
            try container.encode("password", forKey: .type)
            try container.encode(p, forKey: .password)
        case .none:
            try container.encode("none", forKey: .type)
        }
    }

    /// Human-readable description of the action
    public var description: String {
        switch self {
        case .applescript(let script):
            return "AppleScript: \(script)"
        case .keyPress(let key):
            return "Key press: \(key)"
        case .mouseClick(let x, let y):
            return "Mouse click at (\(x), \(y))"
        case .copyToClipboard(let text):
            return "Copy to clipboard: \(text)"
        case .shortcut(let keyCode, let flags):
            return "Shortcut: key=\(keyCode), flags=\(flags)"
        case .text(let t):
            return "Text: \(t)"
        case .password(let p):
            return "Password: ****"
        case .none:
            return "No action"
        }
    }
}

/// A gesture matching rule that can be tested against a stroke.
public struct Rule: Codable {
    /// Human-readable name for the rule
    public let name: String
    /// Description of what this rule does
    public let description: String
    /// Optional toast note shown after the rule matches.
    public let note: String
    /// The gesture template to match against
    public let template: GestureTemplate
    /// The minimum similarity score (0..100) required for a match
    public let minSimilarityScore: Double
    /// The action to execute when the rule matches
    public let action: RuleAction
    /// Whether the rule is enabled
    public let isEnabled: Bool
    /// Whether the rule should keep triggering on every match while the gesture is held.
    public let triggerOnEveryMatch: Bool
    /// Optional bundle ID filter (wildcard or regex) for app-specific rules
    public let filter: String
    /// Filter type: "wildcard" or "regex"
    public let filterType: String

    /// Create a new rule.
    /// - Parameters:
    ///   - name: Human-readable rule name
    ///   - description: Description of the rule
    ///   - template: The gesture template to match against
    ///   - minSimilarityScore: DTW score threshold (0..100) for matching
    ///   - action: Action to execute when matched
    ///   - note: Toast note shown after match
    ///   - isEnabled: Whether the rule is enabled
    ///   - triggerOnEveryMatch: Whether to keep triggering while gesture is held
    ///   - filter: Bundle ID filter (wildcard or regex)
    ///   - filterType: "wildcard" or "regex"
    public init(
        name: String,
        description: String,
        template: GestureTemplate,
        minSimilarityScore: Double = 30.0,
        action: RuleAction,
        note: String = "",
        isEnabled: Bool = true,
        triggerOnEveryMatch: Bool = false,
        filter: String = "",
        filterType: String = "wildcard"
    ) {
        self.name = name
        self.description = description
        self.template = template
        self.minSimilarityScore = minSimilarityScore
        self.action = action
        self.note = note
        self.isEnabled = isEnabled
        self.triggerOnEveryMatch = triggerOnEveryMatch
        self.filter = filter
        self.filterType = filterType
    }
}

/// A rule engine that matches incoming strokes against defined rules.
public final class RuleEngine {
    /// All loaded rules, in order.
    private var rules: [Rule]

    /// Create a new rule engine with no pre-loaded rules.
    public init() {
        self.rules = []
    }

    /// Load a rule into the engine.
    /// - Parameter rule: The rule to add.
    public func add(_ rule: Rule) {
        rules.append(rule)
    }

    /// Load multiple rules into the engine.
    /// - Parameter newRules: The rules to add.
    public func add(contentsOf newRules: [Rule]) {
        rules.append(contentsOf: newRules)
    }

    /// Check if a stroke matches any of the defined rules.
    /// - Parameter stroke: The stroke to test (must be normalized).
    /// - Returns: The matching rule and its similarity score, or nil if no match.
    public func match(stroke: Stroke) -> (rule: Rule, score: Double)? {
        // Normalize the input stroke for comparison
        var normalizedStroke = stroke
        normalizedStroke.normalize()

        for rule in rules where rule.isEnabled {
            let score = compare(
                template: rule.template.stroke,
                candidate: normalizedStroke
            )
            if score >= rule.minSimilarityScore {
                return (rule, score)
            }
        }

        return nil
    }

    /// Execute the action for the first matching rule.
    /// - Parameter stroke: The stroke to test.
    /// - Returns: The executed action, or nil if no match.
    @discardableResult
    public func executeAction(for stroke: Stroke) -> RuleAction? {
        if let (rule, _) = match(stroke: stroke) {
            let action = rule.action
            let executor = ActionExecutor()
            executor.execute(action, for: rule)
            return action
        }
        return nil
    }

    /// The number of enabled rules.
    public var enabledRuleCount: Int {
        rules.filter { $0.isEnabled }.count
    }

    /// All rules.
    public var allRules: [Rule] {
        rules
    }

    /// Remove all rules.
    public func removeAll() {
        rules.removeAll()
    }

    /// Match a stroke against rules, optionally filtered by bundle ID.
    ///
    /// Mirrors the original's `setActionIndex`: iterates **all** filter-matching
    /// rules and returns the one with the **highest** score (not the first to
    /// pass a threshold). The global `enableGestureMinScore` / `minScore`
    /// preferences gate candidate scores, combined with each rule's own
    /// `minSimilarityScore`.
    ///
    /// - Parameters:
    ///   - stroke: The stroke to test
    ///   - bundleID: The current application's bundle ID (optional)
    /// - Returns: The best-matching rule and its similarity score, or nil if no match.
    public func match(stroke: Stroke, bundleID: String? = nil) -> (rule: Rule, score: Double)? {
        // Check BlackWhiteFilter first: if the app is blocked, no rules match
        if let bundleID = bundleID, !BlackWhiteFilter.shared.shouldHookMouseEventForApp(bundleID) {
            return nil
        }

        var normalizedStroke = stroke
        normalizedStroke.normalize()

        // Global score gate (original: enableGestureMinScore + minScore defaults).
        let defaults = UserDefaults.standard
        let enableMinScore = defaults.object(forKey: "enableGestureMinScore") == nil
            ? true
            : defaults.bool(forKey: "enableGestureMinScore")
        let storedMinScore = defaults.double(forKey: "minScore")
        let globalMinScore = storedMinScore > 0 ? storedMinScore : 85.0

        var bestRule: Rule?
        var bestScore: Double = 0.0

        for rule in rules where rule.isEnabled {
            // Apply bundle filter if specified
            if let bundleID = bundleID, !rule.filter.isEmpty {
                if !matchesFilter(filter: rule.filter, type: rule.filterType, bundleID: bundleID) {
                    continue
                }
            }

            let score = compare(
                template: rule.template.stroke,
                candidate: normalizedStroke
            )

            let threshold: Double
            if enableMinScore {
                threshold = max(globalMinScore, rule.minSimilarityScore)
            } else {
                threshold = rule.minSimilarityScore
            }

            if score > 0 && score > bestScore && score >= threshold {
                bestRule = rule
                bestScore = score
            }
        }

        guard let rule = bestRule else { return nil }
        return (rule, bestScore)
    }

    /// Whether any enabled rule's filter matches the given bundle ID
    /// (original: `appSuitedRule:` — used to decide whether the gesture UI
    /// may be shown in the given app).
    public func appSuitedRule(bundleID: String) -> Bool {
        rules.contains { rule in
            rule.isEnabled && matchesFilter(filter: rule.filter, type: rule.filterType, bundleID: bundleID)
        }
    }

    /// Check if a bundle ID matches a filter (wildcard or regex).
    private func matchesFilter(filter: String, type: String, bundleID: String) -> Bool {
        guard !filter.isEmpty else { return true }

        if type == "regex" {
            do {
                let regex = try NSRegularExpression(pattern: filter)
                let range = NSRange(location: 0, length: bundleID.utf16.count)
                return regex.firstMatch(in: bundleID, range: range) != nil
            } catch {
                return false
            }
        } else {
            // Wildcard matching
            let pattern = NSRegularExpression.escapedPattern(for: filter)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            do {
                let regex = try NSRegularExpression(pattern: "^\(pattern)$")
                let range = NSRange(location: 0, length: bundleID.utf16.count)
                return regex.firstMatch(in: bundleID, range: range) != nil
            } catch {
                return false
            }
        }
    }
}