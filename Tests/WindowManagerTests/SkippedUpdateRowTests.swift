// 关于页「已跳过的版本」那一行的界面取证（`SkippedUpdateRowView`）。
//
// 这一行报上来的两条症状都是**画出来**的坏，不是模型值的坏：
// 1. 「已跳过版本后面是空的」—— 标题带个冒号，冒号后面压根没有值，跳没跳过都长一个样；
// 2. 「点恢复没反应，按钮还在」—— 点完之后页面上没有任何东西会变，唯一的反馈是一条
//    系统通知（勿扰能整个压掉，NSUserNotification 本身也废弃了）。
// 所以判据一律取位图差值：一个视图说自己显示了什么不算数，它画出来是什么才算数。
//
// 四条各咬一种坏：
// - **S1** 值没画出来（回到修复前那一版：整行只有一个标题）→ 「跳过了 3.2.0」和「什么都没跳过」
//        两张图必须不一样，且右半边的墨量明显更多（版本号五个字符比一个「无」字占墨）。
//        同时左半边（标题那截）必须**没动静** —— 否则说明变的是标题不是值，判据就假了。
// - **S2** 没得恢复时按钮还画成可用 → 按钮那一小块在两种状态下必须不同色（灰 / 不灰）。
//        这一条是「只灰不藏」的落地：格子要留着告诉用户这儿有件事，只是现在没得做。
// - **S3** 点完没反馈 → 通知回来后，行下面那一带必须多出字来，而行自己那一带**一点都不能动**
//        （动了就是结果句把布局顶跑了，用户看到的还是「按钮还在、位置都变了」那种混乱）。
// - **S4** 结果句作废 → 清完又跳过一个版本时，下面那句「已清除」必须消失，
//        否则页面同时说「已清除」和「已跳过的版本：4.1.0」，两句自相矛盾。
//
// 带子是实测出来的（520×120 的离屏宿主，1x）：行占 y 0…0.33，结果句占 y 0.34…0.70。
// 每条判据前面都先有一条「这一带确实有东西在动」的自检，带子跑偏时用例不会假装绿。
// 差值把 alpha 也算进去：离屏宿主是透明底，字只改透明度不改 RGB，只比 RGB 会一路假绿。
// 另有一条不量像素的（`resultText`）：位图只说「多了一行字」，说不出那行字里是版本号
// 还是没替换掉的 `%@` —— 那一句得直接拿文本钉。
import XCTest
import AppKit
import SwiftUI
import Storage
@testable import Preferences

final class SkippedUpdateRowTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.SkippedUpdateRow"
    private static let exportDir = "/tmp/macstroke-skipped-update-check"
    private static let hostSize = NSSize(width: 520, height: 120)

    /// 行那一带（y 比例）。
    private static let rowBand: ClosedRange<Double> = 0.00...0.33
    /// 行下面那句结果的位置。
    private static let noteBand: ClosedRange<Double> = 0.34...0.70
    /// 标题「已跳过的版本：」那一截（左半边）。
    private static let titleSpan: ClosedRange<Double> = 0.00...0.45
    /// 值 + 按钮那一截（右半边）。
    private static let valueSpan: ClosedRange<Double> = 0.45...1.00
    /// 只有按钮那一小块。
    private static let buttonSpan: ClosedRange<Double> = 0.78...1.00

    override func setUp() {
        super.setUp()
        suite().removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        suite().removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    // MARK: - 脚手架

    private struct Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let defaults: UserDefaults
    }

    /// 摆成「跳过过某几版」的状态再挂起来。写的是注入的那份 suite，不碰 `.standard`。
    @MainActor
    private func mount(skipped: [String]) throws -> Mounted {
        let defaults = suite()
        for (index, key) in SparkleSkippedVersions.allKeys.enumerated() where index < skipped.count {
            defaults.set(skipped[index], forKey: key)
        }
        let root = AnyView(SkippedUpdateRowView(defaults: defaults)
            .frame(width: Self.hostSize.width, height: Self.hostSize.height, alignment: .top))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.hostSize)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.hostSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        // SwiftUI 的状态更新排在下一个 runloop 轮次上；不转一下的话抓到的还是空壳
        // （`onAppear` 里那次 reload 没落地，两种状态就都渲成「无」，S1 会假绿）。
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        return Mounted(host: host, window: window, defaults: defaults)
    }

    @MainActor
    private func capture(_ mounted: Mounted, name: String) throws -> NSBitmapImageRep {
        let host = mounted.host
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "这一行渲不出位图：窗口没挂上视图树")
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: Self.exportDir, withIntermediateDirectories: true)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(Self.exportDir)/\(name).png"))
        return rep
    }

    /// 矩形区域内的变化像素 / 墨量。区间都是**比例**（x、y 各一条），写死像素换台机器就飘。
    private func tally(_ rep: NSBitmapImageRep, x: ClosedRange<Double>, y: ClosedRange<Double>,
                       against other: NSBitmapImageRep? = nil) -> (ink: Int, changed: Int) {
        let loX = Int(x.lowerBound * Double(rep.pixelsWide))
        let hiX = min(Int(x.upperBound * Double(rep.pixelsWide)), rep.pixelsWide)
        let loY = Int(y.lowerBound * Double(rep.pixelsHigh))
        let hiY = min(Int(y.upperBound * Double(rep.pixelsHigh)), rep.pixelsHigh)
        var ink = 0
        var changed = 0
        for py in stride(from: loY, to: hiY, by: 1) {
            for px in stride(from: loX, to: hiX, by: 1) {
                guard let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.05 { ink += 1 }
                guard let other else { continue }
                guard let before = other.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                // 透明度必须一起算。离屏宿主没有底色，字是画在**透明底**上的：多出来的那几个
                // 字把 alpha 从 0 抬到 1，RGB 却可以完全相同（都是同一支墨色）。只比 RGB 的话
                // 两张图逐像素「一样」，S1/S3 会红得莫名其妙 —— 实测就是这个坑。
                let delta = max(abs(color.redComponent - before.redComponent),
                                abs(color.greenComponent - before.greenComponent),
                                abs(color.blueComponent - before.blueComponent),
                                abs(color.alphaComponent - before.alphaComponent))
                if delta > 0.03 { changed += 1 }
            }
        }
        return (ink, changed)
    }

    // MARK: - S1 值必须真的画在冒号后面

    /// 「跳过了 3.2.0」和「什么都没跳过」两张图，右半边必须不一样。
    /// 修复前那一版整行只有一个标题，两张图逐像素相同 —— 这条就是钉住那个症状。
    @MainActor
    func testTheSkippedVersionIsActuallyDrawnAfterTheLabel() throws {
        let empty = try capture(try mount(skipped: []), name: "empty")
        let skipped = try capture(try mount(skipped: ["3.2.0"]), name: "skipped-320")

        // 自检：先证明这一带确实有东西在动，再拿它当判据。
        let right = tally(skipped, x: Self.valueSpan, y: Self.rowBand, against: empty)
        XCTAssertGreaterThan(right.changed, 20,
                             "右半边一点没变 —— 说明值根本没画出来（症状：冒号后面是空的）")
        // 版本号五个字符，比一个「无」字占墨多。
        let inkEmpty = tally(empty, x: Self.valueSpan, y: Self.rowBand).ink
        XCTAssertGreaterThan(right.ink, inkEmpty, "多出来的那几个字符没吃到墨")

        // 左半边（标题）必须一点不动：动了就说明变的是标题文字，判据白设。
        let left = tally(skipped, x: Self.titleSpan, y: Self.rowBand, against: empty)
        XCTAssertEqual(left.changed, 0, "标题那一截跟着变了，右半边的差就不能算值的差")
    }

    /// 大版本那一档 Sparkle 会写两格，页面上要显示成两个号（去重后）。
    /// 这条钉的是「值取自三个键」而不是只取第一个 —— 只读 `SUSkippedVersion` 的话，
    /// 跳过大版本的用户看到的还是「无」。
    @MainActor
    func testMajorSkipShowsBothVersions() throws {
        let single = try capture(try mount(skipped: ["3.2.0"]), name: "one-version")
        let both = try capture(try mount(skipped: ["3.2.0", "4.0.0"]), name: "two-versions")
        let region = tally(both, x: Self.valueSpan, y: Self.rowBand, against: single)
        XCTAssertGreaterThan(region.changed, 20, "第二格的大版本号没画出来")
    }

    // MARK: - S2 没得恢复时按钮要灰着（只灰不藏）

    /// 按钮那一小块在两种状态下必须不同色。这一条量的就是「画出来是灰的」，
    /// 不是「SwiftUI 说它 disabled」—— 用户看的只有前者。
    @MainActor
    func testRestoreButtonGreysOutWhenNothingWasSkipped() throws {
        let empty = try capture(try mount(skipped: []), name: "button-enabled-empty")
        let skipped = try capture(try mount(skipped: ["3.2.0"]), name: "button-on-skipped")

        // 自检：整行两版必然有差（值不同），先确认按钮那一格单独也有差。
        let whole = tally(skipped, x: Self.valueSpan, y: Self.rowBand, against: empty)
        XCTAssertGreaterThan(whole.changed, 20, "尺子坏了：右半边整块都没差")
        let button = tally(skipped, x: Self.buttonSpan, y: Self.rowBand, against: empty)
        XCTAssertGreaterThan(button.changed, 20,
                             "按钮那一格两版同色 —— 没得恢复时它没转灰，点了还是没反应")
    }

    // MARK: - S3 点完之后页面上必须留下一句话

    /// 结果句出现时：下面那一带必须多出字来，行自己那一带一点都不能动。
    /// 「行不能动」这半句是这条用例的用处所在 —— 只测「有东西变了」的话，
    /// 布局被顶跑也算过，而用户看到的还是那句「按钮还在」。
    @MainActor
    func testClearingLeavesAnInPlaceResultLine() throws {
        let mounted = try mount(skipped: [])
        let before = try capture(mounted, name: "note-before")

        NotificationCenter.default.post(name: .macStrokeSkippedUpdateDidChange, object: nil,
                                        userInfo: ["cleared": ["3.2.0"], "rechecking": true])
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        mounted.host.layoutSubtreeIfNeeded()
        let after = try capture(mounted, name: "note-after")

        let note = tally(after, x: 0...1, y: Self.noteBand, against: before)
        XCTAssertGreaterThan(note.changed, 30, "行下面没多出任何东西 —— 点完还是没有反馈")
        let row = tally(after, x: 0...1, y: Self.rowBand, against: before)
        XCTAssertEqual(row.changed, 0, "结果句把那一行顶动了，用户看到的还是「点了没反应」那种错位")
    }

    /// 清完以后用户又在更新窗里跳过一个版本，上一句「已清除」必须作废。
    /// 留着不删的话，页面会同时说「已清除 3.2.0」和「已跳过的版本：3.2.1」——
    /// 两句互相打脸，用户更不知道该信哪个（这一行的用处就是说破现状）。
    @MainActor
    func testTheResultLineGoesAwayWhenSomethingGetsSkippedAgain() throws {
        let mounted = try mount(skipped: ["3.2.0"])
        let first = try capture(mounted, name: "stale-note-start")

        NotificationCenter.default.post(name: .macStrokeSkippedUpdateDidChange, object: nil,
                                        userInfo: ["cleared": ["3.2.0"], "rechecking": false])
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        mounted.host.layoutSubtreeIfNeeded()
        let withNote = try capture(mounted, name: "stale-note-shown")
        XCTAssertGreaterThan(tally(withNote, x: 0...1, y: Self.noteBand, against: first).changed, 30,
                             "前置条件没成立：结果句根本没出现，后面那句「作废」就无从证明")

        // 重新跳过大版本，并模拟 Sparkle 写盘后的 didChange 通知。
        mounted.defaults.set("4.1.0", forKey: SparkleSkippedVersions.majorKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: mounted.defaults)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        mounted.host.layoutSubtreeIfNeeded()
        let after = try capture(mounted, name: "stale-note-cleared")

        let band = tally(after, x: 0...1, y: Self.noteBand, against: first)
        XCTAssertEqual(band.changed, 0, "那句「已清除」还赖在下面 —— 和新出现的跳过记录自相矛盾")
        // 值那一截必须同时把新跳过的号画出来（否则这条只是在测「删了字」）。
        XCTAssertGreaterThan(tally(after, x: 0...1, y: Self.rowBand, against: first).changed, 20,
                             "新跳过的版本号没画出来")
    }

    // MARK: - 那句话说的是**哪个版**（像素量不出字形，只能直接钉文本）

    /// 位图只能证明「下面多出一行字」，证明不了那行字里写的是版本号还是没被替换的 `%@`。
    /// 两种回执（自动检查会补上 / 不会）也必须分得开 —— 用户据此决定要不要再按一次
    /// 「立即检查更新」，写成同一句就等于没说。
    @MainActor
    func testTheResultLineNamesTheVersion() throws {
        let plain = SkippedUpdateRowView.resultText(cleared: ["3.2.0"], rechecking: false)
        XCTAssertTrue(plain.contains("3.2.0"), "结果句没把版本号拼进去：\(plain)")
        XCTAssertFalse(plain.contains("%@"), "占位符没被替换：\(plain)")

        let rechecking = SkippedUpdateRowView.resultText(cleared: ["3.2.0", "4.0.0"], rechecking: true)
        XCTAssertTrue(rechecking.contains("3.2.0, 4.0.0"), "两个号没都写进回执：\(rechecking)")
        XCTAssertFalse(rechecking.contains("%@"), "占位符没被替换：\(rechecking)")
        XCTAssertNotEqual(rechecking, plain, "有没有补一次检查写成同一句，等于没告诉用户下一步")
    }
}
