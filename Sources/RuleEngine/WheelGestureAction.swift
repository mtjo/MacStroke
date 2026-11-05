//
//  WheelGestureAction.swift
//  MacStroke
//
//  3.2.4 起「按住起手键 + 滚轮」不再有自己的一套执行器：上滚/下滚就是两条普通规则，
//  动作、按应用过滤、备注气泡全部走规则表。这个文件只剩升级路径 —— 把 3.2.3 及以前
//  存在 UserDefaults 里的两档翻成 `RuleAction`，由 `LegacyWheelGestureImport` 一次性写成规则。
//
//  `WheelGestureActionKind` 的原始值不能动：老用户 plist 里存的就是 0…5，
//  换序号等于让所有人的设置跑位。
//

import Foundation

/// 3.2.3 及以前偏好里存的那个数（`wheelGestureUpAction` / `wheelGestureDownAction`）。
public enum WheelGestureActionKind: Int, CaseIterable {
    case none = 0
    case tabPrevious = 1
    case tabNext = 2
    case volumeUp = 3
    case volumeDown = 4
    /// 用户自己录的一条快捷键；键值在 `wheelGestureUpShortcut` / `...DownShortcut` 里。
    case customShortcut = 5

    /// 从旧偏好读数。认不出的数（手改 plist / 将来加新档）一律当「没配」，
    /// 宁可让页面照常滚，也不要瞎投一个动作。
    public init(preferenceValue: Int) {
        self = Self(rawValue: preferenceValue) ?? .none
    }
}

extension WheelGestureActionKind {
    /// ⌘⇧ 的修饰位（`maskShift` 131072 | `maskCommand` 1048576）。
    public static let commandShiftFlags: UInt = 0x10_0000 | 0x2_0000

    /// ANSI 虚拟键码：`[`(33) / `]`(30)。Safari、Chrome、Terminal、多数编辑器
    /// 的「上一个/下一个标签页」都绑这一对，是系统里最通用的两条。
    public static let bracketLeftKeyCode: UInt16 = 33
    public static let bracketRightKeyCode: UInt16 = 30

    /// 迁移成规则动作；`nil` = 这一档在旧版里也不会动作，不生成规则。
    ///
    /// 自定义档的键值串由调用方按 `ShortcutMonitor.parseShortcut` 那一份口径解析好再递进来：
    /// RuleEngine 够不到 EventCapture，再抄一条正则就是第二处会漂移的解析。
    public func ruleAction(customShortcut: (keyCode: UInt16, flags: UInt)? = nil) -> RuleAction? {
        switch self {
        case .none:
            return nil
        case .tabPrevious:
            return .shortcut(keyCode: Self.bracketLeftKeyCode, flags: Self.commandShiftFlags)
        case .tabNext:
            return .shortcut(keyCode: Self.bracketRightKeyCode, flags: Self.commandShiftFlags)
        case .volumeUp:
            return .volumeUp
        case .volumeDown:
            return .volumeDown
        case .customShortcut:
            guard let customShortcut else { return nil }
            return .shortcut(keyCode: customShortcut.keyCode, flags: customShortcut.flags)
        }
    }
}
