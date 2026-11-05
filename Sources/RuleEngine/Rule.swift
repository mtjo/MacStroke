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
public enum RuleAction: Codable, Equatable {
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
    /// 弹出截图选区（移植版新增，超出原版）。动作本身在 App 层执行：
    /// RuleEngine 够不到 Screenshot 模块，反向依赖会把下层拖回 App 层。
    case screenshot
    /// 系统音量 +1 档（移植版新增，issue #78 第 3 条）。
    case volumeUp
    /// 系统音量 −1 档。
    case volumeDown
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
        case "screenshot":
            self = .screenshot
        case "volumeUp":
            self = .volumeUp
        case "volumeDown":
            self = .volumeDown
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
        case .screenshot:
            try container.encode("screenshot", forKey: .type)
        case .volumeUp:
            try container.encode("volumeUp", forKey: .type)
        case .volumeDown:
            try container.encode("volumeDown", forKey: .type)
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
        case .screenshot:
            return "Screenshot"
        case .volumeUp:
            return "Volume +1"
        case .volumeDown:
            return "Volume -1"
        case .none:
            return "No action"
        }
    }
}

/// The four action payloads the original keeps side by side on every rule
/// (`text`, `password`, `apple_script_id`, `shortcut_code`/`shortcut_flag`).
/// Changing a rule's action type in the original only rewrites `actionType`,
/// so the values typed for the other types survive; these carry them.
public struct RuleSpareActions: Codable, Equatable {
    public var text: String
    public var password: String
    public var appleScriptId: String
    public var shortcutCode: Int
    public var shortcutFlag: Int

    public init(text: String = "",
                password: String = "",
                appleScriptId: String = "",
                shortcutCode: Int = 0,
                shortcutFlag: Int = 0) {
        self.text = text
        self.password = password
        self.appleScriptId = appleScriptId
        self.shortcutCode = shortcutCode
        self.shortcutFlag = shortcutFlag
    }

    public static let empty = RuleSpareActions()

    /// Mirror an action into the slot the original keeps for its type. The
    /// original stores one value per action type and only rewrites `actionType`
    /// when the user switches, so the active type's slot always holds the value
    /// that actually runs; rules built in code (default rules, presets) have to
    /// keep that invariant or switching type drops the value.
    mutating func seeding(with action: RuleAction) {
        switch action {
        case .text(let value):
            text = value
        case .password(let value):
            password = value
        case .applescript(let id):
            appleScriptId = id
        case .shortcut(let keyCode, let flags):
            shortcutCode = Int(keyCode)
            shortcutFlag = Int(flags)
        default:
            break
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
    /// Values typed for the action types this rule does not currently use.
    public var spareActions: RuleSpareActions
    /// 一个不画轨迹的手势（issue #78 第 2 条）：非 nil 时这条规则靠滚轮那一格触发，
    /// `template` 里的点一律不参与轨迹匹配。nil = 原版的轨迹规则，与旧 rules.json 同义。
    public let instantGesture: InstantGesture?

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
    ///   - spareActions: values for the action types this rule does not use
    ///   - instantGesture: 滚轮那一格（nil = 轨迹规则）
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
        filterType: String = "wildcard",
        spareActions: RuleSpareActions = .empty,
        instantGesture: InstantGesture? = nil
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
        self.instantGesture = instantGesture
        var spares = spareActions
        spares.seeding(with: action)
        self.spareActions = spares
    }

    // MARK: - Persistence (original RulesList.m dictionary schema)

    /// Persisted keys mirror the original rule dictionary exactly:
    /// direction / data / filter / filterType / actionType / text / password /
    /// shortcut_code / shortcut_flag / apple_script_id / note /
    /// trigger_on_every_match, plus `instant_gesture` for the port's wheel rule.
    /// In-memory-only fields (description, minSimilarityScore, isEnabled) are
    /// not stored.
    private enum RuleKeys: String, CodingKey {
        case direction, data, filter, filterType, actionType, text, password
        case shortcutCode = "shortcut_code"
        case shortcutFlag = "shortcut_flag"
        case appleScriptId = "apple_script_id"
        case note
        case triggerOnEveryMatch = "trigger_on_every_match"
        case instantGesture = "instant_gesture"
    }

    private struct StoredPoint: Codable {
        let x: Double
        let y: Double
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RuleKeys.self)
        name = try c.decode(String.self, forKey: .direction)
        let points = try c.decode([StoredPoint].self, forKey: .data)
        template = GestureTemplate(
            points: points.map { GesturePoint(x: $0.x, y: $0.y) },
            name: name
        )
        filter = try c.decode(String.self, forKey: .filter)
        filterType = try c.decode(Int.self, forKey: .filterType) == 1 ? "regex" : "wildcard"
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        description = note
        minSimilarityScore = 30.0
        isEnabled = true
        triggerOnEveryMatch = try c.decodeIfPresent(Bool.self, forKey: .triggerOnEveryMatch) ?? false
        // 旧 rules.json 没有这一格，读出来就是 nil = 原版的轨迹规则。认不出的值（手改
        // 文件 / 将来加的新档）同样当 nil：让它炸掉整份规则文件、连别人的手势一起没，
        // 比这一条退化成轨迹规则严重得多。
        if let raw = try c.decodeIfPresent(String.self, forKey: .instantGesture) {
            instantGesture = InstantGesture(rawValue: raw)
        } else {
            instantGesture = nil
        }

        let text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        let password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        let scriptId = try c.decodeIfPresent(String.self, forKey: .appleScriptId) ?? ""
        let code = try c.decodeIfPresent(Int.self, forKey: .shortcutCode) ?? 0
        let flag = try c.decodeIfPresent(Int.self, forKey: .shortcutFlag) ?? 0
        var spares = RuleSpareActions(text: text, password: password, appleScriptId: scriptId)
        switch try c.decode(Int.self, forKey: .actionType) {
        case 1:
            action = .applescript(scriptId)
            spares.shortcutCode = code
            spares.shortcutFlag = flag
        case 2:
            action = .text(text)
            spares.shortcutCode = code
            spares.shortcutFlag = flag
        case 3:
            action = .password(password)
            spares.shortcutCode = code
            spares.shortcutFlag = flag
        case 4:
            action = .screenshot
            spares.shortcutCode = code
            spares.shortcutFlag = flag
        case 5:
            action = .volumeUp
            spares.shortcutCode = code
            spares.shortcutFlag = flag
        case 6:
            action = .volumeDown
            spares.shortcutCode = code
            spares.shortcutFlag = flag
        default:
            action = .shortcut(keyCode: UInt16(truncatingIfNeeded: code), flags: UInt(truncatingIfNeeded: flag))
        }
        spareActions = spares
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: RuleKeys.self)
        try c.encode(name, forKey: .direction)
        try c.encode(template.points.map { StoredPoint(x: $0.x, y: $0.y) }, forKey: .data)
        try c.encode(filter, forKey: .filter)
        try c.encode(filterType == "regex" ? 1 : 0, forKey: .filterType)
        // Original `addRuleWithDirection:` always writes text/password, and only
        // writes the shortcut / script keys for the action type in use.
        var text = spareActions.text
        var password = spareActions.password
        var scriptId = spareActions.appleScriptId
        var code = spareActions.shortcutCode
        var flag = spareActions.shortcutFlag
        var actionType = 0
        switch action {
        case .applescript(let reference):
            actionType = 1
            scriptId = reference
        case .text(let value):
            actionType = 2
            text = value
        case .password(let value):
            actionType = 3
            password = value
        case .shortcut(let keyCode, let flags):
            actionType = 0
            code = Int(keyCode)
            flag = Int(flags)
        case .screenshot:
            actionType = 4
        case .volumeUp:
            actionType = 5
        case .volumeDown:
            actionType = 6
        case .keyPress, .mouseClick, .copyToClipboard, .none:
            actionType = 0
        }
        try c.encode(actionType, forKey: .actionType)
        try c.encode(text, forKey: .text)
        try c.encode(password, forKey: .password)
        if actionType == 1 {
            try c.encode(scriptId, forKey: .appleScriptId)
        } else if actionType == 0 {
            try c.encode(code, forKey: .shortcutCode)
            try c.encode(flag, forKey: .shortcutFlag)
        }
        try c.encode(note, forKey: .note)
        if triggerOnEveryMatch {
            try c.encode(true, forKey: .triggerOnEveryMatch)
        }
        // 只有瞬时规则才写这一格：轨迹规则（含原版那 15 条）导出的 JSON 与改动前逐字节相同。
        if let instantGesture {
            try c.encode(instantGesture.rawValue, forKey: .instantGesture)
        }
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
            // 瞬时规则没有轨迹可比（issue #78 第 2 条）。
            if rule.instantGesture != nil { continue }
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
    ///   - bundleID: The frontmost application's bundle ID ("" when it has none,
    ///     matching the original's `frontBundleName()`)
    /// - Returns: The best-matching rule and its similarity score, or nil if no match.
    public func match(stroke: Stroke, bundleID: String) -> (rule: Rule, score: Double)? {
        // Check BlackWhiteFilter first: if the app is blocked, no rules match
        if !BlackWhiteFilter.shared.shouldHookMouseEventForApp(bundleID) {
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
            // 瞬时规则没有轨迹可比：让它参与打分，空模板会撞出一条「谁都不该中」的
            // 高分（issue #78 第 2 条加这一档时必须一并挡住）。
            if rule.instantGesture != nil { continue }
            // Original: every rule's filter is evaluated, so a rule whose filter
            // matches nothing is skipped even when the filter field is empty.
            if !Self.matchesFilter(filter: rule.filter, type: rule.filterType, bundleID: bundleID) {
                continue
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
        for rule in rules where rule.isEnabled {
            if Self.matchesFilter(filter: rule.filter, type: rule.filterType, bundleID: bundleID) { return true }
        }
        return false
    }

    /// 一次瞬时手势（按住起始键 + 滚轮上/下，issue #78 第 2 条）命中哪条规则。
    ///
    /// 与轨迹匹配差两处：
    /// - 没有分数可比，按**列表顺序取第一条**（规则是插到第 0 行的，所以「后配的赢」，
    ///   与原版把新规则插在顶上那条一致）；
    /// - 门槛仍是同一条黑白名单 + 同一条按 App 过滤，所以在过滤页把某个软件拉黑之后，
    ///   它的滚轮规则跟轨迹规则一起失效，不会出现「黑名单只管一半」。
    ///
    /// - Parameters:
    ///   - gesture: 这一次是哪一档瞬时手势
    ///   - bundleID: 前台应用的 bundle ID（没有时传 ""，与轨迹匹配同口径）
    /// - Returns: 命中的规则，一条都没有时 nil —— 调用方据此决定放行还是吞掉这一发滚轮。
    public func match(instant gesture: InstantGesture, bundleID: String) -> Rule? {
        if !BlackWhiteFilter.shared.shouldHookMouseEventForApp(bundleID) {
            return nil
        }
        return rules.first {
            $0.isEnabled && $0.instantGesture == gesture
                && Self.matchesFilter(filter: $0.filter, type: $0.filterType, bundleID: bundleID)
        }
    }

    /// Check if a bundle ID matches a filter (wildcard or regex).
    /// Mirrors the original `matchFilter:atIndex:`: wildcard filters are split on
    /// "|"/newlines and each segment is `LIKE`-matched (anchored, `*`/`?`)
    /// case-insensitively against the whole bundle ID; regex filters are
    /// case-sensitive substring matches. An empty filter therefore matches
    /// nothing — the original does not treat it as "all apps".
    private static func matchesFilter(filter: String, type: String, bundleID: String) -> Bool {
        if type == "regex" {
            guard let regex = try? NSRegularExpression(pattern: filter) else { return false }
            let range = NSRange(location: 0, length: bundleID.utf16.count)
            return regex.firstMatch(in: bundleID, options: [], range: range) != nil
        }
        return wildcardString(bundleID, patterns: filter, ignoreCase: true)
    }
}