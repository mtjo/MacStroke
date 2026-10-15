//
//  ScreenshotSettingsTests.swift
//
//  截图偏好的读取口取证：全新安装必须落在「不写盘、纯手动、吸附」这套和现有行为一致
//  的默认值上；保存位置的三级回退（选过的目录 → 桌面 → 家目录）和撞名后缀要能量出来，
//  因为自动保存那条路没有面板，落点错了用户只能靠文件名找。
//

import Foundation
import Storage
import XCTest

@testable import Screenshot

final class ScreenshotSettingsTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.ScreenshotSettings"

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MacStrokeSettingsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func isolatedSuite() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    private func settings() -> ScreenshotSettings {
        ScreenshotSettings.current(from: PreferencesStorage(defaults: isolatedSuite()))
    }

    // MARK: - 默认值

    func testFreshInstallWritesNothingAndBehavesLikeBeforeThePageExisted() {
        let current = settings()
        XCTAssertFalse(current.autoSave, "自动保存默认必须关：默默往桌面写文件是打扰")
        XCTAssertTrue(current.snapToWindows, "吸附是遮罩的原有行为，不该默认关掉")
        XCTAssertTrue(current.magnifier, "放大镜默认开：Retina 上不看像素格根本卡不准边")
        XCTAssertEqual(current.magnification, 8, "默认 8 倍：4 倍糊、16 倍只能看到指甲盖大一块")
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.screenshotSaveDirectory.rawValue),
                     "没打开过这一页就不该往库里写路径")
    }

    func testStoredValuesAreReadBack() {
        let defaults = isolatedSuite()
        defaults.set(true, forKey: StorageKey.screenshotAutoSave.rawValue)
        defaults.set(false, forKey: StorageKey.screenshotSnapToWindows.rawValue)
        defaults.set(tempDirectory.path, forKey: StorageKey.screenshotSaveDirectory.rawValue)
        defaults.set(false, forKey: StorageKey.screenshotMagnifier.rawValue)
        defaults.set(16, forKey: StorageKey.screenshotMagnification.rawValue)

        let current = settings()
        XCTAssertTrue(current.autoSave)
        XCTAssertFalse(current.snapToWindows)
        XCTAssertEqual(current.directory, tempDirectory)
        XCTAssertFalse(current.magnifier)
        XCTAssertEqual(ScreenshotMagnification(stored: current.magnification), .large)
    }

    /// 倍率是下拉框写进去的枚举值，不是自由数字：库里被手改成别的数时得有个可用档位。
    func testUnknownStoredZoomFallsBackToTheDefaultLevel() {
        let defaults = isolatedSuite()
        defaults.set(3, forKey: StorageKey.screenshotMagnification.rawValue)
        XCTAssertEqual(ScreenshotMagnification(stored: settings().magnification), .medium)
    }

    // MARK: - 默认工具

    /// 全新安装不预先装工具：框完选区还是「选区内拖动=平移整块」的老行为，
    /// 要预装哪一格得用户自己在偏好页里选。
    func testDefaultToolIsOffOnFreshInstall() {
        XCTAssertNil(settings().defaultTool, "默认是关闭：不能一上来就抢走平移那一路")
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.screenshotDefaultTool.rawValue),
                     "没打开过这一页就不该往库里写值")
    }

    func testStoredDefaultToolArmsThatTool() {
        let defaults = isolatedSuite()
        defaults.set(ScreenshotTool.mosaic.rawValue, forKey: StorageKey.screenshotDefaultTool.rawValue)
        XCTAssertEqual(settings().defaultTool, .mosaic)
    }

    /// 库里存的是工具序号，认不出的值（包括偏好页「关闭」写的 -1）一律当关闭处理：
    /// 不能凭空装上一格用户压根没选过的工具。
    func testUnknownStoredDefaultToolIsTreatedAsOff() {
        let defaults = isolatedSuite()
        for stored in [StorageDefaults.screenshotDefaultTool, 99, -3] {
            defaults.set(stored, forKey: StorageKey.screenshotDefaultTool.rawValue)
            XCTAssertNil(settings().defaultTool, "库里是 \(stored)，不该装任何工具")
        }
    }

    // MARK: - 保存位置的三级回退

    func testEmptySelectionMeansDesktop() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        XCTAssertEqual(ScreenshotSettings.directory(from: ""), desktop)
    }

    func testSelectedDirectorySurvivesWhileItExists() {
        XCTAssertEqual(ScreenshotSettings.directory(from: tempDirectory.path), tempDirectory)
    }

    /// 用户把文件夹删了不能静默重建一个：图会落到一个他压根没设过的地方，
    /// 所以回退到桌面，并让偏好页把那一行标成警告。
    func testDeletedDirectoryFallsBackToDesktop() {
        let gone = tempDirectory.appendingPathComponent("已删除的目录", isDirectory: true).path
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        XCTAssertEqual(ScreenshotSettings.directory(from: gone), desktop)
    }

    // MARK: - 落点命名

    /// 命名和 macOS 自带截图一致：「截图 <日期> at <时分秒>」，本地时区未知，所以只验形状。
    func testFileNameCarriesTimestampToTheSecond() {
        let name = ScreenshotSettings(autoSave: true, directory: tempDirectory, snapToWindows: true,
                                      magnifier: true, magnification: 8, defaultTool: nil)
            .suggestedName(date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix(L("Screenshot") + " "), "文件名要以「截图 」开头，用户按名字就能认出：\(name)")
        XCTAssertTrue(name.contains(" at "), "日期和时间之间要有 at 分隔，和 macOS 自带截图一致")
        XCTAssertEqual(name.components(separatedBy: " ").count, 4, "名称 + 日期 + at + 时间：\(name)")
        XCTAssertFalse(name.hasSuffix(".png"), "扩展名由调用方补，这里给的是不含扩展名的基名")
    }

    /// 同一秒出两张（连按回车、或复制+保存各写一次）会撞名。自动保存不弹面板，
    /// 撞名就是直接把上一张图盖掉，所以必须往后缀找空位。
    func testCollisionAppendsSuffixInsteadOfOverwriting() throws {
        let settings = ScreenshotSettings(autoSave: true, directory: tempDirectory, snapToWindows: true,
                                          magnifier: true, magnification: 8, defaultTool: nil)
        let date = Date()
        let first = settings.fileURL(date: date)
        try Data("x".utf8).write(to: first)

        let second = settings.fileURL(date: date)
        XCTAssertNotEqual(second, first, "同名文件已经存在时不能返回同一个路径")
        XCTAssertTrue(second.deletingPathExtension().lastPathComponent
                      .hasPrefix(first.deletingPathExtension().lastPathComponent),
                      "后缀要接在原名字后面，改名会让用户找不到")
        XCTAssertEqual(second.deletingPathExtension().lastPathComponent,
                       first.deletingPathExtension().lastPathComponent + " 2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "上一张图不能被覆盖")
    }

    func testKeepGoingUntilTheSuffixIsFree() throws {
        let settings = ScreenshotSettings(autoSave: true, directory: tempDirectory, snapToWindows: true,
                                          magnifier: true, magnification: 8, defaultTool: nil)
        let date = Date()
        let base = settings.suggestedName(date: date)
        for suffix in ["", " 2", " 3"] {
            try Data("x".utf8).write(to: tempDirectory.appendingPathComponent("\(base)\(suffix).png"))
        }
        XCTAssertEqual(settings.fileURL(date: date).deletingPathExtension().lastPathComponent, "\(base) 4")
    }
}
