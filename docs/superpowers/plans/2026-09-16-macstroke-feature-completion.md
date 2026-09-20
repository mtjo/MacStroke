# MacStroke Swift 重构 — 功能补全实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完整实现原始 MacStroke (Objective-C) 的全部功能，当前 Swift 重构版本缺失约 60% 的功能。

**Architecture:** Swift Package Manager, SwiftUI + AppKit 混合, SPM 模块化 target, macOS 13+ (Swift 5.9)

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, SQLite.swift, Sparkle, pluginkit, SPM

**Spec:** 原始项目 /tmp/MacStroke-Original/MacStroke/ 作为功能基准

## Global Constraints
- macOS 13 Ventura 最低版本
- SPM 模块化架构，禁止遗留的 xcodeproj
- 无 Storyboard/XIB，全部代码布局
- 所有原始功能必须完整实现
- 设置面板参考 macOS 27 风格（偏好设置窗口样式）

---

## Task 15: HistoryClipboard（剪贴板历史）

**Files:**
- Create: `Sources/Storage/HistoryClipboard.swift`
- Modify: `Sources/Preferences/Preferences.swift`（添加剪贴板相关属性）
- Modify: `Sources/Preferences/PreferencesView.swift`（添加剪贴板设置 UI）
- Test: `Tests/StorageTests/HistoryClipboardTests.swift`

**Interfaces:**
- `HistoryClipboardManager` 类：`enableHistoryClipboard()`, `isEnable()`, `getHistoryClipboardList(firstPage:)`, `getTopList()`, `clearHistoryList()`, `insertLocalHistoryClipboard(content:isTop:)`, `topCount`, `addTop()`, `removeTop()`, `nextPage()`, `clearTop()`, `clearAll()`, `deleteExpired()`
- `HistoryClipboardEntry` 结构体：`id`, `content`, `isTop`, `createTime`, `modifyTime`
- 分页大小 30，支持置顶条目和普通条目分离存储

**Dependencies:** Task #14（PresetGesture 已完成）

- [ ] **Step 1: 实现 HistoryClipboardManager 核心类**
  基于原始 HistoryClipboard.m，精确移植：
  - SQLite 表 `local_history_clipoard`（id, content, is_top, create_time, modify_time）
  - `enableHistoryClipboard()` — 启动轮询 NSTimer（0.5s 间隔），监听 NSPasteboard changeCount
  - `insertLocalHistoryClipboard(content:isTop:)` — base64 编码存储，SQLite 插入
  - `getHistoryClipboardList(firstPage:)` — 合并 topList + historyList 分页
  - `getTopList()` — 查询 is_top=1 的条目
  - `nextPage()` — 翻页加载
  - `clearTop()`, `clearAll()`, `deleteExpired()` — 清理方法
  - `deleteEarliestItem(isTop:)` — 删除最早条目以限制总数

- [ ] **Step 2: 实现剪贴板轮询和持久化**
  - 使用 Timer.scheduledTimer 每 0.5s 检查 NSPasteboard.generalPasteboard().changeCount
  - 检测到变化时，获取字符串内容并插入数据库
  - 支持存储限制（limitTotal）和置顶限制（limitTop）
  - 支持过期清理（limitSaveDays）

- [ ] **Step 3: 编写单元测试**
  - 测试插入条目、查询列表、置顶、翻页、删除
  - 测试空数据库边界情况

- [ ] **Step 4: 运行测试验证**
  运行: `swift test --filter HistoryClipboard`
  预期: 所有测试通过

---

## Task 16: RightClickMenu（右键菜单扩展）

**Files:**
- Create: `Sources/RightClickMenu/RightClickMenuManager.swift`
- Create: `Sources/RightClickMenu/RightClicksList.swift`
- Create: `Sources/FinderSyncExtension/FinderSync.swift`（扩展已存在，需补全）
- Modify: `Package.swift`（FinderSyncExtension target 依赖）

**Interfaces:**
- `RightClickMenuManager`：管理 FinderSyncExtension 启用/禁用，发送分布式通知
- `RightClicksList`：管理右键菜单应用列表（bundle ID 通配符匹配）
- FinderSyncExtension：接收 Finder 通知，提供"新建文本文件"、"在终端打开"、"复制文件路径"

**Dependencies:** 无

- [ ] **Step 1: 实现 RightClicksList**
  基于原始 RightClicksList.m：
  - NSUserDefaults 持久化，NSKeyedArchiver 序列化
  - `needRightClickByAppname:` — 支持通配符匹配（如 com.jetbrains.*）
  - `addRightClicks`, `removeAtIndex`, `clear`, `reInit`
  - 默认包含 com.jetbrains.*

- [ ] **Step 2: 实现 RightClickMenuManager**
  基于原始 RightClickMenu.m：
  - `initFinderSyncExtension` — 注册 NSDistributedNotificationCenter 观察者
  - `syncSharedDefaultsToFinderSyncExtension` — 同步启用状态到扩展
  - `newFile(path:)` — 在 Finder 路径下新建文本文件（带重命名冲突处理）
  - `openInTerminal(path:)` — 用默认终端打开路径
  - `copyFilePath(path:)` — 复制文件路径到剪贴板
  - `enableFinderExtension` / `disableFinderExtension` — 使用 pluginkit 命令
  - `reEnableFinderExtension` / `delayedEnableFinderExtension` — 禁用后重新启用

- [ ] **Step 3: 补全 FinderSyncExtension**
  当前 Sources/FinderSyncExtension/FinderSync.swift 可能是空壳，补全：
  - 实现 NSExtensionRequestHandling 协议
  - 处理 newFile、openInTerminal、copyFilePath 操作
  - 接收来自主应用的分布式通知

- [ ] **Step 4: 运行测试**
  运行: `swift build`
  预期: 编译通过

---

## Task 17: 完整设置面板（Preferences 标签页 UI）

**Files:**
- Modify: `Sources/Preferences/PreferencesView.swift`
- Modify: `Sources/Preferences/Preferences.swift`
- Modify: `Sources/Preferences/PreferencesWindowController.swift`

**Interfaces:**
- 多标签页偏好设置窗口，参考原始 AppPrefsWindowController 的 8 个标签页：
  General | Rules | AppleScript | Filters | RightClick | RightClickMenu | Clipboard | About
- 每个标签页对应完整的设置项，参照原始 AppPrefsWindowController.m 的界面布局

**Dependencies:** Task #15（HistoryClipboard）, Task #18（AppleScriptsList）

- [ ] **Step 1: 实现标签页导航**
  原始设置窗口有 8 个标签页，当前只有单个 ScrollView。需要改为标签页式：
  - 使用 NSSegmentedControl 或 Picker 作为标签栏
  - 每个标签页对应一个独立的 SwiftUI View
  - 窗口宽度扩展到 800，高度 600-800

- [ ] **Step 2: General 标签页**
  - 启用/禁用手势捕获
  - 状态栏图标显示
  - 登录启动
  - 语言选择（en/zh-Hans）
  - 版本号显示

- [ ] **Step 3: Rules 标签页**
  - 规则列表表格（NSTableView 或 List）
  - 添加/删除规则
  - 规则触发条件：手势方向 + 应用过滤器
  - 动作类型：shortcut / appleScript / text / password
  - 重置规则（恢复预设）
  - 清空规则

- [ ] **Step 4: Filters 标签页**
  - 黑名单/白名单模式切换
  - 黑名单文本视图
  - 白名单文本视图
  - 应用按钮
  - 从应用选择器添加

- [ ] **Step 5: AppleScript 标签页**
  - AppleScript 列表表格
  - 添加/删除/编辑脚本
  - 示例脚本下拉选择

- [ ] **Step 6: RightClick + RightClickMenu 标签页**
  - 启用右键菜单开关
  - 新建文件/终端打开/复制路径 子选项
  - 应用列表（支持通配符）

- [ ] **Step 7: Clipboard 标签页**
  - 启用剪贴板历史开关
  - 置顶条目限制
  - 总条目限制
  - 保存天数限制

- [ ] **Step 8: About 标签页**
  - 版本号
  - README HTML 内容展示

- [ ] **Step 9: 运行验证**
  运行: `swift build`
  预期: 编译通过，设置窗口可正常打开

---

## Task 18: AppleScriptsList 管理

**Files:**
- Create: `Sources/AppleScriptRunner/AppleScriptsList.swift`
- Modify: `Sources/RuleEngine/Rule.swift`（如需添加 appleScriptId 字段支持）

**Interfaces:**
- `AppleScriptsList` 类：`sharedAppleScriptsList` 单例
- `addScript(name:source:)`, `removeScript(id:)`, `getScriptById(id:)`, `getAllScripts()`
- 基于 UserDefaults 或文件系统持久化

**Dependencies:** 无

- [ ] **Step 1: 实现 AppleScriptsList**
  基于原始 AppleScriptsList.m：
  - 每个脚本包含 id, name, source, createTime
  - 支持添加、删除、查询
  - 持久化到 ~/Library/Application Support/MacStroke/appleScripts.json

- [ ] **Step 2: 编写单元测试**
  - 测试添加、删除、查询脚本
  - 测试空列表边界

- [ ] **Step 3: 运行测试**
  运行: `swift test --filter AppleScript`
  预期: 测试通过

---

## Task 19: CanvasWindow（手势绘制窗口）

**Files:**
- Create: `Sources/EventCapture/CanvasWindow.swift`
- Modify: `Sources/EventCapture/CanvasManager.swift`

**Interfaces:**
- `CanvasWindow`：使用 CGShieldingWindowLevel 的手势绘制覆盖窗口
- 支持多屏幕（NSScreen.screens）
- 绘制手势路径动画
- 半透明背景，点击穿透

**Dependencies:** Task #23（DrawGesture）

- [ ] **Step 1: 实现 CanvasWindow**
  基于原始 CanvasWindow.m：
  - 使用 NSWindow.Level(CGShieldingWindowLevel()) 确保在最上层
  - 设置 windowCollectionBehavior = .canJoinAllSpaces
  - 透明背景，无标题栏，不可激活
  - 多屏幕支持：每个屏幕一个窗口实例
  - 绘制贝塞尔曲线路径

- [ ] **Step 2: 集成到 CanvasManager**
  - CanvasManager 创建/显示/隐藏 CanvasWindow
  - strokeInfinity 绘制逻辑
  - 完成手势后隐藏窗口

- [ ] **Step 3: 运行验证**
  运行: `swift build`
  预期: 编译通过

---

## Task 20: Sparkle 自动更新

**Files:**
- Modify: `Sources/MacStrokeApp/main.swift`
- Modify: `Package.swift`（如需添加依赖）

**Interfaces:**
- Sparkle 框架集成，自动检查更新
- SUUpdater 或 SPUStandardUpdaterController

**Dependencies:** 无

- [ ] **Step 1: 集成 Sparkle**
  - 通过 SPM 或手动方式添加 Sparkle 依赖
  - 在 AppDelegate 中初始化更新器
  - 配置更新检查间隔

- [ ] **Step 2: 运行验证**
  运行: `swift build`
  预期: 编译通过

---

## Task 21: LaunchAtLoginController（登录项）

**Files:**
- Modify: `Sources/EventCapture/LoginManager.swift`
- Modify: `Sources/Preferences/PreferencesView.swift`

**Interfaces:**
- `LoginManager`：SMAppService.mainApp 管理登录项
- 偏好设置中"登录启动"开关

**Dependencies:** 无（当前已部分实现，需完善 UI 联动）

- [ ] **Step 1: 完善 LoginManager**
  - `enableLoginItem()` / `disableLoginItem()` / `isLoginItemEnabled()`
  - 使用 SMAppService.mainApp（macOS 13）

- [ ] **Step 2: 连接 UI**
  - PreferencesView 中登录启动开关绑定到 LoginManager
  - 保存用户偏好设置

- [ ] **Step 3: 运行验证**
  运行: `swift build`
  预期: 编译通过

---

## Task 22: BlackWhiteFilter（黑白名单过滤器）

**Files:**
- Create: `Sources/RuleEngine/BlackWhiteFilter.swift`
- Modify: `Sources/Preferences/PreferencesView.swift`

**Interfaces:**
- `BlackWhiteFilter` 类：`isInWhiteListMode`, `blackListText`, `whiteListText`
- `match(bundleID:)` — 基于文本匹配包 ID
- 支持通配符和正则表达式

**Dependencies:** 无

- [ ] **Step 1: 实现 BlackWhiteFilter**
  基于原始 BlackWhiteFilter.m：
  - `isInWhiteListMode` 静态属性
  - `blackListText` / `whiteListText` 静态属性
  - `match(bundleID:)` — 根据模式匹配应用包 ID
  - 通配符匹配（如 com.jetbrains.*）
  - 正则表达式匹配

- [ ] **Step 2: 集成到规则引擎**
  - RuleEngine.match 在匹配规则前先检查 BlackWhiteFilter

- [ ] **Step 3: 运行验证**
  运行: `swift build`
  预期: 编译通过

---

## Task 23: DrawGesture（画布手势绘制）

**Files:**
- Create: `Sources/EventCapture/DrawGesture.swift`
- Modify: `Sources/EventCapture/CanvasManager.swift`

**Interfaces:**
- `DrawGesture`：处理画布上的手势绘制逻辑
- 手势识别、评分、动画反馈
- 与 CanvasWindow 协同显示绘制过程

**Dependencies:** Task #19（CanvasWindow）

- [ ] **Step 1: 实现 DrawGesture 核心逻辑**
  基于原始 DrawGesture.m：
  - 手势绘制事件处理（mouseDown, mouseDragged, mouseUp）
  - 实时绘制贝塞尔曲线到 CanvasWindow
  - 手势完成后计算评分（DTW 比较）
  - 显示评分反馈（Toast 或 Canvas 上的文字）

- [ ] **Step 2: 集成到 CanvasManager**
  - CanvasManager 调用 DrawGesture 处理绘制逻辑
  - 手势识别后触发 RuleEngine 匹配
  - 执行匹配到的规则动作

- [ ] **Step 3: 运行验证**
  运行: `swift build`
  预期: 编译通过

---

## 执行顺序建议

1. **Task 18** (AppleScriptsList) — 独立，无依赖，其他任务需要它的数据
2. **Task 15** (HistoryClipboard) — 独立，剪贴板持久化
3. **Task 22** (BlackWhiteFilter) — 独立，规则引擎需要
4. **Task 16** (RightClickMenu) — 独立，Finder 扩展
5. **Task 21** (LaunchAtLogin) — 简单，登录项管理
6. **Task 20** (Sparkle) — 独立，自动更新
7. **Task 19** (CanvasWindow) — 需要 CanvasManager 配合
8. **Task 23** (DrawGesture) — 依赖 CanvasWindow
9. **Task 17** (完整设置面板) — 依赖 Task 15, 18，集成所有功能

**全局验证:** `swift build && swift test`
