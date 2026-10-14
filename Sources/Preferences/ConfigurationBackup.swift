//
//  ConfigurationBackup.swift
//  MacStroke
//
//  What the preferences' 导出 / 导入 buttons move.
//
//  The preferences domain alone is not a backup: the gesture rules and the
//  AppleScript list live as JSON files under Application Support, so a plist of
//  just the toggles comes out a couple of kilobytes long with none of the
//  configuration the user meant to save (issue #69).
//

import Foundation
import Storage
import RuleEngine
import AppleScriptRunner

enum ConfigurationBackup {
    /// Keys the two configuration files travel under inside the plist.
    static let rulesKey = "rulesJSON"
    static let scriptsKey = "appleScriptsJSON"

    /// A backup: MacStroke's own settings plus both configuration files.
    static func payload(domainValues: [String: Any], rules: Data, scripts: Data) -> [String: Any] {
        var payload = settings(from: domainValues)
        payload[rulesKey] = rules
        payload[scriptsKey] = scripts
        return payload
    }

    /// The settings a backup carries, minus the two payloads — i.e. what may go
    /// back into the preferences domain. Writing a payload there would park a
    /// second copy of the rules under a key nothing reads.
    static func domainValues(from backup: [String: Any]) -> [String: Any] {
        backup.filter { key, _ in key != rulesKey && key != scriptsKey }
    }

    /// Apply the configuration half of a backup. The newest shape wins: a backup
    /// from this build has the JSON payloads, a 2.x export carries
    /// NSKeyedArchiver blobs under the old `rules` / `appleScripts` keys, and a
    /// 3.0–3.1.2 export has neither (that is the settings-only file this replaces).
    ///
    /// Scripts come first: a 2.x rule references its script by the legacy id, and
    /// that alias only exists once the same file's script list is in place.
    static func apply(_ backup: [String: Any],
                      ruleStore: RuleStore,
                      scriptList: AppleScriptsList) throws {
        if let scripts = backup[scriptsKey] as? Data {
            try scriptList.restoreConfiguration(from: scripts)
        } else if let archive = backup["appleScripts"] as? Data {
            scriptList.importLegacyScripts(from: archive)
        }
        if let rules = backup[rulesKey] as? Data {
            try ruleStore.restoreConfiguration(from: rules)
        } else if let archive = backup["rules"] as? Data {
            ruleStore.restoreLegacyRules(from: archive) { legacy in
                scriptList.scriptID(forLegacyID: legacy)?.uuidString ?? legacy
            }
        }
    }

    /// MacStroke's own keys in a full preferences domain dump: the declared
    /// settings, the black/white filters, and the right-click app list.
    private static func settings(from values: [String: Any]) -> [String: Any] {
        values.filter { key, _ in
            StorageKey.allCases.contains { $0.rawValue == key }
                || key.hasPrefix("filter") || key == "rightClicksList"
        }
    }
}
