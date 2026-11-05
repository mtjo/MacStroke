//
//  ShortcutKeyboardView.swift
//  MacStroke
//
//  双击录制框弹出的屏幕键盘（issue #78 第 3 条的入口改版）。
//
//  为什么不再只靠手写：⌘⇧2 这种串要求用户先知道「⇧ 怎么写、数字 2 是主键盘那格」，
//  而大多数人只是想把眼前那几个键点出来。这里把 Mac 键盘摆出来：先点修饰键
//  （点一下选中、再点一下取消），再点主键，一次点击就落成 (keyCode, flags) ——
//  与录制框、手填走同一条 `onShortcutChanged` 链路。
//
//  摆的是不带小键盘的那块妙控键盘（Apple 随 iMac 出货、也是大多数人桌上那块）：
//  六行主键区 + 右下角方向键；真机上 ↑/↓ 是同一格里叠着的两颗半高键，这里照摆，
//  ←/→ 仍是整高。编辑键区（⌦ ↖ ⇞ ↘ ⇟）与省掉的那几颗不画 —— 本 App 的绑定模型
//  用不到它们，用户真要用就在「改成手写…」里写。
//
//  表里没有的键（F13 以上、小键盘、媒体键）仍留给手写：面板左下角的
//  「改成手写…」收起键盘、进原来的文本编辑态。
//

import AppKit
import Carbon.HIToolbox
import GestureEngine
import Storage

/// 屏幕键盘上的一个键。
///
/// `units` 是键宽（一个标准键 = 1），只影响布局，不影响键码。
struct ShortcutKeyboardKey: Equatable {
    enum Behavior: Equatable {
        case key(keyCode: UInt16)
        /// 修饰键不是「主键」：点它是切换选中，不会立即提交。
        case modifier(flag: UInt)
        /// 真机上有、但本 App 的绑定模型里没有的键（⇪）。只占位，不收点击。
        case inert
    }

    let label: String
    let behavior: Behavior
    let units: CGFloat
    /// 悬停提示与 VoiceOver 读的名字。键盘上那套字形（⌘ ⌦ ⇞）对不熟悉的人不直观，
    /// 所以每个键都带一句人话。
    let name: String
}

/// 键盘布局：纯数据，绘制、命中与用例都从这张表读。
enum ShortcutKeyboardLayout {

    static let keyUnit: CGFloat = 32
    static let keyGap: CGFloat = 4
    static let keyHeight: CGFloat = 30
    static let rowGap: CGFloat = 5

    /// 主键盘每一行的标准宽度（单位数）。
    static let mainRowUnits: CGFloat = 14.5

    /// 一个 `units` 宽的键实际占多少点：每多一个单位就多一个键宽 + 一道缝，
    /// 反过来末端的缝不算在键内。
    static func width(for units: CGFloat) -> CGFloat {
        units * (keyUnit + keyGap) - keyGap
    }

    static var mainWidth: CGFloat { width(for: mainRowUnits) }

    struct Row {
        let keys: [ShortcutKeyboardKey]
        /// 这一行最后一个键贴到右沿（回车键比上面几行短，不贴右沿会停在半空）。
        let alignsLastKeyToTrailingEdge: Bool
        /// 这一行末尾接真机那组方向键：← + ↑/↓ 叠层 + →，占三格。
        let endsWithArrowCluster: Bool

        init(_ keys: [ShortcutKeyboardKey],
             alignsLastKeyToTrailingEdge: Bool = false,
             endsWithArrowCluster: Bool = false) {
            self.keys = keys
            self.alignsLastKeyToTrailingEdge = alignsLastKeyToTrailingEdge
            self.endsWithArrowCluster = endsWithArrowCluster
        }
    }

    // MARK: - 主键盘

    static let functionRow = Row([
        key(kVK_Escape, "⎋", name: "Escape"),
        key(kVK_F1, "F1", name: "F1"), key(kVK_F2, "F2", name: "F2"),
        key(kVK_F3, "F3", name: "F3"), key(kVK_F4, "F4", name: "F4"),
        key(kVK_F5, "F5", name: "F5"), key(kVK_F6, "F6", name: "F6"),
        key(kVK_F7, "F7", name: "F7"), key(kVK_F8, "F8", name: "F8"),
        key(kVK_F9, "F9", name: "F9"), key(kVK_F10, "F10", name: "F10"),
        key(kVK_F11, "F11", name: "F11"), key(kVK_F12, "F12", name: "F12"),
    ])

    static let numberRow = Row([
        key(kVK_ANSI_Grave, "`", name: "Grave"),
        key(kVK_ANSI_1, "1", name: "1"), key(kVK_ANSI_2, "2", name: "2"),
        key(kVK_ANSI_3, "3", name: "3"), key(kVK_ANSI_4, "4", name: "4"),
        key(kVK_ANSI_5, "5", name: "5"), key(kVK_ANSI_6, "6", name: "6"),
        key(kVK_ANSI_7, "7", name: "7"), key(kVK_ANSI_8, "8", name: "8"),
        key(kVK_ANSI_9, "9", name: "9"), key(kVK_ANSI_0, "0", name: "0"),
        key(kVK_ANSI_Minus, "-", name: "Minus"),
        key(kVK_ANSI_Equal, "=", name: "Equals"),
        key(kVK_Delete, "⌫", 1.5, name: "Delete"),
    ])

    static let topLetterRow = Row([
        key(kVK_Tab, "⇥", 1.5, name: "Tab"),
        key(kVK_ANSI_Q, "Q", name: "Q"), key(kVK_ANSI_W, "W", name: "W"),
        key(kVK_ANSI_E, "E", name: "E"), key(kVK_ANSI_R, "R", name: "R"),
        key(kVK_ANSI_T, "T", name: "T"), key(kVK_ANSI_Y, "Y", name: "Y"),
        key(kVK_ANSI_U, "U", name: "U"), key(kVK_ANSI_I, "I", name: "I"),
        key(kVK_ANSI_O, "O", name: "O"), key(kVK_ANSI_P, "P", name: "P"),
        key(kVK_ANSI_LeftBracket, "[", name: "Left bracket"),
        key(kVK_ANSI_RightBracket, "]", name: "Right bracket"),
        key(kVK_ANSI_Backslash, "\\", name: "Backslash"),
    ])

    static let homeLetterRow = Row([
        inert("⇪", 1.5, name: "Caps Lock"),
        key(kVK_ANSI_A, "A", name: "A"), key(kVK_ANSI_S, "S", name: "S"),
        key(kVK_ANSI_D, "D", name: "D"), key(kVK_ANSI_F, "F", name: "F"),
        key(kVK_ANSI_G, "G", name: "G"), key(kVK_ANSI_H, "H", name: "H"),
        key(kVK_ANSI_J, "J", name: "J"), key(kVK_ANSI_K, "K", name: "K"),
        key(kVK_ANSI_L, "L", name: "L"),
        key(kVK_ANSI_Semicolon, ";", name: "Semicolon"),
        key(kVK_ANSI_Quote, "'", name: "Quote"),
        key(kVK_Return, "↩", 2, name: "Return"),
    ], alignsLastKeyToTrailingEdge: true)

    static let bottomLetterRow = Row([
        modifier(ShortcutText.shiftFlag, "⇧", 2.25, name: "Shift"),
        key(kVK_ANSI_Z, "Z", name: "Z"), key(kVK_ANSI_X, "X", name: "X"),
        key(kVK_ANSI_C, "C", name: "C"), key(kVK_ANSI_V, "V", name: "V"),
        key(kVK_ANSI_B, "B", name: "B"), key(kVK_ANSI_N, "N", name: "N"),
        key(kVK_ANSI_M, "M", name: "M"),
        key(kVK_ANSI_Comma, ",", name: "Comma"),
        key(kVK_ANSI_Period, ".", name: "Period"),
        key(kVK_ANSI_Slash, "/", name: "Slash"),
        modifier(ShortcutText.shiftFlag, "⇧", 2.25, name: "Shift"),
    ])

    static let modifierRow = Row([
        modifier(ShortcutText.functionFlag, "fn", 1, name: "Function"),
        modifier(ShortcutText.controlFlag, "⌃", 1.25, name: "Control"),
        modifier(ShortcutText.optionFlag, "⌥", 1.25, name: "Option"),
        modifier(ShortcutText.commandFlag, "⌘", 1.25, name: "Command"),
        key(kVK_Space, "space", 4.25, name: "Space"),
        modifier(ShortcutText.commandFlag, "⌘", 1.25, name: "Command"),
        modifier(ShortcutText.optionFlag, "⌥", 1.25, name: "Option"),
    ], endsWithArrowCluster: true)

    static let mainRows: [Row] = [
        functionRow, numberRow, topLetterRow, homeLetterRow, bottomLetterRow, modifierRow,
    ]

    // MARK: - 方向键

    /// 真机右下角那一组：← 和 → 整高，↑/↓ 叠在同一格的上、下半格。
    static let leftArrow = key(kVK_LeftArrow, "←", name: "Left Arrow")
    static let rightArrow = key(kVK_RightArrow, "→", name: "Right Arrow")
    static let upArrow = key(kVK_UpArrow, "↑", name: "Up Arrow")
    static let downArrow = key(kVK_DownArrow, "↓", name: "Down Arrow")
    static let arrowKeys = [leftArrow, upArrow, downArrow, rightArrow]

    /// 修饰键模式的紧凑面板：只摆五个修饰键，按物理顺序排。
    static let modifiersOnlyKeys: [ShortcutKeyboardKey] = [
        modifier(ShortcutText.functionFlag, "fn", name: "Function"),
        modifier(ShortcutText.controlFlag, "⌃", name: "Control"),
        modifier(ShortcutText.optionFlag, "⌥", name: "Option"),
        modifier(ShortcutText.shiftFlag, "⇧", name: "Shift"),
        modifier(ShortcutText.commandFlag, "⌘", name: "Command"),
    ]

    /// 所有会把 (keyCode, flags) 落进模型的键（不含修饰键切换与占位键）。
    static var shortcutKeys: [ShortcutKeyboardKey] {
        (mainRows.flatMap(\.keys) + arrowKeys).filter {
            if case .key = $0.behavior { return true }
            return false
        }
    }

    // MARK: - 构造

    private static func key(_ code: Int, _ label: String, _ units: CGFloat = 1, name: String) -> ShortcutKeyboardKey {
        ShortcutKeyboardKey(label: label, behavior: .key(keyCode: UInt16(code)),
                            units: units, name: name)
    }

    private static func modifier(_ flag: UInt, _ label: String, _ units: CGFloat = 1,
                                 name: String) -> ShortcutKeyboardKey {
        ShortcutKeyboardKey(label: label, behavior: .modifier(flag: flag),
                            units: units, name: name)
    }

    private static func inert(_ label: String, _ units: CGFloat = 1, name: String) -> ShortcutKeyboardKey {
        ShortcutKeyboardKey(label: label, behavior: .inert, units: units, name: name)
    }
}

/// 一颗自绘的键帽。用 `NSButton` 是为了拿到现成的点击、悬停与无障碍语义；
/// 外观按偏好窗口那套语义色现画（明暗两档都跟系统走）。
final class ShortcutKeyButton: NSButton {

    let behavior: ShortcutKeyboardKey.Behavior
    let keyName: String
    let keyLabel: String
    private let units: CGFloat
    private var isPressed = false

    init(key: ShortcutKeyboardKey) {
        behavior = key.behavior
        keyName = key.name
        keyLabel = key.label
        units = key.units
        super.init(frame: .zero)
        isBordered = false
        switch behavior {
        case .key:
            setButtonType(.momentaryPushIn)
        case .modifier:
            setButtonType(.pushOnPushOff)
        case .inert:
            setButtonType(.momentaryPushIn)
            isEnabled = false
        }
        title = key.label
        toolTip = key.name
        setAccessibilityLabel(key.name)
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isModifierKey: Bool {
        if case .modifier = behavior { return true }
        return false
    }

    var preferredWidth: CGFloat { ShortcutKeyboardLayout.width(for: units) }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let selected = isModifierKey && state == .on
        let isInert = behavior == .inert
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        let fill: NSColor
        if selected {
            fill = .controlAccentColor
        } else if isPressed {
            fill = .quaternaryLabelColor
        } else {
            fill = .controlBackgroundColor
        }
        fill.setFill()
        box.fill()
        (selected ? NSColor.controlAccentColor : .separatorColor).setStroke()
        box.lineWidth = 1
        box.stroke()

        // ↑/↓ 在真机上只有半格高，字号得跟着格高收，不然字会顶出键帽。
        let nominal: CGFloat = isModifierKey ? 13 : 12
        let fontSize = min(nominal, bounds.height - 3)
        let font = NSFont.systemFont(ofSize: fontSize,
                                     weight: isModifierKey ? .medium : .regular)
        let color: NSColor
        if selected {
            color = .alternateSelectedControlTextColor
        } else if isInert {
            color = .tertiaryLabelColor
        } else {
            color = .labelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = NSAttributedString(string: keyLabel, attributes: attributes)
        let size = text.size()
        text.draw(in: NSRect(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2,
                             width: size.width, height: size.height))
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
        super.mouseDown(with: event)
        isPressed = false
        needsDisplay = true
    }
}

/// 屏幕键盘面板。正常模式：点修饰键切换选中，点主键提交；修饰键模式：只收修饰键，
/// 点「完成」提交 `(0, flags)`。
final class ShortcutKeyboardView: NSView {

    let modifiersOnly: Bool

    /// 已经选中的修饰位（只保留建模的那五位）。
    private(set) var selectedFlags: UInt = 0

    /// 选好主键、整份绑定就绪。回调里宿主负责写模型、关面板。
    var onCommit: ((UInt16, UInt) -> Void)?
    /// Esc / 取消。旧值原样留着。
    var onCancel: (() -> Void)?
    /// 表里没有的键：收起键盘，交给原来的手填框。
    var onTypeInstead: (() -> Void)?

    private let padding: CGFloat = 12
    private let headerHeight: CGFloat = 62
    private let footerGap: CGFloat = 12
    private let footerHeight: CGFloat = 30
    private let modifierButtonWidth: CGFloat = 64
    private let modifierButtonGap: CGFloat = 8

    private let readoutLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var modifierButtons: [ShortcutKeyButton] = []
    private var doneButton: NSButton?
    private var cancelButton: NSButton?
    private var typeButton: NSButton?

    init(modifiersOnly: Bool) {
        self.modifiersOnly = modifiersOnly
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Shortcut keyboard"))
        build()
        setFrameSize(preferredSize)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static let modeledMask: UInt =
        ShortcutText.commandFlag | ShortcutText.optionFlag | ShortcutText.controlFlag
        | ShortcutText.shiftFlag | ShortcutText.functionFlag

    /// popover 要的尺寸（内容区，不含气泡边缘）。
    var preferredSize: NSSize {
        if modifiersOnly {
            let rowWidth = 5 * modifierButtonWidth + 4 * modifierButtonGap
            return NSSize(width: padding * 2 + rowWidth,
                          height: headerHeight + ShortcutKeyboardLayout.keyHeight
                              + footerGap + footerHeight + padding)
        }
        let width = padding * 2 + ShortcutKeyboardLayout.mainWidth
        let keyboardHeight = CGFloat(ShortcutKeyboardLayout.mainRows.count)
            * (ShortcutKeyboardLayout.keyHeight + ShortcutKeyboardLayout.rowGap)
            - ShortcutKeyboardLayout.rowGap
        return NSSize(width: width,
                      height: headerHeight + keyboardHeight + footerGap + footerHeight + padding)
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        NSColor.separatorColor.setStroke()
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: padding, y: headerHeight - 8))
        rule.line(to: NSPoint(x: bounds.maxX - padding, y: headerHeight - 8))
        rule.lineWidth = 1
        rule.stroke()
    }

    // MARK: - 交互

    func toggleModifier(_ flag: UInt) {
        guard flag & Self.modeledMask != 0 else { return }
        selectedFlags = selectedFlags & flag == 0 ? selectedFlags | flag : selectedFlags & ~flag
        refresh()
    }

    /// 点中一个主键：正常模式立刻提交；修饰键模式里主键本来就没有意义，忽略。
    func activateKey(_ keyCode: UInt16) {
        guard !modifiersOnly else { return }
        onCommit?(keyCode, selectedFlags)
    }

    /// 修饰键模式的「完成」。一个修饰键都没选时不提交 —— 那是「没有」，不是一份空绑定。
    func confirm() {
        guard modifiersOnly, selectedFlags != 0 else { return }
        onCommit?(0, selectedFlags)
    }

    func cancel() {
        onCancel?()
    }

    /// 「改成手写…」的落点（与按钮同一个回调）。
    func typeInstead() {
        onTypeInstead?()
    }

    /// 顶部那行当前选中的修饰符号（用例读它，不必拆标签）。
    var headerReadoutForTesting: String { readoutLabel.stringValue }

    // MARK: - 构造视图

    private func build() {
        readoutLabel.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        readoutLabel.alignment = .left
        readoutLabel.lineBreakMode = .byTruncatingTail
        readoutLabel.frame = NSRect(x: padding, y: 10, width: bounds.width - padding * 2, height: 24)

        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.frame = NSRect(x: padding, y: 38, width: bounds.width - padding * 2, height: 15)
        hintLabel.stringValue = L(modifiersOnly
            ? "Pick the modifiers to hold"
            : "Pick modifiers, then click a key")

        addSubview(readoutLabel)
        addSubview(hintLabel)

        if modifiersOnly {
            buildModifiersOnly()
        } else {
            buildMainKeyboard()
        }
        buildFooter()
        repositionHeaderLabels()
    }

    /// 尺寸在 `init` 里是零，头部两行等布局定下来再拉到全宽。
    private func repositionHeaderLabels() {
        let width = preferredSize.width - padding * 2
        readoutLabel.frame = NSRect(x: padding, y: 10, width: width, height: 24)
        hintLabel.frame = NSRect(x: padding, y: 38, width: width, height: 15)
    }

    private func buildMainKeyboard() {
        let keyHeight = ShortcutKeyboardLayout.keyHeight
        let gap = ShortcutKeyboardLayout.keyGap
        let top = headerHeight

        for (rowIndex, row) in ShortcutKeyboardLayout.mainRows.enumerated() {
            let y = top + CGFloat(rowIndex) * (keyHeight + ShortcutKeyboardLayout.rowGap)
            var x = padding
            var rowButtons: [ShortcutKeyButton] = []
            for key in row.keys {
                let button = makeButton(key)
                button.frame = NSRect(x: x, y: y, width: button.preferredWidth, height: keyHeight)
                addSubview(button)
                rowButtons.append(button)
                x += button.preferredWidth + gap
            }
            if row.alignsLastKeyToTrailingEdge, let last = rowButtons.last {
                last.frame.origin.x = padding + ShortcutKeyboardLayout.mainWidth - last.frame.width
            }
            if row.endsWithArrowCluster {
                buildArrowCluster(atY: y)
            }
        }
    }

    /// 底部那一组方向键：← 与 → 整高，↑/↓ 各占半格，叠在同一列里。
    private func buildArrowCluster(atY y: CGFloat) {
        let unit = ShortcutKeyboardLayout.keyUnit
        let column = unit + ShortcutKeyboardLayout.keyGap
        let height = ShortcutKeyboardLayout.keyHeight
        let startX = padding
            + (ShortcutKeyboardLayout.mainRowUnits - 3) * (unit + ShortcutKeyboardLayout.keyGap)

        let left = makeButton(ShortcutKeyboardLayout.leftArrow)
        left.frame = NSRect(x: startX, y: y, width: unit, height: height)
        addSubview(left)

        let halfHeight = (height - ShortcutKeyboardLayout.keyGap) / 2
        let up = makeButton(ShortcutKeyboardLayout.upArrow)
        up.frame = NSRect(x: startX + column, y: y, width: unit, height: halfHeight)
        addSubview(up)
        let down = makeButton(ShortcutKeyboardLayout.downArrow)
        down.frame = NSRect(x: startX + column,
                            y: y + halfHeight + ShortcutKeyboardLayout.keyGap,
                            width: unit, height: halfHeight)
        addSubview(down)

        let right = makeButton(ShortcutKeyboardLayout.rightArrow)
        right.frame = NSRect(x: startX + 2 * column, y: y, width: unit, height: height)
        addSubview(right)
    }

    private func buildModifiersOnly() {
        let totalWidth = 5 * modifierButtonWidth + 4 * modifierButtonGap
        let startX = (preferredSize.width - totalWidth) / 2
        let y = headerHeight
        for (index, key) in ShortcutKeyboardLayout.modifiersOnlyKeys.enumerated() {
            let button = makeButton(key)
            button.frame = NSRect(x: startX + CGFloat(index) * (modifierButtonWidth + modifierButtonGap),
                                  y: y,
                                  width: modifierButtonWidth,
                                  height: ShortcutKeyboardLayout.keyHeight)
            addSubview(button)
        }
    }

    private func makeButton(_ key: ShortcutKeyboardKey) -> ShortcutKeyButton {
        let button = ShortcutKeyButton(key: key)
        button.target = self
        button.action = #selector(keyPressed(_:))
        if case .modifier = key.behavior {
            modifierButtons.append(button)
        }
        return button
    }

    private func buildFooter() {
        let y = preferredSize.height - padding - footerHeight

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelPressed))
        styleFooterButton(cancel)
        cancelButton = cancel
        addSubview(cancel)

        if modifiersOnly {
            let done = NSButton(title: L("Done"), target: self, action: #selector(donePressed))
            styleFooterButton(done)
            done.keyEquivalent = "\r"
            doneButton = done
            addSubview(done)
        } else {
            let type = NSButton(title: L("Type it instead…"), target: self, action: #selector(typePressed))
            styleFooterButton(type)
            typeButton = type
            addSubview(type)
        }
        layoutFooterButtons(in: NSRect(x: padding, y: y,
                                       width: preferredSize.width - padding * 2,
                                       height: footerHeight))
    }

    private func styleFooterButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 12)
        button.sizeToFit()
    }

    private func layoutFooterButtons(in area: NSRect) {
        guard let cancelButton else { return }
        var right = area.maxX
        cancelButton.frame.origin = NSPoint(x: right - cancelButton.frame.width,
                                            y: area.minY + (area.height - cancelButton.frame.height) / 2)
        right = cancelButton.frame.minX - 8
        if let doneButton {
            doneButton.frame.origin = NSPoint(x: right - doneButton.frame.width,
                                              y: area.minY + (area.height - doneButton.frame.height) / 2)
        }
        if let typeButton {
            typeButton.frame.origin = NSPoint(x: area.minX,
                                              y: area.minY + (area.height - typeButton.frame.height) / 2)
        }
    }

    // MARK: - 状态

    private func refresh() {
        let symbols = ShortcutRecorderView.modifierSymbols(selectedFlags)
        if symbols.isEmpty {
            readoutLabel.stringValue = L("None")
            readoutLabel.textColor = .secondaryLabelColor
        } else {
            readoutLabel.stringValue = symbols
            readoutLabel.textColor = .labelColor
        }
        for button in modifierButtons {
            guard case .modifier(let flag) = button.behavior else { continue }
            button.state = selectedFlags & flag != 0 ? .on : .off
            button.needsDisplay = true
        }
        doneButton?.isEnabled = selectedFlags != 0
        needsDisplay = true
    }

    @objc private func keyPressed(_ sender: ShortcutKeyButton) {
        switch sender.behavior {
        case .key(let keyCode):
            activateKey(keyCode)
        case .modifier(let flag):
            toggleModifier(flag)
        case .inert:
            break
        }
    }

    @objc private func cancelPressed() {
        cancel()
    }

    @objc private func donePressed() {
        confirm()
    }

    @objc private func typePressed() {
        onTypeInstead?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            cancel()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }
}
