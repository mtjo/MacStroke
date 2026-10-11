// 键盘合成的纯换算部分。
//
// 这里刻意一条事件都不往系统里发：测试跑起来时前台是哪个 App，全看用户当下点了
// 什么，往他文档里打字或按一个 ⌘W 都是事故。真的落到事件流里由 E2E 那组用
// 「吞掉键盘事件」的活动 tap 取证。
//
// 唯一涉及操作系统的取证是「一块装得下多少」：那个 20 不是道听途说来的常数，
// 是当场往 CGEvent 里塞了 20 和 30 两个长度、再原样读回来量出来的——顺手也证明了
// 20 不是这一层的硬墙，切块真正的理由是投递侧那层的传统容量。
import XCTest
import CoreGraphics
@testable import RemoteControl

final class RemoteKeyboardTextTests: XCTestCase {
    private func units(_ text: String) -> Int { text.utf16.count }

    func testShortTextIsOneChunk() {
        XCTAssertEqual(RemoteKeyboardExecutor.unicodeChunks(of: "hello"), [[104, 101, 108, 108, 111]])
        XCTAssertEqual(RemoteKeyboardExecutor.unicodeChunks(of: ""), [])
    }

    /// 中文按 UTF-16 单元算而不是按字算：一个汉字 1 单元，一个 emoji 2 单元。
    func testChunkLimitCountsUTF16UnitsNotCharacters() {
        let twentyChinese = String(repeating: "中", count: 20)
        XCTAssertEqual(RemoteKeyboardExecutor.unicodeChunks(of: twentyChinese).count, 1)

        let twentyOne = twentyChinese + "中"
        let chunks = RemoteKeyboardExecutor.unicodeChunks(of: twentyOne)
        XCTAssertEqual(chunks.map(\.count), [20, 1])
    }

    /// 代理对切成两半，到 App 那边就是两个乱码字：宁可一块只装一个字符。
    func testSurrogatePairIsNeverSplit() {
        // 🙂 = 2 个单元；10 个刚好填满一块，第 11 个必须整只进下一块。
        let emojis = String(repeating: "🙂", count: 11)
        let chunks = RemoteKeyboardExecutor.unicodeChunks(of: emojis)
        XCTAssertEqual(chunks.map(\.count), [20, 2])
        XCTAssertEqual(chunks.flatMap { $0 }, Array(emojis.utf16))
    }

    /// 单个字符就超限时（一长串 ZWJ 拼出来的家庭 emoji，23 个单元）整块发出：
    /// 拆碎了一定乱码，整块发出去至少还有机会被 App 认下来。
    func testOversizedSingleCharacterGoesOutWhole() {
        let family = Array(repeating: "👨", count: 8).joined(separator: "\u{200D}")
        XCTAssertEqual(Array(family).count, 1, "ZWJ 串在 Swift 里就是一个字符")
        XCTAssertGreaterThan(units(family), RemoteKeyboardExecutor.maxUnitsPerEvent)

        XCTAssertEqual(RemoteKeyboardExecutor.unicodeChunks(of: family).map(\.count),
                       [units(family)])
        // 它自己独占一块，后面那个 a 不会被挤到同一块里去。
        XCTAssertEqual(RemoteKeyboardExecutor.unicodeChunks(of: family + "a").map(\.count),
                       [units(family), 1])
    }

    func testChunksReassembleIntoTheOriginalText() {
        let text = "MacStroke 远程控制，含 emoji 🙏 与中文，长度超过一块。"
        let rebuilt = String(decoding: RemoteKeyboardExecutor.unicodeChunks(of: text).flatMap { $0 },
                             as: UTF16.self)
        XCTAssertEqual(rebuilt, text)
    }

    /// 一整篇文档不能把主队列钉住：超上限按字符截断，而不是报错或断连。
    func testClampTruncatesOnCharacterBoundary() {
        let limit = RemoteKeyboardExecutor.maxTextUnits
        XCTAssertEqual(RemoteKeyboardExecutor.clampForInjection("short"), "short")

        let doubled = String(repeating: "🙂", count: limit)          // 2 × limit 个单元
        let clamped = RemoteKeyboardExecutor.clampForInjection(doubled)
        XCTAssertEqual(units(clamped), limit)
        XCTAssertEqual(clamped, String(repeating: "🙂", count: limit / 2),
                       "截断点必须落在字符边界，不能留半个代理对")
        XCTAssertEqual(RemoteKeyboardExecutor.clampForInjection("within limit 中文"),
                       "within limit 中文")
    }

    // MARK: - 一块能装多少的取证

    /// 上限 20 是投递侧的保守值，不是 CGEvent 的硬墙：实测一条事件塞 30 个单元
    /// 照样原样读得回来。真正要证明的是「我们切出来的这一块，一个单元都不会少」,
    /// 以及「20 这个数没撞上什么隐藏容量」——后者只能靠量，不能靠传闻。
    func testChunkFitsInsideWhatAnEventCanCarry() throws {
        let chunk = try XCTUnwrap(RemoteKeyboardExecutor.unicodeChunks(of: String(repeating: "中", count: 20)).first)
        XCTAssertEqual(roundTrippedUnits(of: chunk), chunk.count, "一块 20 个单元要能整个装进一条事件")

        let thirty = Array(String(repeating: "A", count: 30).utf16)
        XCTAssertEqual(roundTrippedUnits(of: thirty), 30,
                       "CGEvent 这层根本不是 20 的硬墙；切块是为了投递侧，别把这句话写成系统限制")
    }

    private func roundTrippedUnits(of units: [UniChar]) -> Int {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        var actual = 0
        var buffer = [UniChar](repeating: 0, count: max(units.count, 64))
        event?.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                       actualStringLength: &actual, unicodeString: &buffer)
        let kept = min(max(actual, 0), units.count)
        XCTAssertEqual(Array(buffer.prefix(kept)), Array(units.prefix(kept)),
                       "读回来的内容和写进去的不是同一段")
        return actual
    }
}

final class RemoteKeyboardKeyTableTests: XCTestCase {
    /// 键码逐条来自 SDK 的 `HIToolbox.framework/…/Headers/Events.h`。
    /// 这里挑的是几条「按字母表推不出来」的：ANSI 区按物理排布，数字行还打乱。
    func testPhysicallyScrambledKeycodes() {
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "a"), 0x00)
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "s"), 0x01)
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "f"), 0x03)
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "c"), 0x08)
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "5"), 0x17)
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "6"), 0x16)
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "return"), 0x24)
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "up"), 0x7E)
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "f1"), 0x7A)
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "f12"), 0x6F)
    }

    /// 手机上的快捷键条会写「Enter」「Esc」「⌫」这类叫法。
    func testEverydayAliasesLandOnTheSameKey() {
        for name in ["enter", "return"] {
            XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: name), 0x24)
        }
        for name in ["esc", "escape"] {
            XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: name), 0x35)
        }
        for name in ["delete", "backspace"] {
            XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: name), 0x33)
        }
        for name in ["del", "forwarddelete"] {
            XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: name), 0x75)
        }
    }

    func testUnknownKeyNameIsRejectedNotGuessed() {
        XCTAssertNil(RemoteKeyboardExecutor.keycode(for: "banana"))
        XCTAssertNil(RemoteKeyboardExecutor.keycode(for: ""))
        XCTAssertNil(RemoteKeyboardExecutor.keycode(for: "⇧"))   // 修饰键不是键
        XCTAssertEqual(RemoteKeyboardExecutor.keycode(for: "C"), 0x08, "大小写不分")
    }
}

final class RemoteKeyModifiersTests: XCTestCase {
    func testDescriptorAcceptsNamesAndGlyphs() {
        XCTAssertEqual(RemoteKeyModifiers(descriptor: "cmd+shift"), [.command, .shift])
        XCTAssertEqual(RemoteKeyModifiers(descriptor: "CMD + Shift"), [.command, .shift])
        XCTAssertEqual(RemoteKeyModifiers(descriptor: "⌘+⌥"), [.command, .alternate])
        XCTAssertEqual(RemoteKeyModifiers(descriptor: "control"), .control)
        XCTAssertEqual(RemoteKeyModifiers(descriptor: "option"), .alternate)
        XCTAssertEqual(RemoteKeyModifiers(descriptor: "fn"), .function)
    }

    /// 省略 m 就是按纯键；末尾多一个加号是手机拼串时常见的毛病，不该因此报错。
    func testEmptyDescriptorMeansNoModifiers() {
        XCTAssertEqual(RemoteKeyModifiers(descriptor: ""), [])
        XCTAssertEqual(RemoteKeyModifiers(descriptor: "cmd+"), .command)
    }

    /// 认不出的修饰键要当场拒绝：猜成「不带修饰」就等于在用户桌面上多按一个纯键。
    func testUnrecognizedModifierIsRejected() {
        XCTAssertNil(RemoteKeyModifiers(descriptor: "cmd+hyper"))
        XCTAssertNil(RemoteKeyModifiers(descriptor: "meta"))
        // 分隔符不能省：报文的写法就是 cmd+shift，一长串字形是 UI 上显示的标签，不是协议。
        XCTAssertNil(RemoteKeyModifiers(descriptor: "⌘⌥"))
    }

    /// 字段整个缺席才是「按纯键」；在场但写坏了（数字、null）算错，
    /// 悄悄当成没修饰键的话，手机上标 ⌘W 的按钮会在 Mac 上按出一个 w。
    func testWireFieldDistinguishesAbsentFromBroken() {
        XCTAssertEqual(RemoteKeyModifiers(wireField: nil), [])
        XCTAssertEqual(RemoteKeyModifiers(wireField: ""), [])
        XCTAssertNil(RemoteKeyModifiers(wireField: 3))
        XCTAssertNil(RemoteKeyModifiers(wireField: NSNull()))
    }
}
