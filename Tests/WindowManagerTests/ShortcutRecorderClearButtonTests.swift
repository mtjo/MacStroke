// 快捷键录入框右端的清除按钮（issue #72：截图快捷键要能置空）。
// 四条判据：① 只有录好值时才出现，置空/空值时不出现；② 点它 = 清空 + 通知宿主，
// 点别处 = 照原版那样切换录制；③ 宿主写回的必须是空串而不是 "keyCode=0, flags=0"，
// 因为后者能解析成一个真实的键（keyCode 0 就是 A），全局监听会照挂；
// ④ 空串回落到视图时旧值要一起抹掉，否则偏好里已经没了、框上还挂着 ⌃⇧A。
// 图标用次级/四级标签色，明暗两档跟随系统外观（跟注解条那条子同一套做法）。
import XCTest
import AppKit
import SwiftUI
import Combine
import EventCapture
@testable import Preferences

final class ShortcutRecorderClearButtonTests: XCTestCase {

    /// 离屏用的窗口渲染完就能丢，但 SwiftUI 那两条用例得留着宿主窗口：视图一离窗，
    /// `updateNSView` 就不再被调用，binding 的改动同步不进来。
    private var retainedWindows: [NSWindow] = []

    // MARK: - 命中分流

    func testClickOnClearButtonEmptiesTheFieldAndNotifiesHost() {
        let view = recordedView()
        var cleared = 0
        view.onClear = { cleared += 1 }

        view.click(at: NSPoint(x: view.clearButtonRect().midX, y: view.clearButtonRect().midY))

        XCTAssertEqual(cleared, 1, "点那一叉没触发 onClear，宿主就不会把空值写进偏好")
        XCTAssertFalse(view.hasRecordedValue, "值没清掉：\(view.keyCode)/\(view.flags)")
        XCTAssertFalse(view.isRecording, "清完不该顺手把框拉进录制态")
    }

    /// 反向对照：同一个坐标落在空值框上必须不算清除，否则连开录都点不动。
    func testClickOnClearButtonAreaWhileEmptyStartsRecordingInstead() {
        let view = ShortcutRecorderView()
        var cleared = 0
        view.onClear = { cleared += 1 }

        view.click(at: NSPoint(x: view.clearButtonRect().midX, y: view.clearButtonRect().midY))

        XCTAssertEqual(cleared, 0)
        XCTAssertTrue(view.isRecording, "空值时那一格位置该照常用来开录制")
    }

    func testClickOnTheMiddleTogglesRecordingAndKeepsTheValue() {
        let view = recordedView()
        var cleared = 0
        view.onClear = { cleared += 1 }

        view.click(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))

        XCTAssertTrue(view.isRecording)
        XCTAssertEqual(cleared, 0, "点中间就清掉的话，用户根本没法改键")
        XCTAssertEqual(view.keyCode, 0, "没录完不该改动已存的值")
        XCTAssertEqual(view.flags, 0x100000 | 0x20000, "不该改动已存的修饰键")
    }

    /// 按钮贴在右端内侧面：既不越界，也不压到框的描边。
    func testClearButtonSitsInsideTheRightEdge() {
        let rect = ShortcutRecorderView.clearButtonRect(for: NSRect(x: 0, y: 0, width: 200, height: 28))
        XCTAssertEqual(rect, NSRect(x: 180, y: 7, width: 14, height: 14))
        XCTAssertGreaterThanOrEqual(rect.maxX, 200 - 8)
        XCTAssertLessThan(rect.maxX, 200 - 1, "压到描边上就不像框里的控件了")
        XCTAssertGreaterThan(rect.minX, 100, "按钮要在右半边")
    }

    // MARK: - 这一格用不上的时候（issue #75：下拉没选「自定义快捷键」）

    /// `.disabled` 走到 `NSViewRepresentable` 上不会画灰、也不会挡 `mouseDown`，
    /// 所以可用状态由 `controlEnabled` 自己管：点不动、不接焦点、也不许被程序拉进录制态。
    /// 反过来的坏法是「灰着的框仍把你的下一个键吞掉」—— 那比不灰更难查。
    func testADisabledRecorderIgnoresClicksAndRefusesFirstResponder() {
        let view = recordedView()
        view.controlEnabled = false
        var cleared = 0
        view.onClear = { cleared += 1 }

        view.click(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        XCTAssertFalse(view.isRecording, "灰着的框点一下就开始录键了")
        view.click(at: NSPoint(x: view.clearButtonRect().midX, y: view.clearButtonRect().midY))
        XCTAssertEqual(cleared, 0, "灰着的框还能置空：用户会以为这一格真的连着偏好")
        XCTAssertFalse(view.acceptsFirstResponder, "接了焦点就能吃 keyDown")
        view.startRecording(currentlyHeld: 0)
        XCTAssertFalse(view.isRecording, "程序侧也不该能把不可用的框拉进录制态")
        XCTAssertTrue(view.hasRecordedValue, "拒录不等于删值：那一档动作还是原样")
    }

    /// 从「能录」切到「不能录」时正在录制的那一格要自己退出去：界面上灰了、
    /// 后台还在按 first responder 收键，就是看不见的生效。
    func testDisablingWhileRecordingCancelsIt() {
        let view = ShortcutRecorderView()
        view.startRecording(currentlyHeld: 0)
        XCTAssertTrue(view.isRecording)

        view.controlEnabled = false
        XCTAssertFalse(view.isRecording, "改成不可用时没退出录制态")
    }

    /// 撤掉清除抓手（而不是画一把点不动的叉）不能把已录的值一起弄丢，**画面上那一叉也得真的没了**。
    /// 光看 `clearButtonRect()` 是空的：那块几何一直在，跟可见性判据无关 —— 只断言它就等于
    /// 没断言（`isClearVisible` 里删掉 `controlEnabled` 照样绿）。这里量的是那一格的实际墨。
    @MainActor
    func testDisablingHidesTheClearAffordanceButKeepsTheValue() {
        let view = recordedView()
        view.controlEnabled = true
        let rect = view.clearButtonRect()
        XCTAssertGreaterThan(rect.minX, 0, "启用时那一叉在框里")

        let enabledInk = inkCount(recorded: true, appearance: .aqua, controlEnabled: true)
        let disabledInk = inkCount(recorded: true, appearance: .aqua, controlEnabled: false)
        XCTAssertGreaterThan(enabledInk, 60, "可用时那一叉没画出来：\(enabledInk)")
        XCTAssertEqual(disabledInk, 0, "灰掉的框还挂着那一叉：点下去什么也不会发生，比不画更坏")

        view.controlEnabled = false
        XCTAssertEqual(view.keyCode, 0)
        XCTAssertEqual(view.flags, 0x100000 | 0x20000, "撤抓手不该把已录的值一起弄丢")
    }

    func testModifiersOnlyFieldCountsAsValueFromFlagsAlone() {
        let view = ShortcutRecorderView()
        view.modifiersOnly = true
        XCTAssertFalse(view.hasRecordedValue)
        view.flags = 0x40000 | 0x80000 // ⌃⌥
        XCTAssertTrue(view.hasRecordedValue, "修饰键档 keyCode 恒为 0，判空只能看 flags")
        view.clear()
        XCTAssertFalse(view.hasRecordedValue, "清了之后还显示 ⌃⌥ 就是没清干净")
    }

    /// 规则页的动作格复用同一个视图，但它存的是「要按下哪个键」，置空会变成按下 A。
    func testShowsClearButtonOffSendsTheClickBackToRecording() {
        let view = recordedView()
        view.showsClearButton = false
        var cleared = 0
        view.onClear = { cleared += 1 }

        view.click(at: NSPoint(x: view.clearButtonRect().midX, y: view.clearButtonRect().midY))

        XCTAssertEqual(cleared, 0)
        XCTAssertTrue(view.isRecording)
    }

    // MARK: - 宿主写回空串，空串再落回视图

    /// 端到端：SwiftUI 包装 + 可观测的 binding。点叉之后偏好里必须是空串。
    /// 存 "keyCode=0, flags=0" 的话 ShortcutMonitor 会解析成「裸按 A」并吞键。
    @MainActor
    func testHostBindingReceivesEmptyStringAndViewFollowsIt() throws {
        let box = ShortcutTextBox(text: "keyCode=0, flags=\(0x100000 | 0x20000)")
        let view = try hostedRecorder(box)
        XCTAssertEqual(view.displayString, "⌘⇧A", "前置条件：框里先有值")

        view.click(at: NSPoint(x: view.clearButtonRect().midX, y: view.clearButtonRect().midY))
        XCTAssertEqual(box.text, "", "清除写回的串：\(box.text)")
        XCTAssertFalse(view.hasRecordedValue)
    }

    /// 外部把偏好改成空串（重置到预设、另一处写入）时，视图里那份旧值必须跟着抹掉。
    /// 这条走的不是点击那条路：点叉的时候视图自己就把值清了，同步分支根本没参与。
    @MainActor
    func testExternalClearReachesTheViewWithoutClicking() throws {
        let box = ShortcutTextBox(text: "keyCode=9, flags=1572864")
        let view = try hostedRecorder(box)
        XCTAssertEqual(view.displayString, "⌘⌥V", "前置条件：框里先有值")

        box.text = ""
        flushSwiftUI()
        XCTAssertFalse(view.hasRecordedValue,
                       "偏好里已经空了，框上还挂着 ⌘⌥V：\(view.displayString)")
    }

    /// 同一座桥的反方向：外部改值（重置到预设）要落到视图上。
    @MainActor
    func testExternalValueChangeReachesTheView() throws {
        let box = ShortcutTextBox(text: "")
        let view = try hostedRecorder(box)
        XCTAssertFalse(view.hasRecordedValue)

        box.text = "keyCode=9, flags=1572864"
        flushSwiftUI()
        XCTAssertEqual(view.displayString, "⌘⌥V")
        XCTAssertTrue(view.hasRecordedValue)
    }

    /// 外层 `.disabled` **在挂好之后**翻动的那一手（issue #75：页面开着就把滚轮总开关关掉）。
    /// `makeNSView` 里那一行只管第一次，之后全靠 `updateNSView` 把 `isEnabled` 递进去 ——
    /// 少了那一行，框看着灰（SwiftUI 自己那层灰不到 NSView）、点下去照样进录制态吞掉下一个键。
    /// 上面那几条位图用例都是「先设好状态再渲染」，走不到这条路，所以这里单独钉一发。
    @MainActor
    func testDisablingAfterMountReachesTheNSView() throws {
        let box = ShortcutTextBox(text: "keyCode=9, flags=1048576")
        let view = try hostedRecorder(box)
        XCTAssertTrue(view.controlEnabled, "前置条件：挂上时外层没关")

        box.disabled = true
        flushSwiftUI()
        XCTAssertFalse(view.controlEnabled, "外层关了，NSView 没收到：灰是假的，点击还照吞")

        box.disabled = false
        flushSwiftUI()
        XCTAssertTrue(view.controlEnabled, "反向也要回到可用：不然关掉再打开那一档就永久点不动了")
    }

    // MARK: - 消费端：空串 = 不挂监听

    /// issue #72 的落点：置空之后全局快捷键监听解析不出东西，走「停掉」那条分支。
    /// 同时钉住为什么必须写空串 —— "keyCode=0, flags=0" 解析得出一个真实的键。
    func testEmptyShortcutStringIsNotAParsableShortcut() {
        XCTAssertNil(ShortcutMonitor.parseShortcut(""))
        XCTAssertNil(ShortcutMonitor.parseShortcut("   "))
        XCTAssertNil(ShortcutRecorder.parse(""))
        let zeroZero = ShortcutMonitor.parseShortcut("keyCode=0, flags=0")
        XCTAssertNotNil(zeroZero, "0/0 解析不出来的话，「清除必须写空串」这条顾虑就只是想象")
        XCTAssertEqual(zeroZero?.0, 0, "0/0 是一个真实的键（A）的键码")
        XCTAssertEqual(zeroZero?.1, 0)
    }

    // MARK: - 离屏渲染取证

    /// 有值时清除区里必须有一把叉，置空/关掉之后一个像素都不许剩。
    @MainActor
    func testGlyphInksAppearInBothAppearancesAndVanishAfterClear() throws {
        let light = inkCount(recorded: true, appearance: .aqua)
        let dark = inkCount(recorded: true, appearance: .darkAqua)
        let cleared = inkCount(recorded: false, appearance: .aqua)
        let hidden = inkCount(recorded: true, appearance: .aqua, showsClearButton: false)

        // 实测 148 / 156（circleX 那档），阈值取 60：既躲开抗锯齿毛边，又咬得住整块墨没画出来。
        XCTAssertGreaterThan(light, 60, "浅色档清除区里几乎没有墨色：\(light)")
        XCTAssertGreaterThan(dark, 60, "深色档清除区里几乎没有墨色：\(dark)")
        XCTAssertEqual(cleared, 0, "置空之后按钮还留着，可见性判据是反的：\(cleared)")
        XCTAssertEqual(hidden, 0, "showsClearButton=false 那一格不该画出叉：\(hidden)")
    }

    /// 灰掉的框里那行字必须**真的比可用时淡**：SwiftUI 的 `.disabled` 到不了自绘 NSView 的
    /// 文字（描边、底、墨色全是我们自己画的），`disabledControlTextColor` 那一档就是
    /// 「这一格用不上」在页面上的唯一视觉来源。上面几条位图判据数的是清除那一格的墨，
    /// 分不出文字浓度 —— 少了这一条，把 `labelColor` 写死也能全绿。
    @MainActor
    func testDisabledTextIsReallyLighterThanEnabledText() throws {
        let strong = try maxTextInk(controlEnabled: true)
        let weak = try maxTextInk(controlEnabled: false)
        XCTAssertGreaterThan(strong, 0.9, "可用档里那行字几乎没有墨：\(strong)")
        XCTAssertLessThan(weak, strong * 3 / 4,
                          "灰掉那档的字还跟可用档一样浓（实测 \(weak) 对 \(strong)）：页面看不出这一格关了")
    }

    /// 清除图标必须跟着外观换墨色：两档下底色一个偏亮一个偏暗。
    @MainActor
    func testRecorderBackgroundStillFollowsAppearance() throws {
        XCTAssertGreaterThan(try background(recorded: true, appearance: .aqua).redComponent, 0.8)
        XCTAssertLessThan(try background(recorded: true, appearance: .darkAqua).redComponent, 0.5)
    }

    /// 选定图标（浅灰圆底 + 次级墨色的叉）× 明暗两档，加一张置空后的参照图，导 PNG 供回看。
    @MainActor
    func testExportClearButtonReference() throws {
        let dir = URL(fileURLWithPath: "/tmp/macstroke-clear-check", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            let suffix = name == .aqua ? "light" : "dark"
            try png(recorded: true, appearance: name)
                .write(to: dir.appendingPathComponent("circleX-\(suffix).png"))
        }
        try png(recorded: false, appearance: .aqua)
            .write(to: dir.appendingPathComponent("cleared-light.png"))
    }

    // MARK: - 脚手架

    /// ⌘⇧A（截图的默认值）：keyCode 0 就是 A，所以这个 fixture 同时踩住「0 有值」这条判空规则。
    private func recordedView() -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        view.keyCode = 0
        view.flags = 0x100000 | 0x20000 // ⌘⇧，和截图默认值同一串
        return view
    }

    private func mount(_ view: NSView, _ appearance: NSAppearance.Name) -> NSWindow {
        let window = NSWindow(contentRect: view.bounds,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        return window
    }

    private func cached(recorded: Bool, appearance: NSAppearance.Name,
                        showsClearButton: Bool = true,
                        controlEnabled: Bool = true) -> (NSBitmapImageRep, ShortcutRecorderView) {
        let view = recorded ? recordedView() : ShortcutRecorderView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        view.showsClearButton = showsClearButton
        view.controlEnabled = controlEnabled
        view.drawAppearance = NSAppearance(named: appearance)
        let window = mount(view, appearance)
        defer { window.orderOut(nil) }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return (rep, view)
    }

    /// 数清除按钮那一格里跟底色对不上的像素。框的描边在 maxX-0.5，所以格子右界收到 maxX-6。
    private func inkCount(recorded: Bool, appearance: NSAppearance.Name,
                          showsClearButton: Bool = true,
                          controlEnabled: Bool = true) -> Int {
        let (rep, view) = cached(recorded: recorded, appearance: appearance,
                                 showsClearButton: showsClearButton, controlEnabled: controlEnabled)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let background = rep.colorAt(x: 30, y: Int(view.bounds.midY * scale))!
            .usingColorSpace(.deviceRGB)!
        let rect = view.clearButtonRect()
        var ink = 0
        for x in stride(from: Int(rect.minX * scale), to: Int((view.bounds.maxX - 6) * scale), by: 1) {
            for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 1) {
                let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if channelDistance(color, background) > 0.15 { ink += 1 }
            }
        }
        return ink
    }

    private func background(recorded: Bool, appearance: NSAppearance.Name) throws -> NSColor {
        let (rep, view) = cached(recorded: recorded, appearance: appearance)
        let y = Int(view.bounds.midY * CGFloat(rep.pixelsWide) / view.bounds.width)
        return try XCTUnwrap(rep.colorAt(x: 30, y: y)?.usingColorSpace(.deviceRGB))
    }

    private func png(recorded: Bool, appearance: NSAppearance.Name) throws -> Data {
        let (rep, _) = cached(recorded: recorded, appearance: appearance)
        let cg = try XCTUnwrap(rep.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: cg)
            .representation(using: .png, properties: [:]))
    }

    private func channelDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    /// 文字那一带（左边内缩 8pt、右到清除格之前）里离底色最远的一个点，三通道差相加。
    /// 取样范围两种状态都用同一个矩形（`clearButtonRect()` 只是几何，跟可见性无关），
    /// 否则比的就不是同一块地方。
    private func maxTextInk(controlEnabled: Bool) throws -> CGFloat {
        let (rep, view) = cached(recorded: true, appearance: .aqua, controlEnabled: controlEnabled)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let background = rep.colorAt(x: 30, y: Int(view.bounds.midY * scale))!
            .usingColorSpace(.deviceRGB)!
        let lo = Int((view.bounds.minX + 8) * scale)
        let hi = Int((view.clearButtonRect().minX - 2) * scale)
        let yLo = Int((view.bounds.minY + 4) * scale)
        let yHi = Int((view.bounds.maxY - 4) * scale)
        var worst: CGFloat = 0
        for x in stride(from: lo, to: hi, by: 1) {
            for y in stride(from: yLo, to: yHi, by: 1) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                worst = max(worst, channelDistance(color, background))
            }
        }
        return worst
    }

    @MainActor
    private func hostedRecorder(_ box: ShortcutTextBox) throws -> ShortcutRecorderView {
        let host = NSHostingView(rootView: RecorderHarness(box: box))
        // 窗口活到用例结束：视图一旦离窗，SwiftUI 不再调用 updateNSView，
        // binding 的改动就同步不进视图。
        retainedWindows.append(mount(host, .aqua))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 60)
        host.layoutSubtreeIfNeeded()
        return try XCTUnwrap(findRecorder(in: host))
    }

    private func findRecorder(in view: NSView) -> ShortcutRecorderView? {
        if let match = view as? ShortcutRecorderView { return match }
        for sub in view.subviews {
            if let found = findRecorder(in: sub) { return found }
        }
        return nil
    }

    /// SwiftUI 把 binding 的改动排到下一个 runloop tick，测试里要自己推一把。
    @MainActor
    private func flushSwiftUI() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }
}

/// 能读回写的 binding 源：`@State` 在测试里读不到，只能挂 ObservableObject。
/// `disabled` 是为了能在**挂好之后**翻外层可用性 —— 真用户就是那个时机改的（先在别处选了档，
/// 再回来关总开关），而那正是只有 `updateNSView` 才走得到的路。
final class ShortcutTextBox: ObservableObject {
    @Published var text: String
    @Published var disabled = false
    init(text: String) { self.text = text }
}

struct RecorderHarness: View {
    @ObservedObject var box: ShortcutTextBox
    var body: some View {
        ShortcutRecorder(text: $box.text)
            .frame(width: 200, height: 28)
            .disabled(box.disabled)
            .environment(\.colorScheme, .light)
    }
}
