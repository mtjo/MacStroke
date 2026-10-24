//
//  WheelGesture.swift
//  MacStroke
//
//  issue #75：「希望分别添加右键+滚轮上滚和滚轮下滚的触发手势，可以用于快速的切换前后
//  标签页，或者调整音量等等」。
//
//  这一手要的是**两个独立触发**，不是两条新轨迹 —— 所以它不进 DTW：按住起始键的那一小段
//  里，滚轮每过一格就是一个明确的触发事件，方向就是它的身份。本文件只管三件事，全是不碰
//  事件循环的纯逻辑，好让取证用例能逐条钉：
//
//  1. 从一发滚轮 `CGEvent` 里读出方向和格数（`WheelGestureReading`）；
//  2. 把「一次拨动」和「几十发惯性滚动事件」分开（`WheelGestureGate`）；
//  3. 方向的符号约定（下面 `lineDelta` 那条注释，本机实测来的）。
//
//  监听本身（第二条 CGEventTap）在 `EventCapture`，开关与触发后的动作在 CanvasManager /
//  App 层 —— 捕获层不该知道「上一个标签页」是什么。
//

import Foundation
import AppKit

/// 滚轮手势的身份：往上还是往下。两条独立触发就是这两个 case，没有第三种。
public enum WheelGestureDirection: String, CaseIterable {
    case up
    case down
}

/// 从一发滚轮事件里读出来的东西。`lines` 带符号（正 = 上滚），`direction` 是它的符号读法。
public struct WheelGestureReading: Equatable {
    public let direction: WheelGestureDirection
    public let lines: Double
    /// 秒（开机起算，见 `timestamp(of:)`）。节流只认它的**差值**，不认绝对值。
    public let timestamp: TimeInterval
    public let modifiers: Set<GestureModifier>

    public init(lines: Double, timestamp: TimeInterval, modifiers: Set<GestureModifier> = []) {
        self.lines = lines
        self.direction = lines >= 0 ? .up : .down
        self.timestamp = timestamp
        self.modifiers = modifiers
    }
}

/// 读一发滚轮事件。抽成独立枚举是为了让用例能直接喂构造好的读数，不必造 CGEvent。
public enum WheelGestureParser {

    /// 一格鼠标滚轮 = 10 点。本机实测（/tmp/wheelprobe/probe.swift，2026-10-25）：
    /// 以 `.pixel` 造一发 `wheel1 = -40` 的事件，CG 自己把它归一成
    /// 「整数行 −4、点增量 −40」，两档正好差 10 倍。
    static let pointsPerNotch: Double = 10

    /// 读出一发滚轮相当于几「格」（带符号，可以带小数）。
    ///
    /// 符号约定（本机取证，2026-10-24）：**正数 = 朝屏幕方向推那一格（上滚）**。
    /// 依据不是文档而是本仓库已有的另一手 —— 长截图注入滚动时，要「向下滚」得把
    /// `wheel1` 取负再投（`ScreenshotScrollCapture.postScroll`：`wheel1: -wheelUnits(points)`，
    /// points 为正表示向下），也就是 CG 的轴 1 增量本身正号是往上。
    ///
    /// 三档退让（都来自上面那次实测，字段量纲不一样，别混）：
    /// 1. `DeltaAxis1` = 整数格，鼠标拨一格就是 ±1，最常用；
    /// 2. `FixedPtDeltaAxis1` = **带小数的格**（`.pixel` 那发 -40 点它给 -4.0，不是 -40），
    ///    触控板的惯性滚动常常只到这一档、第 1 档是 0 —— 只认第 1 档就会把触控板读成「没动」
    ///    （长截图那边记过同一条坑：滚轮单位是点不是设备行）；
    /// 3. `PointDeltaAxis1` = 点，要除以 10 才回到「格」这个量纲。
    ///
    /// 三档都折成「格」，`WheelGestureGate` 那条「够一格才算一次」在鼠标和触控板上才是同一个
    /// 意思；不折的话触控板两指一推几十发瞬间刷满门槛，声音直接拉满 / 连翻八页。
    static func lineDelta(of event: CGEvent) -> Double {
        let lines = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        if lines != 0 { return lines }
        let fractionalLines = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        if fractionalLines != 0 { return fractionalLines }
        return Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) / pointsPerNotch
    }

    /// 时间戳换秒。`CGEvent.timestamp` 是「开机起算的纳秒」，而 `WheelGestureGate` 只看差值，
    /// 所以量纲对上就行。
    ///
    /// 退回 `systemUptime` 是因为这个字段对**注入**的事件可能压根没填（0）。同一个窗口里
    /// 全是 0 的话，第二次起 `差值 < 最小间隔` 恒成立，节流会把后续触发一口吞干净 —— 那种
    /// 症状看起来像「只能切一次」，比读错方向更难查。两者都是开机起算，可以直接混用。
    static func seconds(of event: CGEvent) -> TimeInterval {
        let nanoseconds = event.timestamp
        return nanoseconds > 0
            ? Double(nanoseconds) / 1_000_000_000
            : ProcessInfo.processInfo.systemUptime
    }

    /// 读不出方向（一格都没动）就返回 nil，调用方直接把事件交回前台应用。
    public static func reading(from event: CGEvent) -> WheelGestureReading? {
        let lines = lineDelta(of: event)
        guard lines != 0 else { return nil }
        return WheelGestureReading(lines: lines, timestamp: seconds(of: event),
                                   modifiers: GestureModifier.all(in: event.flags))
    }
}

/// 一次拨动只该触发一次。
///
/// 高分辨率滚轮和触控板的惯性滚动会把「拨一格」拆成几十发小增量事件；照单全收的话，
/// 一次滚轮就是切八页 / 音量拉满。两道闸：累计够一格才算一次，且两次触发之间留最小间隔。
/// 反向先清账 —— 往上滚完立刻往下滚，第一格不该被上一方向的余量吃掉。
public struct WheelGestureGate {
    /// 触发一次所需的格数（1 = 一格鼠标滚轮）。
    public var minimumLines: Double
    /// 两次触发之间的最小间隔（秒）。
    public var minimumInterval: TimeInterval

    private var accumulated: Double = 0
    private var lastFired: TimeInterval?

    public init(minimumLines: Double = 1.0, minimumInterval: TimeInterval = 0.09) {
        self.minimumLines = minimumLines
        self.minimumInterval = minimumInterval
    }

    /// 这一发读数要不要当作一次触发。返回 false 时调用方**不许吞事件**，
    /// 页面照常滚动 —— 门槛没到就当没发生，这是这套判据的底线。
    ///
    /// 顺序是「先记账，再两道闸」，不是「间隔没过就连账都不记」：被间隔挡住的那几发照样
    /// 累计，间隔一过立刻能落下一次。反过来（挡了就丢）会让一次快速拨动的第二档被整批发掉，
    /// 症状是「滚三格只切了两页」，而且丢多少取决于机型的事件密度，在偏好里怎么调都调不准。
    /// `testGateFoldsAFloodIntoSeparateTriggers` 钉的就是这个：30 发 0.1 格、每 10ms 一发
    /// （一整格惯性滚动的量）→ 恰好 3 次，不多不少。
    public mutating func accept(_ reading: WheelGestureReading) -> Bool {
        if accumulated != 0, (accumulated > 0) != (reading.lines > 0) {
            accumulated = 0
        }
        accumulated += reading.lines
        guard abs(accumulated) >= minimumLines else { return false }
        guard let last = lastFired else {
            accumulated = 0
            lastFired = reading.timestamp
            return true
        }
        guard reading.timestamp - last >= minimumInterval else { return false }
        accumulated = 0
        lastFired = reading.timestamp
        return true
    }

    public mutating func reset() {
        accumulated = 0
        lastFired = nil
    }
}
