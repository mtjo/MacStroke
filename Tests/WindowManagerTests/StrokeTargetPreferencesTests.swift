//
//  StrokeTargetPreferencesTests.swift
//  MacStroke
//
//  issue #22 的界面侧取证：「手势打到光标下的窗口」那一段（画在改名后的「右键增强」页里，
//  紧接滚轮那一段下方）。
//
//  判据一律取**位图差值**，不读页面自己的状态：一个 SwiftUI 控件说自己禁用了，和它画出来
//  是灰的，是两件事 —— 用户看的只有后者。这一段的两颗都是真 SwiftUI `Toggle`（不像滚轮那段的
//  `ShortcutRecorder` 是 NSView），`.disabled` 既画灰也挡点击，所以这里量的是**画出来**那一半，
//  并把「挡点击」留给系统那一侧保证 —— 但下面第 3 条用另一个角度咬住同一件事：灰档下拨这颗开关，
//  动幅必须明显小于亮档（暗底上的滑块位移对比度低），`.disabled` 一旦没接上，两者就一样大。
//
//  四条各咬一种坏：
//  - **S1** 总开关只灰自己那一行 → 关掉它，还焦那一行必须画成灰（113 个点）。不灰就是
//          「功能关着还能配还焦」，用户改完以为配好了。
//  - **S2** 两行接成同一份绑定 → 拨还焦时总开关那一行必须没动静；反过来（S1）关掉总开关时
//          还焦行动的必须是「灰」而不是「值」。
//  - **S3** `.disabled` 没传到这颗开关的渲染 → 灰档与亮档各拨一次，差值点数必须差几倍。
//  - **S4** 新段把上面两段带得动（共用绑定，或页面整体重排）→ 滚轮整段与两张 Finder 卡片
//          在带子里必须没动静。
//  外加三条静态的：段里的两条小字与段下方那一带（还焦行以下）在任何一次拨开关里都不许动 ——
//  动了说明整页重排，本文件**所有**带子都跑偏；文案表里这五个 key 查得到（查不到就把 key 原文
//  画在页面上），且两行标题不撞车。
//
//  带子全是**实测**出来的（1x 离屏位图、页高 1000、`apply` 显式写两档）：
//  总开关滑块 y 599…620、两条 hint 与分隔线 y 626…700、还焦滑块 y 706…727。
//  每条判据前面先有带子自证（这一带里真的画出了东西），带子跑偏时用例不会假装绿。
//  实测差值：S1 关总开关 → 自己那行 174、还焦那行 113；S2 拨还焦 → 自己那行 178、总开关行 0；
//  S3 关着拨还焦 → 25（开着拨是 178）；两版自比的噪声地板 0。
//

import XCTest
import AppKit
import SwiftUI
import Storage
@testable import Preferences

final class StrokeTargetPreferencesTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.StrokeTargetPrefs"
    private static let exportDir = "/tmp/macstroke-stroke-target-check"
    private static let pageSize = NSSize(width: 760, height: 1000)

    override func setUp() {
        super.setUp()
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func isolatedSuite() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    private func makePrefs() -> UserPreferences {
        UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
    }

    /// 两个值**都必须显式写**：`restore` 的默认是 true，而 `UserDefaults.bool` 对从没落盘的键返回
    /// false —— 忘了写的话，「灰」与「不灰」两次渲染比的其实是被上一个用例遗留的那个值，
    /// 于是判据恒绿（M132 那一回全绿就是这么来的）。
    @discardableResult
    private func apply(enabled: Bool, restore: Bool) -> UserPreferences {
        let prefs = makePrefs()
        prefs.strokeTargetsCursorWindow = enabled
        prefs.strokeTargetRestoresFocus = restore
        return prefs
    }

    // MARK: - 渲染与差分

    /// 一次比对的两种计数：这一带画了多少个不透明的点，和两版之间差了多少个点。
    private struct Diff { let ink: Int; let changed: Int }

    /// 上面两张 Finder 卡片（这一段的一切都不许把它们带得动）。
    private static let finderCardsBand = 0.000 ... 0.240
    /// 滚轮那整段（同上：新段与它共用了什么就该在这里红）。
    private static let wheelSectionBand = 0.280 ... 0.598
    /// 「手势打到光标下的窗口」总开关自己那一行。
    private static let masterRowBand = 0.598 ... 0.626
    /// 段里的两条小字 + 分隔线：静态文案，任何一次拨开关都不该让它动。
    private static let hintsBand = 0.626 ... 0.700
    /// 「投完把焦点还回去」那一行。
    private static let restoreRowBand = 0.700 ... 0.730
    /// 还焦行以下到页尾：这一段底下没有别的东西，动了就是整页重排。
    private static let belowSectionBand = 0.730 ... 1.000

    /// `band` 是**页高比例**区间（不是像素）：同一页在 1x 离屏位图里是 1000 高，
    /// 挂到 Retina 屏上渲出来就是 2000 高，写死像素的判据换台机器就飘。
    private func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                               name: String, band: ClosedRange<Double>) throws -> Diff {
        XCTAssertEqual(a.pixelsWide, b.pixelsWide, "\(name)：两版宽度不一样，说明布局被重排了")
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh, "\(name)：两版高度不一样，说明布局被重排了")
        let lo = Int(band.lowerBound * Double(a.pixelsHigh))
        let hi = Int(band.upperBound * Double(a.pixelsHigh))
        var ink = 0
        var changed = 0
        for y in stride(from: lo, to: min(hi, a.pixelsHigh), by: 2) {
            for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                guard let left = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let right = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if left.alphaComponent > 0.01 { ink += 1 }
                let delta = max(abs(left.redComponent - right.redComponent),
                                abs(left.greenComponent - right.greenComponent),
                                abs(left.blueComponent - right.blueComponent))
                if delta > 0.03 { changed += 1 }
            }
        }
        return Diff(ink: ink, changed: changed)
    }

    private func render(name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: RightClickMenuTabView(viewModel: makePrefs()))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.pageSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: Self.pageSize)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        host.needsDisplay = true

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "这一页渲不出位图：窗口没挂上视图树")
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: Self.exportDir,
                                                withIntermediateDirectories: true)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(Self.exportDir)/\(name).png"))
        return rep
    }

    /// 带子里得真的画出了东西，差值才作数。
    /// 说清楚这一条能证明什么：卡片的底是不透明的，所以「有墨」在任何状态下都成立 ——
    /// 它挡的是「整页压根没渲出来」（挂不上视图树、`RightClickMenuTabView` 改名、页面空白），
    /// 挡不住「这一行的控件没画」。后一半由每条判据前面的**差值自检**来担（S1 第一句、S2 第一句）。
    private func assertRendered(_ diff: Diff, name: String) {
        XCTAssertGreaterThan(diff.ink, 200, "\(name)：这一带几乎没画出东西，差值不作数")
    }

    // MARK: - S1 总开关要灰掉还焦那一行

    /// 关掉总开关，「投完把焦点还回去」那一行必须画成灰 —— 关着的时候压根没有「跳过去」这回事，
    /// 也就没有「还」；那一行亮着就是骗人。
    func testMasterSwitchGreysTheRestoreRow() throws {
        apply(enabled: true, restore: true)
        let on = try render(name: "target-master-on")
        apply(enabled: false, restore: true)
        let off = try render(name: "target-master-off")

        let master = try changedPixels(on, off, name: "开关自己", band: Self.masterRowBand)
        assertRendered(master, name: "总开关行")
        XCTAssertGreaterThan(master.changed, 20,
                             "总开关滑块没动：这一段的绑定压根没接上，后面的判据都不作数")
        // 差值自检的另一半：还焦行在两版里都是「开」，所以这里动的只可能是**灰**。
        let restore = try changedPixels(on, off, name: "还焦行跟着灰", band: Self.restoreRowBand)
        assertRendered(restore, name: "还焦行")
        XCTAssertGreaterThan(restore.changed, 20,
                             "关掉总开关，还焦那一行没灰：还能拨，拨了也不生效（实测 113 个点）")
        // 静态文案不动 + 段下方不动（动了就是整页重排，本文件所有带子都跑偏）。
        XCTAssertLessThan(try changedPixels(on, off, name: "两条小字不动",
                                            band: Self.hintsBand).changed, 20,
                          "关掉总开关把段里的小字也改了：带子不再可信")
        XCTAssertLessThan(try changedPixels(on, off, name: "段下方不动",
                                            band: Self.belowSectionBand).changed, 20,
                          "关掉总开关把这一页下面顶动了")
    }

    // MARK: - S2 两行各管各的绑定

    /// 总开关开着时拨还焦：只许还焦那一行动，总开关那一行必须没动静。
    /// 两个开关系到同一份绑定时（把 `$viewModel.strokeTargetRestoresFocus` 写成
    /// `$viewModel.strokeTargetsCursorWindow`）这里必红，而且是「一拨全拨」那种最难受的坏法。
    func testRestoreSwitchMovesItsOwnRowOnly() throws {
        apply(enabled: true, restore: true)
        let on = try render(name: "target-restore-on")
        apply(enabled: true, restore: false)
        let off = try render(name: "target-restore-off")

        let restore = try changedPixels(on, off, name: "还焦自己", band: Self.restoreRowBand)
        assertRendered(restore, name: "还焦行")
        XCTAssertGreaterThan(restore.changed, 20,
                             "拨还焦那一行没动静：这颗开关没接绑定，或者档位压根没落盘")
        XCTAssertLessThan(try changedPixels(on, off, name: "拨还焦时总开关不动",
                                            band: Self.masterRowBand).changed, 20,
                          "拨还焦把总开关也带着动：两行接在同一份绑定上")
        XCTAssertLessThan(try changedPixels(on, off, name: "小字不动",
                                            band: Self.hintsBand).changed, 20)
        XCTAssertLessThan(try changedPixels(on, off, name: "段下方不动",
                                            band: Self.belowSectionBand).changed, 20)
    }

    // MARK: - S3 灰是真的灰（不是只少了个边框）

    /// 同一行、同样拨一次，**总开关关着**时的动幅必须明显小于开着时 —— 因为那时滑块是暗的，
    /// 位移带来的对比点数少。`SystemFocusControl` 那侧的闸由 CursorTargetTests 验；
    /// 这一条验的是「`.disabled` 到底传到这颗开关的渲染没有」：没传的话两档动幅一样（实测 178 对 25）。
    func testGreyedRestoreRowHasLessContrastThanLiveOne() throws {
        apply(enabled: true, restore: true)
        let liveOn = try render(name: "target-live-on")
        apply(enabled: true, restore: false)
        let liveOff = try render(name: "target-live-off")
        // 上面两版：总开关开着。下面两版：总开关关着，还焦行应当是灰的。
        apply(enabled: false, restore: true)
        let greyOn = try render(name: "target-grey-on")
        apply(enabled: false, restore: false)
        let greyOff = try render(name: "target-grey-off")

        let live = try changedPixels(liveOn, liveOff, name: "亮档拨一次", band: Self.restoreRowBand)
        assertRendered(live, name: "还焦行（亮）")
        let grey = try changedPixels(greyOn, greyOff, name: "灰档拨一次", band: Self.restoreRowBand)
        XCTAssertGreaterThan(live.changed, 20, "亮档拨还焦没画出动静：带子跑偏，比值判据不作数")
        XCTAssertLessThan(grey.changed * 2, live.changed,
                          "灰档拨一次动幅不比亮档小：`.disabled` 没传到这颗开关（实测 25 对 178）")
    }

    // MARK: - S4 不许把上面两段带得动

    /// 这一段是新加在滚轮段下面的。两处判据：关掉总开关、拨还焦，都只许动本段那两行 ——
    /// 坏法是「两段的绑定共用了」或「加了新段之后整页重排」（`changedPixels` 里那两条
    /// 高度相等断言只挡得住重排挡不住共键）。
    func testTheStrokeTargetSwitchesDoNotTouchTheSectionsAbove() throws {
        apply(enabled: true, restore: true)
        let on = try render(name: "target-neighbours-on")
        apply(enabled: false, restore: true)
        let masterOff = try render(name: "target-neighbours-master-off")
        apply(enabled: true, restore: false)
        let restoreOff = try render(name: "target-neighbours-restore-off")

        for (label, other) in [("关总开关", masterOff), ("拨还焦", restoreOff)] {
            let wheel = try changedPixels(on, other, name: "\(label)时滚轮段不动",
                                          band: Self.wheelSectionBand)
            assertRendered(wheel, name: "滚轮段")
            XCTAssertLessThan(wheel.changed, 20, "\(label)把滚轮那一段也改了：两段共用了绑定")
            let finder = try changedPixels(on, other, name: "\(label)时 Finder 卡片不动",
                                           band: Self.finderCardsBand)
            assertRendered(finder, name: "Finder 卡片")
            XCTAssertLessThan(finder.changed, 20, "\(label)把上面两张 Finder 卡片也改了")
        }
    }

    // MARK: - 文案

    /// 段里每一行都要在文案表里（漏一条就把 key 原文画在页面上）。
    /// 这里查的是**当前界面语言**那一套；中英文两套的键齐全由装机前的 `Localizable.strings`
    /// 对表保证，像素这边只验「查得到、且不是 key 原文」。
    func testEveryRowInTheSectionHasCopy() {
        for key in ["Stroke Target", "Stroke Target master", "Stroke Target master hint",
                    "Stroke Target restore row", "Stroke Target restore hint"] {
            XCTAssertFalse(L(key).isEmpty, "\(key) 没进文案表")
            XCTAssertNotEqual(L(key), key, "\(key) 查不到，页面上会露出 key 原文")
        }
        // 两行的标题不许撞车：撞了用户就分不清哪颗是总开关（真出了事，日志里也只有一行行标题）。
        XCTAssertNotEqual(L("Stroke Target master"), L("Stroke Target restore row"))
    }
}
