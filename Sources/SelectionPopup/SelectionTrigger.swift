//
//  SelectionTrigger.swift
//  MacStroke
//
//  「这一次松手算不算划词」和「读回来的这段文字该不该弹」两个判定。纯函数：不碰事件、
//  不碰窗口、不碰无障碍，全部输入输出都是值 —— 所以 `swift test` 里能逐条咬住。
//
//  判定放在这里而不是控制器里，是因为这两处的边界最容易写反：位移下限记反了就是
//  「单击也弹」，读取结果忘了分空与非空就是「什么都往屏幕上抛一条空气泡」。
//

import AppKit
import CoreGraphics

/// 一次左键动作的采样，由控制器从只读全局监听里攒出来。
struct DragSample: Equatable {
    /// 按下时的全局坐标（AppKit 那套左下角原点）。
    var start: CGPoint
    /// 松手时的全局坐标。
    var end: CGPoint
    /// 中间收到过几笔拖动。0 就是「按下→松开」，一次单击。
    var dragEvents: Int

    var travel: CGFloat { hypot(end.x - start.x, end.y - start.y) }
    var dragged: Bool { dragEvents > 0 }
}

/// 判定结果：要么「armed」——松手位置记下来，等一会儿去读选区；要么明确说明为什么不算划词。
enum SelectionTrigger {
    enum Skip: String, Equatable {
        /// 一次按下加松开，中间没有拖动。
        case singleClick
        /// 拖了，但没拖出最小位移（在一段文字上抖动、双击选词都在这一档）。
        case tooShort
        /// 松手时按着 ⌥/⇧/⌘ —— 这三个键下的拖动另有含义（列选、扩展选区、多选），
        /// 弹一条气泡是抢戏。⌃ 不在里面：这些控件里 ⌃ 拖动没有第二含义，拦它只会少弹。
        case modifierHeld
    }

    enum Outcome: Equatable {
        /// 到 `anchor` 这个位置去读选区（松手点，屏幕坐标）。
        case arm(anchor: CGPoint)
        case skip(Skip)
    }

    /// `blockedModifiers` 默认那三个键；单独传出来是给反向变异留口子，也免得判定里出现
    /// 一个「测试改不动」的常量。
    static func decide(drag: DragSample,
                       modifiers: NSEvent.ModifierFlags,
                       minimumTravel: CGFloat = SelectionBubbleSettings.minimumTravel,
                       blockedModifiers: NSEvent.ModifierFlags = [.option, .shift, .command]) -> Outcome {
        guard drag.dragged else { return .skip(.singleClick) }
        guard drag.travel >= minimumTravel else { return .skip(.tooShort) }
        guard modifiers.isDisjoint(with: blockedModifiers) else { return .skip(.modifierHeld) }
        return .arm(anchor: drag.end)
    }

    // MARK: - 读回来的那段文字

    enum ReadSkip: Equatable {
        /// 接口答上了但没选中任何东西（或者落在密码框里）。
        case nothingSelected
        /// 读不到，带无障碍那边的原因，只为日志。
        case readFailed(SelectedTextResult.Unavailable)
        /// 太长了：全选整篇文档时弹气泡只会挡字。
        case tooLong(characterCount: Int)
    }

    enum ReadOutcome: Equatable {
        case show(String)
        case skip(ReadSkip)
    }

    /// 空白也算「没选中」：拖过一段全是空格换行的区域，弹出来四格里没有一格有活干。
    static func decide(text: SelectedTextResult,
                       maximumCharacters: Int = SelectionBubbleSettings.maximumCharacters) -> ReadOutcome {
        switch text {
        case .nothingSelected:
            return .skip(.nothingSelected)
        case .unavailable(let reason):
            return .skip(.readFailed(reason))
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .skip(.nothingSelected) }
            guard trimmed.count <= maximumCharacters else { return .skip(.tooLong(characterCount: trimmed.count)) }
            // 弹出去的是裁过首尾空白的原样：复制那段留白没有意义，朗读读到一串换行更怪。
            return .show(trimmed)
        }
    }
}
