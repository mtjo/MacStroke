//
//  ScreenshotSettings.swift
//  MacStroke
//
//  截图偏好的读取口（对齐 RemoteControlSettings 的做法：模块自己读库，App 层只负责
//  在偏好页里改）。八件事：出图后要不要直接落盘、落到哪、拖选时吸不吸附窗口边界、
//  选区阶段开不开放大镜（含倍率）、选区落定后预先装上哪个注解工具，外加录屏的帧率、
//  时长上限、带不带指针，和长截图的滚动步长、最多接几屏。
//
//  录屏和长截图各有自己的两三项设置（帧率、时长上限、带不带指针 / 步长、接几屏），
//  但落盘位置不另开一份：录像和长图都进上面的「默认保存位置」（见 `videoURL()`）。
//  一个能力只给一组控件，能共用的绝不重复铺行。
//
//  保存位置存的是绝对路径字符串，空串表示「用户没选过」，这时回退到桌面 —— 和 macOS
//  自带截图一致。选过的目录如果哪天被删了也回退到桌面：静默重建一个目录比把图存到
//  用户找不到的地方更糟，而偏好页会在那一行标出「该位置已不存在」。
//

import Foundation
import Storage

/// 一次截图会话开始时取到的偏好快照。
public struct ScreenshotSettings: Equatable {
    public var autoSave: Bool
    public var directory: URL
    public var snapToWindows: Bool
    /// 选区阶段跟光的放大镜，和它的倍率（一个像素放大成几pt）。
    public var magnifier: Bool
    public var magnification: Int
    /// 选区落定时预先装在注解条上的工具；nil = 偏好里选了「关闭」，什么都不装。
    public var defaultTool: ScreenshotTool?
    /// 录屏三档：帧率、最长秒数、带不带鼠标指针。都已经在 `current()` 里夹过，
    /// 消费端拿到的一定是能用的值。
    public var recordFrameRate: Int
    public var recordMaxSeconds: Int
    public var recordCursor: Bool
    /// 长截图两档：每次注入滚多少点、最多接几屏。
    public var scrollStep: Int
    public var scrollMaxScreens: Int

    public init(autoSave: Bool, directory: URL, snapToWindows: Bool,
                magnifier: Bool, magnification: Int, defaultTool: ScreenshotTool?,
                recordFrameRate: Int = StorageDefaults.screenshotRecordFrameRate,
                recordMaxSeconds: Int = StorageDefaults.screenshotRecordMaxSeconds,
                recordCursor: Bool = StorageDefaults.screenshotRecordCursor,
                scrollStep: Int = StorageDefaults.screenshotScrollStep,
                scrollMaxScreens: Int = StorageDefaults.screenshotScrollMaxScreens) {
        self.autoSave = autoSave
        self.directory = directory
        self.snapToWindows = snapToWindows
        self.magnifier = magnifier
        self.magnification = magnification
        self.defaultTool = defaultTool
        self.recordFrameRate = recordFrameRate
        self.recordMaxSeconds = recordMaxSeconds
        self.recordCursor = recordCursor
        self.scrollStep = scrollStep
        self.scrollMaxScreens = scrollMaxScreens
    }

    public static func current(from storage: PreferencesStorage = PreferencesStorage()) -> ScreenshotSettings {
        ScreenshotSettings(
            autoSave: storage.getBoolOptional(forKey: .screenshotAutoSave) ?? StorageDefaults.screenshotAutoSave,
            directory: directory(from: storage.getStringOptional(forKey: .screenshotSaveDirectory)
                                 ?? StorageDefaults.screenshotSaveDirectory),
            snapToWindows: storage.getBoolOptional(forKey: .screenshotSnapToWindows)
                ?? StorageDefaults.screenshotSnapToWindows,
            magnifier: storage.getBoolOptional(forKey: .screenshotMagnifier)
                ?? StorageDefaults.screenshotMagnifier,
            magnification: storage.getIntOptional(forKey: .screenshotMagnification)
                ?? StorageDefaults.screenshotMagnification,
            defaultTool: ScreenshotTool(stored: storage.getIntOptional(forKey: .screenshotDefaultTool)
                                        ?? StorageDefaults.screenshotDefaultTool),
            recordFrameRate: clamped(storage.getIntOptional(forKey: .screenshotRecordFrameRate)
                                     ?? StorageDefaults.screenshotRecordFrameRate,
                                     low: frameRateRange.lowerBound, high: frameRateRange.upperBound),
            recordMaxSeconds: clamped(storage.getIntOptional(forKey: .screenshotRecordMaxSeconds)
                                      ?? StorageDefaults.screenshotRecordMaxSeconds,
                                      low: maxSecondsRange.lowerBound, high: maxSecondsRange.upperBound),
            recordCursor: storage.getBoolOptional(forKey: .screenshotRecordCursor)
                ?? StorageDefaults.screenshotRecordCursor,
            scrollStep: clamped(storage.getIntOptional(forKey: .screenshotScrollStep)
                                ?? StorageDefaults.screenshotScrollStep,
                                low: scrollStepRange.lowerBound, high: scrollStepRange.upperBound),
            scrollMaxScreens: clamped(storage.getIntOptional(forKey: .screenshotScrollMaxScreens)
                                      ?? StorageDefaults.screenshotScrollMaxScreens,
                                      low: scrollMaxScreensRange.lowerBound,
                                      high: scrollMaxScreensRange.upperBound)
        )
    }

    // MARK: 取值范围
    // 偏好页的下拉只给这几档里的值，但 defaults 是能被手改的（`defaults write`、旧版本
    // 留下的值）。夹紧而不是信任：帧率为 0 会让 `CMTime(timescale: 0)` 当场崩，长截图
    // 步长为 0 会让每轮都抓到同一帧、认成「到底了」。

    /// 每秒帧数。下限 5 是为了读数别变成幻灯片，上限 120 是这路采集的实际天花板。
    public static let frameRateRange = 5...120
    /// 单次录屏最长秒数：10 秒是个有用的最短值（录个动图），30 分钟再长就没人看了。
    public static let maxSecondsRange = 10...1800
    /// 每次滚动的点数。小于 20 点几乎认不出位移，大于 400 点一次跳过头就拼不上。
    public static let scrollStepRange = 20...400
    /// 长截图最多接几屏。
    public static let scrollMaxScreensRange = 2...40

    static func clamped(_ value: Int, low: Int, high: Int) -> Int {
        Swift.max(low, Swift.min(high, value))
    }

    /// 用户存过且目录还在就用它，否则用桌面（桌面也拿不到就用家目录）。
    /// 偏好页也走这里，这样「页面上显示的位置」和「截图真正落盘的位置」永远是同一个。
    public static func directory(from raw: String) -> URL {
        if !raw.isEmpty, FileManager.default.fileExists(atPath: raw) {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return desktop
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// 落盘的目标路径。时间戳只到秒，同一秒内出两张（连按回车）会撞名，所以往后缀
    /// 「 2」「 3」找第一个空位 —— 自动保存不弹面板，撞名就是覆盖用户的上一张图。
    public func fileURL(date: Date = Date()) -> URL {
        uniqueURL(base: suggestedName(date: date), ext: "png")
    }

    /// 录屏落盘的目标路径。目录沿用「默认保存位置」，不再单开一个偏好：区域录像出来的
    /// 就是十几秒的短片，和截图落去同一个文件夹最省事，也不用多解释一行设置。
    public func videoURL(date: Date = Date()) -> URL {
        uniqueURL(base: "\(L("Screenshot Record")) \(stamp(date))", ext: "mp4")
    }

    /// 不含扩展名的文件名（NSSavePanel 的默认名和自动保存共用同一套命名）。
    public func suggestedName(date: Date = Date()) -> String {
        "\(L("Screenshot")) \(stamp(date))"
    }

    private static func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }

    private func stamp(_ date: Date) -> String {
        Self.stampFormatter().string(from: date)
    }

    private func uniqueURL(base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }
}
