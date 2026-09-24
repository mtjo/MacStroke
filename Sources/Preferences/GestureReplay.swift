//
//  GestureReplay.swift
//  MacStroke
//
//  The preset gestures ship in forward/reverse twins whose static thumbnails are
//  identical shapes — only the pen order tells them apart. Hovering a thumbnail
//  therefore replays the drawing, one thumbnail at a time.
//

import AppKit

/// Renders a scaled polyline with the original per-segment colour ramp
/// (`DrawGesture.m`), truncated to how far the pen has travelled.
enum GestureStrokeRenderer {
    /// The part of `points` drawn at `progress` (1 = the whole stroke). It is a
    /// prefix of `points`, so segment colours keep their original indices.
    static func visiblePolyline(_ points: [CGPoint], progress: CGFloat) -> [CGPoint] {
        guard points.count > 1 else { return points }
        let reached = min(max(progress, 0), 1) * CGFloat(points.count - 1)
        var visible = Array(points.prefix(Int(reached) + 1))
        let index = Int(reached)
        let fraction = reached - CGFloat(index)
        if fraction > 0, index + 1 < points.count {
            visible.append(CGPoint(x: points[index].x + (points[index + 1].x - points[index].x) * fraction,
                                   y: points[index].y + (points[index + 1].y - points[index].y) * fraction))
        }
        return visible
    }

    static func draw(_ scaled: [CGPoint], progress: CGFloat = 1, lineWidth: CGFloat = 2) {
        let visible = visiblePolyline(scaled, progress: progress)
        guard visible.count > 1 else { return }
        let total = Double(scaled.count)
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        for i in 0..<(visible.count - 1) {
            let t = Double(i) / total
            NSColor(red: 0.5 * t, green: 0.47 + 0.53 * t, blue: 0.9, alpha: 1).setStroke()
            path.move(to: visible[i])
            path.line(to: visible[i + 1])
            path.stroke()
            path.removeAllPoints()
        }
        guard progress < 1, let tip = visible.last else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: tip.x - 2.5, y: tip.y - 2.5, width: 5, height: 5)).fill()
    }
}

/// Drives one thumbnail's replay loop while the pointer is over it. The timer holds
/// the view weakly, so an unmounted thumbnail stops on its own.
final class GestureReplayAnimator {
    /// 1 when idle: the thumbnail then renders the finished static stroke.
    private(set) var progress: CGFloat = 1

    private weak var view: NSView?
    private var timer: Timer?
    private var started = 0.0

    private static let drawDuration = 0.7
    private static let cycleDuration = 1.7

    init(view: NSView) {
        self.view = view
    }

    func start() {
        guard timer == nil else { return }
        started = Date.timeIntervalSinceReferenceDate
        advance(Date.timeIntervalSinceReferenceDate)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak view] timer in
            guard let self, view != nil else {
                timer.invalidate()
                return
            }
            self.advance(Date.timeIntervalSinceReferenceDate)
            view?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        view?.needsDisplay = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        progress = 1
        view?.needsDisplay = true
    }

    private func advance(_ now: TimeInterval) {
        let phase = (now - started).truncatingRemainder(dividingBy: Self.cycleDuration)
        progress = CGFloat(min(phase / Self.drawDuration, 1))
    }
}
