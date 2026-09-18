//
//  CanvasWindow.swift
//  MacStroke
//
//  Gesture drawing overlay window using CGShieldingWindowLevel.
//
//  Created by mtjo on 2026-09-16.
//

import Foundation
import AppKit

// MARK: - CanvasView

/// A view that draws gesture paths as lines between points.
final class CanvasView: NSView {
    // Stores the points of the current gesture being drawn.
    private var points: [CGPoint] = []

    // Color of the gesture path line.
    private var lineColor: NSColor = NSColor(red: 0, green: 0, blue: 1, alpha: 1)
    // Line width (matches original hardcoded radius=2 → lineWidth=4).
    private let lineWidth: CGFloat = 4.0

    /// Initializes the canvas view with default settings from UserDefaults.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        updateColorFromDefaults()
    }

    /// Reads line color from UserDefaults.
    private func updateColorFromDefaults() {
        let hex = UserDefaults.standard.string(forKey: "lineColorHex") ?? "#0000FFFF"
        lineColor = NSColor(hex: hex) ?? NSColor.blue
    }

    /// Adds a point to the gesture path and requests a redraw.
    /// - Parameter point: The point to add (in view coordinates).
    public func addPoint(_ point: CGPoint) {
        points.append(point)
        needsDisplay = true
    }

    /// Clears all points and requests a redraw.
    public func clear() {
        points.removeAll()
        needsDisplay = true
    }

    /// Resizes the canvas to the given frame and requests a redraw.
    /// - Parameter frame: The new frame rectangle.
    public func resize(to frame: NSRect) {
        self.frame = frame
        needsDisplay = true
    }

    /// Draws the gesture path as connected line segments.
    /// If the user has disabled mouse paths in preferences, nothing is drawn.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Do not draw the mouse path if disabled in preferences.
        if UserDefaults.standard.bool(forKey: "disableMousePath") {
            return
        }

        guard points.count >= 2 else { return }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        lineColor.setStroke()

        path.move(to: points[0])
        for i in 1..<points.count {
            path.line(to: points[i])
        }
        path.stroke()
    }
}

// MARK: - CanvasWindow

/// A transparent overlay window for gesture drawing.
///
/// Uses `CGShieldingWindowLevel()` to appear above other non-modal windows
/// while remaining semi-transparent. Click-through behavior is enabled
/// (ignoresMouseEvents = true) because gesture events are captured by
/// EventCapture and forwarded to CanvasView programmatically.
final class CanvasWindow: NSWindow {
    /// The canvas view contained by this window.
    var canvasView: CanvasView {
        contentView as! CanvasView
    }

    /// Creates a CanvasWindow that covers the given screen frame.
    /// - Parameter screenFrame: The frame rectangle of the screen to cover.
    init(screenFrame: NSRect) {
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        contentView = CanvasView()
    }

    /// Shows the canvas window on screen.
    public func show() {
        orderFrontRegardless()
    }

    /// Hides the canvas window.
    public func hide() {
        orderOut(self)
    }

    /// Shows or hides the canvas window based on the enabled state.
    /// - Parameter shouldEnable: true to show, false to hide.
    public func setEnable(_ shouldEnable: Bool) {
        if shouldEnable {
            show()
        } else {
            hide()
        }
    }
}

// MARK: - NSColor extension for hex support

private extension NSColor {
    /// Creates an NSColor from a hex string (e.g. "#RRGGBB" or "#RRGGBBAA").
    /// - Parameter hex: The hex string, optionally prefixed with "#".
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexSanitized.hasPrefix("#") {
            hexSanitized = String(hexSanitized.dropFirst())
        }

        // Pad to 8 characters (ARGB) if needed.
        let length = hexSanitized.unicodeScalars.count
        guard length >= 3 && length <= 8 else { return nil }

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let alpha: CGFloat
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        switch length {
        case 3: // #RGB
            let r = CGFloat((rgb >> 8) & 0xF) / 15.0
            let g = CGFloat((rgb >> 4) & 0xF) / 15.0
            let b = CGFloat(rgb & 0xF) / 15.0
            red = r; green = g; blue = b; alpha = 1.0
        case 4: // #RGBA
            let a = CGFloat((rgb >> 12) & 0xF) / 15.0
            let r = CGFloat((rgb >> 8) & 0xF) / 15.0
            let g = CGFloat((rgb >> 4) & 0xF) / 15.0
            let b = CGFloat(rgb & 0xF) / 15.0
            red = r; green = g; blue = b; alpha = a
        case 6: // #RRGGBB
            red = CGFloat((rgb >> 16) & 0xFF) / 255.0
            green = CGFloat((rgb >> 8) & 0xFF) / 255.0
            blue = CGFloat(rgb & 0xFF) / 255.0
            alpha = 1.0
        case 8: // #RRGGBBAA
            alpha = CGFloat((rgb >> 24) & 0xFF) / 255.0
            red = CGFloat((rgb >> 16) & 0xFF) / 255.0
            green = CGFloat((rgb >> 8) & 0xFF) / 255.0
            blue = CGFloat(rgb & 0xFF) / 255.0
        default:
            return nil
        }

        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}