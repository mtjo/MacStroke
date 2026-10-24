//
//  WheelGestureAction.swift
//  MacStroke
//
//  issue #75：按住起始键 + 滚轮上/下滚之后的那「一下」干什么。
//
//  这一层是纯查表 + 一次执行，不碰事件循环：滚轮事件本身（方向、格数、节流）归
//  EventCapture 的 `WheelGesture`，这里只回答「这个方向配了什么动作 → 投什么出去」。
//  分开是因为捕获层不该知道「上一个标签页」是 ⌘⇧[，而偏好页只关心下拉里那六个字。
//
//  判据全部收在 `WheelGesturePlan.effect` 这个静态纯函数里，好让取证用例逐条钉：
//  没配动作 → nil（事件原样交回前台应用，页面照常滚），配了 → 一个明确的效应。
//

import Foundation

/// 偏好里存的那个数（`wheelGestureUpAction` / `wheelGestureDownAction`）。
///
/// 用 `Int` 原始值而不是字符串：与本页其余开关一样存进 UserDefaults 的整数，旧值
/// 缺失时读到 `StorageDefaults` 的 1/2 正好是「上滚切上一页、下滚切下一页」。
public enum WheelGestureActionKind: Int, CaseIterable {
    case none = 0
    case tabPrevious = 1
    case tabNext = 2
    case volumeUp = 3
    case volumeDown = 4
    /// 用户自己录的一条快捷键；键值在 `wheelGestureUpShortcut` / `...DownShortcut` 里。
    case customShortcut = 5

    /// 从偏好读数。认不出的数（手改 plist / 将来加新档）一律当「没配」，
    /// 宁可让页面照常滚，也不要瞎投一个动作。
    public init(preferenceValue: Int) {
        self = Self(rawValue: preferenceValue) ?? .none
    }
}

/// 一次滚轮触发要投出去的东西。
public enum WheelGestureEffect: Equatable {
    case shortcut(keyCode: UInt16, flags: UInt)
    /// 音量：`step` 是这一档的增减量（0…1 标度，正 = 变大）。
    case volume(step: Double)
}

/// 查表：动作档位 + 自定义快捷键 → 要投出去的效应（nil = 这一格没配，不拦事件）。
public enum WheelGesturePlan {

    /// ⌘⇧ 的修饰位（`maskShift` 131072 | `maskCommand` 1048576）。
    public static let commandShiftFlags: UInt = 0x10_0000 | 0x2_0000

    /// ANSI 虚拟键码：`[`(33) / `]`(30)。Safari、Chrome、Terminal、多数编辑器
    /// 的「上一个/下一个标签页」都绑这一对，是系统里最通用的两条。
    public static let bracketLeftKeyCode: UInt16 = 33
    public static let bracketRightKeyCode: UInt16 = 30

    /// 一格滚轮 = 音量 5%（0…1 标度）。一格到五格之间还有 4.76 秒的间隔上限，
    /// 快速滚到头也只要十几格，与键盘多媒体键的档位粗细相当。
    public static let volumeStep: Double = 0.05

    /// 自定义快捷键的解析入口（偏好存的是 "keyCode=X, flags=Y"）。
    ///
    /// 键值串在 Storage 那层，解析函数在 EventCapture 那层（`ShortcutMonitor` 是它俩
    /// 之间唯一的口径），本层够不到 —— 所以由 App 层解析完把 `(keyCode, flags)` 递进来。
    /// 递进来的就是「没解析出来」（空串 / 已清除）→ nil，这一格当没配。
    public static func effect(kind: WheelGestureActionKind,
                              customShortcut: (keyCode: UInt16, flags: UInt)?) -> WheelGestureEffect? {
        switch kind {
        case .none:
            return nil
        case .tabPrevious:
            return .shortcut(keyCode: bracketLeftKeyCode, flags: commandShiftFlags)
        case .tabNext:
            return .shortcut(keyCode: bracketRightKeyCode, flags: commandShiftFlags)
        case .volumeUp:
            return .volume(step: volumeStep)
        case .volumeDown:
            return .volume(step: -volumeStep)
        case .customShortcut:
            guard let customShortcut else { return nil }
            return .shortcut(keyCode: customShortcut.keyCode, flags: customShortcut.flags)
        }
    }

    /// 下拉里给自定义档位用的显示名（偏好页与日志共用一份，免得两处对不上）。
    public static func displayName(_ kind: WheelGestureActionKind) -> String {
        switch kind {
        case .none: return "无"
        case .tabPrevious: return "上一个标签页"
        case .tabNext: return "下一个标签页"
        case .volumeUp: return "音量 +1 档"
        case .volumeDown: return "音量 −1 档"
        case .customShortcut: return "自定义快捷键"
        }
    }
}

/// 把 `WheelGestureEffect` 投出去。
///
/// 两条出口都留了接缝：单测换掉它们就能数出「前台应用到底收到了什么 / 音量到底动没动」，
/// 不必真去切标签页或改本机音量。返回值即「这件事做成了没有」—— false 时调用方**不许吞**
/// 滚轮事件（页面照常滚），比假装成功更难被误解。
public final class WheelGestureExecutor {

    /// 快捷键出口。默认交给 `ActionExecutor` 的 `.shortcut` 分支（session 层投键，
    /// 与规则动作同一条路：绕过我们自己的 HID tap，不会自环）。
    public var shortcutPoster: ((UInt16, UInt) -> Void)?

    /// 音量出口。默认 `SystemVolume.step(by:)`；返回是否真的动了。
    public var volumeStepper: ((Double) -> Bool)?

    private let actionExecutor: ActionExecutor

    public init(actionExecutor: ActionExecutor = ActionExecutor()) {
        self.actionExecutor = actionExecutor
    }

    @discardableResult
    public func execute(_ effect: WheelGestureEffect) -> Bool {
        switch effect {
        case .shortcut(let keyCode, let flags):
            if let shortcutPoster {
                shortcutPoster(keyCode, flags)
            } else {
                actionExecutor.execute(.shortcut(keyCode: keyCode, flags: flags))
            }
            // 投键是 fire-and-forget，CG 不给回执；能走到这里就算做成。
            return true
        case .volume(let step):
            if let volumeStepper { return volumeStepper(step) }
            return SystemVolume.step(by: step)
        }
    }

    /// 一步到位：查表 + 执行。调用方（App 层）只想知道「这一格该不该吞」。
    @discardableResult
    public func fire(kind: WheelGestureActionKind,
                     customShortcut: (keyCode: UInt16, flags: UInt)?) -> Bool {
        guard let effect = WheelGesturePlan.effect(kind: kind, customShortcut: customShortcut) else {
            return false
        }
        let done = execute(effect)
        NSLog("%@", "[WheelGesture] \(WheelGesturePlan.displayName(kind)) → "
            + "\(effect.describe) 已执行 \(done)")
        return done
    }
}

extension WheelGestureEffect {
    /// 日志用的一行读法：⌘⇧[ 这种带修饰位的写成符号，音量写成增减百分比。
    public var describe: String {
        switch self {
        case .shortcut(let keyCode, let flags):
            return "keyCode=\(keyCode) flags=\(flags) \(WheelGestureEffect.symbol(for: flags))"
        case .volume(let step):
            return String(format: "音量 %+.0f%%", step * 100)
        }
    }

    /// 修饰位的可读形式（只认那四个标准位，顺序固定 ⌃⌥⇧⌘）。
    static func symbol(for flags: UInt) -> String {
        var text = ""
        if flags & 0x40000 != 0 { text += "⌃" }
        if flags & 0x80000 != 0 { text += "⌥" }
        if flags & 0x20000 != 0 { text += "⇧" }
        if flags & 0x100000 != 0 { text += "⌘" }
        return text.isEmpty ? "" : "(\(text))"
    }
}
