MacStroke
================================
[English Version](https://github.com/mtjo/MacStroke/blob/master/README_en.md)

![MacStroke](https://github.com/mtjo/MacStroke/raw/release/logo.png)

macOS上一款高度可配置的全局鼠标手势软件。
===
>MacStroke是MacOS的手势识别应用程序。 手势是在按住特定鼠标按钮的同时使用鼠标进行的运动。 如果手势被识别，MacStroke将执行某些操作。
>目前MacStroke可以模拟按键，执行shell命令，执行apple script， MacStroke尝试提供直观和高效的用户界面，同时具有高度可配置性并提供许多高级功能。

## 版本与系统支持

| 版本 | 源码分支 | 系统要求 | 状态 |
| --- | --- | --- | --- |
| **3.0.0 及以后** | [`main`](https://github.com/mtjo/MacStroke/tree/main)（Swift 重写） | **macOS 13 Ventura 或更新** | 当前维护线。通用二进制（Apple Silicon 原生 + Intel），界面与操作与原版保持一致 |
| 2.0.5 及更早 | [`master`](https://github.com/mtjo/MacStroke/tree/master) / `release`（Objective-C） | macOS 10.10 及以上 | 停止维护，仅作为老系统的兜底版本 |

- **旧版可以直接升级：** 2.0.5 及更早版本在软件内「检查更新」就能升到 3.0.0，走的是同一条 appcast（更新条目同时带 Sparkle 1.x 的 DSA 签名和 Sparkle 2 的 EdDSA 签名）。规则、AppleScript、历史粘贴板等数据沿用同一份，不需要迁移。
- **低于 macOS 13 收不到升级：** 更新条目声明了 `minimumSystemVersion 13.0`，macOS 12 及更老的机器会一直停在 2.0.5。需要新功能的机器请先升级系统。
- **升级后请重新勾选辅助功能：** 换到 Swift 版后二进制换了身份，系统可能要求重新授权（见下）。
- 版本号只在 [`build_app.sh`](build_app.sh) 顶部的 `APP_VERSION` 里维护，打包、appcast 条目、更新说明页都从这一处取。

> 从源码构建时，Swift 版需要 macOS 13 及以上的部署目标（`Package.swift` 里的 `.macOS(.v13)`），Sparkle 这个依赖本身要求 macOS 12 及以上。

## 权限

### 10.14系统后就要添加权限 设置->安全性与隐私->隐私->辅助功能 这个必须的, 才能正常使用

![权限设置](https://github.com/mtjo/MacStroke/raw/release/help.png)

### 软件多次升级对旧版数据可能会出现不兼容而闪退，如果遇程序闪退，请清除旧数据重新打开，操作： 常规->重置到预设，然后手动退出程序再打开，或者删除 ~/Library/Preferences/net.mtjo.MacStroke.plist 重新打开软件

###  预设手势说明

![预设手势说明](https://github.com/mtjo/MacStroke/raw/release/MacStroke.gif)

## 下载安装

安装包下载：[MacStroke](https://github.com/mtjo/MacStroke/releases/latest)

homebrew 安装
```
brew install --cask macstroke
```

> ⚠️ 这条命令目前装不了：官方 homebrew-cask 已在 2026-09-01 把 `macstroke` 标记为 `disable! :fails_gatekeeper_check`（发布包用的是自签名证书，`spctl` 判定过不了 Gatekeeper），并且 cask 里还停在 2.0.5。请先用上面的 releases 链接手动下载。要恢复 homebrew 分发，需要给发布包换成 Developer ID 签名 + 公证（notarization），之后向 homebrew-cask 提 PR 把版本升到 3.0.0 并去掉 `disable!`。

### 反馈
[反馈BUG&建义](https://github.com/mtjo/MacStroke/issues)

### 软件实用的话就分享给你的亲朋好友,顺便帮点一下 star 和 fork (把软件发到 homebrew 有硬性要求)
### 软件实用的话就分享给你的亲朋好友,顺便帮点一下 star 和 fork (把软件发到 homebrew 有硬性要求)
### 软件实用的话就分享给你的亲朋好友,顺便帮点一下 star 和 fork (把软件发到 homebrew 有硬性要求)
![homebrew](https://github.com/mtjo/MacStroke/raw/master/homebrew.png)

Power by [![mtjo](https://github.com/mtjo/MacStroke/raw/release/logo-mtjo.png)](http://mtjo.net)

---

## 源码与构建（Swift 版）

- Swift 5.9+，Swift Package Manager，SwiftUI + AppKit 混合 UI，SQLite.swift 持久化
- 功能：CGEventTap 全局事件捕获、DTW 手势识别、规则引擎与动作执行（AppleScript / 按键 / shell / 剪贴板）、偏好设置、状态栏菜单、Finder Sync 右键菜单扩展、历史剪贴板、预设手势、Toast 提示

```bash
swift build            # 编译
swift test             # 单元测试
./build_app.sh         # 打出 MacStroke.app（通用二进制 + 内嵌 Sparkle + Finder 扩展）
./make_release.sh      # 生成发版用 zip 与双签 appcast 条目（release_out/）
```

```
Sources/
  GestureEngine/      # Stroke / GesturePoint / GestureMatcher (DTW)
  EventCapture/       # CGEventTap 全局捕获
  RuleEngine/         # Rule / RuleAction / ActionExecutor
  Storage/            # PreferencesStorage / HistoryClipboard
  Preferences/        # SwiftUI 偏好页面
  WindowManager/      # ToastManager / WindowManager
  AppleScriptRunner/  # AppleScript 执行器
  FinderSyncExtension/# Finder 右键菜单扩展
  MacStrokeApp/       # 应用入口
Tests/                # 各模块单元测试
```

本地开发与自签名证书的说明见 [docs/signing.md](docs/signing.md)。
