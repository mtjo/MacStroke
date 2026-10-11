//
//  RemoteKeyboardExecutor.swift
//  MacStroke
//
//  Turns remote text and shortcut commands into real keyboard events.
//
//  Posting recipe is the one the click executor already uses: events go out at
//  `kCGSessionEventTap`, downstream of MacStroke's own HID tap, so injected
//  keys are never mistaken for the start of a gesture.
//
//  Two facts shape the text path. A phone's Chinese/emoji input has no key on a
//  Mac keyboard at all, so text goes in through the per-event unicode override
//  rather than as keycodes. And that override is chopped into small chunks: the
//  layer between the session tap and the app has historically carried 20 UTF-16
//  units per key event, and nothing is going to tell us when a longer one loses
//  its tail. Chunk boundaries stay on character boundaries, because a surrogate
//  pair split across two events arrives as mojibake.
//

import CoreGraphics

/// 文本注入。键码表逐条抄自 SDK 的
/// `HIToolbox.framework/…/Headers/Events.h`（kVK_* 枚举），不是凭记忆写的。
public enum RemoteKeyboardExecutor {
    /// 一块切 20 个 UTF-16 单元。
    ///
    /// 这个数字不是 CGEvent 的硬墙——实测（见 RemoteKeyboardTextTests）往一条事件
    /// 塞 30 个单元照样原样读得回来。它是键盘事件进 App 之前那一层的传统容量
    /// （Carbon 的 KeyEventRecord 一直按 20 个单元设计），没人保证超了会怎样。
    /// 按 20 切只是多几条事件，代价换来的是「尾部文本不会静默不见」。
    static let maxUnitsPerEvent = 20

    /// 一次 `type` 最多注入这么多 UTF-16 单元。手机上粘贴一整篇文档时，
    /// 主队列要被占用的时间得有上限；截断比卡住整个手势识别合适。
    static let maxTextUnits = 2000

    /// 纯换算：把文本切成「一条事件装得下」的块，且不把一个字符切成两半。
    /// 单个字符就超限时（少见的超长组合字）整块发出，由系统决定截不截。
    static func unicodeChunks(of text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxUnitsPerEvent {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// 纯换算：按字符边界截到 `maxTextUnits`。和切块同一套规矩——宁可少几个字，
    /// 也不在事件中间留下半个代理对。
    static func clampForInjection(_ text: String) -> String {
        var units = 0
        var kept = ""
        for character in text {
            units += String(character).utf16.count
            if units > maxTextUnits { break }
            kept.append(character)
        }
        return kept
    }

    /// 按键名 → 虚拟键码。手机发的是「c」「return」这样的名字而不是键码，
    /// 因为手机屏幕上没有 Mac 键盘，让小程序去数键码只会数错。
    static func keycode(for name: String) -> Int? {
        RemoteKeyboard.keyCodes[name.lowercased()]
    }

    /// 在当前焦点处注入文本。主队列调用。
    public static func type(_ text: String) {
        for units in unicodeChunks(of: text) {
            post(units: units)
        }
    }

    /// 按下「修饰键 + 一个键」的组合，修饰键按系统习惯的顺序逐个按下、反序松开。
    public static func press(combo: RemoteKeyCombo) {
        var flags = CGEventFlags()
        for modifier in combo.modifiers.pressSequence {
            flags.insert(modifier.flag)
            postFlagsChanged(keycode: modifier.keyCode, pressed: true, flags: flags)
        }
        post(keycode: combo.keyCode, down: true, flags: flags)
        post(keycode: combo.keyCode, down: false, flags: flags)
        for modifier in combo.modifiers.pressSequence.reversed() {
            flags.remove(modifier.flag)
            postFlagsChanged(keycode: modifier.keyCode, pressed: false, flags: flags)
        }
    }

    /// 一条 unicode 文本的按下与松开。键码填 0：那些按虚拟键码自己翻译
    /// Unicode 的 App 是少数，而 keycode 0（A 键）配上文本覆盖是最不被无视的取值。
    private static func post(units: [UniChar]) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
                continue
            }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.flags = []
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func post(keycode: Int, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: CGKeyCode(keycode), keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }

    /// 修饰键走 flagsChanged 而不是 keyDown：真键盘就是这么发的，系统那套全局
    /// 快捷键（⌘Tab、⌘Space）读的也是 flagsChanged。
    ///
    /// 这不是理论推导——把修饰键当普通键 post 成 keyDown，E2E 那只挂在会话流上的
    /// 事件 tap 一条都收不到，只有主键带着 flags 过去。全局快捷键能不能成，
    /// 差的就是这几条。
    private static func postFlagsChanged(keycode: Int, pressed: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: CGKeyCode(keycode), keyDown: pressed) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }
}

/// 「cmd+shift」这样的修饰键串 → 一份修饰键集合。
public struct RemoteKeyModifiers: OptionSet, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = RemoteKeyModifiers(rawValue: 1 << 0)
    public static let control = RemoteKeyModifiers(rawValue: 1 << 1)
    public static let alternate = RemoteKeyModifiers(rawValue: 1 << 2)
    public static let shift = RemoteKeyModifiers(rawValue: 1 << 3)
    public static let function = RemoteKeyModifiers(rawValue: 1 << 4)

    /// 按下顺序固定为 ⌃⌥⇧⌘（fn 垫底），松开走反序。
    fileprivate static let pressOrder: [(option: RemoteKeyModifiers, keyCode: Int, flag: CGEventFlags)] = [
        (.control, 0x3B, .maskControl),
        (.alternate, 0x3A, .maskAlternate),
        (.shift, 0x38, .maskShift),
        (.command, 0x37, .maskCommand),
        (.function, 0x3F, .maskSecondaryFn),
    ]

    fileprivate var pressSequence: [(keyCode: Int, flag: CGEventFlags)] {
        RemoteKeyModifiers.pressOrder
            .filter { contains($0.option) }
            .map { (keyCode: $0.keyCode, flag: $0.flag) }
    }

    /// 解析「cmd+shift」：分隔符固定 `+`，名字大小写不管，空格无所谓。
    /// 认识 ⌘⌥⇧⌃fn 这些字形，是因为手机上的快捷键条就想直接印字形。
    /// 空串合法（不带修饰键，split 直接给出空数组），写了却不认识则返回 nil——
    /// 宁可报错也不猜成「按纯键」。
    public init?(descriptor: String) {
        var parsed: RemoteKeyModifiers = []
        for piece in descriptor.lowercased().split(separator: "+") {
            let name = piece.trimmingCharacters(in: .whitespaces)
            guard let option = RemoteKeyModifiers.names[name] else { return nil }
            parsed.insert(option)
        }
        self.init(rawValue: parsed.rawValue)
    }

    /// 报文字段那一版的入口：整个字段缺席才是「不带修饰键」，
    /// 在场但不是字符串（手机拼串拼坏了）算写错，不能当成空串。
    public init?(wireField field: Any?) {
        guard let field else {
            self.init(descriptor: "")
            return
        }
        guard let descriptor = field as? String else { return nil }
        self.init(descriptor: descriptor)
    }

    private static let names: [String: RemoteKeyModifiers] = [
        "cmd": .command, "command": .command, "super": .command, "⌘": .command,
        "ctrl": .control, "control": .control, "⌃": .control,
        "alt": .alternate, "option": .alternate, "⌥": .alternate,
        "shift": .shift, "⇧": .shift,
        "fn": .function, "function": .function,
    ]
}

/// 一次快捷键按下：一个键码加一组修饰键。
public struct RemoteKeyCombo: Equatable {
    public var keyCode: Int
    public var modifiers: RemoteKeyModifiers

    public init(keyCode: Int, modifiers: RemoteKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// 键名表。数字全部取自 SDK 的 kVK_* 枚举；ANSI 区的键位是物理位置，
/// 所以这里给的是「US 布局上印着什么」的名字，键位随布局变也不影响组合键语义。
private enum RemoteKeyboard {
    static let keyCodes: [String: Int] = [
        // 字母：ANSI 区按物理排布，顺序并不连续。
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "u": 0x20,
        "i": 0x22, "o": 0x1F, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
        // 数字行同样打乱：5/6、7/8/9 的键码不连续。
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16,
        "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
        // 主键区符号。
        "=": 0x18, "-": 0x1B, "[": 0x21, "]": 0x1E, "\\": 0x2A, ";": 0x29,
        "'": 0x27, ",": 0x2B, "/": 0x2C, ".": 0x2F, "`": 0x32,
        // 与布局无关的功能键。
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
        "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
        "forwarddelete": 0x75, "del": 0x75,
        "home": 0x73, "pageup": 0x74, "end": 0x77, "pagedown": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E, "help": 0x72,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]
}
