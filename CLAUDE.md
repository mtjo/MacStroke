# CLAUDE.md

本文件为将来在此仓库中工作的 Claude Code（claude.ai/code）提供开发指导。

## 构建与测试命令

```bash
# 构建全部目标
swift build

# 运行全部测试
swift test

# 运行单个测试目标
swift test --filter GestureEngineTests
swift test --filter RuleEngineTests
# 其他测试目标同理

# 列出可用测试
swift test --list-tests
```

## 架构概览

**MacStroke-Swift** 是一个 macOS 全局鼠标手势识别应用，使用 Swift 5.9+ 从原始 Objective-C 项目（mtjo/MacStroke）完整重写。最低部署版本为 macOS 13 Ventura。

### 包结构（Package.swift）

13 个 target，由多个库和一个可执行文件组成：

| Target | 作用 | 关键依赖 |
|--------|------|----------|
| `GestureEngine` | 核心 DTW 手势匹配（纯 Swift，完全可测试） | — |
| `EventCapture` | 通过 CGEventTap 进行全局鼠标捕获 | `GestureEngine` |
| `RuleEngine` | 规则、动作、模板匹配 | `GestureEngine`, `AppleScriptRunner` |
| `Storage` | 偏好设置（UserDefaults）+ 剪贴板历史（SQLite.swift） | `SQLite` |
| `Preferences` | SwiftUI + AppKit 偏好设置 UI | `Storage`, `RuleEngine`, `AppleScriptRunner`, `RightClickMenu`, `EventCapture` |
| `WindowManager` | 状态栏项目、Toast 通知 | `GestureEngine`, `RuleEngine`, `Storage`, `Preferences` |
| `AppleScriptRunner` | 通过 `osascript` 执行 AppleScript | — |
| `RightClickMenu` | Finder 右键菜单管理 | — |
| `FinderSyncExtension` | Finder Sync 扩展（独立 bundle） | `RuleEngine` |
| `MacStrokeApp` | 主应用可执行文件（accessory policy） | `EventCapture`, `WindowManager`, `Preferences`, `AppleScriptRunner`, `Sparkle` |

外部依赖：`SQLite.swift`（剪贴板历史）、`Sparkle`（自动更新）。


## Git Commit 规范

- 绝对不要在 commit message 中添加 `Co-Authored-By: Claude ...` 或任何 AI 署名/尾缀（trailer）



### 关键组件

- **Sources/MacStrokeApp/main.swift** — 应用入口。设置 `NSApplication.shared.setActivationPolicy(.accessory)`。创建 `AppDelegate`，其职责包括：
  - 单实例检测：二次启动时发送 `MacStrokeOpenPreferences` 分布式通知并退出
  - 在启动时应用已保存的语言偏好
  - 检查/请求无障碍权限（`AXIsProcessTrustedWithOptions`）
  - `firstLaunch` 首次启动初始化（默认规则、RightClicksList）
  - `BlackWhiteFilter.compatibleProcedureWithPreviousVersion()` 旧版 blockFilter 迁移
  - `openPrefOnStartup` / `applicationShouldHandleReopen` 打开偏好窗口
  - 启动 `EventCapture` → `CanvasManager` → `RuleEngine` 处理链，并注入 `shouldCaptureGesture` / `needsRightClickMenu` 闭包
  - `initRightClickMenu`（RightClickMenuManager 分布式通知 + pluginkit 延迟启用）
  - `initHistoryClipboard`（剪贴板监控 + `ShortcutMonitor` 全局快捷键唤起历史列表，默认 ⌘⌥V，key `historyCilpboardListShortcut` 格式 "keyCode=X, flags=Y"）
  - 创建状态栏项目，使用模板图片（`menu_icon_16x16.png` / disabled 版本）
  - 初始化 Sparkle 更新器（沿用原版 appcast；Info.plist 必须带 `SUPublicEDKey`，否则 Sparkle 2 启动即弹致命错误模态框）

- **Sources/EventCapture/EventCapture.swift** — 在 `.cghidEventTap` 使用 `CGEventTap` 拦截右键手势事件（rightMouseDown/Dragged/Up + leftMouseDown）。**只有右键开始手势**；delegate 返回 `true` 时事件被吞掉（返回 NULL），`false` 时放行。坐标在边界处转换为 AppKit 底左原点（`primaryScreenHeight - cgY`），与手势模板坐标系一致。`kCGEventTapDisabledByTimeout` 时自动重新启用 tap。`isEnabled` 主开关对应状态栏"Enable MacStroke"。

- **Sources/GestureEngine/** — 从原始 `GestureCompare.m` 移植的 DTW 算法：
  - `Stroke` / `GesturePoint` — 归一化坐标、`t`（时间）、`alpha`（角度）、`dt`
  - `GestureMatcher.compare(template:candidate:)` → 分数 0…100（越高越相似）
  - `Stroke.normalize()` 平移 + 缩放到 `[0,1]²`，计算 `t/dt/alpha`

- **Sources/RuleEngine/** —
  - `Rule`（`struct`）包含 `GestureTemplate`、`RuleAction`、过滤器（通配符/正则 bundle ID）、`minSimilarityScore`，以及 `spareActions`（`RuleSpareActions`）：原版每条规则同时保存 `text` / `password` / `apple_script_id` / `shortcut_code`+`shortcut_flag` 四类动作值，切换 `actionType` 只改类型不清空其他字段，`spareActions` 就是为此存在（非当前动作类型的值从同名持久化键解出）；编码时只有当前动作类型对应的键会被写出，与原版 `addRuleWithDirection:` 一致
  - `RuleAction`: `.shortcut(keyCode:flags:)`、`.applescript`、`.text`、`.password`、`.keyPress`、`.mouseClick`、`.copyToClipboard`、`.none`
  - `WildcardMatch.swift`：原版 `utils.m` 的 `wildcardArray` / `wildcardString`，即 `NSPredicate "self LIKE %@"` 语义 —— 整串锚定、`*` 任意串、`?` 单个字符、大小写由两侧 lowercase 实现（不做 trim、不丢弃空片段，因此空 filter 永不匹配）；`BlackWhiteFilter` 与规则 filter 的通配匹配共用此实现（`regex:` 前缀等自创语法已删除）
  - `RuleEngine.match(stroke:bundleID:)` 的 `bundleID` 必传（无 bundle id 时传 `""`，对齐 `frontBundleName()`），**每条规则的 filter 都会参与判定**；遍历**所有**过滤匹配的规则取**最高分**（对齐原版 `setActionIndex`），并接入全局 `enableGestureMinScore` / `minScore`（默认 85）门槛；`appSuitedRule(bundleID:)` 判断某 app 是否有适用规则
  - `RuleStore` 将规则持久化到 `~/Library/Application Support/MacStroke/rules.json`；`defaultRules()` 提供与原版 `RulesList.reInit` 相同的 15 条默认规则（首条 direction 为小写 `password`，description 即 note，带修饰键的 shortcut 动作、Reversed 点序反转模板、text/password 动作）
  - `ActionExecutor.typeText` 使用 `CGEventKeyboardSetUnicodeString` 模拟键入（对齐原版 `typeSting`）
  - **不可变性**：更新规则时，创建新的 `Rule` 实例并调用 `RuleStore.update()`

- **Sources/GestureEngine/GestureTemplateProvider.swift** — 预设手势（A–Z、方向箭头、方框符号）；`reversedTemplate(for:)` 提供 Reversed（点序反转）变体，`allTemplatesIncludingReversed()` 命名格式为 "X Shape" / "X Shape Revered"
  - `presetPickerEntries` 是 UI 里唯一的预设候选集，严格对齐原版 `alertModalFirstBtnTitle:` 的 68 项顺序：8 个方向符号（← ↑ → ↓ ↙ ↗ ↘ ↖，**无** Revered 变体）→ ┏ ┓ ┗ ┛ 各带 " Revered" → 裸字母 "A"/"A Revered" … "Z"/"Z Revered"（字母在列表里不带 " Shape" 后缀，模板内部名仍是 "A Shape"）

- **Sources/EventCapture/CanvasManager.swift** — 手势状态机（对齐原版 `mouseEventCallback`）：
  - 右键按下时经 `shouldCaptureGesture` 闭包过滤（main.swift 注入：黑白名单 + showUIInWhateverApp + appSuitedRule）
  - 手势未匹配时重放右键 down/up 事件；无拖拽且 app 在 RightClicksList 中时合成 Ctrl+左键（`threadRightClick` 等价）
  - `isRecordingGesture` + `onGestureRecorded` 支持"屏幕绘制录入手势"（通过 `.macStrokeRecordGesture` 通知触发）

- **Sources/Preferences/** —
  - `UserPreferences`（`ObservableObject`）将每个设置绑定到 `PreferencesStorage`（`StorageKey` enum 中的 UserDefaults key）
  - `PreferencesView`（SwiftUI）— 标签页 UI：General、Rules、Filters、AppleScript、RightClick、RightClickMenu、Clipboard、About（8 个，对齐原版 `AppPrefsWindowController.setupToolbar`；注意：早期 CLAUDE.md 记录的 7 标签布局与原版代码不符，勿再沿用）
  - 视觉风格参照 macOS 系统设置：`SettingsChrome` 常量 + `SettingsPage` / `SettingsFillingPage`（含表格的页不滚动）+ `SettingsSection` / `SettingsCard` / `SettingsRow` / `TrailingSwitch`；侧栏圆角高亮、灰底页面、白色圆角卡片、左标题右控件
  - 规则表格列：Image（`GestureThumb` 84pt 行高；轨迹为空的行按原版渲染一个 80x25 的"绘制手势"按钮）、Gesture（名称，双击打开编辑器）、Type、Action、Filter、Description。Image 列双击与"绘制手势"按钮在原版都走 `preSetRuleGestureAtIndex:`，即弹出带 68 项预设下拉的"绘制手势！"模态框（不是单独的绘制面板）；选中预设或屏幕上画完会立刻 `setGestureData:` 落库、发"手势绘制完成"通知并合成 Return 键关掉模态框
  - `GestureThumb` 复刻原版 `DrawGesture setPoints:` 的数学：60pt 画布、`zoo = max(w/60, h/60)`、只在短轴居中、整体右下偏移 12pt、逐段渐变 `(0.5t, 0.47+0.53t, 0.9)` 且 `t = i / points.count`（不是 count-1）；编辑器里 56pt 预览框用 `canvas: 44, inset: 6` 以免裁切
  - `RuleEditorView` — 添加/编辑规则的弹层（原版是表格就地编辑，Swift Table 只读所以改为 sheet）；字段仅名称/说明/手势轨迹/过滤/动作类型+内容，原版没有的每规则开关（启用、最小分数、持续触发、正则）不再暴露，保存时原样保留旧值
  - 常规页对齐原版 `Preferences.xib` 的 General 面板：语言下拉是**原始 locale 码**（`en` / `zh-Hans`，宽 81，原版就是代码里塞进 combo 的裸值），切换后只弹非模态通知"重启MacStroke后生效"；字号是只读文本（原版两个字段都是 display-only 绑定，只能由字体面板改）；滑块宽 210、颜色井宽 100
  - 字体面板：`chooseFont:` 先 `fontPanel:YES` 显示、**再** `setSelectedAttributes(["NSColor": noteColor])`（原版注释：显示前设置会一直是黑色），因此面板里的颜色井可直接改提示文字色，回调走 `setColor(_:forAttribute:)` 写 `defaultNoteColor`
  - `resetToDefaults()` 严格照搬原版 `resetDefaults:`：只回写 `DefaultPreferences.plist` 携带的键（+ `resetColors` 从 `defaultLineColor`/`defaultNoteColor` 重新派生 `lineColorHex`），**不动**语言、黑白名单与模式、登录项、`minimumPoints`、`disableMousePath`、更新设置；原版没有确认框也没有重启提示，SwiftUI 侧靠 `reloadResetValues()` 把新值推回 `@Published` 属性来模拟原版的绑定自动刷新
  - `isEnabled` 是**运行时状态**（原版 `AppDelegate` 的 `static BOOL isEnabled`，每次启动回到 YES 且从不落库），所以 `UserDefaults` 里没有 `isEnabled` 这个 key，勾选框状态不跨启动
  - 偏好页的确认/提示统一走 `postMacStrokeNotification(_:)`（原版一律用 `NSUserNotification`，标题 "MacStroke"，默认声音；只有规则"清空"才是模态 NSAlert）
  - 关于页只有 Sparkle 两个开关 + Version/Check Now/issues + Author + README.html WebView；原版是 `LSUIElement` 常驻 accessory 应用，主菜单（`MainMenu.xib` 里那套 "About MenuBarApp" 模板残留）**永远不会显示**，因此标准关于面板与 Credits.rtf 无需移植

- **Sources/Storage/** —
  - `PreferencesStorage` — 对 `UserDefaults` 的薄封装，提供类型化 getter/setter 以及 `StorageDefaults` 常量
  - `HistoryClipboardManager` — 基于 SQLite 的剪贴板历史，支持置顶/收藏条目、分页、过期清理。监控只由 `enableHistoryClipboard` 决定；`clipoardStroageLocal` 单选决定落库位置与裁剪（false 时用 `file::memory:?cache=shared` 内存库），`deleteExpired` 的总数/按天裁剪只在 local 模式执行（原版 `STROAGE_LOCAL` 分支）；`clipoardStroageRam` 在原版中是永不读取的死键，Swift 侧已移除
  - `HistoryClipboardListWindowController` — 历史列表窗口（780x453、三列表头 序号/内容/操作、底部 tips + clearTop/clear/clearAll 按钮、行内 ↑/- 置顶按钮、双击回填粘贴板并关窗、滚到底加载下一页 30 条）

- **Sources/WindowManager/** — `WindowManager`（状态栏）、`Toast` / `ToastManager`（屏幕上的提示）

- **Sources/RightClickMenu/RightClickMenuManager.swift** — 管理 FinderSync 扩展生命周期：
  - 注册分布式通知观察者（`CustomMessageReceivedNotification`、`RequestObservingPathNotification`）
  - 通过 `SyncSharedDefaultsNotification` 将启用开关 + 本地化菜单标题同步到扩展
  - 操作：创建文本文件（`touch` + AppleScript 回退）、在终端中打开（`open -a`）、复制路径到剪贴板
  - 通过 `pluginkit -e use|ignore -i net.mtjo.MacStroke.FinderSyncExtension` 启用/禁用扩展

- **Sources/FinderSyncExtension/FinderSync.swift** — `FIFinderSync` 子类：
  - 工具栏项目，使用 `toolbarIcon` 图片
  - 上下文菜单项（新建文件、在终端中打开、复制路径），图片来自资源目录
  - 在用户操作时向主应用发送分布式通知

- **Sources/AppleScriptRunner/** — 通过 `osascript` 执行 AppleScript 字符串；提供预设动作（close-window、minimize、hide-app、launch Safari/Chrome/Terminal）。

### 本地化

- `L(key)` 函数位于 `Sources/Storage/Localization.swift`，实际生效的文件是 `Sources/MacStrokeApp/Resources/{en,zh-Hans}.lproj/Localizable.strings`（`build_app.sh` 整目录拷进 app bundle；仓库根下曾有一份 145 行的旧副本，已删除，勿再新建）
- 语言持久化在 `UserDefaults` 的 `language` key 中；运行时切换会发送 `.languageDidChange` 通知
- `applyUserLanguage(_)` 会更新 `Bundle.main.preferredLocalizations`

### 重要实现注意事项

- **Rule 是不可变的** — 不要修改 `rule.template` 或其他 `let` 属性；始终构造新的 `Rule` 并调用 `RuleStore.update(newRule)`
- **DrawGesture 缩放** — `computeScaledPoints` 使用 `bounds.width/height`（不是硬编码常量）；`layout()` 覆写会在 bounds 变化时重新计算；`clipsToBounds = true`，背景透明
- **手势录入** — 规则表 Image 列双击（或编辑器里的"在屏幕上绘制"按钮）→ 发送 `.macStrokeRecordGesture`（userInfo 带规则名；编辑器发起时额外带 `deferStoreUpdate: true`）→ AppDelegate 进入录制模式 → 画完 `onGestureRecorded` 写回规则并广播 `.macStrokeGestureDidRecord`（编辑器据此回填轨迹）。编辑器发起的录制只回填表单、不写库，点保存才落盘
- **Toast 位置** — `ToastPosition` 原始值对齐原版 `notePostion`：0=跟随鼠标、1=屏幕中央、2=右上、3=右下、4=左上、5=左下
- **FinderSync 通信** — 主 app → 扩展：`SyncSharedDefaultsNotification`（object=主 app bundleID，userInfo 带开关与菜单标题，扩展收到后写入自己的 UserDefaults；开关值按原版编码为 `"1"/"0"` 字符串，扩展用 `intValue` 解析，发 `"true"/"false"` 会一律读成 0 导致菜单为空）；扩展启动时发 `RequestObservingPathNotification`，主 app 回 `ObservingPathSetNotification`（根路径 "/"）；扩展 → 主 app：`CustomMessageReceivedNotification`（object=JSON 字符串，解析 operation/path/items）。主 app 端解析在 `RightClickMenuManager.customMessageReceivedFromFinder`，两个 DNC 观察者必须带 `suspensionBehavior: .deliverImmediately`（后台 agent 会被节流丢包）
- **无障碍权限** — 启动时通过 `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` 检查；会显示带 "Open System Settings" 按钮的模态提示
- **Sparkle** — `SPUStandardUpdaterController` 在 `AppDelegate.initSparkleUpdater()` 中初始化；feed URL 与原版一致（`mtjo/MacStroke` release 分支的 AppCast），但 Sparkle 2 要求 `SUPublicEDKey`（缺了会在 `startUpdater:` 直接弹模态致命错误、冻结主线程，Finder 菜单随之失效），私钥在本地 `.sparkle/ed25519-private.pem`（未入库）。移植期启动自动检查关闭（`SUEnableAutomaticChecks=false`、`StorageDefaults.autoCheckUpdates=false`），因为该 feed 只发布 ObjC 版且仅有 DSA 签名——自动检查会提示把 Swift 版覆盖成另一条代码线的构建；关于页"Check Now"（`.macStrokeCheckForUpdates`）仍可手动触发。

### 测试

- 7 个测试 target（每个库一个）：`GestureEngineTests`、`EventCaptureTests`、`RuleEngineTests`、`StorageTests`、`WindowManagerTests`、`AppleScriptRunnerTests`、`RightClickMenuTests`
- 全部 105 个测试通过（`swift test`）

### 仓库中不存在的文件

未发现现有的 `CLAUDE.md`、`.cursor/rules/`、`.cursorrules` 或 `.github/copilot-instructions.md`。
