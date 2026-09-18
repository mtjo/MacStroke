//
//  Toast.swift
//  MacStroke
//
//  Toast notification display for gesture recognition feedback.
//

import Foundation
import AppKit
import Preferences

/// A toast notification shown briefly on screen.
public struct Toast {
    public let message: String
    public let duration: TimeInterval
    public let position: ToastPosition

    public init(message: String, duration: TimeInterval = 2.0, position: ToastPosition = .bottom) {
        self.message = message
        self.duration = duration
        self.position = position
    }
}

/// Position for toast notifications.
public enum ToastPosition: Int {
    case top = 0
    case center = 1
    case bottom = 2
    case topRight = 3
    case bottomRight = 4
    case topLeft = 5
    case bottomLeft = 6
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

        // Read preferences for display
        let fontSize = CGFloat(preferences.noteFontSize)
        let bgAlpha = preferences.noteBackgroundAlpha
        let fontName = preferences.noteFontName
        let retention = preferences.noteRetentionTime
        let positionIndex = preferences.notePosition

        // Create window for toast
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
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
        label.frame = NSRect(x: 16, y: 16, width: 248, height: 28)
        contentView.addSubview(label)

        window.contentView = contentView

        // Position window
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        let x: CGFloat
        let y: CGFloat
        let toastPosition = ToastPosition(rawValue: positionIndex) ?? ToastPosition.bottom

        switch toastPosition {
        case .top:
            x = (frame.width - 280) / 2
            y = frame.height - 80
        case .bottom:
            x = (frame.width - 280) / 2
            y = 40
        case .center:
            x = (frame.width - 280) / 2
            y = (frame.height - 60) / 2
        case .topRight:
            x = frame.width - 280 - 16
            y = frame.height - 80
        case .bottomRight:
            x = frame.width - 280 - 16
            y = 40
        case .topLeft:
            x = 16
            y = frame.height - 80
        case .bottomLeft:
            x = 16
            y = 40
        }

        window.setFrameOrigin(NSPoint(x: x, y: y))
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