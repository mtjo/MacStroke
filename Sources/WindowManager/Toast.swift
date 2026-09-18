//
//  Toast.swift
//  MacStroke
//
//  Toast notification display for gesture recognition feedback.
//  Position mapping matches the original's notePostion values:
//  0 = follow mouse, 1 = screen center, 2 = right top, 3 = right bottom,
//  4 = left top, 5 = left bottom.
//

import Foundation
import AppKit
import Preferences

/// A toast notification shown briefly on screen.
public struct Toast {
    public let message: String
    public let duration: TimeInterval
    public let position: ToastPosition

    public init(message: String, duration: TimeInterval = 2.0, position: ToastPosition = .center) {
        self.message = message
        self.duration = duration
        self.position = position
    }
}

/// Position for toast notifications.
/// Raw values match the original `notePostion` preference.
public enum ToastPosition: Int {
    case mouse = 0
    case center = 1
    case rightTop = 2
    case rightBottom = 3
    case leftTop = 4
    case leftBottom = 5
}

/// Manages toast notifications displayed on screen.
public final class ToastManager {
    public static let shared = ToastManager()

    private var currentToastWindow: NSWindow?
    private var toastTimer: Timer?
    private let preferences: UserPreferences

    private init() {
        self.preferences = UserPreferences()
    }

    /// Show a toast notification.
    /// - Parameter toast: The toast to display
    public func show(_ toast: Toast) {
        // Cancel any existing toast
        toastTimer?.invalidate()

        // Read preferences for display (original: showNoteTost)
        let fontSize = CGFloat(preferences.noteFontSize)
        let bgAlpha = preferences.noteBackgroundAlpha
        let fontName = preferences.noteFontName
        let retention = preferences.noteRetentionTime
        let positionIndex = preferences.notePosition

        let toastSize = CGSize(width: 280, height: 60)

        // Create window for toast
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: toastSize.width, height: toastSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.backgroundColor = .black.withAlphaComponent(bgAlpha)
        window.hasShadow = true
        window.isOpaque = false

        // Create content view
        let contentView = NSView(frame: window.frame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.withAlphaComponent(bgAlpha).cgColor
        contentView.layer?.cornerRadius = 8

        // Add label
        let label = NSTextField(labelWithString: toast.message)
        label.textColor = .white
        label.font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        label.frame = NSRect(x: 16, y: 16, width: toastSize.width - 32, height: 28)
        contentView.addSubview(label)

        window.contentView = contentView

        // Position window — original notePostion mapping.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        let toastPosition = ToastPosition(rawValue: positionIndex) ?? toast.position

        let origin: NSPoint
        switch toastPosition {
        case .mouse:
            // Follow the current mouse location (original: CTPositionMouse).
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(
                x: mouse.x - toastSize.width / 2,
                y: mouse.y - toastSize.height / 2
            )
        case .center:
            origin = NSPoint(
                x: frame.midX - toastSize.width / 2,
                y: frame.midY - toastSize.height / 2
            )
        case .rightTop:
            origin = NSPoint(
                x: frame.maxX - toastSize.width - 16,
                y: frame.maxY - toastSize.height - 16
            )
        case .rightBottom:
            origin = NSPoint(
                x: frame.maxX - toastSize.width - 16,
                y: frame.minY + 16
            )
        case .leftTop:
            origin = NSPoint(
                x: frame.minX + 16,
                y: frame.maxY - toastSize.height - 16
            )
        case .leftBottom:
            origin = NSPoint(
                x: frame.minX + 16,
                y: frame.minY + 16
            )
        }

        window.setFrameOrigin(origin)
        window.orderFrontRegardless()

        currentToastWindow = window

        // Auto-dismiss after duration (use retention time in seconds)
        toastTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(retention), repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    /// Hide the current toast.
    public func hide() {
        currentToastWindow?.close()
        currentToastWindow = nil
        toastTimer?.invalidate()
        toastTimer = nil
    }
}
