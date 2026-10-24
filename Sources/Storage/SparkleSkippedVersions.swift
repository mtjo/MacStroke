import Foundation

/// Sparkle 自己记的「跳过这个版本」。三个键名抄自 Sparkle 2 的 `SUConstants.m`：
/// `SUSkippedMinorVersionKey` 的实际字符串是 `SUSkippedVersion`（普通版），
/// 另两个是大版本 / 被跳过的大版本里的小更新。用户在更新窗点「跳过这个版本」时，
/// `SPUSkippedUpdate.skipUpdate:` 按 majorUpgrade 写进其中一到两格。
///
/// domain 必须和 Sparkle 用的是同一个：`build_app.sh` 没往 Info.plist 写
/// `SUDefaultsDomain`，`-[SUHost initWithBundle:]` 于是落到
/// `[NSUserDefaults standardUserDefaults]`（= 本 App 的 `net.mtjo.MacStroke`）。
/// 两边拿的还是同一个单例对象，所以清完不需要额外的同步手段。
///
/// 值本身：Sparkle 2 走 `objectForUserDefaultsKey:ofClass:NSString.class`，只认字符串；
/// 原版（ObjC + Sparkle 1.x）那几台老机器上可能留着数字，读的时候一并收，
/// 否则页面会显示成「无」而实际还跳着 —— 正是这次要修的毛病。
public enum SparkleSkippedVersions {
    public static let minorKey = "SUSkippedVersion"
    public static let majorKey = "SUSkippedMajorVersion"
    public static let majorSubreleaseVersionKey = "SUSkippedMajorSubreleaseVersion"

    /// 顺序 = 页面上显示的顺序：普通版在前，大版本和它的小更新在后。
    public static let allKeys: [String] = [minorKey, majorKey, majorSubreleaseVersionKey]

    /// 当前被跳过的版本号（去重、保序）。空数组 = 没有任何跳过记录。
    public static func versions(in defaults: UserDefaults = .standard) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in allKeys {
            guard let version = versionString(for: defaults.object(forKey: key)) else { continue }
            if seen.insert(version).inserted {
                result.append(version)
            }
        }
        return result
    }

    /// 清掉全部跳过记录，返回清掉的版本号（空数组 = 本来就没有，调用方据此区分
    /// 「真的清了」和「无事可做」，别把后者也说成成功）。
    @discardableResult
    public static func clear(in defaults: UserDefaults = .standard) -> [String] {
        let cleared = versions(in: defaults)
        for key in allKeys {
            defaults.removeObject(forKey: key)
        }
        return cleared
    }

    private static func versionString(for object: Any?) -> String? {
        switch object {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
