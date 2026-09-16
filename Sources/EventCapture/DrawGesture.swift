//
//  DrawGesture.swift
//  MacStroke
//
//  A reusable view for displaying and editing gesture templates.
//
//  Mirrors the original DrawGesture.m, which drew scaled-down gesture
//  paths inside the preferences window and allowed double-clicking to
//  assign a preset gesture to a rule.
//
//  Created by mtjo on 2026-09-16.
//

import Foundation
import AppKit
import GestureEngine

// MARK: - DrawGestureDelegate

/// A delegate for DrawGesture to notify when a preset gesture is requested.
public protocol DrawGestureDelegate: AnyObject {
    /// Called when the user double-clicks the view to set a preset gesture.
    /// - Parameters:
    ///   - drawGesture: The DrawGesture view
    ///   - ruleIndex: The index of the rule whose gesture should be preset
    func drawGesture(_ drawGesture: DrawGesture, didRequestPresetGestureForRuleAt ruleIndex: Int)
}

// MARK: - DrawGesture

/// A view that draws a scaled-down gesture template and handles
/// double-click to assign a preset gesture.
public final class DrawGesture: NSView {

    /// Delegate for preset gesture requests.
    public weak var delegate: DrawGestureDelegate?

    /// The index of the rule this view represents.
    public var ruleIndex: Int = 0

    /// The points to draw (in the original gesture coordinate system).
    /// Setting this property scales the points to fit the canvas.
    public var points: [NSPoint] = [] {
        didSet {
            scaledPoints = computeScaledPoints(points)
            needsDisplay = true
        }
    }

    /// The scaled points ready for drawing.
    private var scaledPoints: [NSPoint] = []

    /// Whether to show the "Draw Gesture" button when no points are set.
    public var showsAddButton: Bool = true

    private static let canvasWidth: CGFloat = 60
    private static let canvasHeight: CGFloat = 60

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 0.5).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 0.5).cgColor
    }

    /// Sets the points from an array of GesturePoint values.
    /// - Parameter ruleDataPoints: The points in the original gesture coordinate system.
    public func setPoints(_ ruleDataPoints: [GesturePoint]) {
        points = ruleDataPoints.map { NSPoint(x: $0.x, y: $0.y) }
    }

    /// Sets the points from a Stroke.
    /// - Parameter stroke: The stroke whose points to display.
    public func setPoints(_ stroke: Stroke) {
        points = stroke.points.map { NSPoint(x: $0.x, y: $0.y) }
    }

    private func computeScaledPoints(_ inputPoints: [NSPoint]) -> [NSPoint] {
        guard !inputPoints.isEmpty else { return [] }

        let pcount = inputPoints.count
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        var minX: CGFloat = 0
        var minY: CGFloat = 0

        for i in 0..<pcount {
            let p = inputPoints[i]
            if i == 0 {
                minX = p.x
                minY = p.y
                maxX = p.x
                maxY = p.y
            } else {
                minX = min(minX, p.x)
                minY = min(minY, p.y)
                maxX = max(maxX, p.x)
                maxY = max(maxY, p.y)
            }
        }

        let width = abs(maxX - minX)
        let height = abs(maxY - minY)

        let xZoom = width / DrawGesture.canvasWidth
        let yZoom = height / DrawGesture.canvasHeight
        let zoom = max(xZoom, yZoom)

        let fixX: CGFloat = width < height
            ? (DrawGesture.canvasWidth - (width / zoom)) / 2 + 12
            : 12
        let fixY: CGFloat = width > height
            ? (DrawGesture.canvasHeight - (height / zoom)) / 2 + 12
            : 12

        var result: [NSPoint] = []
        for i in 0..<pcount {
            let p = inputPoints[i]
            let scaledX = (p.x - minX) / zoom + fixX
            let scaledY = (p.y - minY) / zoom + fixY
            result.append(NSPoint(x: scaledX, y: scaledY))
        }
        return result
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if scaledPoints.count > 0 {
            drawGesturePath()
        } else if showsAddButton {
            drawAddButton()
        }
    }

    private func drawGesturePath() {
        let path = NSBezierPath()
        path.lineWidth = 2

        let colorCount = max(scaledPoints.count - 1, 1)
        for i in 0..<scaledPoints.count - 1 {
            let t = CGFloat(i) / CGFloat(colorCount)
            let color = NSColor(
                red: 0.5 * t,
                green: 0.47 + 0.53 * t,
                blue: 0.9,
                alpha: 1.0
            )
            color.setStroke()
            path.removeAllPoints()
            path.move(to: scaledPoints[i])
            path.line(to: scaledPoints[i + 1])
            path.stroke()
        }
    }

    private func drawAddButton() {
        let button = NSButton(frame: NSRect(x: 0, y: 28, width: 80, height: 25))
        button.tag = ruleIndex
        button.bezelStyle = .texturedSquare
        button.target = self
        button.action = #selector(onSetGestureData(_:))
        button.title = localizedString("Draw Gesture")
        button.setAccessibilityElement(true)
        button.setAccessibilityIdentifier("addGestureButton_\(ruleIndex)")
        self.addSubview(button)
    }

    @objc private func onSetGestureData(_ sender: NSButton) {
        delegate?.drawGesture(self, didRequestPresetGestureForRuleAt: sender.tag)
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            delegate?.drawGesture(self, didRequestPresetGestureForRuleAt: ruleIndex)
        }
    }

    /// Clears the gesture points and redraws.
    public func clear() {
        points = []
        scaledPoints = []
        needsDisplay = true
    }
}

// MARK: - Localization helper

private func localizedString(_ key: String) -> String {
    return key
}
