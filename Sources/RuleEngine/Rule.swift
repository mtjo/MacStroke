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
    /// No action (for rules that only trigger state changes)
    case none

    private enum CodingKeys: String, CodingKey {
        case type, applescript, keyPress, mouseClickX, mouseClickY, copyToClipboard
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

    /// Create a new rule.
    /// - Parameters:
    ///   - name: Human-readable rule name
    ///   - description: Description of the rule
    ///   - template: The gesture template to match against
    ///   - minSimilarityScore: DTW score threshold (0..100) for matching
    ///   - action: Action to execute when matched
    ///   - isEnabled: Whether the rule is enabled
    public init(
        name: String,
        description: String,
        template: GestureTemplate,
        minSimilarityScore: Double = 30.0,
        action: RuleAction,
        note: String = "",
        isEnabled: Bool = true
    ) {
        self.name = name
        self.description = description
        self.template = template
        self.minSimilarityScore = minSimilarityScore
        self.action = action
        self.note = note
        self.isEnabled = isEnabled
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
}