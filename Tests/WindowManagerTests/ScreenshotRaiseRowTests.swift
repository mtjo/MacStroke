//
//  ScreenshotRaiseRowTests.swift
//
//  截图页新增那一行的界面取证：「截图前把光标下的窗口提到最前」（2026-11-05，默认开）。
//
//  绑定和默认值在单测里钉过了；这一条要看的是**画出来**的结果 —— 那一行真的装进了
//  截图卡片、右端那颗开关跟着库里的值走、吸附关掉后它会被画成不可用。判据取位图差值：
//  只比「提窗开/关」两张图，变化必须是一小条落在行尾（开关那枚），不是整页文字；
//  再拿「吸附关」那张比，同一带里还得有变化（开关转灰），否则说明禁用根本没画出来。
//
//  带子不写死比例：两张图先自己算出差异的包围盒，断言只看那个盒子。这样以后页面
//  上下加行，这条用例不会因为比例漂移而假红。
//

import AppKit
import Storage
import SwiftUI
import XCTest

@testable import Preferences

final class ScreenshotRaiseRowTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.ScreenshotRaiseRow"
    private static let exportDir = "/tmp/macstroke-raise-row-check"
    private static let hostSize = NSSize(width: 720, height: 1600)

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

    // MARK: - 脚手架

    @MainActor
    private func capture(snap: Bool, raise: Bool, name: String) throws -> NSBitmapImageRep {
        let defaults = isolatedSuite()
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults.set(snap, forKey: StorageKey.screenshotSnapToWindows.rawValue)
        defaults.set(raise, forKey: StorageKey.screenshotRaiseWindowBeforeCapture.rawValue)

        let prefs = UserPreferences(storage: PreferencesStorage(defaults: defaults))
        let host = NSHostingView(rootView: AnyView(
            ScreenshotTabView(viewModel: prefs)
                .frame(width: Self.hostSize.width, height: Self.hostSize.height, alignment: .top)))
        host.frame = NSRect(origin: .zero, size: Self.hostSize)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.hostSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        // SwiftUI 的布局和绑定回填排在下一个 runloop 轮次上。
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "页面渲不出位图：窗口没挂上视图树")
        host.cacheDisplay(in: host.bounds, to: rep)

        try FileManager.default.createDirectory(atPath: Self.exportDir, withIntermediateDirectories: true)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(Self.exportDir)/\(name).png"))
        return rep
    }

    private struct Diff {
        let count: Int
        let minX: Int, maxX: Int, minY: Int, maxY: Int
    }

    /// 两张位图的差异包围盒。alpha 一起比：离屏宿主没有底色，字只改透明度不改 RGB。
    private func diff(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Diff {
        var count = 0
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for py in 0..<min(lhs.pixelsHigh, rhs.pixelsHigh) {
            for px in 0..<min(lhs.pixelsWide, rhs.pixelsWide) {
                guard let a = lhs.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
                      let b = rhs.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                abs(a.greenComponent - b.greenComponent),
                                abs(a.blueComponent - b.blueComponent),
                                abs(a.alphaComponent - b.alphaComponent))
                guard delta > 0.03 else { continue }
                count += 1
                minX = min(minX, px); maxX = max(maxX, px)
                minY = min(minY, py); maxY = max(maxY, py)
            }
        }
        return Diff(count: count, minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    /// 指定纵向带里的差异像素数。
    private func changed(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep,
                         rows: ClosedRange<Int>) -> Int {
        var count = 0
        for py in rows where py >= 0 && py < min(lhs.pixelsHigh, rhs.pixelsHigh) {
            for px in 0..<min(lhs.pixelsWide, rhs.pixelsWide) {
                guard let a = lhs.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
                      let b = rhs.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                abs(a.greenComponent - b.greenComponent),
                                abs(a.blueComponent - b.blueComponent),
                                abs(a.alphaComponent - b.alphaComponent))
                if delta > 0.03 { count += 1 }
            }
        }
        return count
    }

    // MARK: - 判据

    /// 库里的值要真的画出来：提窗开/关两张图，差异只能是一小条、落在行尾。
    /// 落在左边就是标题跟着变了（那说明这一行绑错了东西），摊开一大片就是整页被顶动。
    @MainActor
    func testTheRaiseSwitchIsDrawnOnTheTrailingEdgeAndFollowsTheStore() throws {
        let on = try capture(snap: true, raise: true, name: "raise-on")
        let off = try capture(snap: true, raise: false, name: "raise-off")

        let delta = diff(on, off)
        XCTAssertGreaterThan(delta.count, 30, "提窗开/关两张图一模一样 —— 这一行根本没画出来")
        XCTAssertGreaterThan(delta.minX, on.pixelsWide * 3 / 5,
                             "变化跑到了行左边：动的是标题文字，不是行尾那颗开关")
        XCTAssertLessThanOrEqual(delta.maxY - delta.minY, 60,
                                 "变化摊开了 \(delta.maxY - delta.minY) 行：不是一枚开关该有的动静")
    }

    /// 吸附关掉后，提窗那一行是禁用的：同一带里必须看得出变化（开关转灰）。
    @MainActor
    func testTheRaiseSwitchGreysOutWhenSnappingIsOff() throws {
        let on = try capture(snap: true, raise: true, name: "snap-on")
        let off = try capture(snap: false, raise: true, name: "snap-off")
        let raiseOff = try capture(snap: true, raise: false, name: "raise-off-band")
        let band = diff(on, raiseOff)

        // 前置条件不成立时直接收工：下面要拿差异包围盒当带子，空差异的 maxY 是 -1，
        // 再往下拼区间会把整个进程 trap 掉（变异趟里就是这么从「该红」变成「用例 0」的）。
        guard band.count > 30 else {
            return XCTFail("前置条件没成立：提窗开关那一带根本没画出来")
        }
        let rows = band.minY...band.maxY
        XCTAssertGreaterThan(changed(on, off, rows: rows), 10,
                             "吸附关掉后提窗开关还是原样 —— 说明禁用状态没画出来，用户以为还能点")
    }
}
