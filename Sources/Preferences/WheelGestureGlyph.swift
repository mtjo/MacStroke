//
//  WheelGestureGlyph.swift
//  MacStroke
//
//  「不用画的手势」那一档的图标（issue #78 第 2 条）。
//
//  规则页的手势格与「绘制手势」面板底部那一栏共用这一份画法：两处各画一遍，迟早
//  画成两个样子（预设轨迹的图标也是同一条规矩，见 GestureStrokeRenderer）。
//
//  五档的图形语言：一枚鼠标胶囊，里面是方向的记号 ——
//  - 上滚 / 下滚：竖直箭头；
//  - 中键：中央一枚实心药丸（按下去的是滚轮本身）；
//  - 后退 / 前进：水平箭头。
//  墨色跟随系统外观（labelColor），浅色/深色两档都不用另画一套。
//

import AppKit
import GestureEngine

enum WheelGestureGlyph {
    /// 竖直箭头两端离胶囊边的距离；水平箭头只留一点，因为胶囊本来就很窄。
    private static let verticalInset: CGFloat = 6
    private static let horizontalInset: CGFloat = 2.5

    /// 在 `rect` 里画这一档手势。
    static func draw(_ gesture: InstantGesture, in rect: NSRect) {
        let capsule = capsuleRect(in: rect)
        let body = NSBezierPath(roundedRect: capsule,
                                xRadius: capsule.width / 2,
                                yRadius: capsule.width / 2)
        body.lineWidth = 1.2
        NSColor.labelColor.withAlphaComponent(0.75).setStroke()
        body.stroke()

        switch gesture {
        case .wheelUp, .wheelDown:
            drawVerticalArrow(up: gesture == .wheelUp, in: capsule)
        case .middleClick:
            drawMiddleClick(in: capsule)
        case .backClick, .forwardClick:
            drawHorizontalArrow(left: gesture == .backClick, in: capsule)
        }
    }

    private static func drawVerticalArrow(up: Bool, in capsule: NSRect) {
        let shaftTop = capsule.maxY - verticalInset
        let shaftBottom = capsule.minY + verticalInset
        // AppKit 的坐标原点在设计左下角：y 越大越靠上，所以「上滚」的箭尖在 shaftTop。
        let tipY = up ? shaftTop : shaftBottom
        let tailY = up ? shaftBottom : shaftTop
        let midX = capsule.midX

        let shaft = NSBezierPath()
        shaft.lineWidth = 1.8
        shaft.lineCapStyle = .round
        shaft.move(to: NSPoint(x: midX, y: tailY))
        shaft.line(to: NSPoint(x: midX, y: tipY))
        NSColor.labelColor.setStroke()
        shaft.stroke()

        let wings: CGFloat = up ? -4 : 4
        let head = NSBezierPath()
        head.lineWidth = 1.8
        head.lineJoinStyle = .round
        head.move(to: NSPoint(x: midX - 4, y: tipY + wings))
        head.line(to: NSPoint(x: midX, y: tipY))
        head.line(to: NSPoint(x: midX + 4, y: tipY + wings))
        head.stroke()
    }

    private static func drawHorizontalArrow(left: Bool, in capsule: NSRect) {
        let tipX = left ? capsule.minX + horizontalInset : capsule.maxX - horizontalInset
        let tailX = left ? capsule.maxX - horizontalInset : capsule.minX + horizontalInset
        let midY = capsule.midY

        let shaft = NSBezierPath()
        shaft.lineWidth = 1.8
        shaft.lineCapStyle = .round
        shaft.move(to: NSPoint(x: tailX, y: midY))
        shaft.line(to: NSPoint(x: tipX, y: midY))
        NSColor.labelColor.setStroke()
        shaft.stroke()

        let wings: CGFloat = left ? 4 : -4
        let head = NSBezierPath()
        head.lineWidth = 1.8
        head.lineJoinStyle = .round
        head.move(to: NSPoint(x: tipX + wings, y: midY - 4))
        head.line(to: NSPoint(x: tipX, y: midY))
        head.line(to: NSPoint(x: tipX + wings, y: midY + 4))
        head.stroke()
    }

    private static func drawMiddleClick(in capsule: NSRect) {
        let width = max(4, capsule.width * 0.42)
        let height = max(8, capsule.height * 0.30)
        let pill = NSRect(x: capsule.midX - width / 2, y: capsule.midY - height / 2,
                          width: width, height: height)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: width / 2, yRadius: width / 2).fill()
    }

    /// 胶囊在 `rect` 里的取位（纯函数：取证用例钉住它居中、且不超出格子）。
    static func capsuleRect(in rect: NSRect) -> NSRect {
        let width = min(max(rect.width * 0.36, 14), 24)
        let height = min(max(rect.height * 0.56, 22), 34)
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                      width: width, height: height)
    }

    /// 滚轮箭尖的 y：上滚在胶囊上半、下滚在下半（用例按这一格判方向没画反）。
    /// 其余三档没有竖直箭头，返回胶囊中线。
    static func arrowTipY(_ gesture: InstantGesture, in rect: NSRect) -> CGFloat {
        let capsule = capsuleRect(in: rect)
        switch gesture {
        case .wheelUp: return capsule.maxY - verticalInset
        case .wheelDown: return capsule.minY + verticalInset
        default: return capsule.midY
        }
    }

    /// 侧键箭尖的 x：后退在胶囊左端、前进攻在右端。滚轮与中键返回 nil。
    static func horizontalArrowTipX(_ gesture: InstantGesture, in rect: NSRect) -> CGFloat? {
        let capsule = capsuleRect(in: rect)
        switch gesture {
        case .backClick: return capsule.minX + horizontalInset
        case .forwardClick: return capsule.maxX - horizontalInset
        default: return nil
        }
    }

    /// 规则页手势格里图标的位置：下半条留给文字读法（纯函数，取证用例钉住它
    /// 不超出格子、也不和文字行重叠）。
    static func cellGlyphRect(in bounds: NSRect) -> NSRect {
        let labelHeight: CGFloat = 16
        return NSRect(x: bounds.midX - 21, y: bounds.minY + labelHeight + 2,
                      width: 42, height: bounds.height - labelHeight - 6)
    }

    /// 规则页手势格里那一行读法的位置（贴着格子底边，整宽居中）。
    static func cellLabelRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX, y: bounds.minY + 2, width: bounds.width, height: 14)
    }
}

extension InstantGesture {
    /// 界面上的读法。轮子两档借用「右键增强」那两行，按键三档借用起手键录制框那三行：
    /// 两处各写一份，改一处忘一处是迟早的事。
    var locKey: String {
        switch self {
        case .wheelUp: return "Wheel Gesture up row"
        case .wheelDown: return "Wheel Gesture down row"
        case .middleClick: return "Middle Button"
        case .backClick: return "Back Button"
        case .forwardClick: return "Forward Button"
        }
    }
}
