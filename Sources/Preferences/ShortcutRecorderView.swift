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
import GestureEngine
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

    /// 这一格此刻用不不用得上（宿主按 `.disabled` 的环境值喂进来）。
    ///
    /// 为什么要在 AppKit 这侧自己做：SwiftUI 的 `.disabled(true)` 只作用于它自己的控件，
    /// 包在 `NSViewRepresentable` 外面的那层修饰符既不会把这块墨字画灰，也不会让 `NSView`
    /// 收不到点击 —— 于是「上滚选了切标签页、快捷键录入框还照样能点」，用户录完一个键，
    /// 那一格其实根本不读它（划词气泡页、issue #75 的滚轮页都是这个形状）。
    /// 本项目的口径是「只灰不藏」，所以这里既改画（次级墨色）也改行为（点不动）。
    /// 叫 `controlEnabled` 而不是 `isEnabled`：`NSView` 没有这个属性，`NSAccessibility`
    /// 那套协议里倒是有同名读写，占掉它会把无障碍状态一起改掉。
    public var controlEnabled = true {
        didSet {
            guard oldValue != controlEnabled else { return }
            // 从「能录」变成「不能录」时如果正在录制，得先退出去：录制态靠的是
            // first responder + keyDown，界面上灰了还在吃键就是「看不见却在生效」。
            // 手填的那个文本框同理 —— 它是这一格里唯一还能打字的东西。
            if !controlEnabled {
                if isRecording { cancelRecording() }
                cancelManualEntry()
                closeKeyboard()
            }
            needsDisplay = true
        }
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
    /// 这一格不可用时连这把叉一起撤掉：叉是「点我就能清空」的抓手，留着点不动就是在骗人
    /// （撤掉不引起重排 —— 它定在框的右端，不占文字流）。
    private var isClearVisible: Bool {
        showsClearButton && !isRecording && !isEditingManually && !isEditingWithKeyboard
            && hasRecordedValue && controlEnabled
    }

    /// 清掉当前值并重绘。回调给宿主去持久化。
    public func clear() {
        keyCode = 0
        flags = 0
        needsDisplay = true
        onClear?()
    }

    // MARK: - 屏幕键盘（双击入口）

    /// 双击时弹着的那块键盘。
    ///
    /// 不再默认进手写：⌘⇧2 这种串要求用户先知道符号怎么写，而多数人只是想把
    /// 眼前那几个键点出来 —— 先点修饰键（可多选、再点取消），再点主键即可。
    /// 手写仍留在面板左下角的「改成手写…」，给键盘表里没有的键（F13 以上、小键盘）。
    public private(set) var isEditingWithKeyboard = false {
        didSet { needsDisplay = true }
    }

    private var keyboardPanel: ShortcutKeyboardView?
    private var keyboardPopover: NSPopover?

    /// 用例读装配结果；界面上没有这条路径。
    var keyboardPanelForTesting: ShortcutKeyboardView? { keyboardPanel }

    /// 双击入口：把键盘面板放进 popover。窗口不是 key 时那一下点击还没完成激活，
    /// 和手写框同一条口径 —— 留给用户再点一次。
    public func presentShortcutKeyboard() {
        guard controlEnabled, !isEditingWithKeyboard else { return }
        guard let window, window.isKeyWindow else { return }
        if isRecording { cancelRecording() }
        if isEditingManually { cancelManualEntry() }
        let panel = makeKeyboardPanel()
        let popover = makeKeyboardPopover(for: panel, in: window)
        keyboardPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        // Esc 要落在这块面板上；popover 有自己的一扇窗口，得冲它要 first responder。
        panel.window?.makeFirstResponder(panel)
    }

    /// 气泡外壳（不显示）：明暗、尺寸与「点外面就收」都挂在这几行上。
    func makeKeyboardPopover(for panel: ShortcutKeyboardView, in window: NSWindow) -> NSPopover {
        let controller = NSViewController()
        controller.view = panel
        let popover = NSPopover()
        popover.behavior = .transient
        // SwiftUI 给的那套 appearance 跟着系统设置，偏好页自己的明暗要靠它带进来
        // （同 `drawAppearance` 那段）。popover 换了外观，里面每颗键帽才跟着对。
        popover.appearance = drawAppearance ?? window.effectiveAppearance
        popover.contentSize = panel.preferredSize
        popover.contentViewController = controller
        popover.delegate = self
        return popover
    }

    /// 面板装配（popover 之外的部分）。用例走这一条验接线，不必真开一扇气泡。
    func makeKeyboardPanel() -> ShortcutKeyboardView {
        if isRecording { cancelRecording() }
        let panel = ShortcutKeyboardView(modifiersOnly: modifiersOnly)
        panel.onCommit = { [weak self] code, flags in
            self?.commitKeyboardShortcut(keyCode: code, flags: flags)
        }
        panel.onCancel = { [weak self] in self?.closeKeyboard() }
        panel.onTypeInstead = { [weak self] in self?.switchToManualEntry() }
        keyboardPanel = panel
        isEditingWithKeyboard = true
        return panel
    }

    /// 键盘选好的一份绑定，和录制、手写走同一条落库路径：改模型 + 恰好一次回调。
    private func commitKeyboardShortcut(keyCode: UInt16, flags: UInt) {
        closeKeyboard()
        manualDraft = nil
        manualFailure = nil
        self.keyCode = keyCode
        self.flags = flags
        onShortcutChanged?(keyCode, flags)
    }

    private func closeKeyboard() {
        guard keyboardPanel != nil || keyboardPopover != nil else { return }
        keyboardPopover?.delegate = nil
        keyboardPopover?.close()
        keyboardPopover = nil
        keyboardPanel = nil
        isEditingWithKeyboard = false
        needsDisplay = true
    }

    /// 收起屏幕键盘（Esc / 点外面 / 宿主禁用这一格）：旧值原样留着，一次回调都不发。
    public func cancelKeyboardEntry() {
        closeKeyboard()
    }

    /// 收起键盘、进原来的文本编辑态。popover 关掉之后主窗口可能还没拿回 key，
    /// 所以第一下没起来时再等一拍重试 —— 用户点的是「改成手写」，不该看见没反应。
    private func switchToManualEntry() {
        closeKeyboard()
        startManualEntry()
        guard !isEditingManually else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isEditingManually else { return }
            self.startManualEntry()
        }
    }

    // MARK: - 手填（issue #78 第 3 条）

    /// 双击进入的文本编辑态。
    ///
    /// 为什么需要：有些组合键根本走不到这只录制框 —— ⌃↑（切桌面）、⌘⇧2（系统截图）
    /// 这类被系统或前台应用先吃掉了，`keyDown` 收不到那一下，框里点破了也录不进。
    /// 手填让人把 "⌘⇧2" / "cmd+shift+2" 直接写出来。
    public private(set) var isEditingManually = false {
        didSet { needsDisplay = true }
    }

    /// 手填框里的初始串：显示串解得回同一个 (keyCode, flags) 就直接用它，解不回的那几处
    /// （小键盘 0–9 显示成主键盘数字、两种回车都显示成 ↩）换成名字写法。
    ///
    /// 不这么办的坏法很隐蔽：双击进去、一个字没改、回车 —— 用户以为什么都没发生，
    /// 实际把小键盘的 5 换成了主键盘的 5（`keypad5` ≠ 19，投出去的键是另一个）。
    private var manualEntrySeed: String {
        let shown = displayString
        let current = ShortcutText.Parsed(keyCode: keyCode, flags: flags)
        if ShortcutText.parse(shown, requiresKey: !modifiersOnly) == current { return shown }
        guard let name = KeyboardKeys.name(for: keyCode) else { return shown }
        return Self.modifierSymbols(flags) + name
    }

    /// 上一次被拒的原文与拒因：红字留在框里、原因进 tooltip。
    ///
    /// 认不出的串绝不写进模型（写进去就是给规则塞一个用户没打算绑的键），但也不能
    /// 静默吃掉 —— 点了回车却什么都没变，最容易被读成「这功能坏了」。
    private var manualDraft: String?
    private var manualFailure: ShortcutText.Failure?
    private var manualField: ManualEntryField?

    /// 编辑到底起来过没有。
    ///
    /// 为什么要单独记：`controlTextDidEndEditing` 可能在你根本没编辑过的时候送到委托里
    /// —— 窗口不是 key 时（从别的 App 双击过来，本视图 `acceptsFirstMouse` 返回 true，
    /// 那一下不会先把窗口变 key）编辑会话起不来。送上来的是预填的旧值、不是用户打的，
    /// 当成提交等于「双击一下就把当前快捷键重新写了一次」。
    /// 入口已经先挡掉非 key 窗口，这一位是第二道保险：字段编辑器真的挂上才允许结束编辑走提交。
    private var manualEditingBegan = false

    /// 双击 = 进手填；单击仍是原版那一下切换录制。
    /// 不可用时和录制一样进不去（`controlEnabled`），不给点不动却已经在吃的抓手。
    public func startManualEntry() {
        guard controlEnabled, !isEditingManually else { return }
        // 窗口不是 key 时那一下点击还没完成激活（本视图 `acceptsFirstMouse` 返回 true，
        // 从别的 App 点过来的头一下不会先把窗口变 key）：留给用户再双击一次，不在这里
        // 挂一个打不了字、收起时还会把预填旧值当成用户提交的框（§10.2）。
        guard window?.isKeyWindow == true else { return }
        if isRecording { cancelRecording() }
        manualDraft = nil
        manualFailure = nil
        manualEditingBegan = false
        let field = ManualEntryField(frame: bounds.insetBy(dx: 6, dy: 2))
        field.font = NSFont.systemFont(ofSize: 12)
        field.alignment = .center
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = L("Type a shortcut, e.g. ⌘⇧2")
        field.delegate = self
        // 空值时不能直接抄 displayString：normal 档 keyCode 0 显示出来是「A」，
        // 那等于替用户预填了一个键。
        field.stringValue = hasRecordedValue ? manualEntrySeed : ""
        field.onCancel = { [weak self] in self?.cancelManualEntry() }
        addSubview(field)
        manualField = field
        isEditingManually = true
        let focused = window?.makeFirstResponder(field) ?? false
        guard focused, let editor = field.currentEditor() else {
            cancelManualEntry()
            return
        }
        // 全选只能经由字段编辑器做：`field.selectText(nil)` 会把刚挂上的会话当场结束掉 ——
        // 真机实测 `controlTextDidEndEditing` 2 ms 后送到委托、而 `controlTextDidBeginEditing`
        // 一次都没来，闸门据此判「编辑没起来」，3.2.4 装机版的双击手填就此整个哑掉。
        manualEditingBegan = true
        editor.selectedRange = NSRange(location: 0, length: (field.stringValue as NSString).length)
    }

    /// 收起手填框。必须**先摘委托再拆视图**：拆掉正持字段编辑器的那个视图会让 AppKit
    /// 再发一次 `controlTextDidEndEditing`，那一次会把预填旧值当成第二次提交
    /// （提交成功的那次会被它用旧值盖回去，被拒的那次会被它清掉红字）。
    private func tearDownManualField() {
        guard let field = manualField else { return }
        field.delegate = nil
        // 编辑起来后 first responder 是那块字段编辑器（NSTextView），不是文本框本身。
        if let editor = field.currentEditor(), window?.firstResponder === editor {
            window?.makeFirstResponder(nil)
        }
        field.removeFromSuperview()
        manualField = nil
        manualEditingBegan = false
        isEditingManually = false
        needsDisplay = true
    }

    /// 放弃手填（Esc / 编程调用）：旧值原样留着，一次回调都不发。
    public func cancelManualEntry() {
        guard isEditingManually else { return }
        tearDownManualField()
    }

    /// 交回内容：认得出才写回并通知宿主，认不出把原文留在框里标红。
    @discardableResult
    func commitManualEntry(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        tearDownManualField()
        guard !text.isEmpty else {
            // 清空文本框不等于「清除快捷键」：那一手是右端那把叉的职责，它写的必须是
            // 空串，而这里落下的是「什么都没改」。
            return false
        }
        switch ShortcutText.evaluate(text, requiresKey: !modifiersOnly) {
        case .success(let parsed):
            manualDraft = nil
            manualFailure = nil
            keyCode = parsed.keyCode
            flags = parsed.flags
            onShortcutChanged?(parsed.keyCode, parsed.flags)
            return true
        case .failure(let failure):
            manualDraft = text
            manualFailure = failure
            return false
        }
    }

    /// 拒因写成一句人话（tooltip 用）。
    static func failureMessage(_ failure: ShortcutText.Failure) -> String {
        switch failure {
        case .empty:
            return L("Type a shortcut first")
        case .unknownToken(let token):
            return String(format: L("Can’t read “%@” as a key"), token)
        case .missingKey:
            return L("Add a key, not only modifiers")
        case .moreThanOneKey(let token):
            return String(format: L("Two keys in one shortcut: %@"), token)
        }
    }

    /// 框里那行字的墨色：被拒的原文用红，禁用态用系统的禁用色，其余用正文色。
    private func textColor(isRejection: Bool) -> NSColor {
        if isRejection, controlEnabled { return .systemRed }
        return controlEnabled ? .labelColor : .disabledControlTextColor
    }

    /// 框子闲时给的一句提示（单击录制 / 双击键盘）。
    static var manualHint: String { L("Click to record · double-click for keyboard") }

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

    /// 框里现在画的那串字。录制中的完整提示在上方气泡里（见 `presentRecordingHint`），
    /// 框内只留短句。用例直接断言这一串，不必离屏去数像素。
    var displayedText: String {
        if isEditingManually {
            // 文本字段自己铺在框里，这里再画一层会和它对不齐。
            return ""
        }
        if let draft = manualDraft { return draft }
        if isRecording {
            // 框里只放短句：完整提示漫出小格会盖住旁边的列（装机实测），挪到上方气泡里。
            // 按住修饰键时给即时回显 —— 那串符号短，放得下，也是原版 SRRecorderControl 的行为。
            return pressedFlags != 0
                ? Self.modifierSymbols(pressedFlags) + "…"
                : L("Recording…")
        }
        if !hasRecordedValue { return L("Click to Record") }
        return displayString
    }

    private func drawContent() {
        // Painted here instead of via layer.backgroundColor: a CGColor is frozen
        // to whichever appearance was current when it was captured, so a recorder
        // built before the view joined the window came out a black box on macOS 26.
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let box = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        NSColor.controlBackgroundColor.setFill()
        box.fill()
        // 被拒的那串还挂在框上时描红：文字已经缩回旧值，只剩框色说得出「你刚才填的没收」。
        let stroke: NSColor
        if manualDraft != nil && !isEditingManually {
            stroke = .systemRed
        } else {
            stroke = isRecording || isEditingManually || isEditingWithKeyboard
                ? .controlAccentColor : .separatorColor
        }
        stroke.setStroke()
        box.lineWidth = 1
        box.stroke()

        let text = displayedText
        let isRejection = manualDraft != nil && !isEditingManually

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            // 灰的时候用系统那一份「禁用控件墨色」，不自己调 alpha：明暗两档各是多少
            // 由系统定，用户看到的「这格不能点」才和别的页一致。
            .foregroundColor: textColor(isRejection: isRejection),
            .paragraphStyle: paragraphStyle
        ]
        if let manualFailure {
            toolTip = Self.failureMessage(manualFailure) + "\n" + Self.manualHint
        } else if !isRecording, hasRecordedValue {
            toolTip = String(format: "keyCode=%d, flags=%d", keyCode, flags) + "\n" + Self.manualHint
        } else {
            toolTip = Self.manualHint
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

    /// 不可用时连 first responder 都不接：录制靠的是「成为焦点 + 吃 keyDown」，
    /// 光挡鼠标点击的话 Tab 键还能把焦点挪进来，那一格灰着却把你的下一个键吞掉。
    public override var acceptsFirstResponder: Bool {
        controlEnabled && !isEditingManually && !isEditingWithKeyboard
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    /// 按落点分流：命中右端那一叉就置空，双击弹屏幕键盘，否则照原版那样点一下切换录制。
    /// 视图是 flipped 的，这个点和 `clearButtonRect()` 在同一个坐标空间里。
    public func click(at point: NSPoint, clickCount: Int = 1) {
        guard controlEnabled else { return }
        // 编辑态 / 键盘态里那一下归面板自己（选词、挪光标、点键），这里不去切录制。
        if isEditingManually || isEditingWithKeyboard { return }
        if isClearVisible, clearButtonRect().contains(point) {
            clear()
            return
        }
        if clickCount >= 2 {
            presentShortcutKeyboard()
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
        guard !isRecording, controlEnabled else { return }
        // 重新去录制 = 上一次那串被拒的作废，红字提示不该还挂在框上。
        manualDraft = nil
        manualFailure = nil
        let current = currentlyHeld
            ?? UInt(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        pressedFlags = modifiersOnly ? Self.modeledFlags(current) : current
        isRecording = true
        presentRecordingHint()
    }

    /// Stops listening and reports the recorded shortcut.
    public func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        pressedFlags = 0
        dismissRecordingHint()
        onShortcutChanged?(keyCode, flags)
    }

    /// Stop listening without reporting a change (cancel).
    public func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        pressedFlags = 0
        dismissRecordingHint()
        needsDisplay = true
    }

    // MARK: - 录制提示气泡

    /// 录制中挂在框上方的那句完整提示。框里只留得下「录制中…」，长句塞回小格
    /// 会重新漫出去盖住旁边的列（装机实测）—— 气泡不受表格单元格宽度限制。
    private var recordingHintPopover: NSPopover?

    /// 用例读装配结果；界面上没有这条路径。
    var recordingHintPopoverForTesting: NSPopover? { recordingHintPopover }

    private var recordingHintText: String {
        // 「双击打开键盘」必须写进气泡：双击是屏幕键盘的唯一入口，悬停 tooltip 没人看得到。
        L(modifiersOnly
            ? "Hold modifiers (double-click for keyboard, Esc to cancel)"
            : "Press a key (double-click for keyboard, Esc to cancel)")
    }

    /// 气泡外壳（不显示）：与屏幕键盘同一套口径 —— 明暗跟偏好页、尺寸贴着文案。
    /// 行为是 applicationDefined：点外面不收，气泡的生死只跟录制态走，
    /// 不然点一下旁边列，提示没了、录制还开着，框里剩一句看不懂的「录制中…」。
    func makeRecordingHintPopover(in window: NSWindow) -> NSPopover {
        let label = NSTextField(labelWithString: recordingHintText)
        label.font = NSFont.systemFont(ofSize: 12)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let container = NSView(frame: .zero)
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7)
        ])
        container.frame = NSRect(origin: .zero, size: container.fittingSize)
        let controller = NSViewController()
        controller.view = container
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.appearance = drawAppearance ?? window.effectiveAppearance
        popover.contentSize = container.frame.size
        popover.contentViewController = controller
        popover.delegate = self
        return popover
    }

    private func presentRecordingHint() {
        guard recordingHintPopover == nil, let window, window.isKeyWindow else { return }
        let popover = makeRecordingHintPopover(in: window)
        recordingHintPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func dismissRecordingHint() {
        guard recordingHintPopover != nil else { return }
        recordingHintPopover?.delegate = nil
        recordingHintPopover?.close()
        recordingHintPopover = nil
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

extension ShortcutRecorderView: NSPopoverDelegate {
    /// 点面板外面（transient 气泡自己收掉）时把状态清干净：没有提交，也没有半开的 editor。
    public func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if popover === recordingHintPopover {
            // 窗口整个关掉时系统会代劳收气泡；录制态已被一并收掉，这里只清引用。
            recordingHintPopover = nil
            return
        }
        guard popover === keyboardPopover else { return }
        keyboardPopover = nil
        keyboardPanel = nil
        isEditingWithKeyboard = false
        needsDisplay = true
    }
}

/// 手填用的文本框。
///
/// Esc 必须自己接：默认那一下只会响一声、既不交还焦点也不通知宿主，用户按了 Esc
/// 却看见框子还亮着，比录不进去更难解释。
private final class ManualEntryField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

extension ShortcutRecorderView: NSTextFieldDelegate {
    /// 编辑真的起来了（field editor 挂上这只框）才允许后面那次「结束」当提交。
    public func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === manualField else { return }
        manualEditingBegan = true
    }

    /// 回车和「点别处」都走这一手：交回内容 → 解析 → 认得出才写库。
    /// 认不出时框子缩回旧值、原文标红，一次回调都不发。
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === manualField else { return }
        guard manualEditingBegan else {
            // 编辑压根没起来（见 `manualEditingBegan` 那段）：框里的串是预填的旧值，
            // 不是用户打的。这里干净退出 —— 旧值留着、一次回调都不发，用户点第二下就能真编辑。
            cancelManualEntry()
            return
        }
        commitManualEntry(field.stringValue)
    }
}
