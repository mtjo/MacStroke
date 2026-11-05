//
//  InstantGesture.swift
//  GestureEngine
//
//  issue #78 第 2 条：一条规则除了「画出来的轨迹」，还可以绑一个不用画的瞬时手势
//  —— 按住起始键 + 滚轮上滚 / 下滚，或者不按起始键直接按中键 / 侧键，一次算一次。
//
//  放在 GestureEngine 这层（谁都不依赖）而不是 RuleEngine 或 EventCapture：捕获层要
//  按滚轮方向 / 按键编号点名它，规则层要把它存进 rules.json 并拿去匹配。放上面任何
//  一层都会让下面那层反过来依赖上面那层，这两层之间本没有边。
//
//  五档分两类：
//  - 滚轮两档（`wheelUp` / `wheelDown`）只在按住起手键的那段窗口里算，事件来自第二条
//    滚轮 tap；
//  - 按键三档（`middleClick` / `backClick` / `forwardClick`）是独立的一击，事件来自主
//    tap 的 `otherMouse*`。**起手键优先**：同一颗键被设成起手键时，按下去是画手势，
//    不会再当瞬时手势（捕获层先判起手键）。
//
//  Shift 水平滚不在这里：那是滚轮方向的问题，不是「另一颗键」。
//

import Foundation

/// 一个不画轨迹的手势：按住起始键的一次滚轮，或一次中键 / 侧键点击。
public enum InstantGesture: String, Codable, CaseIterable, Equatable, Sendable {
    case wheelUp
    case wheelDown
    case middleClick
    case backClick
    case forwardClick

    /// 规则页与日志用的读法（本地化文案在偏好层按 key 取，这里只给兜底英文）。
    public var displayName: String {
        switch self {
        case .wheelUp: return "Wheel Up"
        case .wheelDown: return "Wheel Down"
        case .middleClick: return "Middle Button"
        case .backClick: return "Back Button"
        case .forwardClick: return "Forward Button"
        }
    }

    /// 按键档对应的 CoreGraphics 按键编号；滚轮两档没有按键编号（nil）。
    public var mouseButtonNumber: Int? {
        switch self {
        case .wheelUp, .wheelDown: return nil
        case .middleClick: return 2
        case .backClick: return 3
        case .forwardClick: return 4
        }
    }

    /// 是不是滚轮档。滚轮要走第二条 tap 上膛，按键档走主 tap，接线不同。
    public var isWheel: Bool { mouseButtonNumber == nil }

    /// 按键编号 → 瞬时手势。起手键之外的其他按键一律返回 nil（比如按键 5 的侧键）。
    public init?(mouseButtonNumber number: Int) {
        switch number {
        case 2: self = .middleClick
        case 3: self = .backClick
        case 4: self = .forwardClick
        default: return nil
        }
    }
}
