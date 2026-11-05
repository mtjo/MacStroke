//
//  GestureRecordFlow.swift
//  MacStroke
//
//  「录一个手势」的流程：先把事件捕获层切到录制模式，同时弹原版那个预设手势网格。
//  用户在屏幕遮罩上画完即自存（原版的合成 Return），点了预设则把模板写回规则。
//  规则页和截图页共用，所以从 PreferencesView 的私有方法里挪出来。
//

import AppKit
import GestureEngine
import RuleEngine
import Storage

enum GestureRecordFlow {
    /// 冲突提示的出口与起手键来源。留成接缝（不是 private）：桩件里弹不出系统通知，
    /// 也不该去动用户真实偏好，判据只能直接调 `applyInstantGesture` 再看这两格。
    static var conflictNotifier: (String) -> Void = { postMacStrokeNotification($0) }
    static var triggerButtonNumber: () -> Int = {
        PreferencesStorage().getIntOptional(forKey: .gestureTriggerButton)
            ?? StorageDefaults.gestureTriggerButton
    }

    /// Enter screen-recording mode for the given rule and show the original
    /// "Draw Gesture!" alert with its preset-gesture combo box
    /// (AppPrefsWindowController.m preSetRuleGestureAtIndex / alertModal…).
    static func record(ruleName: String, store: RuleStore) {
        NotificationCenter.default.post(
            name: .macStrokeRecordGesture,
            object: nil,
            userInfo: ["ruleName": ruleName]
        )

        // A gesture drawn on the live overlay saves itself and closes the picker,
        // like the original's synthetic Return key press.
        var drawnOnScreen = false
        let drawnObs = NotificationCenter.default.addObserver(
            forName: .macStrokeGestureDidRecord, object: nil, queue: .main
        ) { _ in
            drawnOnScreen = true
        }
        defer { NotificationCenter.default.removeObserver(drawnObs) }

        guard let preset = PresetGesturePickerPanel.pick() else {
            if !drawnOnScreen {
                NotificationCenter.default.post(name: .macStrokeCancelRecordGesture, object: nil)
            }
            return
        }
        NotificationCenter.default.post(name: .macStrokeCancelRecordGesture, object: nil)
        let applied: Bool
        if let instant = preset.instant {
            applied = applyInstantGesture(instant, toRuleNamed: ruleName, store: store)
        } else {
            applied = applyPresetGesture(preset.name, toRuleNamed: ruleName, store: store)
        }
        guard applied else { return }
        postMacStrokeNotification(L("Gesture draw complete!"))
    }

    /// 选了面板底部那一栏的瞬时档（滚轮两档或中键/侧键）：规则从此按「瞬时手势」匹配，
    /// 轨迹点清掉。一条规则只有一个手势来源，留着旧轨迹点的话，哪天把 `instant_gesture`
    /// 键手工删掉，那条早就没人认的轨迹会静默复活。
    ///
    /// 留成模块内可见（不是 private）：桩件里弹不出模态面板，`record` 那条链走不到
    /// 这一手，判据只能直接调它（见 WheelRuleGestureFlowTests）。
    @discardableResult
    static func applyInstantGesture(
        _ gesture: InstantGesture, toRuleNamed ruleName: String, store ruleStore: RuleStore
    ) -> Bool {
        guard let old = ruleStore.rule(named: ruleName) else { return false }
        let newRule = Rule(
            name: old.name,
            description: old.description,
            template: GestureTemplate(points: [], name: gesture.displayName),
            minSimilarityScore: old.minSimilarityScore,
            action: old.action,
            note: old.note,
            isEnabled: old.isEnabled,
            triggerOnEveryMatch: old.triggerOnEveryMatch,
            filter: old.filter,
            filterType: old.filterType,
            spareActions: old.spareActions,
            instantGesture: gesture
        )
        ruleStore.update(newRule)
        NotificationCenter.default.post(name: .macStrokeRuleStoreDidChange, object: nil)
        warnIfConflicting(gesture)
        return true
    }

    /// 选中的瞬时档正好是当前起手键：规则照样存下来（用户可能随后去换起手键），但必须
    /// 提醒一声 —— 运行时起手键优先，这条规则现在按不出来。
    private static func warnIfConflicting(_ gesture: InstantGesture) {
        guard let number = gesture.mouseButtonNumber,
              triggerButtonNumber() == number else { return }
        conflictNotifier(String(format: L("Gesture Trigger Conflicts With Instant Rule"),
                                L(gesture.locKey)))
    }

    /// Map a combo title ("M", "M Revered", "┏"…) to a preset template and
    /// write it into the rule (original: preGestureSelectionChanged:).
    private static func applyPresetGesture(
        _ title: String, toRuleNamed ruleName: String, store ruleStore: RuleStore
    ) -> Bool {
        // Only titles the original picker actually offers may be applied.
        guard let entry = GestureTemplateProvider.shared.presetPickerEntries
            .first(where: { $0.name == title }) else { return false }
        guard let idx = ruleStore.rules.firstIndex(where: { $0.name == ruleName }) else { return false }
        let old = ruleStore.rules[idx]
        let template = GestureTemplate(from: entry.stroke, name: entry.name)
        let newRule = Rule(
            name: old.name,
            description: old.description,
            template: template,
            minSimilarityScore: old.minSimilarityScore,
            action: old.action,
            note: old.note,
            isEnabled: old.isEnabled,
            triggerOnEveryMatch: old.triggerOnEveryMatch,
            filter: old.filter,
            filterType: old.filterType,
            spareActions: old.spareActions
        )
        ruleStore.update(newRule)
        NotificationCenter.default.post(name: .macStrokeRuleStoreDidChange, object: nil)
        return true
    }
}
