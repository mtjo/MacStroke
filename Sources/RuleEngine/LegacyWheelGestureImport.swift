//
//  LegacyWheelGestureImport.swift
//  MacStroke
//
//  3.2.3 及以前，「按住起手键 + 滚轮」是一组独立偏好（`wheelGesture*` 五个键），
//  在「右键增强」页配、由一只专用执行器投键。3.2.4 把这段整并进规则表，旧页面删掉：
//  升级时把老用户真开过的那两档一次性翻成两条瞬时规则，之后只看规则表。
//
//  判据必须读**持久域**而不是 `object(forKey:)`：注册域里的值会让「没用过这个功能」
//  也读出默认的 false / 1 / 2，迁移就永远以为用户配过（issue #76 同一条教训）。
//  这五个键也已从 `registerUserDefaultsDefaults()` 摘掉，两处一起兜住。
//

import Foundation
import GestureEngine

extension RuleStore {
    /// 3.2.3 及以前的五个键。用字面量而不是 `StorageKey`：RuleEngine 看不到 Storage，
    /// 而且这几个名字属于历史数据，不该跟着偏好层一起改名。
    private enum LegacyWheelKey {
        static let enabled = "wheelGestureEnabled"
        static let upAction = "wheelGestureUpAction"
        static let downAction = "wheelGestureDownAction"
        static let upShortcut = "wheelGestureUpShortcut"
        static let downShortcut = "wheelGestureDownShortcut"

        /// 旧偏好缺失时页面上显示的那两档（`StorageDefaults` 当年的值）。
        static let upActionDefault = 1
        static let downActionDefault = 2
    }

    /// 把旧的两档转成滚轮规则，只做一次。
    ///
    /// 触发条件只有一条：持久域里 `wheelGestureEnabled` 真的写着 `true`。
    /// 没落过盘（全新安装）、或用户当年关着（旧页面关掉总开关时也会先写 false）都不迁移，
    /// 保持原版「滚轮不接管」的行为。
    ///
    /// 每个方向各转一条 `filter = "*"` 的启用规则：
    /// - 上一个/下一个标签页 → ⌘⇧[ / ⌘⇧]；
    /// - 音量 ±1 档 → `.volumeUp` / `.volumeDown`；
    /// - 自定义快捷键按调用方给的解析口径转 `.shortcut`；
    /// - 「无」、以及解析不出来的自定义键，不生成规则（旧版这两档本来也不动作）。
    ///
    /// 迁移后把总开关写回 `false`，所以重复启动不会再加一遍；某一方向规则表里已经有
    /// 一条瞬时规则时也跳过，不会和用户后来手配的那条撞车。
    ///
    /// - Parameters:
    ///   - defaults: 读旧偏好的域（生产 = `.standard`）。
    ///   - domainName: 该域的持久化名字（生产 = bundle identifier，测试 = suite 名）。
    ///   - upName / downName: 新规则名，由调用方给本地化文案；重名时自动加序号。
    ///   - parseShortcut: `"keyCode=X, flags=Y"` 的解析入口。生产传
    ///     `ShortcutMonitor.parseShortcut`，RuleEngine 够不到那一层。
    /// - Returns: 是否真的写入了规则。
    @discardableResult
    public func importLegacyWheelGesturesIfNeeded(
        defaults: UserDefaults = .standard,
        domainName: String,
        upName: String,
        downName: String,
        parseShortcut: (String) -> (keyCode: UInt16, flags: UInt)? = { _ in nil }
    ) -> Bool {
        let stored = defaults.persistentDomain(forName: domainName) ?? [:]
        guard storedBool(LegacyWheelKey.enabled, in: stored) else { return false }

        // 先关闸：下面就算一条规则都没生成，下次启动也不该再猜一遍。
        defaults.set(false, forKey: LegacyWheelKey.enabled)
        defaults.synchronize()

        let directions: [(gesture: InstantGesture, name: String, action: Int, shortcut: String)] = [
            (.wheelUp,
             upName,
             storedInt(LegacyWheelKey.upAction, in: stored) ?? LegacyWheelKey.upActionDefault,
             storedString(LegacyWheelKey.upShortcut, in: stored) ?? ""),
            (.wheelDown,
             downName,
             storedInt(LegacyWheelKey.downAction, in: stored) ?? LegacyWheelKey.downActionDefault,
             storedString(LegacyWheelKey.downShortcut, in: stored) ?? ""),
        ]

        var imported: [Rule] = []
        for direction in directions {
            // 已经有一条同方向的瞬时规则 = 用户后来自己配过，旧档不再插一脚。
            guard !rules.contains(where: { $0.instantGesture == direction.gesture }) else { continue }
            let custom = direction.shortcut.isEmpty ? nil : parseShortcut(direction.shortcut)
            guard let action = WheelGestureActionKind(preferenceValue: direction.action)
                .ruleAction(customShortcut: custom) else { continue }
            imported.append(Rule(
                name: availableName(basedOn: direction.name),
                description: "",
                template: GestureTemplate(points: [], name: direction.gesture.displayName),
                action: action,
                note: "",
                isEnabled: true,
                filter: "*",
                filterType: "wildcard",
                instantGesture: direction.gesture
            ))
        }

        guard !imported.isEmpty else {
            NSLog("%@", "[RuleStore] 旧滚轮设置开着，但两档都没有可迁移的动作")
            return false
        }
        // 新规则放最前面，与「+」新建一条的落点一致（规则表按行号显示）。
        rules.insert(contentsOf: imported, at: 0)
        save()
        NSLog("%@", "[RuleStore] 把旧滚轮设置迁移成 \(imported.count) 条规则："
            + imported.map(\.name).joined(separator: ", "))
        return true
    }

    /// 规则按名字寻址（改名、就地编辑都靠它），迁移出来的名字撞上已有规则时加序号。
    private func availableName(basedOn base: String) -> String {
        var candidate = base
        var suffix = 2
        while rules.contains(where: { $0.name == candidate }) {
            candidate = "\(base) (\(suffix))"
            suffix += 1
        }
        return candidate
    }

    // MARK: - 持久域读数

    private func storedBool(_ key: String, in domain: [String: Any]) -> Bool {
        (domain[key] as? NSNumber)?.boolValue ?? false
    }

    private func storedInt(_ key: String, in domain: [String: Any]) -> Int? {
        (domain[key] as? NSNumber)?.intValue
    }

    private func storedString(_ key: String, in domain: [String: Any]) -> String? {
        domain[key] as? String
    }
}
