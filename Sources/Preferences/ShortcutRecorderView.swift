//
//  ShortcutRecorderView.swift
//  MacStroke
//
//  A view for recording keyboard shortcuts, similar to SRRecorderControl.
//

import Foundation
import AppKit

/// A view that records a keyboard shortcut (key code + modifier flags).
public final class ShortcutRecorderView: NSView {

    /// The currently recorded key code (0 if none).
    public var keyCode: UInt16 = 0 {
        didSet { needsDisplay = true }
    }

    /// The currently recorded modifier flags (0 if none).
    public var flags: UInt = 0 {
        didSet { needsDisplay = true }
    }

    /// Whether the recorder is currently listening for input.
    @Published public var isRecording = false {
        didSet { needsDisplay = true }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitoring = false

    /// Callback when shortcut recording completes.
    var onShortcutChanged: ((UInt16, UInt) -> Void)?

    public override var isFlipped: Bool { true }

    // MARK: - Initialization

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let text: String
        if keyCode == 0 && flags == 0 {
            text = isRecording ? "Recording..." : "Click to Record"
        } else {
            text = String(format: "keyCode=%d, flags=%d", keyCode, flags)
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]

        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        attributed.draw(in: textRect)
    }

    // MARK: - Mouse Handling

    public override func mouseDown(with event: NSEvent) {
        startRecording()
    }

    public override func mouseUp(with event: NSEvent) {
        stopRecording()
    }

    // MARK: - Public API

    /// Starts listening for keyboard input.
    public func startRecording() {
        guard !monitoring else { return }
        isRecording = true

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let selfPtr = Unmanaged<ShortcutRecorderView>.fromOpaque(refcon).takeUnretainedValue()
            return selfPtr.handleKeyEvent(type: type, event: event)
        }

        // Create event tap for key down events only
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            print("[ShortcutRecorder] Failed to create event tap")
            isRecording = false
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        monitoring = true
    }

    /// Stops listening for keyboard input.
    public func stopRecording() {
        guard monitoring else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        monitoring = false
        isRecording = false
        onShortcutChanged?(keyCode, flags)
    }

    private func handleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // Extract key code and flags
        let keyCodeValue = event.getIntegerValueField(.keyboardEventKeycode)
        let flagsValue = event.flags.rawValue

        self.keyCode = UInt16(keyCodeValue)
        self.flags = UInt(flagsValue)

        // Update the view to show the recorded shortcut
        DispatchQueue.main.async { [weak self] in
            self?.needsDisplay = true
            self?.stopRecording()
        }

        // Allow the event to propagate normally
        return Unmanaged.passRetained(event)
    }
}