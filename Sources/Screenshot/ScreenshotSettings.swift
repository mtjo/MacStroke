//
//  ScreenshotSettings.swift
//  MacStroke
//
//  截图偏好的读取口（对齐 RemoteControlSettings 的做法：模块自己读库，App 层只负责
//  在偏好页里改）。五件事：出图后要不要直接落盘、落到哪、拖选时吸不吸附窗口边界、
//  选区阶段开不开放大镜（含倍率）、选区落定后预先装上哪个注解工具。
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

    public init(autoSave: Bool, directory: URL, snapToWindows: Bool,
                magnifier: Bool, magnification: Int, defaultTool: ScreenshotTool?) {
        self.autoSave = autoSave
        self.directory = directory
        self.snapToWindows = snapToWindows
        self.magnifier = magnifier
        self.magnification = magnification
        self.defaultTool = defaultTool
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
                                        ?? StorageDefaults.screenshotDefaultTool)
        )
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
        let base = suggestedName(date: date)
        var candidate = directory.appendingPathComponent("\(base).png")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).png")
            index += 1
        }
        return candidate
    }

    /// 不含扩展名的文件名（NSSavePanel 的默认名和自动保存共用同一套命名）。
    public func suggestedName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(L("Screenshot")) \(formatter.string(from: date))"
    }
}
