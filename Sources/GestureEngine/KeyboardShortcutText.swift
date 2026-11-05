//
//  KeyboardShortcutText.swift
//  MacStroke
//
//  issue #78 第 3 条：有些全局快捷键录不到 —— 组合键在到达偏好窗口之前就被系统
//  或前台应用吃掉（⌃↑ 切桌面、⌘⇧2 系统截图…），录制框的 `keyDown` 压根收不到那一下。
//  这一层给「手填」兜底：把人写的 "⌘⇧2" / "cmd+shift+2" 解析成 `keyCode + flags`。
//
//  为什么放 GestureEngine：这张表三处要用，而它们都够不到偏好层 —— 规则动作
//  `keyPress("space")` 本来就有一份私有的名→键码表（`ActionExecutor`），录制框在
//  Preferences 层，本层是两者唯一共同的下游。表只有一份，改一处三处一起改。
//
//  判据全收在纯函数里：解析结果与「为什么没解析出来」都能用例外直接钉住，
//  不需要真的把焦点抢进一个编辑框。
//

import Foundation
import Carbon.HIToolbox

/// 键名 / 单个字符 → ANSI 虚拟键码。
public enum KeyboardKeys {

    /// 认不出返回 nil。大小写不敏感，`space` 与 `␣`（录制框显示的那个字）都收，
    /// 为的是「把框里显示的那串原样填回去」这条最常见的手路能走通。
    public static func keyCode(for token: String) -> UInt16? {
        let key = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let code = names[key] { return code }
        // key(105)：认不出的键码直接按数字填。表里没名字的键（F13 以上、小键盘以外
        // 的 HID 键）总得有入口，否则「手填」对这类键等于没做。
        return numericCode(from: key)
    }

    /// 键码 → 一个必定能解析回来的写法（与 `keyCode(for:)` 同一份表，反过来查）。
    ///
    /// 为什么需要：显示用的那张字形表有几处是**有损**的 —— 小键盘的 0–9 显示成主键盘的
    /// "0"…"9"、小键盘回车和主键盘回车都显示成 ↩。手填框要是直接抄这份显示，用户双击进去
    /// 什么都不改就回车，键会被换成另一格（36 ⇄ 76、84 ⇄ 19 这种）。这几处得改用名字写。
    public static func name(for keyCode: UInt16) -> String? {
        names.first { $0.value == keyCode }?.key
    }

    /// `key(105)` 里的数字部分；不是这个形状、或超出 UInt16 返回 nil。
    static func numericCode(from normalizedToken: String) -> UInt16? {
        guard normalizedToken.hasPrefix("key("), normalizedToken.hasSuffix(")") else { return nil }
        let body = normalizedToken.dropFirst(4).dropLast()
        guard let value = Int(body), (0...Int(UInt16.max)).contains(value) else { return nil }
        return UInt16(value)
    }

    private static let names: [String: UInt16] = [
        // 字母：ANSI 键码不是 ASCII 顺序，逐个写死。26 个一个都不能少 —— 这张表同时是
        // 规则动作 `keyPress("o")` 的唯一名→码来源（原来 ActionExecutor 那份私有表是
        // 全的，合并时漏掉 o/u 就等于把这两条老规则静默变成「Unknown key」）。
        "a": UInt16(kVK_ANSI_A), "s": UInt16(kVK_ANSI_S), "d": UInt16(kVK_ANSI_D),
        "f": UInt16(kVK_ANSI_F), "h": UInt16(kVK_ANSI_H), "g": UInt16(kVK_ANSI_G),
        "z": UInt16(kVK_ANSI_Z), "x": UInt16(kVK_ANSI_X), "c": UInt16(kVK_ANSI_C),
        "v": UInt16(kVK_ANSI_V), "b": UInt16(kVK_ANSI_B), "q": UInt16(kVK_ANSI_Q),
        "w": UInt16(kVK_ANSI_W), "e": UInt16(kVK_ANSI_E), "r": UInt16(kVK_ANSI_R),
        "y": UInt16(kVK_ANSI_Y), "t": UInt16(kVK_ANSI_T), "i": UInt16(kVK_ANSI_I),
        "p": UInt16(kVK_ANSI_P), "l": UInt16(kVK_ANSI_L), "j": UInt16(kVK_ANSI_J),
        "k": UInt16(kVK_ANSI_K), "n": UInt16(kVK_ANSI_N), "m": UInt16(kVK_ANSI_M),
        "o": UInt16(kVK_ANSI_O), "u": UInt16(kVK_ANSI_U),
        // 数字：主键盘那一排（小键盘见 keypad*）。
        "1": UInt16(kVK_ANSI_1), "2": UInt16(kVK_ANSI_2), "3": UInt16(kVK_ANSI_3),
        "4": UInt16(kVK_ANSI_4), "5": UInt16(kVK_ANSI_5), "6": UInt16(kVK_ANSI_6),
        "7": UInt16(kVK_ANSI_7), "8": UInt16(kVK_ANSI_8), "9": UInt16(kVK_ANSI_9),
        "0": UInt16(kVK_ANSI_0),
        // 标点：显示字符与原名各收一份。减号在这里只能靠名字 —— "-" 在快捷方式串里
        // 是分词符（`cmd-shift-2`），当键写会被切没。
        "minus": UInt16(kVK_ANSI_Minus), "hyphen": UInt16(kVK_ANSI_Minus),
        // 手填串里 "-" 是分词符，这一格走不到；规则动作 `keyPress("-")` 走得到。
        "-": UInt16(kVK_ANSI_Minus),
        "equal": UInt16(kVK_ANSI_Equal), "=": UInt16(kVK_ANSI_Equal),
        "leftbracket": UInt16(kVK_ANSI_LeftBracket), "[": UInt16(kVK_ANSI_LeftBracket),
        "rightbracket": UInt16(kVK_ANSI_RightBracket), "]": UInt16(kVK_ANSI_RightBracket),
        "quote": UInt16(kVK_ANSI_Quote), "'": UInt16(kVK_ANSI_Quote),
        "semicolon": UInt16(kVK_ANSI_Semicolon), ";": UInt16(kVK_ANSI_Semicolon),
        "comma": UInt16(kVK_ANSI_Comma),
        "period": UInt16(kVK_ANSI_Period), ".": UInt16(kVK_ANSI_Period),
        "slash": UInt16(kVK_ANSI_Slash), "/": UInt16(kVK_ANSI_Slash),
        "backslash": UInt16(kVK_ANSI_Backslash), "\\": UInt16(kVK_ANSI_Backslash),
        "grave": UInt16(kVK_ANSI_Grave), "`": UInt16(kVK_ANSI_Grave),

        // 功能键。F13 以上不给名字：那些取值本机没验证过，宁缺勿错，需要的人走 key(N)。
        "f1": UInt16(kVK_F1), "f2": UInt16(kVK_F2), "f3": UInt16(kVK_F3),
        "f4": UInt16(kVK_F4), "f5": UInt16(kVK_F5), "f6": UInt16(kVK_F6),
        "f7": UInt16(kVK_F7), "f8": UInt16(kVK_F8), "f9": UInt16(kVK_F9),
        "f10": UInt16(kVK_F10), "f11": UInt16(kVK_F11), "f12": UInt16(kVK_F12),

        // 特殊键：原名 + 录制框显示的那个字，两种写法等价。
        "space": UInt16(kVK_Space), "␣": UInt16(kVK_Space),
        "return": UInt16(kVK_Return), "enter": UInt16(kVK_Return), "↩": UInt16(kVK_Return),
        "tab": UInt16(kVK_Tab), "⇥": UInt16(kVK_Tab),
        "escape": UInt16(kVK_Escape), "esc": UInt16(kVK_Escape), "⎋": UInt16(kVK_Escape),
        "delete": UInt16(kVK_Delete), "backspace": UInt16(kVK_Delete), "⌫": UInt16(kVK_Delete),
        "forwarddelete": UInt16(kVK_ForwardDelete), "⌦": UInt16(kVK_ForwardDelete),
        "home": UInt16(kVK_Home), "↖": UInt16(kVK_Home),
        "end": UInt16(kVK_End), "↘": UInt16(kVK_End),
        "pageup": UInt16(kVK_PageUp), "⇞": UInt16(kVK_PageUp), "pageupkey": UInt16(kVK_PageUp),
        "pagedown": UInt16(kVK_PageDown), "⇟": UInt16(kVK_PageDown), "pagedownkey": UInt16(kVK_PageDown),
        "left": UInt16(kVK_LeftArrow), "leftarrow": UInt16(kVK_LeftArrow), "←": UInt16(kVK_LeftArrow),
        "right": UInt16(kVK_RightArrow), "rightarrow": UInt16(kVK_RightArrow), "→": UInt16(kVK_RightArrow),
        "up": UInt16(kVK_UpArrow), "uparrow": UInt16(kVK_UpArrow), "↑": UInt16(kVK_UpArrow),
        "down": UInt16(kVK_DownArrow), "downarrow": UInt16(kVK_DownArrow), "↓": UInt16(kVK_DownArrow),

        // 小键盘。裸的 "5" 是主键盘那一排，所以这一组只给名字，不给单字符。
        "keypadenter": UInt16(kVK_ANSI_KeypadEnter),
        "keypadclear": UInt16(kVK_ANSI_KeypadClear),
        "keypadplus": UInt16(kVK_ANSI_KeypadPlus),
        "keypadminus": UInt16(kVK_ANSI_KeypadMinus),
        "keypadmultiply": UInt16(kVK_ANSI_KeypadMultiply),
        "keypaddivide": UInt16(kVK_ANSI_KeypadDivide),
        "keypadequals": UInt16(kVK_ANSI_KeypadEquals),
        "keypad0": UInt16(kVK_ANSI_Keypad0), "keypad1": UInt16(kVK_ANSI_Keypad1),
        "keypad2": UInt16(kVK_ANSI_Keypad2), "keypad3": UInt16(kVK_ANSI_Keypad3),
        "keypad4": UInt16(kVK_ANSI_Keypad4), "keypad5": UInt16(kVK_ANSI_Keypad5),
        "keypad6": UInt16(kVK_ANSI_Keypad6), "keypad7": UInt16(kVK_ANSI_Keypad7),
        "keypad8": UInt16(kVK_ANSI_Keypad8), "keypad9": UInt16(kVK_ANSI_Keypad9),
    ]
}

/// 手填的快捷键串 → (keyCode, flags)。
public enum ShortcutText {

    public struct Parsed: Equatable {
        public let keyCode: UInt16
        public let flags: UInt

        /// 手写出来的一份：默认的 memberwise init 是 internal 的，
        /// 而这一手要给 Preferences 层（回填预填串）和用例两侧用。
        public init(keyCode: UInt16, flags: UInt) {
            self.keyCode = keyCode
            self.flags = flags
        }
    }

    /// 没解析出来的原因。UI 直接把它写进 tooltip，用户看得见「到底是哪一段不认识」。
    public enum Failure: Equatable, Error {
        case empty
        case unknownToken(String)
        /// 普通录制框里 keyCode 0 是键盘上的 A，「只给修饰键」在模型里不是「没有」，
        /// 所以那种写法必须拒掉；只有修饰键模式（`requiresKey: false`）才收。
        case missingKey
        /// 两段都像键（"⌘A2"）：猜哪个都可能投出用户没打算绑的那一键。
        case moreThanOneKey(String)
    }

    /// 修饰位：与录制框、`Set(eventFlags:)` 那套一致。
    public static let controlFlag: UInt = 0x40000
    public static let optionFlag: UInt = 0x80000
    public static let shiftFlag: UInt = 0x20000
    public static let commandFlag: UInt = 0x100000
    public static let functionFlag: UInt = 0x800000

    private static let modifierAliases: [String: UInt] = [
        "⌘": commandFlag, "cmd": commandFlag, "command": commandFlag,
        "⌥": optionFlag, "opt": optionFlag, "option": optionFlag, "alt": optionFlag,
        "⌃": controlFlag, "ctrl": controlFlag, "control": controlFlag, "^": controlFlag,
        "⇧": shiftFlag, "shift": shiftFlag,
        "fn": functionFlag, "function": functionFlag,
    ]

    /// - Parameter requiresKey: 普通录制框 true（必须有键），修饰键模式 false（可以只有修饰键）。
    public static func evaluate(_ text: String, requiresKey: Bool = true) -> Result<Parsed, Failure> {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return .failure(.empty) }

        var flags: UInt = 0
        var keyCode: UInt16?
        for token in tokens {
            if let bit = modifierAliases[token.lowercased()] {
                flags |= bit
                continue
            }
            guard let code = KeyboardKeys.keyCode(for: token) else {
                return .failure(.unknownToken(token))
            }
            guard keyCode == nil else { return .failure(.moreThanOneKey(token)) }
            keyCode = code
        }
        guard let keyCode else {
            if requiresKey { return .failure(.missingKey) }
            return .success(Parsed(keyCode: 0, flags: flags))
        }
        return .success(Parsed(keyCode: keyCode, flags: flags))
    }

    /// 成功才给值；认不出统一 nil（给只要个结果的调用方）。
    public static func parse(_ text: String, requiresKey: Bool = true) -> Parsed? {
        switch evaluate(text, requiresKey: requiresKey) {
        case .success(let parsed): return parsed
        case .failure: return nil
        }
    }

    /// 分隔符（空白、`+`、`-`、`,`、`_`）切段，同时把连写的修饰符号各自拆成一 token
    /// —— "⌘⇧2" 里没有任何分隔符。
    static func tokenize(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }
        for character in text {
            if isSeparator(character) {
                flush()
                continue
            }
            if isModifierSymbol(character) {
                flush()
                pieces.append(String(character))
                continue
            }
            current.append(character)
        }
        flush()
        return pieces.filter { !$0.isEmpty }
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "+" || character == "-" || character == "," || character == "_"
            || character == " " || character == "\t"
    }

    private static func isModifierSymbol(_ character: Character) -> Bool {
        character == "⌘" || character == "⌥" || character == "⌃" || character == "⇧"
    }
}
