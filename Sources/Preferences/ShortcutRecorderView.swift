//
//  ShortcutRecorderView.swift
//  MacStroke
//
//  A view for recording keyboard shortcuts, similar to SRRecorderControl.
//  Click to start recording; press any key to record it, or Esc to cancel.
//

import Foundation
import AppKit
import Carbon.HIToolbox
import Storage

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

    // MARK: - Display

    /// Standard keyboard modifier bits (shift/control/option/command).
    private static let modifierMask: UInt64 = 0x1E_0000

    /// Human-readable shortcut like "⌃⇧V" (mirrors ShortcutRecorder's display).
    public var displayString: String {
        if keyCode == 0 && flags == 0 { return "" }
        var symbols = ""
        let f = flags
        if f & 0x100000 != 0 { symbols += "⌘" }   // command
        if f & 0x80000 != 0 { symbols += "⌥" }    // option
        if f & 0x40000 != 0 { symbols += "⌃" }    // control
        if f & 0x20000 != 0 { symbols += "⇧" }    // shift
        return symbols + Self.keyName(for: keyCode)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let text: String
        if isRecording {
            text = L("Recording… press a key (Esc to cancel)")
        } else if keyCode == 0 && flags == 0 {
            text = L("Click to Record")
        } else {
            text = displayString
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        if !isRecording, keyCode != 0 || flags != 0 {
            toolTip = String(format: "keyCode=%d, flags=%d", keyCode, flags)
        } else {
            toolTip = nil
        }

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
        // Keep the tap running until a key is pressed or the mouse leaves —
        // stopping on mouseUp would end recording before any key is pressed.
    }

    public override func mouseExited(with event: NSEvent) {
        if isRecording && keyCode == 0 {
            cancelRecording()
        }
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

        // Track when the pointer leaves the view so a stray click doesn't
        // leave the recorder armed forever.
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    /// Stops listening and reports the recorded shortcut.
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
        trackingAreas.forEach(removeTrackingArea)
        onShortcutChanged?(keyCode, flags)
    }

    /// Stop listening without reporting a change (cancel).
    public func cancelRecording() {
        guard monitoring else { return }
        eventTap = nil
        runLoopSource = nil
        monitoring = false
        isRecording = false
        trackingAreas.forEach(removeTrackingArea)
    }

    private func handleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        let keyCodeValue = event.getIntegerValueField(.keyboardEventKeycode)

        // Esc cancels recording and swallows the key.
        if keyCodeValue == UInt64(kVK_Escape) {
            DispatchQueue.main.async { [weak self] in
                self?.cancelRecording()
                self?.needsDisplay = true
            }
            return nil
        }

        // Extract key code and flags
        self.keyCode = UInt16(keyCodeValue)
        self.flags = UInt(event.flags.rawValue)

        // Update the view and finish recording
        DispatchQueue.main.async { [weak self] in
            self?.needsDisplay = true
            self?.stopRecording()
        }

        // Swallow the recorded key so it doesn't trigger other shortcuts.
        return nil
    }

    // MARK: - Key naming

    /// Maps a virtual key code to a display name (letters, digits, arrows,
    /// punctuation and common special keys).
    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "␣"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_Keypad0: return "0"
        case kVK_ANSI_Keypad1: return "1"
        case kVK_ANSI_Keypad2: return "2"
        case kVK_ANSI_Keypad3: return "3"
        case kVK_ANSI_Keypad4: return "4"
        case kVK_ANSI_Keypad5: return "5"
        case kVK_ANSI_Keypad6: return "6"
        case kVK_ANSI_Keypad7: return "7"
        case kVK_ANSI_Keypad8: return "8"
        case kVK_ANSI_Keypad9: return "9"
        default: break
        }

        // Letters / digits / punctuation via UCKeyTranslate on the current layout.
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        if let layoutData = layoutData {
            let layout = unsafeBitCast(layoutData, to: CFData.self) as Data
            let result = layout.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
                let keyboardLayout = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress
                return UCKeyTranslate(
                    keyboardLayout,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    4,
                    &length,
                    &chars
                )
            }
            if result == noErr, length > 0 {
                let string = String(utf16CodeUnits: chars, count: length)
                if let first = string.first, !first.isWhitespace {
                    return first.uppercased()
                }
            }
        }

        // Fallback to the raw numeric code.
        return String(format: "key(%d)", keyCode)
    }
}
