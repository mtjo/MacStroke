//
//  WheelGesturePreferencesTests.swift
//  MacStroke
//
//  issue #75 的界面侧取证：「按住起手键 + 滚轮」那一段（画在改名后的「右键增强」页里）。
//
//  判据一律取**位图差值**，不读页面自己的状态：一个 SwiftUI 控件说自己禁用了，和它画出来
//  是灰的，是两件事 —— 用户看的只有后者。这里还多一层：`ShortcutRecorder` 是
//  `NSViewRepresentable`，SwiftUI 的 `.disabled` 既不把它画灰、也不挡它的 `mouseDown`，
//  所以「这一格现在用不用得上」必须由视图按环境值自己画、自己决定点不点得动
//  （`ShortcutRecorderView.controlEnabled`）。第 2 条用例量的就是这件事的**画出来**那一半，
//  点不动那一半在 ShortcutRecorderClearButtonTests 里量状态。
//
//  五条各咬一种坏：
//  - **W1** 总开关只灰自己那一行 → 两个下拉各钉一条「必须变灰」，整段差值还要明显大于
//          「只动一行」那一档（尺子本身也换了一整行的字，所以倍数只取 1.5×，实测 266 对 128）
//  - **W2** 总开关没把两个录入框一起灰掉（NSView 那侧收不到环境值就是这种坏）
//  - **W3** 上下两个下拉接成同一份绑定 → 只换上滚 与 只换下滚 必须互不相同，
//          且**各自动自己那一行**（另一行在带子里必须没动静）
//  - **W4** 录入框不看自己那一档 / 串没接到自己那格（两条带子左右各钉一头）；
//          另加一条专咬 binding 写串（四个互不相同的键，只改一头看另一头 —— 反向变异 P2）
//  - **W5** 那句「两个方向都没配动作」的橙字常驻或压根没画
//  每条都拿「另一档状态」当参照物，不数绝对阈值 —— 这个套路是从 M52 那一回学来的：
//  当时只看「整页有没有差」，开关自己那一小块的差把「滑杆没灰」整个盖掉，变异跑完全绿。
//
//  带子全是**实测**出来的（1x 离屏位图、页高 1000）：每条判据前面先有一条带子自检，
//  先证明这一带里确实有东西在动，才拿它去判灰没灰。带子跑偏时用例不会假装绿。
//

import XCTest
import AppKit
import SwiftUI
import Storage
@testable import Preferences
@testable import RuleEngine

final class WheelGesturePreferencesTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.WheelGesturePrefs"
    private static let exportDir = "/tmp/macstroke-wheel-gesture-check"
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

    /// 把段里那几颗控件一次摆成一种状态。走 `UserPreferences` 而不是直接写库：
    /// 要连 `didSet` 那段写盘一起验，少接一根线就是「界面动了库没动」。
    ///
    /// 每条用例都显式写 `enabled`：默认是「关」，忘了写的话「灰」与「不灰」两次渲染比的
    /// 其实是被上一个用例遗留的那个值（M132 那一回全绿就是这么来的）。
    @discardableResult
    private func apply(enabled: Bool = true, up: WheelGestureActionKind = .tabPrevious,
                       down: WheelGestureActionKind = .tabNext,
                       upShortcut: String = "", downShortcut: String = "") -> UserPreferences {
        let prefs = makePrefs()
        prefs.wheelGestureEnabled = enabled
        prefs.wheelGestureUpAction = up.rawValue
        prefs.wheelGestureDownAction = down.rawValue
        prefs.wheelGestureUpShortcut = upShortcut
        prefs.wheelGestureDownShortcut = downShortcut
        return prefs
    }

    // MARK: - 渲染与差分

    /// 一次比对的两种计数：这一带画了多少有内容的点，和两版之间差了多少个点。
    private struct Diff { let ink: Int; let changed: Int }

    // 实测（1x，页高 1000）：总开关滑块 y 254…274、上拉 y 338…352、下拉 y 416…432、
    // 上录入框 y 456…468、下录入框 y 522…534、卡片外那句橙字 y 556…568。
    /// 上面两张 Finder 卡片（这一段的一切都不许把它们带得动）。
    private static let finderCardsBand = 0.00 ... 0.24
    /// 总开关自己那一行。
    private static let masterRowBand = 0.24 ... 0.28
    /// 「上滚」那一行（行标题 + 动作下拉）。
    private static let upRowBand = 0.325 ... 0.36
    /// 「下滚」那一行。
    private static let downRowBand = 0.405 ... 0.44
    /// 「上滚的快捷键」那一行（行标题 + 录入框）。
    private static let upShortcutBand = 0.45 ... 0.475
    /// 「下滚的快捷键」那一行。
    private static let downShortcutBand = 0.515 ... 0.54
    /// 卡片以下那一句橙字。
    private static let warningBand = 0.548 ... 0.60
    /// 总开关**以下**整段（两个下拉、两个录入框、那句橙字）—— W1 的度量带。
    private static let belowMasterBand = 0.30 ... 0.60

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

    // MARK: - W1 总开关要灰整段

    /// 关掉总开关，两个动作下拉都得画成不可用 —— 只灰开关自己那一行的话，
    /// 用户还能改下拉，改完以为配好了（而运行时那条滚轮监听根本没上膛）。
    func testMasterSwitchGreysTheWholeWheelSection() throws {
        apply(enabled: true)
        let on = try render(name: "wheel-master-on")
        apply(enabled: false)
        let off = try render(name: "wheel-master-off")
        // 尺子：只让「上滚」那一行动（其余全一样）—— 这一档的差值就是「一行在动」的量级。
        apply(enabled: true, up: .volumeUp)
        let oneRow = try render(name: "wheel-one-row-only")

        XCTAssertGreaterThan(try changedPixels(on, off, name: "开关自己",
                                               band: Self.masterRowBand).changed, 20,
                             "总开关滑块没动：这一段的绑定压根没接上，后面的判据都不作数")
        XCTAssertGreaterThan(try changedPixels(on, off, name: "上滚那一行",
                                               band: Self.upRowBand).changed, 20,
                             "关掉总开关，上滚的下拉没灰：还能选，选了也不生效")
        XCTAssertGreaterThan(try changedPixels(on, off, name: "下滚那一行",
                                               band: Self.downRowBand).changed, 20,
                             "关掉总开关，下滚的下拉没灰")
        let whole = try changedPixels(on, off, name: "整段", band: Self.belowMasterBand)
        let single = try changedPixels(on, oneRow, name: "只一行", band: Self.belowMasterBand)
        XCTAssertGreaterThan(whole.changed, 200, "这一页几乎没画出来，差值不作数：\(whole.changed)")
        // 尺子那一档本身就把一整行换了字（实测 128 个点），所以「两行都在灰」只能到 ~2 倍
        // （实测 266）。写成 3 倍会红在桩件的账上而不是页面的账上：那条坏法（总开关只灰
        // 自己那一行）真正的判据是上面两条**分行**判据 —— 那时两个下拉一格都没灰。
        XCTAssertGreaterThan(whole.changed, single.changed * 3 / 2,
                             "关掉总开关的整段差值不比「只动一行」大：多半只灰了一行")
        // 再钉一次「不是只灰上滚那一行」：下滚那一行自己也得有动静（上面那条已量过 86 个点）。
        XCTAssertGreaterThan(try changedPixels(on, off, name: "下滚行的量级",
                                               band: Self.downRowBand).changed, single.changed / 3,
                             "下滚那一行只动了一点点：整段里其实只有一行在灰")
    }

    /// 关掉总开关不许把上面那两张 Finder 卡片带得动 —— 两段的绑定共用了，或者
    /// 页面整体重排了（`changedPixels` 里那两条高度相等断言只挡得住重排）。
    func testTheWheelSwitchDoesNotTouchTheFinderCardsAboveIt() throws {
        apply(enabled: true)
        let on = try render(name: "wheel-finder-on")
        apply(enabled: false)
        let off = try render(name: "wheel-finder-off")
        XCTAssertGreaterThan(try changedPixels(on, off, name: "上面卡片有内容",
                                               band: Self.finderCardsBand).ink, 200,
                             "Finder 那两张卡片没画出来：这一带的判据不作数")
        XCTAssertLessThan(try changedPixels(on, off, name: "上面卡片不动",
                                            band: Self.finderCardsBand).changed, 20,
                          "滚轮段的开关把上面两张卡片也改了")
    }

    // MARK: - W2 两个录入框也跟着灰（NSView 那侧收得到环境值吗）

    /// `.disabled` 套在 `NSViewRepresentable` 上不会画灰，也不会挡 `mouseDown` ——
    /// 灰必须由 `ShortcutRecorderView.controlEnabled` 自己画。这条量的就是「画出来」那一半：
    /// 两档都选了「自定义快捷键」、键也录好了，这时候关掉总开关，两个录入框里那串字必须变淡。
    func testBothRecordersGreyWithTheMasterSwitch() throws {
        let keyUp = "keyCode=9, flags=1048576"
        let keyDown = "keyCode=8, flags=1048576"
        apply(enabled: true, up: .customShortcut, down: .customShortcut,
              upShortcut: keyUp, downShortcut: keyDown)
        let on = try render(name: "wheel-rec-on")
        apply(enabled: false, up: .customShortcut, down: .customShortcut,
              upShortcut: keyUp, downShortcut: keyDown)
        let off = try render(name: "wheel-rec-off")

        XCTAssertGreaterThan(try changedPixels(on, off, name: "上录入框",
                                               band: Self.upShortcutBand).changed, 20,
                             "关掉总开关，上滚的录入框没灰：SwiftUI 的 .disabled 没传到 NSView")
        XCTAssertGreaterThan(try changedPixels(on, off, name: "下录入框",
                                               band: Self.downShortcutBand).changed, 20,
                             "关掉总开关，下滚的录入框没灰")
    }

    // MARK: - W3 上下两档各管各行

    /// 两个下拉接成同一份绑定时，只换上滚和只换下滚会渲出**一模一样**的图（同一行在动）。
    /// 于是这里既比「两版互不相同」，也各自动自己那一行：另一行在带子里必须没动静。
    func testEachDirectionPickerMovesItsOwnRowOnly() throws {
        apply(enabled: true)
        let base = try render(name: "wheel-dirs-base")
        apply(enabled: true, up: .volumeUp)
        let upChanged = try render(name: "wheel-dirs-up")
        apply(enabled: true, down: .volumeUp)
        let downChanged = try render(name: "wheel-dirs-down")

        // 带子自检：只换上滚 → 上滚那一行必须动（这条同时证明下拉真的画的是库里的值）。
        XCTAssertGreaterThan(try changedPixels(base, upChanged, name: "上滚带自检",
                                               band: Self.upRowBand).changed, 20,
                             "换了上滚的动作，上滚那一行没动静：带子跑偏或下拉没接绑定")
        XCTAssertGreaterThan(try changedPixels(base, downChanged, name: "下滚带自检",
                                               band: Self.downRowBand).changed, 20,
                             "换了下滚的动作，下滚那一行没动静")
        // 另一行不许跟着动：共用了绑定就是这里红。
        XCTAssertLessThan(try changedPixels(base, upChanged, name: "只换上滚时下滚行不动",
                                            band: Self.downRowBand).changed, 20,
                          "只换上滚，下滚那一行也改了：两个下拉接在同一份绑定上")
        XCTAssertLessThan(try changedPixels(base, downChanged, name: "只换下滚时上滚行不动",
                                            band: Self.upRowBand).changed, 20,
                          "只换下滚，上滚那一行也改了")
        XCTAssertGreaterThan(try changedPixels(upChanged, downChanged, name: "两版互不相同",
                                               band: Self.belowMasterBand).changed, 20,
                             "只换上滚与只换下滚渲出来一样")
    }

    // MARK: - W4 录入框只跟自己那一档

    /// 上滚选了「自定义快捷键」→ 只有上滚那个录入框亮起来；下滚那一格保持灰。
    /// 反过来的坏法有两种：录入框只看总开关（档没选到自定义也亮着，录完不生效）、
    /// 或者两个框共用了状态（一灰全灰、一亮全亮）。
    func testRecorderLightsUpOnlyForItsOwnDirection() throws {
        let recorded = "keyCode=9, flags=1048576"
        apply(enabled: true, up: .customShortcut, upShortcut: recorded)
        let upCustom = try render(name: "wheel-rec-up-custom")
        apply(enabled: true, down: .customShortcut, downShortcut: recorded)
        let downCustom = try render(name: "wheel-rec-down-custom")

        // 同一份已录的键、同一个档位，只换一个方向 → 差值只该出现在那一行。
        XCTAssertGreaterThan(try changedPixels(upCustom, downCustom, name: "上录入框跟着档",
                                               band: Self.upShortcutBand).changed, 20,
                             "上滚从自定义换成预设，上滚的录入框没变灰")
        XCTAssertGreaterThan(try changedPixels(upCustom, downCustom, name: "下录入框跟着档",
                                               band: Self.downShortcutBand).changed, 20,
                             "下滚从预设换成自定义，下滚的录入框没亮起来")
        // 串要接到**自己那一格**：两格共用了绑定会出现「两个框显示同一个键」。
        apply(enabled: true, up: .customShortcut, down: .customShortcut,
              upShortcut: recorded, downShortcut: "")
        let upOnlyFilled = try render(name: "wheel-rec-up-only-filled")
        apply(enabled: true, up: .customShortcut, down: .customShortcut,
              upShortcut: "", downShortcut: recorded)
        let downOnlyFilled = try render(name: "wheel-rec-down-only-filled")
        XCTAssertGreaterThan(try changedPixels(upOnlyFilled, downOnlyFilled, name: "两格各显示各的键",
                                               band: Self.belowMasterBand).changed, 20,
                             "把键只写进上格和只写进下格，渲出来一样：两个录入框共用了串")
    }

    /// W3 钉的是「动作下拉」各接各的绑定，这条钉「快捷键录入框」：上滚那格录的键
    /// 只许落在上滚那一行（反向变异表里 P2 上一轮漏的就是这一条）。
    ///
    /// 为什么上面那条 W4 抓不到串线：它两个方向填的是**同一个** keycode，
    /// `ShortcutRecorder(text: $wheelGestureUpShortcut)` 与 `$wheelGestureDownShortcut` 一旦写串，
    /// 页面画出来的字还是一模一样 —— 判据看不见任何差别。这条用四个互不相同的键，
    /// 只改一个方向，要求「自己那一行动、另一行不动」同时成立。
    /// 坏法发生在 `PreferencesView` 里那两个 `ShortcutRecorder(text:)` 的 binding：
    /// 用户给上滚录的键存进了下滚那格，issue #75 要的「两条独立触发」当场退化成一条。
    func testEachDirectionRecorderFollowsItsOwnShortcut() throws {
        // 两个方向各先钉一个「光杆 ⌘ + 一个字母」，改动版一律加满四个修饰键
        // （0x100000|0x80000|0x40000|0x20000）：这样那一行的字一定挪位，带子里点数得到。
        // 只换一个字母（⌘V→⌘X）不算：录入框居中排字，改一个字形采不到 20 个点，自检会假红。
        let upKey = "keyCode=9, flags=1048576"             // ⌘V
        let otherUpKey = "keyCode=9, flags=1966080"        // ⌘⌥⌃⇧V
        let downKey = "keyCode=8, flags=1048576"           // ⌘C
        let otherDownKey = "keyCode=8, flags=1966080"      // ⌘⌥⌃⇧C

        apply(enabled: true, up: .customShortcut, down: .customShortcut,
              upShortcut: upKey, downShortcut: downKey)
        let base = try render(name: "wheel-rec-binding-base")

        apply(enabled: true, up: .customShortcut, down: .customShortcut,
              upShortcut: otherUpKey, downShortcut: downKey)
        let upChanged = try render(name: "wheel-rec-binding-up")

        apply(enabled: true, up: .customShortcut, down: .customShortcut,
              upShortcut: upKey, downShortcut: otherDownKey)
        let downChanged = try render(name: "wheel-rec-binding-down")

        // 带子自检：先证明这一带里确实有字在动，才拿它去判串没串。
        XCTAssertGreaterThan(try changedPixels(base, upChanged, name: "上录入带自检",
                                               band: Self.upShortcutBand).changed, 20,
                             "改了上滚那格录的键，上滚那一行没动静：录入框没吃到上滚那格的绑定")
        XCTAssertGreaterThan(try changedPixels(base, downChanged, name: "下录入带自检",
                                               band: Self.downShortcutBand).changed, 20,
                             "改了下滚那格录的键，下滚那一行没动静")
        // 另一行不许跟着动：接串了就是这里红。
        XCTAssertLessThan(try changedPixels(base, upChanged, name: "只改上滚时下滚行不动",
                                            band: Self.downShortcutBand).changed, 20,
                          "只改上滚的键，下滚那一行也改了：两个录入框接的是同一份绑定")
        XCTAssertLessThan(try changedPixels(base, downChanged, name: "只改下滚时上滚行不动",
                                            band: Self.upShortcutBand).changed, 20,
                          "只改下滚的键，上滚那一行也改了")
    }

    // MARK: - W5 那句橙字只在「开着但两档都空」时出现

    /// 两档都选「无」是「功能开着却什么都不会发生」的唯一一种配法，界面上必须说破。
    /// 三条判据合起来挡三种坏：那句没画、常驻、以及只看档位不看总开关（关着还在喊）。
    func testTheNoActionWarningAppearsOnlyWhenTheFeatureIsOnAndBothDirectionsAreEmpty() throws {
        apply(enabled: true)
        let preset = try render(name: "wheel-warn-default")
        apply(enabled: true, up: .none, down: .none)
        let bothNone = try render(name: "wheel-warn-both-none")
        apply(enabled: true, up: .none, down: .volumeUp)
        let oneConfigured = try render(name: "wheel-warn-one-configured")
        apply(enabled: false, up: .none, down: .none)
        let bothNoneOff = try render(name: "wheel-warn-both-none-off")

        // 带子自检 + 有橙字（实测 503 个点 / 0 个点两档）。
        XCTAssertGreaterThan(try changedPixels(preset, bothNone, name: "橙字出现",
                                               band: Self.warningBand).changed, 20,
                             "两档都选了「无」，卡片下面那句提醒没画出来")
        // 只配一个方向就不该再喊 —— 拿同样「没喊」的默认档当参照物（两次都比的是卡片以下，
        // 那一带里除了这句没有别的东西在动）。
        XCTAssertLessThan(try changedPixels(preset, oneConfigured, name: "配了一个就不喊",
                                            band: Self.warningBand).changed, 20,
                          "下滚配了动作，那句还挂着：常驻的话下面那条判据都不作数")
        XCTAssertGreaterThan(try changedPixels(bothNone, oneConfigured, name: "一配上去就撤",
                                               band: Self.warningBand).changed, 20,
                             "把下滚配成有动作，那句橙字没撤掉")
        // 总开关关着时不喊（那时候整段都是灰的，喊了反而误导）。
        XCTAssertLessThan(try changedPixels(preset, bothNoneOff, name: "开关关着不喊",
                                            band: Self.warningBand).changed, 20,
                          "总开关没开也把那句说出来了：那句的条件没看总开关")
    }

    /// 「自定义快捷键」但录入框空着，和选「无」一样什么都不会发生 —— 那句提醒必须一起算进来。
    /// 判据取卡片以下那一带：档位换成自定义会让录入框亮（在卡片里，带子之外），
    /// 所以这一带里唯一在动的就是那句橙字。
    func testEmptyCustomShortcutsAlsoTriggerTheWarning() throws {
        apply(enabled: true, up: .customShortcut, down: .customShortcut)
        let bothEmpty = try render(name: "wheel-warn-custom-empty")
        apply(enabled: true, up: .customShortcut, down: .customShortcut,
              upShortcut: "keyCode=9, flags=1048576")
        let oneFilled = try render(name: "wheel-warn-custom-one-filled")

        XCTAssertGreaterThan(try changedPixels(bothEmpty, oneFilled, name: "录进一个键后撤掉",
                                               band: Self.warningBand).changed, 20,
                             "两格都选了自定义但没录键时没提醒；录进一个键也没撤掉")
    }

    // MARK: - 侧栏与文案

    /// 这一页改名「右键增强」（issue #75 提的：现在这一页不止 Finder 右键菜单了），
    /// 但**另一页** `.rightClick`「模拟右键」不许跟着一起改 —— 两页一旦同名，用户会以为
    /// 它们是同一件事的两半，改完名单还跑到这一页来找滚轮设置。
    func testTheRenamedPageStaysDistinctFromTheOtherRightClickPage() throws {
        let extras = PreferencesTab.rightClickMenu
        let fake = PreferencesTab.rightClick
        XCTAssertEqual(extras.rawValue, "rightClickMenu", "外部入口只传 rawValue，键名一改跳页就断")
        XCTAssertNotEqual(extras.title, fake.title, "两页同名：侧栏里看不出哪一页是滚轮那一段")
        XCTAssertFalse(extras.title.isEmpty)
        XCTAssertFalse(extras.systemImage.isEmpty)
        // 段里每一行都要在文案表里（漏一条就把 key 原文画在页面上）。清单只有一份：
        // `WheelGestureStringTablesTests.wheelCopyKeys`，两处各列各的迟早漂开。
        // 注意这一条走 `L()`，桩件里读到的是**英文表**（详见那条双表用例的注释）。
        for key in WheelGestureStringTablesTests.wheelCopyKeys {
            XCTAssertFalse(L(key).isEmpty, "\(key) 没进文案表")
            XCTAssertNotEqual(L(key), key, "\(key) 查不到，页面上会露出 key 原文")
        }
        // 六档动作在下拉里各占一行：显示成同一串就选不出区别（比的是**查出来的文案**，
        // 不是 key —— key 天生不同，那条判据等于没判）。
        XCTAssertEqual(Set(WheelGestureActionKind.allCases.map { L(actionKey($0)) }).count,
                       WheelGestureActionKind.allCases.count,
                       "两档动作显示成同一串：下拉里分不出来")
    }

    private func actionKey(_ kind: WheelGestureActionKind) -> String {
        switch kind {
        case .none: return "Wheel Gesture action none"
        case .tabPrevious: return "Wheel Gesture action tab previous"
        case .tabNext: return "Wheel Gesture action tab next"
        case .volumeUp: return "Wheel Gesture action volume up"
        case .volumeDown: return "Wheel Gesture action volume down"
        case .customShortcut: return "Wheel Gesture action custom shortcut"
        }
    }
}
