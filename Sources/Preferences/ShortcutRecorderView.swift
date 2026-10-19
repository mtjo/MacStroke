//
//  ShortcutRecorderView.swift
//  MacStroke
//
//  A view for recording keyboard shortcuts, mirroring the original
//  SRRecorderControl: clicking makes the view first responder and it
//  captures the next key press through keyDown: — no CGEvent tap needed.
//

import Foundation
import AppKit
import Carbon.HIToolbox
import EventCapture
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

    /// Modifiers-only mode: the key itself is irrelevant and the recorded
    /// combination is committed when the user lets go of the last modifier, so
    /// the gesture-suppression row can ask for "⌥⇧" without a letter. The key
    /// code stays 0 and only the five `GestureModifier` bits are kept.
    public var modifiersOnly = false {
        didSet { needsDisplay = true }
    }

    /// Live modifier flags echoed while recording (SRModifierOptionView).
    private var pressedFlags: UInt = 0

    /// Appearance to draw with, decided by whoever hosts this view.
    ///
    /// SwiftUI gives an `NSViewRepresentable` an appearance of its own — measured on
    /// macOS 26/27 it follows the *system* setting instead of the page it is drawn
    /// in, so a recorder on a light preferences page resolved the dark variants of
    /// every dynamic colour and came out black. The SwiftUI wrapper sets this to the
    /// scheme the page really uses; AppKit hosts leave it nil and keep the window's.
    public var drawAppearance: NSAppearance? {
        didSet { needsDisplay = true }
    }

    /// Callback when shortcut recording completes.
    var onShortcutChanged: ((UInt16, UInt) -> Void)?

    /// Callback when the user clears the field with the trailing button (issue #72).
    /// 空值怎么写由宿主决定：偏好页必须写空串，因为 `"keyCode=0, flags=0"` 能被解析成
    /// 一个真实的键（keyCode 0 就是 A），消费端会去挂一只「裸按 A」的全局监听。
    var onClear: (() -> Void)?

    /// 规则页的动作格复用同一个视图，但那里的「空」在模型里是「按下 A」而不是「没有」，
    /// 所以那一格把清除按钮关掉。
    public var showsClearButton = true {
        didSet { needsDisplay = true }
    }

    static let clearButtonDiameter: CGFloat = 14
    static let clearButtonTrailingInset: CGFloat = 6

    /// 框内右端的清除按钮位置。视图是 flipped 的，但按钮水平居中于自身、上下对称，
    /// 所以这套几何在两种坐标方向下读起来一样。
    public static func clearButtonRect(for bounds: NSRect) -> NSRect {
        let d = clearButtonDiameter
        return NSRect(x: (bounds.maxX - clearButtonTrailingInset - d).rounded(),
                      y: (bounds.midY - d / 2).rounded(),
                      width: d, height: d)
    }

    public func clearButtonRect() -> NSRect { Self.clearButtonRect(for: bounds) }

    /// 有没有「录入完成的值」。normal 档 keyCode 0 是键盘上的 A，所以判空必须两个字段一起看。
    public var hasRecordedValue: Bool {
        modifiersOnly ? flags != 0 : keyCode != 0 || flags != 0
    }

    /// 只有录好了才出现；录制中的那一格显示的是提示文字，没有东西可清。
    private var isClearVisible: Bool { showsClearButton && !isRecording && hasRecordedValue }

    /// 清掉当前值并重绘。回调给宿主去持久化。
    public func clear() {
        keyCode = 0
        flags = 0
        needsDisplay = true
        onClear?()
    }

    public override var isFlipped: Bool { true }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Initialization

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Display

    /// Human-readable shortcut like "⌃⇧V" (mirrors ShortcutRecorder's display).
    /// Which mode decides whether the key part exists: a modifiers-only recorder
    /// always keeps keyCode 0, while a normal one records a real key — and 0 is a
    /// key of its own (⌘⇧A), so it has to be named.
    public var displayString: String {
        if modifiersOnly { return Self.modifierSymbols(flags) }
        return Self.modifierSymbols(flags) + Self.keyName(for: keyCode)
    }

    static func modifierSymbols(_ flags: UInt) -> String {
        var symbols = ""
        if flags & 0x100000 != 0 { symbols += "⌘" }   // command
        if flags & 0x80000 != 0 { symbols += "⌥" }    // option
        if flags & 0x40000 != 0 { symbols += "⌃" }    // control
        if flags & 0x20000 != 0 { symbols += "⇧" }    // shift
        if flags & 0x800000 != 0 { symbols += "fn" }  // function
        return symbols
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Resolve every colour against the appearance the host asks for (see
        // `drawAppearance`) rather than the one AppKit happens to have current.
        (drawAppearance ?? window?.effectiveAppearance ?? effectiveAppearance)
            .performAsCurrentDrawingAppearance {
                drawContent()
            }
    }

    private func drawContent() {
        // Painted here instead of via layer.backgroundColor: a CGColor is frozen
        // to whichever appearance was current when it was captured, so a recorder
        // built before the view joined the window came out a black box on macOS 26.
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let box = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        NSColor.controlBackgroundColor.setFill()
        box.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        box.lineWidth = 1
        box.stroke()

        let text: String
        if isRecording {
            text = pressedFlags != 0
                ? Self.modifierSymbols(pressedFlags) + "…"
                : L(modifiersOnly
                    ? "Recording… hold modifiers (Esc to cancel)"
                    : "Recording… press a key (Esc to cancel)")
        } else if !hasRecordedValue {
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
        if !isRecording, hasRecordedValue {
            toolTip = String(format: "keyCode=%d, flags=%d", keyCode, flags)
        } else {
            toolTip = nil
        }

        let clearRect = isClearVisible ? Self.clearButtonRect(for: bounds) : nil
        // 有清除按钮时把文字的可放区域收窄到按钮左边：200 宽的框装 ⌘⌃⇧⌥fn␣ 这种长串
        // 会跟按钮叠上，收窄之后文字仍在剩下的区域里居中。
        let textArea: NSRect
        if let clearRect {
            textArea = NSRect(x: bounds.minX, y: bounds.minY,
                              width: max(0, clearRect.minX - 2 - bounds.minX),
                              height: bounds.height)
        } else {
            textArea = bounds
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let textRect = NSRect(
            x: textArea.minX + (textArea.width - textSize.width) / 2,
            y: textArea.minY + (textArea.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        attributed.draw(in: textRect)

        if let clearRect {
            Self.drawClearButton(in: clearRect)
        }
    }

    // MARK: - Clear button glyph

    /// 画清除图标：浅灰圆底衬 + 一把次级墨色的叉（系统搜索框那一款）。
    /// 颜色全是语义色，所以明暗两档跟随系统外观，跟注解条那条子同一套做法。
    private static func drawClearButton(in rect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let cross = NSBezierPath()
        let arms = rect.insetBy(dx: 4, dy: 4)
        cross.move(to: NSPoint(x: arms.minX, y: arms.minY))
        cross.line(to: NSPoint(x: arms.maxX, y: arms.maxY))
        cross.move(to: NSPoint(x: arms.minX, y: arms.maxY))
        cross.line(to: NSPoint(x: arms.maxX, y: arms.minY))
        NSColor.secondaryLabelColor.setStroke()
        cross.lineWidth = 1.2
        cross.lineCapStyle = .round
        cross.stroke()
    }

    // MARK: - First responder (original SRRecorderControl style)

    public override var acceptsFirstResponder: Bool { true }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil))
    }

    /// 按落点分流：命中右端那一叉就置空，否则照原版那样点一下切换录制。
    /// 视图是 flipped 的，这个点和 `clearButtonRect()` 在同一个坐标空间里。
    public func click(at point: NSPoint) {
        if isClearVisible, clearButtonRect().contains(point) {
            clear()
            return
        }
        window?.makeFirstResponder(self)
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    public override func resignFirstResponder() -> Bool {
        if isRecording { cancelRecording() }
        return super.resignFirstResponder()
    }

    /// ⌘-combos normally go to menu key equivalents; capture them here so
    /// recording works for shortcuts that include Command.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording, event.type == .keyDown {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
            return
        }
        let held = UInt(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        // A key struck while modifiers are down still settles the modifiers-only
        // recorder — the letter is what the user meant to leave out, not extra data.
        if modifiersOnly {
            keyCode = 0
            flags = Self.modeledFlags(held)
            stopRecording()
            return
        }
        keyCode = event.keyCode
        flags = held
        stopRecording()
    }

    public override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        let current = UInt(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        if modifiersOnly {
            let held = Self.modeledFlags(current)
            // Letting go of the last modifier finishes the recording; before that
            // the view just echoes what is being held.
            if pressedFlags != 0 && held == 0 {
                flags = pressedFlags
                keyCode = 0
                stopRecording()
                return
            }
            pressedFlags = held
            needsDisplay = true
            return
        }
        pressedFlags = current
        needsDisplay = true
    }

    /// The modifier bits `GestureModifier` models (⌘⌃⇧⌥fn), dropping caps-lock
    /// and anything else that shares the device-independent mask.
    static func modeledFlags(_ flags: UInt) -> UInt {
        UInt(Set(eventFlags: flags).eventFlags)
    }

    // MARK: - Public API

    /// Starts listening for keyboard input.
    ///
    /// - Parameter currentlyHeld: the modifier bits already held when recording
    ///   starts. Real callers pass nothing and we read the live session flags —
    ///   people habitually press ⌘ *before* clicking the recorder, and that ⌘ is
    ///   part of the shortcut they mean to bind. Tests pass `0`: the session's
    ///   modifier state can be dirtied by unrelated suites that post synthetic
    ///   key events into it (remote control does exactly that), and a recorder
    ///   test that inherits a stuck ⌘ settles a shortcut nobody pressed.
    public func startRecording(currentlyHeld: UInt? = nil) {
        guard !isRecording else { return }
        let current = currentlyHeld
            ?? UInt(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        pressedFlags = modifiersOnly ? Self.modeledFlags(current) : current
        isRecording = true
    }

    /// Stops listening and reports the recorded shortcut.
    public func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        pressedFlags = 0
        onShortcutChanged?(keyCode, flags)
    }

    /// Stop listening without reporting a change (cancel).
    public func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        pressedFlags = 0
        needsDisplay = true
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

        // Letters / digits / punctuation via UCKeyTranslate. CJK input
        // sources (e.g. Pinyin) expose no key-layout data, so fall back to
        // the ASCII-capable layout and finally to a static US table.
        if let char = Self.translateKey(keyCode, source: TISCopyCurrentKeyboardInputSource().takeRetainedValue())
            ?? Self.translateKey(keyCode, source: TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()) {
            return char
        }
        if let name = Self.usKeyNames[Int(keyCode)] {
            return name
        }

        // Fallback to the raw numeric code.
        return String(format: "key(%d)", keyCode)
    }

    /// Translate one key code to its display character using the given
    /// input source's Unicode key layout, or nil when unavailable.
    private static func translateKey(_ keyCode: UInt16, source: TISInputSource) -> String? {
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
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
        guard result == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: chars, count: length)
        guard let first = string.first, !first.isWhitespace else { return nil }
        return first.uppercased()
    }

    /// US-layout names for ordinary keys (last-resort display table).
    private static let usKeyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_S: "S", kVK_ANSI_D: "D", kVK_ANSI_F: "F",
        kVK_ANSI_H: "H", kVK_ANSI_G: "G", kVK_ANSI_Z: "Z", kVK_ANSI_X: "X",
        kVK_ANSI_C: "C", kVK_ANSI_V: "V", kVK_ANSI_B: "B", kVK_ANSI_Q: "Q",
        kVK_ANSI_W: "W", kVK_ANSI_E: "E", kVK_ANSI_R: "R", kVK_ANSI_Y: "Y",
        kVK_ANSI_T: "T", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_ANSI_KeypadMultiply: "*", kVK_ANSI_KeypadPlus: "+",
        kVK_ANSI_KeypadClear: "⌧", kVK_ANSI_KeypadDivide: "/",
        kVK_ANSI_KeypadMinus: "-", kVK_ANSI_KeypadEquals: "=",
    ]
}
