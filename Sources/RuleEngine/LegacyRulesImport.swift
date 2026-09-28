//
//  LegacyRulesImport.swift
//  MacStroke
//
//  Reads the rule storage of the pre-3.0 (Objective-C) build, which archived an
//  NSMutableArray of rule dictionaries into `UserDefaults["rules"]`. Everything
//  else the old build kept in UserDefaults still loads from there directly; only
//  the rules moved to a JSON file, which is why upgrading dropped them
//  (issue #67).
//

import Foundation
import AppleScriptRunner

@available(macOS 13.0, *)
extension RuleStore {
    /// UserDefaults key holding the pre-3.0 archived rule array.
    static let legacyRulesKey = "rules"

    /// Written once the archived rules have been brought into `rules.json`, so
    /// the import never repeats (and never resurrects rules cleared afterwards).
    static let legacyRulesImportedKey = "legacyRulesImported"

    /// Import the pre-3.0 build's rules, once.
    ///
    /// Run this before the store reaches the gesture pipeline — that is what
    /// `AppDelegate` does, ahead of `capture.start()`. `RuleStore`'s own first
    /// access seeds `rules.json` with the presets, which is why "nothing edited
    /// in this build yet" has to be decided by content rather than by the file
    /// being absent: no rules at all, or a list that persists byte-for-byte the
    /// same as the built-in presets. Those presets are exactly what 3.0.0 and
    /// 3.0.1 wrote on first launch, which is also the moment the archived rules
    /// were dropped. Any other content belongs to the user and wins over
    /// the archive.
    ///
    /// The archived key survives whenever the import declines to run, so the old
    /// rules stay recoverable by hand.
    /// - Parameters:
    ///   - defaults: Preferences domain to read the archive from.
    ///   - appleScriptID: rewrites archived script ids; the production resolver
    ///     needs the shared script list, so tests pass their own.
    ///   - force: Import even when rules have been edited, and ignore the marker
    ///     (the preferences' "导入" button: an explicit restore request).
    /// - Returns: true when the archive was applied to this store.
    @discardableResult
    public func importLegacyRulesIfNeeded(
        defaults: UserDefaults = .standard,
        appleScriptID: (String) -> String = RuleStore.resolveLegacyAppleScriptID,
        force: Bool = false
    ) -> Bool {
        guard force || !defaults.bool(forKey: Self.legacyRulesImportedKey) else { return false }
        if !force, !rules.isEmpty, !Self.isPersistedEqual(rules, RuleStore.defaultRules()) {
            NSLog("%@", "[RuleStore] Rules were edited in this build, leaving the pre-3.0 archive alone")
            return false
        }
        guard let archive = defaults.object(forKey: Self.legacyRulesKey) as? Data else { return false }
        guard let decoded = Self.decodeLegacyRules(archive, appleScriptID: appleScriptID),
              !decoded.rules.isEmpty else { return false }

        rules = decoded.rules
        save()
        defaults.set(true, forKey: Self.legacyRulesImportedKey)
        // Only drop the archive once every row came across; a partial read leaves
        // the untouched source available to the next attempt.
        if decoded.droppedRows == 0 {
            defaults.removeObject(forKey: Self.legacyRulesKey)
        }
        defaults.synchronize()
        NSLog("%@", "[RuleStore] Imported \(decoded.rules.count) rules from the pre-3.0 preferences"
              + (decoded.droppedRows == 0 ? "" : " (\(decoded.droppedRows) rows unreadable)"))
        return true
    }

    /// Decode the pre-3.0 archived rule array (`nil` when the blob holds
    /// something else).
    /// - Parameter appleScriptID: rewrites a rule's `apple_script_id`, used to
    ///   point the rule at the script this build imported it as.
    public static func rules(
        fromLegacyArchive data: Data,
        appleScriptID: (String) -> String = { $0 }
    ) -> [Rule]? {
        decodeLegacyRules(data, appleScriptID: appleScriptID).map(\.rules)
    }

    /// A single unreadable row is skipped rather than dropping the whole list,
    /// which is what an all-or-nothing decode of the archive would do; the count
    /// of rows left behind decides whether the source may be discarded.
    private static func decodeLegacyRules(
        _ data: Data,
        appleScriptID: (String) -> String
    ) -> (rules: [Rule], droppedRows: Int)? {
        let classes: [AnyClass] = [
            NSArray.self, NSDictionary.self, NSString.self, NSNumber.self, NSValue.self,
        ]
        guard let archived = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data),
              let dictionaries = archived as? [[String: Any]] else { return nil }
        var imported: [Rule] = []
        var dropped = 0
        var seenNames: Set<String> = []
        for dictionary in dictionaries {
            var json = legacyRuleJSON(dictionary, appleScriptID: appleScriptID)
            if let direction = json["direction"] as? String {
                json["direction"] = uniqueDirection(direction, seen: &seenNames)
            }
            guard let encoded = try? JSONSerialization.data(withJSONObject: json),
                  let rule = try? JSONDecoder().decode(Rule.self, from: encoded) else {
                dropped += 1
                NSLog("%@", "[RuleStore] Skipping unreadable pre-3.0 rule: \(dictionary["direction"] ?? "?")")
                continue
            }
            imported.append(rule)
        }
        // The old build indexed rows positionally like this one does, so the
        // archived order is the list the user saw; keep it.
        return (imported, dropped)
    }

    /// This build addresses rules by name (`update` and `replace(named:with:)`
    /// both look one up), while the old "+" button let the same direction repeat
    /// — two rows with one name would edit each other. Suffix the later ones.
    private static func uniqueDirection(_ name: String, seen: inout Set<String>) -> String {
        var candidate = name
        var suffix = 2
        while seen.contains(candidate) {
            candidate = "\(name) (\(suffix))"
            suffix += 1
        }
        seen.insert(candidate)
        return candidate
    }

    /// Reshape one archived rule into what `Rule.init(from:)` decodes: the
    /// `NSNumber`s become plain integers / booleans, and `data` — an array of
    /// `NSValue`-wrapped `NSPoint`s — becomes the `{x, y}` objects this build
    /// writes. A rule created by the old "+" button has no gesture at all, and
    /// an empty template is what shows its "Draw Gesture" placeholder again.
    private static func legacyRuleJSON(
        _ raw: [String: Any],
        appleScriptID: (String) -> String
    ) -> [String: Any] {
        var json: [String: Any] = [:]
        for key in ["direction", "filter", "note", "text", "password"] {
            if let value = raw[key] as? String { json[key] = value }
        }
        for key in ["filterType", "actionType", "shortcut_code", "shortcut_flag"] {
            if let value = raw[key] as? NSNumber { json[key] = value.int64Value }
        }
        if let value = raw["trigger_on_every_match"] as? NSNumber {
            json["trigger_on_every_match"] = value.boolValue
        }
        if let legacyID = raw["apple_script_id"] as? String {
            json["apple_script_id"] = appleScriptID(legacyID)
        }
        json["data"] = (raw["data"] as? [NSValue] ?? []).map { value in
            let point = value.pointValue
            return ["x": Double(point.x), "y": Double(point.y)]
        }
        return json
    }

    /// Map the old build's `NSProcessInfo` globally-unique script ids (a pre-3.0
    /// rule's `apple_script_id`) onto the UUIDs this build gave the same scripts.
    /// Touching the shared list runs its own one-time import first, so the
    /// aliases are in place. An id with no matching script — it was deleted
    /// before the upgrade — is kept verbatim: the row still reads as an
    /// AppleScript action instead of turning into a shortcut on key code 0.
    public static func resolveLegacyAppleScriptID(_ legacyID: String) -> String {
        AppleScriptsList.sharedAppleScriptsList.scriptID(forLegacyID: legacyID)?.uuidString ?? legacyID
    }

    /// Compare two lists through the persisted schema, so the check means "the
    /// file would come out identical" and ignores in-memory-only fields.
    private static func isPersistedEqual(_ lhs: [Rule], _ rhs: [Rule]) -> Bool {
        func persisted(_ rules: [Rule]) -> NSObject? {
            guard let data = try? JSONEncoder().encode(rules),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return json as? NSObject
        }
        guard let left = persisted(lhs), let right = persisted(rhs) else { return false }
        return left.isEqual(right)
    }
}
