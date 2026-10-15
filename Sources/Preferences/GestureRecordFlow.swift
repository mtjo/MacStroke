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
        guard applyPresetGesture(preset.name, toRuleNamed: ruleName, store: store) else { return }
        postMacStrokeNotification(L("Gesture draw complete!"))
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
