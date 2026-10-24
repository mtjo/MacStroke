# 划词气泡（文本选中弹窗）方案 v0.2

日期：2026-10-20　状态：**已实现（模块 + 偏好页 + 接线），离线取证跑完，待装机验收**
一句话目标：用户在**别的 App** 里用鼠标划选一段文字后，在光标附近弹一枚小气泡，给几个不装插件就能用的出口（复制 / 搜索 / 翻译 / 朗读）。

功能在仓库里叫**划词气泡**（本地化 key 前缀 `Selection Bubble` / `Selection bubble`），模块 `Sources/SelectionPopup`，总开关 `enableSelectionPopup` **默认关**。第 5、6、9 节记的是实际落地的样子，与 v0.1 方案的偏差在 §9 逐条列出。

## 0. 先把「macOS 支持吗」这件事钉死

没有「文本选中」这个系统事件可以订阅：`NSWorkspace`、`DistributedNotificationCenter` 都不通知这件事，也没有公开 API 让第三方 App 注册「选中变了」的回调。能读到别家 App 选中文本的**唯一现实路径是 Accessibility API**：

```
NSWorkspace.shared.frontmostApplication
  → AXUIElementCreateApplication(pid)
  → kAXFocusedUIElementAttribute          // 当前聚焦的元素
  → kAXSelectedTextAttribute              // 它选中的字符串
```

这条是 Bob / PopClip / 欧路 / 静读天下这类划词工具真正在用的路径，权限就是我们已经有的辅助功能（`main.swift` 里 `AXIsProcessTrustedWithOptions` 那扇门），**不需要屏幕录制**。

三条被排除的路线，评审时可以直接否掉我：

- **剪贴板法**（模拟 ⌘C 读剪贴板再还原）：每次划词都动用户剪贴板 + 往会话里注键，还会被自家 0.5s 粘贴板监控收成历史条目。脏，且违反「不往真实登录会话里注键」这条既有红线。
- **macOS 15 `AccessibilitySharedContent` / Continuity 选中共享**：要 App 主动实现协议，实测只有 Safari / Notes / 邮件这类自家 App 支持，且包下限 `.macOS(.v13)` 对不上。
- **OCR 兜底**（`ScreenshotOCR.swift` 现成）：处理的是「图上印着的字」，和「划得动的真文本」是两件事。混进来就要屏幕录制权限、要用户再框一次，一期不做。

## 1. 一期做不到 / 不承诺的（写明白，省得验收时扯）

| 事 | 结论 |
| --- | --- |
| 气泡贴在**选中的那几个字**旁边 | 做不到。AX 只给 `kAXSelectedTextRangeAttribute`（字符区间）和整个文本框的 `kAXPosition/Size`，不给那一段的像素矩形。一期只贴**鼠标抬起点**右下 ~12pt |
| 密码框 / Secure Input 期间 | 读不到，也不弹（正当行为，不绕） |
| 划词事件精确时刻 | `kAXSelectedTextChangedNotification` 理论可用，但要给别家 App 每个 focus 元素挂 observer、切 App/切窗口都得重挂，一期不用，改成「抬起后延迟读一次」 |
| 富文本 / 自绘控件的 App | 读回来是空或纯乱码。靠判定函数挡掉，不弹 |

## 2. 触发链路（重点：不进 `pointerDown` 那棵判定树）

现成的事件入口是 `Sources/EventCapture/EventCapture.swift`：tap 建在 `.cghidEventTap` + `.defaultTap`，mask 里有 `.leftMouseDown`，**但没有 `.leftMouseUp` / `.leftMouseDragged`**；左键按下这一路进来只为了一个用途 —— 手势进行中把左键吞掉防误触（`CanvasManager.eventCapture` 里 `case .left: return shouldShow && isCapturing`）。

**一期不改这棵树**，改用只读监听（实现里的 `SelectionBubbleController.monitorMask`）：

```swift
NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
```

比方案里多收一条 `.leftMouseDown`，为的是「读期间用户又按了一次 = 这次作废」和「按下即抬起的纯单击 = 不算划词」这两条判定 —— 只读监听拿不到「吞不吞」，多收一条不会多挡下任何一次点击。

理由，按这个工程的优先级排：

1. 加进 mask 意味着左键的每一次按下—拖动—抬起都要穿过 **HID 层 + defaultTap** 的回调。这是这条链路上最敏感的地方，用户历史上压过一句硬约束：「识别执行和时间不要受到影响」。划词这个附带功能不值当拿它换。
2. 在 tap 回调里返回 `passUnretained` 就变成**改写**投递语义，要吞得自己判、还得维护 `deliver(_:at:)` 那套（issue #73 刚动过）。
3. 全局监听**天生只读**、拿不到「吞不吞」，结构上就不可能伤到手势与别的 App 的正常点击。副作用是它不覆盖自家窗口的事件，正合适。

判定「这是一次划词」的规则（纯函数，可单测）：

- 同一次按压里收到过 ≥1 个 `.leftMouseDragged`，且轨迹包围盒两条边都 ≥ `selectionMinTravel`（**待定，先 6pt**）；按下即抬起的纯单击不算。
- 抬起后**延迟 `readDelay`（先 250ms，探针实测后再定）**再读，早读常拿到空。
- 这一拍之间，前台 App 变了 / 鼠标又按下了 → 作废，不弹。
- ⌥/⇧/⌘ 任一按下着的划选不弹（用户可能在做区间选择/连选，弹了碍事）。

## 3. 形态

`NSPanel` + `.borderless` + `.nonactivatingPanel` + `level = .floating`，一条自绘胶囊，复用截图注解条那套底衬/墨色/图标语言：

- **底衬跟随系统明暗**，照 `ToolbarStyle.resolved(for:)` 那套做法；色块和线宽这类要进成品的才写死 sRGB —— 这里没有要导出的东西。
- **不 `NSApp.activate`**：`.nonactivatingPanel` 可以点。**键盘不进来**，所以 Esc 关闭只走 `addLocalMonitorForEvents`，拿不到就退回「点别处自动收」。
- 层级用 `.floating`，**不用 `CGShieldingWindowLevel`** —— 那层是抢整屏交互的，划词气泡不该挡掉用户下一次点击。
- 气泡 `hitTest` 只对格子返回视图，空白处放行；每个格子**自己吃掉 `mouseDown`**，否则顺 responder chain 冒到 `NSWindow`，就成了「点了等于没点」（录屏胶囊那个坑的第二次踩）。
- **`sharingType = .none`**：否则自家截图工具会把这枚气泡拍进成品图。
- 消失规则：点格子 / 点别处 / 焦点或前台 App 变了 / 新划词（气泡跟着挪位换内容）/ 停留 6s 后淡出。

## 4. 功能（一期克制，全用 URL 或系统能力）

1. **复制** —— 写 `NSPasteboard`，不显式插入历史（被自家 0.5s 监控自动收成条目，这条与截图复制同源）
2. **搜索** —— 默认搜索引擎，URL 模板可在偏好里改，默认 `https://www.google.com/search?q=`（**这一条到第六轮已扩成「一张表 + 一条自选模板」：六家搜索 + 八家网页 AI + 自定义，见 §14**）
3. **翻译** —— 走网页 `https://translate.google.com/?sl=auto&tl=zh-CN&text=`，不接 API、不要 key
4. **朗读** —— `AVSpeechSynthesizer`，中文自动选 zh-CN voice，再点一次停，零依赖

不做（列出来是为了别默默跳过）：词典/翻译引擎、送进 AI、格式转换、加入粘贴板收藏、OCR 兜底。

## 5. 偏好与黑名单（实际落地版）

**侧栏独立一页「划词气泡」**（`PreferencesTab.selectionBubble` → `Sources/Preferences/SelectionBubbleTabView.swift`），排在靠近锁屏之后、关于之前。一开始是给常规页底部铺一段三行，评审时被驳回：这一条要配的东西是「一条总开关 + 两条触发 + 四格各自开关 + 一个延迟」共九项，压在原版最满的常规页底部会把导入/导出/重置顶出可视区，而且用户在侧栏里搜不到名字。四段各一个 `SettingsSection`：

| 段 | 行 | 控件 | 落盘的键 | 默认 |
| --- | --- | --- | --- | --- |
| 划词气泡 | 启用划词气泡 | `TrailingSwitch` | `enableSelectionPopup` (Bool) | **`false`** |
| 触发方式 | 划完字自动弹出 | `TrailingSwitch` | `selectionPopupAutoPop` (Bool) | `true` |
| 触发方式 | 手动快捷键唤出 | `TrailingSwitch` | `selectionPopupShortcutEnabled` (Bool) | `true` |
| 触发方式 | 快捷键 | `ShortcutRecorder`（200×28，带清除叉） | `selectionPopupShortcut` (String) | `keyCode=11, flags=1310720` = ⌃⌘B |
| 气泡上的四个功能 | 复制 / 搜索 / 翻译 / 朗读 | 四行 `TrailingSwitch`（`ForEach` over `SelectionBubbleAction.allCases`） | `selectionPopupActionCopy` / `…Search` / `…Translate` / `…Speak` (Bool) | 全 `true` |
| 读取时机 | 读取延迟 | `Slider`，步长 `readDelayStepMilliseconds` = 50ms，区间 50…1500 | `selectionPopupReadDelay` (Int，毫秒) | 250 |

「灰」的规则只有一句话：画出来的条件 = 消费端判定用的条件，都从 `SelectionBubbleSettings` 那几个纯函数取（`popsOnSelection` / `popsOnShortcut` / `monitorShortcut` / `hasCells`）。总开关关掉 → 其余八项全灰（灰而不隐藏，隐藏会让人以为功能少做了）；「手动快捷键唤出」自己关掉 → 只有快捷键录制框灰；读取延迟只作用在自动那一路 → 跟着「划完字自动弹出」灰。四格全关时页面底部出现一句橙色说明（这是「功能开着但什么都不会发生」的唯一一种配法，不说破用户只以为坏了）。

九项都不发专用通知：App 层在 `UserDefaults.didChangeNotification` 里比一份 `SelectionBubbleSettings` 快照（它本身 `Equatable`，整个结构体拿来比，新增字段自动进比较），变了才重喂 —— 和截图那两条快捷键同一个路子。总开关一关，`SelectionBubbleController.stop()` 把左键监听、App 切换观察者、正在等的那次读取、浮着的气泡、还没念完的话一次收干净；递给快捷键那只 monitor 的串换成空串（`monitorShortcut`），也就是**连键位都不占**。「划完字自动弹出」单独关掉时只拆左键那三档监听（`refreshMouseMonitor`），⌃⌘B 照常 —— 这条是本轮改版新增的行为差别。

App 过滤**复用现有 filter 语义**（App 层把 `BlackWhiteFilter.shared.shouldHookMouseEventForApp(bundleID)` 注进 `isAppAllowed`），不另造一份名单；截图遮罩摊开期间同样不弹（`ScreenshotController.shared.isActive`）。密码类输入框由「读到空/异常」自然挡掉。

上表是**头两轮的状态**。第五轮在后面加了「读不到选区时」那一段（`selectionPopupCopyFallback`，见 §13），第六轮又加了「搜索走哪一家」那一段（`selectionPopupSearchEngine` + `selectionPopupSearchCustomURL`，见 §14）。两段都照同一句老规矩接：键进 `SelectionBubbleSettings.current(from:)`、灰的条件从同一份快照取、不发专用通知。


## 6. 取证（能不能自己验，决定评审能不能过）

`swift test` 进程里没有辅助功能授权，这条链**自测不了** —— 与远程控制 E2E 同一堵墙。所以判据得拆两半：

**离线可测（接缝注入）** — 接缝比方案开的多几条，但都开在「系统调用」那一步上，判定本身全是纯函数：

- `SelectedTextReader`：`read() -> SelectedTextResult`（`Scope` 分 `.systemWide` / 某个 pid / `.atPoint(pid, 松手点)` 三档，见 §11），真 AX 调用藏在 `readReal(from:)` 后面；接缝开在「读一个来源」（`readSourceOverride`）和「往进程写开关」（`enableOverride`）这两步上。`string(from:)`、`classify(...)`、`cgPoint(appKit:primaryHeight:)`、`pid(of:)` 各自单独可测，因为 `kAXSelectedTextAttribute` 实测会返回 CFString **或** CFAttributedString，而坐标翻转/归属核对那两手的坏在界面上都长成「就是不弹」。
- `SelectionTrigger.evaluate(drag:flags:…) -> Decision`：`.show(text)` / `.skip(原因)`。
- `SelectionBubbleController`：`monitorRegistration` / `monitorRemoval` / `appSwitchRegistration` / `readerFactory` / `frontmostApp` / `cursorLocation` / `presenter` 全部可注入，测试用 `Tests/SelectionPopupTests/Fakes.swift` 那套假件。`readerFactory` 的第二参数是**松手点**（`CGPoint?`），容器那一手全靠它，`Fakes` 把每次收到的坐标记下来钉住（§11）。成功那行日志的正文抽成了 `SelectionBubbleController.successLogLine(...)` 纯函数 —— 不然「按 App 统计谁有效」这句话永远只能靠肉眼核日志。
- `SelectionBubbleLayout`：`cellFrame` / `capsuleSize` / `panelFrame` / `windowConfig` 纯函数。
- `SelectionBubbleLinks`：搜索/翻译 URL 拼装。

判据写「为什么弹 / 为什么不弹」，不写「弹了几次」：拖出 6pt 才算划词、纯单击不读、读到空/纯空白不弹、超上限（2000 字）不弹、按下修饰键时划选不弹、读期间换 App 结果作废、总开关一关监听整个拆掉。

用例分布（`swift test --filter "SelectionPopupTests|SelectionBubblePreferencesTests"` = 122 条，全绿）：SelectedTextReader 35（第二轮记的是 22，第三轮加 13，见 §10、§11）、Controller 26（第二轮 21、第三轮加 5）、Layout 10、Links 10、Settings 13、Trigger 8、Render 9，加独立偏好页那一页的取证 11 条（`Tests/WindowManagerTests/SelectionBubblePreferencesTests.swift`）。全量 846 条 / 1 skip（`testMirrorFramesFollowTheSwitch`，要屏幕录制授权）/ 1 条红，而那条红与划词无关：`RemoteControlServerE2ETests.testTypeAndKeyReachTheEventStream` 两处断言。判环境要同时读两个数（探针 `/tmp/sesschk.swift`，走的正是 `Sources/ProximityLock/ScreenLock.swift` 那句 `CGSessionCopyCurrentDictionary`）：跑红的那一次（10:43）`CGSSessionScreenIsLocked = 1`、`kCGSSessionSecureInputPID` = 212 = `loginwindow`；同一份代码 10:25 那一次 846 条 0 红。屏锁着、安全输入被别人占着，注入的按键到不了会话流，`flagsChanged` 却照样收得到，所以只有键入那两条红 —— 只看 `CGSSessionScreenIsLocked` 会把它误判成代码问题。

**真链路只能靠日志** — 前缀 `[SelectionBubble]`：`开始监听划词（延迟 Nms）` / `读到了：N 个字符 —— <包名> pid=…（<哪一手答上来的>）` / `弹气泡：N 个字符，格子 …，位置 …` / `读选区失败（<原因>），不弹 —— <包名> pid=…`。**「读到了」那一行是这一版才有的**：上一版只有失败行带 App 名，成功行不带，于是装机时问「现在到底哪些软件里有效果」日志答不上来（§11）。AXError 码的含义按 `HIServices/AXError.h`（第一轮这张表写错过一档，把 -25212 当成超时、-25204 当成无值，归因跟着指错方向）：

| 码 | 名字 | 在这一条链路里是什么意思 | 分类到 |
| --- | --- | --- | --- |
| -25211 | APIDisabled | 对方没开无障碍接口（Chromium 那一类在写开关之前） | `.accessibilityNotEnabled` → 请开接口 |
| -25204 | CannotComplete | **通信超时**：对方这个时间没答话 | `.timedOut` → 不补救 |
| -25205 | AttributeUnsupported | 没这个属性：SwiftUI 的文本框、被拒的开关写入 | `.selectedTextUnsupported` → 只探测鼠标点 |
| -25208 | NotImplemented | 同上，属性存在但实现没做 | `.selectedTextUnsupported` |
| -25212 | NoValue | **属性在、这一格当前没有值**：焦点元素是容器（`AXWebArea`、`AXRow`），选区在子树里 | `.noSelectedTextValue` → 改读鼠标点并上溯（§11） |
| -25202 | InvalidUIElement | 焦点元素已作废（切 App 那一瞬最容易撞） | `.noFocusedElement` |

这条是「读不到」的唯一分类办法，装机验收就按它记。方案的 P0 探针（App×场景可读性表）折进这一步一起做：装机时逐 App 划一次，看日志里读到几个字。

**离屏渲染验形态** — `SelectionBubbleRenderTests`：把视图挂到一扇 `NSWindow` 上（不挂的话 SwiftUI/AppKit 的 focus context 不全，字形会画丢），`cacheDisplay` 出 PNG 到 `/tmp/macstroke-selection-bubble-check`，判据取像素和 `cellIDs` 串。九条对应下面的 M39–M43 与 M47，第九条（`testOnlyTheCellsTheUserLeftOnGetBuilt`）验的是「用户关掉两格之后，剩下的格子对象、格子位置、点击命中仍指同一个人」。两点诚实交代：**y 方向翻不翻转验不出来**（格子高度 == 胶囊高度，两种朝向的位图一样），这条只能靠 M36 那个「永远不盖住锚点」的位置纯函数咬；图标那条（M41）咬的是「有没有墨」，咬不到「是不是那个 SF Symbol」。同一个「格子高度 == 胶囊高度」还让 M62 变成了一条**等价变异**（见下表下面那段）。

**反向变异**（脚本 `/tmp/mut_selection.py`、`/tmp/mut_bubble_wiring.py`、`/tmp/mut_bubble_page.py`、`/tmp/mut_reader.py`、`/tmp/mut_reader3.py`、`/tmp/mut_reader4.py`；M52 重跑 `/tmp/mut_m52.py`、M70 重跑 `/tmp/mut_m70.py`；日志 `/tmp/mut-log-*.txt`，完整输出 `/tmp/mut-out-*/`）

| 变异 | 咬住它的用例 | 结果 |
| --- | --- | --- |
| M33a 单击也算划词 | Controller.testASingleClickDoesNotEvenRead、Trigger.testASingleClickIsNotASelection | 断言红 |
| M33b 位移下限写成 0 | Trigger.testATwitchShorterThanTheMinimumTravelIsNotASelection | 断言红 |
| M34a 读到空串也弹 | Controller.testNothingWorthShowingNeverReachesTheScreen 等 2 条 | 断言红 |
| M34b nothingSelected 当有字上屏 | 同上两条 | 断言红 |
| M35 读期间切 App 照弹 | Controller.testAProcessChangeDuringTheReadKillsTheResult | 断言红 |
| M36 离鼠标的缝写成 0 | Layout 两条（含「任何时候不盖锚点」） | 断言红 |
| M37 层级改成 `.statusBar` | Layout 两条窗配置取证 | 断言红 |
| M38 监听多收滚轮事件 | Layout.testMonitorMaskIsExactlyTheThreeLeftButtonEvents | 断言红 |
| M39 四格全绑第一格的动作 | Render.testEachCellFiresOnlyItsOwnAction、testClicksNearTheBorder… | 断言红（第一版是编译红，不构成行为差别，改成能编译的写法重跑） |
| M40 底衬写死浅档 | Render.testBodyColourFollowsSystemAppearance 等 3 条 | 断言红 |
| M41 图标不画 | Render.testGlyphsAreVisibleInBothAppearances | 断言红 |
| M42 画成直角矩形 | Render.testBubbleIsACapsuleNotARectangle | 断言红 |
| M43 按下没有反馈 | Render.testPressedCellPaintsItsOwnBackground | 断言红 |
| M44 关掉仍挂监听 | Controller.testTheMasterSwitch…、testTurningTheSwitchOffInvalidatesTheReadInFlight | 断言红 |
| M45 坏延迟夹到边界 | Settings.testBrokenReadDelayFallsBackToTheDefault… | 断言红 |
| M46 只认 CFString | SelectedTextReader.testBothFlavoursOfTheAttributeValueBecomeAString | 断言红 |
| M47 四格全摆同一格位置 | Render 同 M39 那两条 | 断言红 |
| M48 总开关默认改成开 | Settings.testFactoryDefaultIsOff、prefs.testOffByDefault、testSnapshotChangesForEverySingleField | 断言红（5 条） |
| M49 默认快捷键修饰键位写成 0（裸按 B） | Settings.testDefaultShortcutIsControlCommandBAndCollidesWithNothing | 断言红 |
| M50 读取延迟无视库里那个值 | Settings.testBrokenReadDelayFallsBack…、prefs.testDelayRoundTripsMillisecondsToSeconds、testSnapshotChangesForEverySingleField | 断言红（3 条） |
| M51 偏好页照原样显示越界延迟（看到的数和跑的两回事） | prefs.testGarbageDelayFallsBackOnBothSides | 断言红 |
| M52 关掉总开关时延迟那格不灰 | 当时是 prefs.testDelayRowGreysOutWhenTheSwitchIsOff；独立页改版后由 prefs.testMasterSwitchGreysTheWholePageNotJustItsOwnRow（M56 那一条）接管 | **第一版全绿（逃掉了）**，判据改对后断言红 |
| M53 滑杆步长改成 37（默认值和上下限都滑不出格子） | prefs.testSliderGridReachesTheDocumentedRange | 断言红 |
| M54 关掉开关仍把快捷键递去挂监听（占着键位不做事） | Settings.testOffYieldsAnEmptyShortcutSoTheKeyIsNotOccupied | 断言红 |
| M55 监听快照只比开关、不比延迟和快捷键（改了不重挂） | prefs.testSnapshotChangesForEverySingleField | 断言红 |
| M56 总开关只灰自己那一行，其余八项照常可点 | prefs.testMasterSwitchGreysTheWholePageNotJustItsOwnRow（顺带 testManualTriggerOnlyGreysTheShortcutRow） | 断言红（2 条） |
| M57 四格接的是同一份绑定（关哪一格都是第一格在动） | prefs.testEachCellSwitchIsItsOwnRow（顺带 M56 那条） | 断言红（10 条：三格「关掉没有任何可见变化」+ 两两相同的配对断言） |
| M58 「手动快捷键唤出」一关把自动弹和四格一起灰掉 | prefs.testManualTriggerOnlyGreysTheShortcutRow | 断言红（2 条） |
| M59 关掉「划完字自动弹出」仍挂左键的全局只读监听 | Controller.testTurningAutoPopOffTakesOnlyTheMouseButtonMonitorDown | 断言红（3 条） |
| M60 关掉「手动快捷键唤出」把左键监听一起拆了 | Controller.testTurningTheShortcutOffLeavesTheMouseButtonMonitorAlone | 断言红 |
| M61 四格全关仍照常弹（`hasCells` 不参与两条触发的判定） | Controller.testNoCellsStopsBothTriggerPathsFromEvenReading、Settings.testNoCellsStopsBothTriggersButLeavesTheMasterAlone | 断言红（5 条） |
| M62 过滤后的格子仍按四格的尺子摆位 | —— | **等价变异，全绿（改它没有行为差别，见下面那段）** |
| M63 滑杆把秒当毫秒显示（界面上是 0、实际跑 250） | prefs.testDelayRoundTripsMillisecondsToSeconds、testEveryFieldLandsInTheStore、testGarbageDelayFallsBackOnBothSides、testOffByDefault | 断言红（6 条） |
| M64 「朗读」那一格拨了不落盘（界面动了库里没动） | prefs.testEveryFieldLandsInTheStore、testSnapshotChangesForEverySingleField、testEachCellSwitchIsItsOwnRow | 断言红（3 条） |
| M65 两个开关属性换了个儿：贵的 `AXEnhancedUserInterface` 先写 | Reader.testChromeShapeWritesTheSecondSwitchAfterTheFirstIsRejected、testTheCheaperEnableAttributeIsTriedFirst | 断言红（2 条） |
| M66 「试过了」的名单退回按进程记（旧代码的坑：Chrome 拒收第一条后第二条永没机会） | Reader.testARejectedAttributeDoesNotBlockTheNextOneOnTheSameProcess、testBothSwitchesRejectedFallsBackToTheSystemWideElement、testChromeShape…、testTheSecondDrag… 等 4 条 | 断言红（4 条） |
| M67 控件压根不给选区时也去请对方开接口 | Reader.testAnElementThatAlreadyRefusesSelectionGetsNoSecondLook、testOnlyTheNoAccessibilityFailuresAskTheAppToOpenItsInterface、testTheSystemWideFallbackIsNotWastedOnAnElementWeAlreadyHold 等 4 条 | 断言红（4 条） |
| M68 焦点元素已经拿到手，还换系统级那份再读一遍 | Reader.testAnElementThatAlreadyRefusesSelectionGetsNoSecondLook、testTheSystemWideFallbackIsNotWastedOnAnElementWeAlreadyHold | 断言红（2 条） |
| M69 超时那一档也去补救（一次划词排三回跨进程队） | Reader.testOnlyTheRecoverableFailuresAreWorthAnotherTry | 断言红 |
| M70 关掉功能时不清「试过了」的名单 —— **第一版写法** `removeAll(keepingCapacity: true)` | —— | **等价变异，全绿**（这句照样把名单清空，见下面 M70 那段） |
| M70b 同一条改成真写法：`removeValue(forKey: "__never__")`，一个进程号都不清 | Controller.testTurningTheFeatureOffReleasesTheAccessibilityRequests、Reader.testTurningTheFeatureOffResetsTheEnableBookkeeping | 断言红（2 条） |
| M71 读取预算改成 1：补救那一手压根轮不到 | Reader.testAJustOpenedInterfaceRereadsItsOwnTreeAndStopsThere、testBothSwitchesRejected…、testChromeShape…、testTheSecondDrag… 等 8 条 | 断言红（8 条） |
| M72 刚开成接口、树还没建好时，报的是第一次的错 | Reader.testAJustOpenedInterfaceRereadsItsOwnTreeAndStopsThere | 断言红 |
| M73 系统级那份也读不到时，用第二次的错盖掉第一次 | Reader.testTheSystemWideFallbackDoesNotStealTheBlame | 断言红 |
| M74 接缝被摘掉（次序用例其实在测真无障碍调用） | Reader 那批次序用例全体（21 条） | 断言红（21 条） |
| M75 控制器 `stop()` 不再请 reader 放掉名单（接线漏了） | Controller.testTurningTheFeatureOffReleasesTheAccessibilityRequests | 断言红 |
| M76 鼠标点那一手整个摘掉（退回第二轮的样子：邮件、Chrome 每次划词都停在容器上） | Reader.testTheFocusedContainerIsWorkedAroundUnderTheCursor、testOnlyTheContainerShapedFailuresAreProbedUnderTheCursor、testAnEmptySelectionFromTheProbeIsAnAnswerNotAFailure、testAnElementThatAlreadyRefusesSelectionGetsNoEnableOrSystemWideRetry 等 | 断言红（12 条） |
| M77 鼠标点那一手无条件上场（超时、拿不到焦点元素也去探测） | Reader.testOnlyTheContainerShapedFailuresAreProbedUnderTheCursor | 断言红（5 条） |
| M78 -25212 又并回 -25205 那一句（能绕的被写成「这个 App 修不了」） | Reader.testNoValueIsNotTheSameAsAttributeUnsupported | 断言红（2 条） |
| M79 控制器把松手点丢了（reader 永远拿到 nil → 容器那一手轮不到） | Controller.testAPlayedDragHandsItsReleasePointToTheReader、testTheReleasedPointTravelsIntoTheReader | 断言红（2 条） |
| M80 探测拿的是 `.zero` 而不是松手那一点（打到屏幕左上角别人家的窗口） | Reader.testTheProbeUsesTheReleasedPointNotSomewhereElse、testTheFocusedContainerIsWorkedAroundUnderTheCursor | 断言红（3 条） |
| M81 没有坐标也去探测（快捷键那一路凭空拿 `.zero` 打一次） | Reader.testTheProbeIsSkippedWhenThereIsNoPointToHitTest | 断言红（3 条） |
| M82 探测没答上来时用它的错盖掉第一次（`role=` 那句归因丢了） | Reader.testTheProbeDoesNotStealTheBlameEither、testAnElementThatAlreadyRefusesSelectionGetsNoEnableOrSystemWideRetry | 断言红（2 条） |
| M83 「哪一手答上来的」无条件记（探测读回空也算探测答的 → 成功那行指错地方） | Reader.testAnEmptySelectionFromTheProbeIsAnAnswerNotAFailure、testTheProbeDoesNotStealTheBlameEither | 断言红（2 条） |
| M84 成功那行日志不写是谁（「现在什么软件里有效果」又答不上来） | Controller.testTheSuccessLineNamesTheAppAndTheAnsweringSource | 断言红（2 条） |
| M85 成功那行日志不写靠哪一手读到的（下一轮不知道该收窄哪一档） | Controller.testTheSuccessLineNamesTheAppAndTheAnsweringSource、testTheSuccessLineSurvivesAnUnrecordedSource | 断言红（2 条） |
| M86 探测改用主读的 0.6s（慢 App 面前一次划词排六回队） | Reader.testTheCursorProbeIsGivenAShorterTimeoutThanTheMainRead、testWorstCaseLatencyStaysUnderASinglePerceptibleBeat | 断言红（2 条） |
| M87 往上只走一格（正文里打中的是 `AXStaticText`，管选区的是祖先） | Reader.testTheCursorProbeIsGivenAShorterTimeoutThanTheMainRead 里那句 `XCTAssertGreaterThan(maximumElementsProbedAtThePoint, 1)` | 断言红（1 条）—— **只咬住常量，没咬住行为**，见下面那段 |
| M88 坐标不翻 y（AppKit 左下原点直接喂给 CG 的左上原点 → 永远打不中） | Reader.testThePointIsFlippedIntoCoreGraphicsCoordinates | 断言红（3 条） |
| M89 最坏耗时退回「只算一次主读」（鼠标点那几趟从账上消失） | Reader.testWorstCaseLatencyStaysUnderASinglePerceptibleBeat | 断言红（1 条） |
| M90 焦点是容器时也去请对方开接口（接口本来就开着，白让人家多维护一棵树） | Reader.testOnlyTheNoAccessibilityFailuresAskTheAppToOpenItsInterface、testTheFocusedContainerIsWorkedAroundUnderTheCursor、testTheSystemWideFallbackIsNotWastedOnAnElementWeAlreadyHold 等 | 断言红（4 条） |
| M91 -25212 那一档从「值得再试」名单里删掉 —— **第一版写法** | — | **编译红**（`switch must be exhaustive`，不构成行为差别） |
| M91b 同一条改成挪进 `false` 那一组（穷尽性不动，改的只是这一档补不补） | Reader.testOnlyTheRecoverableFailuresAreWorthAnotherTry、testTheFocusedContainerIsWorkedAroundUnderTheCursor、testTheProbeUsesTheReleasedPointNotSomewhereElse 等 | 断言红（9 条） |
| M92 命中元素「是不是这一家的」那道闸摘掉（`readAtPoint` 里的真 AX 段） | — | **全绿，有意抓不到**（离线够不着，见下面那段） |
| M93 命中那一格与每格父级不再单独设超时（同段） | — | **全绿，有意抓不到** |
| M94 探测读到空选区时不再记账（收尾把「选区为空」报成「容器没有选区」；同段） | — | **全绿，有意抓不到** |

M52 这一条值得单独交代，因为它暴露的是**取证方法本身的洞**：整页位图里跟着这个开关变的东西有两样 —— 最右侧那小块开关、和左面那一大片被禁用的滑杆。原判据只数「整页有没有差」，开关那一小块的差把「滑杆没灰」这个坏消息整个盖掉了，于是变异跑完全绿。现在把差值按 x 分带数（0.70 宽这条线以左是滑杆带，以右是开关带，行右端开关的左沿实测在 ~0.84 宽）：右侧带必须有差（证明渲染真吃到了库里那个值，否则后面什么都判不了），左侧带也得有差（那才是灰掉），再加一条「整页都在变 = 布局被重排了」的上限。改完拿 `/tmp/mut_m52.py` 单独重跑 M52，断言红。

六批合计表里 66 行（M33–M64 那三批 34 行 + 第四批 M65–M75 共 12 行 + 第五批 M76–M92 共 17 行 + 第六批 M91b/M93/M94 共 3 行；M70 与 M70b、M91 与 M91b 各是同一条的两种写法），断言红抓到 60、等价变异 2（M62、M70 第一版）、编译红 1（M91 第一版，已由 M91b 补上）、有意抓不到 3（M92/M93/M94）；其中 M39 第一版是编译红（不构成行为差别，换能编译的写法重跑）、M52 第一版整页判据逃掉（改分带判据后重跑）、M70 第二版 `removeAll(where:)` 是编译红（字典上没这个方法），第三版 `removeValue(forKey:)` 才真把两条用例咬红。

M62 这一条要交代清楚，因为「跑完全绿」长得和 M52 那一回一模一样，但根子完全不同：`cellFrame(index:cellCount:)` 里那个 `cellCount` 只喂给 `capsuleSize(...).height`，而胶囊高度恒等于格子高度（`(size.height - cellSize.height)/2` 就是 0），所以把 `cellCount: count` 换成 `cellCount: 4` 算出来的 NSRect 一个点都没变 —— **没有任何判据能抓到它**，写一条去抓它等于把被测常量当判据。这个参数留着是给「将来胶囊比格子高」那一档留的口子（和上面 y 方向验不出翻转是同一个事实的两面）。换句话说：这一格抓到的是「取证没咬住」，还是「坏根本不存在」，得先分清楚再改判据 —— 上一回（M52）是前者，这一回是后者。

独立页改版后，M52 那套「按 x 分带」的判据升级成更通用的一条规矩：**差值必须拿另一档状态当尺子**，不数绝对阈值。总开关那一条拿「只关一格」的差值当分母（M56），四格那一条拿「两张图不许一模一样」当判据（M57），手动那一条拿「关掉总开关」的差值当上限（M58）。三条跑在同一套 `cacheDisplay` 出的位图上，页面 PNG 一并导出到 `/tmp/macstroke-selection-bubble-check` 供肉眼核排版。

M70 是第二回撞上「等价变异」，而且这次连变异本身都得改：我把 `didAttempt.removeAll()` 写成 `didAttempt.removeAll(keepingCapacity: true)`，想表达「关掉功能后名单还留着」，实际这两句**都把名单清空**，只差存储容量 —— 跑完全绿抓到的是「这个坏根本不存在」。改成字典上真存在的写法（`removeValue(forKey: "__never__")`，清不掉任何进程号）就是 M70b，两条用例立刻红。判据本身没问题，问题在变异算子；下次写「不清名单」这类变异，先问一句改完的那句是否真的少清了东西。顺带一条：M70 第一版之前我还试过 `removeAll(where:)`，字典上没这个方法（`error: extra argument 'where' in call`），编译红同样不算抓到。

第五批往后（M76–M94，`/tmp/mut_reader3.py`、`/tmp/mut_reader4.py`）有两处取证上的空洞，写出来免得读的人以为它们被覆盖了：

- **M87 抓到的是常量，不是行为。** 「往上只走一格」只有 `XCTAssertGreaterThan(maximumElementsProbedAtThePoint, 1)` 那一句红，次序用例全绿 —— 因为假件 `Script` 的 `.atPoint` 分支是按**排好的答复队列**回的，它不看代码走到了第几格。所以「三格够不够到持有选区的祖先」这句话没有离线判据，只能装机时看日志里那句 `role=`。拿被测常量本身当判据是 M62 那条教训反面的一种：常量确实被钉住了，行为没有。
- **M92/M93/M94 有意抓不到。** 三条改的都在 `readAtPoint` 里，而测试用 `readSourceOverride` 把 `.atPoint` 那一档整个接走了，函数体一行也不执行（SDK 里也没有 `AXUIElementGetMessagingTimeout` 可以核对超时是否落到元素上）。放进去是为了给「这一档只能靠装机日志核」留出处，并顺手量一下边界：`readAtPoint` 的**入口条件、用的坐标、失败怎么归因**都在接缝之外、被咬住了（M76–M81、M88），**函数体内部**（走几格、谁的元素、超时、空选区怎么收尾）没有判据。装机清单第 2、5 步就是补这一段。

**装机验收清单（只能在你自己机器上跑）** —— 这一节是离线测不到的全部剩余项：


1. 打开偏好设置 → 侧栏「划词气泡」（靠近锁屏下面、关于上面）。校验值：**这一页在侧栏里点得到**、**总开关本来是关的**、关掉时下面八项全都画成灰的（灰、但还在 —— 隐藏会让人以为功能少做了）。
2. 只开总开关（其余保持默认），去访达 / 备忘录 / Safari / Chrome / VS Code（或 Cursor）/ Telegram / 微信 / 终端各划一次字，密码框划一次，图片上的文字划一次。每条记：弹没弹、弹在哪、有没有挡住鼠标。
3. 同一个 App 里跑一遍日志核对：`Console` 里搜 `[SelectionBubble]`，或直接 `/usr/bin/log show --last 5m --predicate 'process == "MacStroke"' --style compact | grep SelectionBubble`（`log` 在本机 zsh 里是内建命令，必须写全路径）。看 `读到了：N 个字符 —— <包名> pid=…`（N 对不对、后面那个包名是不是刚才那个 App）、`读选区失败（…），不弹 —— <包名>`、`没有选中内容（…），不弹 —— <包名>`（不弹的那次原因是否说得通），以及 Chromium/Electron 上是不是 `-25204`/`-25205`。成功那句是 3.2.2 才有的（见 §11），旧版只有 `弹气泡：N 个字符`、不带 App 名。
4. 四格逐个真点一次：复制（⌘V 试得出）、搜索（浏览器开的搜索页里词就是你划的那段）、翻译（同上）、朗读（再点一次要停）。
5. 关掉「翻译」和「朗读」两格再划一次：胶囊上只剩两格，位置要**重新铺满胶囊**而不是留两个空位；点在剩下两格上仍是它们自己的功能（少一格不许整体错位）。
6. 两条触发各关一次：关「划完字自动弹出」→ 划字不弹、⌃⌘B 照常弹，日志出现一句 `[SelectionBubble] 已停止划词监听`（只一句，别拆两次）；反过来关「手动快捷键唤出」→ 划字照弹，而 ⌃⌘B 要把这组键临时交给别的 App 试，那边得收得到。
7. 四格全关、总开关仍开着：两条触发都不该弹任何东西，页面上那行橙色说明要出现（这是唯一一种「开着但什么都不做」的配法）。
8. 键盘选字（IDE 里 ⌥⇧→ 选一段，不产生鼠标事件）之后按 ⌃⌘B：要能弹 —— 这条路是唯一不靠鼠标触发的。
9. 觉得慢半拍或读到空，再动「读取延迟」（250 → 400 → 600），把「哪个 App 要多少毫秒」记下来。这条就是 P0 探针要的数。滑杆右边的数要跟着变，别显示成 0。
10. 截图遮罩摊开期间划选（框选区那一下）不该弹气泡；「过滤」页里把某个 App 加黑，那个 App 里就不该弹。
11. 最后关一次总开关：气泡立刻收、再划字不弹、⌃⌘B 也不占。

**第二轮加的（专治「很多软件里没效果」，见 §10）**

12. Chrome 里**连着划两次**字（同一段也行）。校验值：第一次日志该有两句 —— `pid=… 的 AXManualAccessibility 写 true result=-25205` 紧跟 `pid=… 的 AXEnhancedUserInterface 写 true result=0`，然后一句「无障碍树还在建，这一次划词不弹」；**第二次划词要看结果**：出现 `读到了：N 个字符 —— com.google.Chrome pid=…（焦点元素）`（3.2.2 起）或 `弹气泡：N 个字符` 就是这一版真把 Chrome 修好了，还是一句 `读选区失败（…），不弹 —— com.google.Chrome pid=…` 就是「开了接口也读不到」，把它上面那两行（`焦点元素 role=…` 与 `鼠标点 …`）一起抄回来。
13. 信息里划一次气泡正文（或任意一段能选中了的文字）。校验值：看那句有没有变成 `焦点元素 role=AX… 不给选中文字`，`AX` 后面那个词就是要抄回来的东西（`AXTextArea` 和 `AXGroup` 是两个不同的结论）。
14. 在偏好设置里把总开关关掉，等两三秒。校验值：日志出现一句 `关掉划词功能：pid=… 的 AXEnhancedUserInterface 写 false`（有几个 App 就几句），活动监视器里 Chrome 的 CPU 该回落。
15. 一家没试过的 App（VS Code / 微信 / Telegram / Safari 都行）划两次，抄 `—— 包名 pid=…` 那一句。这条是 P0 那张「哪个 App 读到几个字」的表的第一批数据。

## 7. 已知风险（装机时要盯的几处）

- **Chromium / Electron 要靠写一笔属性才读得到**：与方案里「只读、不写」不同，实现在**首次读失败时**给目标 App 的 app element 写一次开接口属性（每个进程每个属性一生一次，值必须是 CFBoolean，写 Swift `true` 会桥成 NSNumber、对方认不下来）。代价是真的：对方从此开始维护自己的无障碍树，Chromium 上 CPU 会吃掉一档，而且要等那个 App 退出才回落。日志里那行「pid=… 的 AX… 写 true …」就是这一笔，装机时看一眼它落在哪些 App 上。**两个属性名按顺序试、为什么必须试第二个、以及「关掉功能时把翻上去的那一笔再翻下来」，都见 §10。**
- 只读监听拿不到「这一按有没有被吞」，好处是结构上不可能伤到手势识别与耗时（`EventCapture` 一棵完全没动），代价是它读到的东西没法回退 —— 用户在自己 App 里做自定义划词时也会被打扰，靠「默认关 + 过滤页名单」挡。
- `readDelay` 只能经验值；250ms 在个别 App 里读空，500ms 以上会有人嫌慢半拍。**要装机实测才能定默认**，所以偏好页给了这根滑杆（50…1500ms）。
- **SwiftUI `TextField` / `TextEditor` 的 AX 实现历史上出过返回空**；这条只能实测覆盖。
- 气泡**不抢焦点也接不到键盘**（`.nonactivatingPanel` + `canBecomeKey = false`），所以方案 §3 里那条「Esc 走 local monitor」在自己 App 之外根本收不到事件 —— 实际只有「点别处 / 切 App / 6 秒」三条收法。装机时如果觉得非有 Esc 不可，得另想不抢焦点的键盘路。

## 8. 分期

- **P0 探针（0.5 天）**：**没有单独跑**，折进第 6 节装机验收清单的第 3、6 步（逐 App 划一次，按 `[SelectionBubble]` 日志记「读到几个字 / 要多少毫秒」）。理由见 §9 第 4 条。
- **P1 最小可用（1～2 天）**：已完成 —— 模块七个文件、122 条离线用例全绿（全量 846 条 / 1 skip / 1 条红是屏锁 + 安全输入造成的键盘 E2E，见 §6）、66 行反向变异里 60 行断言红（另 2 行等价变异、1 行编译红已由 M91b 补上、3 行是有意的：`readAtPoint` 函数体在离线判据之外）、侧栏独立一页九项 + 中英文案、接线含总开关拆到根。装机第一轮反馈「很多软件里没效果」→ §10（开接口属性回退 + 系统级兜底）；第二轮 3.2.1 装机反馈「邮件里也没效果」→ §11（焦点是容器时读鼠标点那一棵 + 成功日志补归因）。剩下的全部是装机验收：清单从 1 步排到 20 步，第三轮那 5 步在 §11 末尾。
- **P2（P1 验过再谈）**：URL 模板可编辑、动作格可增删、朗读音色、每 App 单独开关、位置策略（能拿元素包围盒时贴文本框而不是贴光标）、旋转/翻转那套手感。

## 9. 与方案的偏差（评审时请一并判这几条）

1. **名字**：叫「划词气泡」，模块 `Sources/SelectionPopup`，本地化 key 前缀 `Selection Bubble`。
2. **默认挂快捷键 ⌃⌘B**，不是方案里的「默认不挂，建议 ⌥⇧S」。理由：总开关本来就默认关，挂着的那条键在关掉时会被 `monitorShortcut` 换成空串、整个不占（M54 钉这条）；而一旦用户把开关打开，没有这条路的话「键盘选字」那一类根本叫不出气泡。这是本轮唯一一处「比方案多给了一点默认」。
3. **给的是侧栏独立一页（九项），不是方案说的「一行」或「常规页一段三行」**：延迟这个数必须能被用户自己调，否则 P0 那张「哪个 App 要多少毫秒」的表没人能填；而「四格各自开哪个」「两条触发要不要挂」是三类不同的意图，压在常规页底部没人翻。URL 模板仍然不给控件（留 P2）。
4. **P0 不单独跑**：判定链路、位置、四格命中这些都能离线咬住，剩下唯一的未知是各家真 App 读到几个字，而那只有你机器上的真 App 能答 —— 半天探针换成装机那 8 步。
5. **多写了 `AXManualAccessibility`**（方案 §7 原话是「一期只读、不写那两个属性」）；`AXEnhancedUserInterface` 第一轮仍然没碰 —— **第二轮改成两个都试**，理由和实测见 §10。
6. **监听 mask 是三条**（多一条 `.leftMouseDown`），为的是「再次按下即作废」和「纯单击不算划词」。
7. **越界的延迟值退回默认而不是夹到边界**，并且偏好页读进来时过同一道校验（`SelectionBubbleSettings.clampedDelay`）—— 界面显示 999999 而实际跑 250 是「看到的和跑的两回事」，比退回默认更难查。
8. **步长与区间常量进模块**（`readDelayStepMilliseconds`、`readDelayMillisecondsRange`），界面和测试都从它出发：界面写死数字，将来阈值一改就会出现滑不到边界的格子。
9. **侧栏位置那三条既有用例只动了一条**：新页插在靠近锁屏和关于之间（远程控制/截图/靠近锁屏三条相邻断言原样不动）。靠近锁屏那条里的 `about == proximity + 1` 改成 `about == tabs.count - 1` —— 它想守的只是「关于不能跑到中间去」，写成相邻序号等于每移植一个功能都要回来改一次测试；这是插入新页的固有代价，写在测试注释里。


## 10. 装机第二轮：「很多软件里没效果」（Chrome、信息）

装机反馈的原话是「怎么很多软件里都没有效果，比如 chrome imessages」。先取证，再改。

**实测数据（本机 2026-10-21，脚本 `/tmp/ax_tree_probe.swift`，Qoder 在前台）**

| 观察 | Chrome 155（pid 37471） | 信息 / Messages（pid 81985） |
| --- | --- | --- |
| App 元素属性表 | 19 项、含 `AXWindows` | 19 项、含 `AXWindows` |
| `AXWindows` 个数 | 1 | 0（窗口本来就没开） |
| 读 `AXManualAccessibility` 现值 | -25205（压根没这个属性） | -25205 |
| **写** `AXManualAccessibility` = true | **-25205 拒收** | **-25205 拒收** |
| 读 `AXEnhancedUserInterface` 现值 | 0，值 = false | 0，值 = false |
| **写** `AXEnhancedUserInterface` = true | **0 收下** | **0 收下** |
| `AXFocusedUIElement`（不在前台时） | -25212 | -25212 |

最后那一行是**探针本身的坑**，先记下来免得下次又踩：非前台的 App 读 `AXFocusedUIElement` 基本一律 -25212（本机测过 Chrome、信息、TextEdit、Terminal、Mail、Docker Desktop 全 -25212；只有当时在前台的 Qoder 和桌面进程 Finder 返回 0）。所以「无障碍树有没有真被建起来」不能用焦点元素当判据 —— 上面的表用的是结构（属性表项数、`AXWindows` 个数），而这两样在写与不写之间都没变，**说明结构这一档看不出树建没建**，只能看真划词时的日志。

**装机日志里「不弹」的两种原因**（`/usr/bin/log show --last 2h --predicate 'process == "MacStroke"'`，注意 `log` 在本机 zsh 里是个内建命令，得写全路径）：

- `01:02:32 请求 pid=37471 打开无障碍接口 … result=-25205` → 紧接一句 `读选区失败（取不到焦点元素），不弹`；后面 01:02:51 / 01:03:29 / 01:03:37 / 01:03:43 / 01:03:50 五次同样是「取不到焦点元素」，**却一行请求都没有了**。
- `01:04:56 读选区失败（该控件不支持选中文字属性），不弹`（信息那一类：焦点元素拿到了，控件不给选区）。
- 另一头 `23:35:18 … result=0`（Electron，写成功）当句立刻重读仍失败，6 秒后下一次划词 `弹气泡：12 个字符` —— **开接口是异步的，树要现建**。

**根因两条，都是代码的坏，不是「这个 App 不支持」**：

1. **只写了一个属性名。** Chrome 和信息由头到尾拒收 `AXManualAccessibility`，收 `AXEnhancedUserInterface`（VoiceOver 用的那条老通道），而旧代码只有前者。
2. **「试过了」的名单记在进程这一档。** 第一次划词写 `AXManualAccessibility` 被拒（-25205），那个 pid 就永久进了名单；后面每一次划词连 `AXEnhancedUserInterface` 都不再试 —— 日志里那五句「取不到焦点元素」前面什么都没有，就是这一条。表现成「在 Chrome 里划一万次也不弹」。

**改了什么**（`Sources/SelectionPopup/SelectedTextReader.swift`、`SelectionBubbleController.swift`）：

- 开接口按**代价从小到大**试两个名字：`AXManualAccessibility` → 被拒才试 `AXEnhancedUserInterface`；名单改成按（进程 × 属性）记，第一条被拒不挡第二条。
- 系统级兜底：App 那一棵读不到焦点元素时，再用 `AXUIElementCreateSystemWide()` 的焦点元素读一次（有些桥接层在 App 元素上不答焦点）。两条补救**不会同时上场**，所以失败那条路上最多 2 次跨进程读取 = `maximumReadAttemptsOnTheFailurePath`，这个数是代码在用的（每读一次扣一格），不是注释。
- 归因按第一次：兜底也读不到时报的是 App 那一次的错，不是系统级那一次的 —— 装机要统计的是「在这个 App 里划词为什么不弹」。
- 请开接口**写成功**了但树还没建好时，不再去读系统级那一份（换来源读到的还是同一句「没焦点元素」，白排队），并打一句「无障碍树还在建，这一次划词不弹；下一次划词再读」。
- 关掉总开关时把**我们自己**翻上去的那一笔写回 `false`（`releaseRequestedAccessibility`），别的辅助工具本来开着的那一份不动。
- 失败那两句日志带上是谁：`读选区失败（取不到焦点元素），不弹 —— com.google.Chrome pid=37471`；控件不给选区那一档还多读一个 `AXRole` 打进日志（`焦点元素 role=AXGroup 不给选中文字（code=-25212）`），报 AXGroup 和报 AXTextArea 是两个不同的结论。

**离线取证**：把「读一个来源」和「写开关」抽成接缝（`readSourceOverride` / `enableOverride`），次序这一段才有判据 —— 它 otherwise 要有辅助功能授权、要有个真在前台并且真选中了什么的 App。新增 15 条（SelectedTextReader 22 条、Controller 21 条），`swift test --filter "SelectionPopupTests|SelectionBubblePreferencesTests"` = 104 条全绿（这一轮的数；第三轮之后同一 filter 是 122 条，见 §11）。反向变异 M65–M75 共 11 条：10 条断言红，M70 第一版是**等价变异**（`removeAll(keepingCapacity: true)` 照样清空名单），改成 M70b 后由两条用例咬红 —— 逐行见 §6 那张表，脚本 `/tmp/mut_reader.py`、重跑 `/tmp/mut_m70.py`。

**还没验的（别当已修）**：写了 `AXEnhancedUserInterface` 之后 Chrome 的选区到底读不读得到 —— 结构判据看不出来（见上面那段），只能靠装机日志。信息那一档要多看一句 `role=`：如果 `role=AXGroup`，那是焦点压根不在文本控件上，Catalyst 的桥接层这一期修不了。装机清单加在第 12–15 步。

## 11. 装机第三轮：接口开上了还是不弹（邮件、Chrome、Electron）

3.2.1 装机之后用户报「**现在什么软件里才有效果，我刚刚测试了邮件里也没效果**」。这一问当时**答不上来** —— 不是没日志，是成功那行日志不带 App 名（下面第 3 条）。按包名翻 `/usr/bin/log show --last 4h --predicate 'process == "MacStroke"'`，最近 4 小时 71 行 `[SelectionBubble]`，其中 13 句成功、13 句失败，失败按 App 摊开：

| 前台 App | 失败次数 | 日志里那一句 | role |
| --- | --- | --- | --- |
| `com.apple.mail` pid=48317 | **7 / 7** | `焦点元素 role=AXWebArea 不给选中文字（code=-25212）` → `读选区失败（该控件不支持选中文字属性），不弹` | AXWebArea |
| `com.google.Chrome` pid=37471 | 4 | 同上（code=-25212） | AXWebArea ×2、AXRow ×2 |
| `com.electron.dockerdesktop` pid=70940 | 2 | 第一次 `AXManualAccessibility 写 true result=0` → 「无障碍树还在建」 → 第二次就落到 AXWebArea 那一档 | AXWebArea |
| 13 句 `弹气泡：N 个字符` | — | **没有一句带 App 名** | — |

**这张表里最要紧的是它的形状**：4 小时里所有失败（11/13）都停在同一档 —— 焦点元素**拿到了**、接口**开着**、码是 **-25212**。也就是说 §10 那一轮修完之后，坏已经不是「读不到焦点」，而是往下一步去了。

### 三条真因

1. **-25212 和 -25205 被并成了同一句。** `classify` 里两个码都落 `.selectedTextUnsupported`，日志因此报「该控件不支持选中文字属性」。可 -25212 是 `kAXErrorNoValue`：属性在、这一格当前没有值。焦点给的是**容器** —— 邮件正文和网页是 `AXWebArea`、列表里那一行是 `AXRow`，选区在它子树里的某个孩子身上，容器自己不应 `kAXSelectedTextAttribute`。这一句文案直接把归因带到「这个 App 修不了」上去了。
2. **这一档旧代码什么都不做。** `shouldAskAgain` 里 `.selectedTextUnsupported` 是唯一「再试」的档，但 `shouldRequestAccessibility` 与 `shouldRetrySystemWide` 都不含它，于是 `read()` 首读失败就直接返回 —— 每次划词只读一次，一次也不补救。（`testAnElementThatAlreadyRefusesSelectionGetsNoSecondLook` 当时还把这件事当成**正确行为**在钉，理由写的是「开接口不会给它凭空长出一个属性，换系统级读到的还是同一个元素」—— 那两句到今天仍然成立，缺的是第三手。）
3. **成功那行日志不带 App，也不带来源。** `弹气泡：N 个字符，格子 …，位置 …` 只有位置。于是「现在哪些软件里有效」这一问，只能靠用户自己记得刚才在哪个窗口里划的 —— 这正是本轮被问住的直接原因。

### 改了什么

- 新增第三手补救 `readAtPoint`：`AXUIElementCopyElementAtPosition(系统级, x, y)` 按**松手那一点**命中元素，再沿 `kAXParentAttribute` 往上走，最多 `maximumElementsProbedAtThePoint = 3` 格（装机第一轮看到的样子是 `AXStaticText` → `AXGroup` → `AXWebArea`，三格够到管选区那层）。只读命中那一格等于白读。
- 坐标换算 `cgPoint(appKit:primaryHeight:)`：AppKit 原点在主屏**左下**，CG/AX 要的是**左上**，`y = 主屏高 - y`。写反的表现是「永远打不中」，而在测试里没法拿真坐标验，所以抽成纯函数钉住。
- 归属闸：命中的第一个元素先 `AXUIElementGetPid` 核对是不是被划那个进程 —— 压在那一行字上面的可能就是我们自己那枚还没收掉的气泡，读它会念出 MacStroke 的字。
- 这一手用**短超时**（主读是 0.6）：它是白捡的一手，对方慢就放弃，不能把「不弹」拖成「划完词卡半天」。超时是**按对象**记的（`AXUIElement.h`：「给某个对象设的超时只对它自己生效，别的对象即使与它相等也不受影响」），而 `AXUIElementCopyElementAtPosition` 命中的那一格和往上走的每一格父级都是**新对象**，所以循环里每格都设一次 `hitTestProbeTimeout = 0.2`，不是只在 systemWide 上设一次就完事。失败那条路的最坏耗时统一进 `worstCaseWaitSeconds()` = 0.6 + max(0.6, 6×0.2) = **1.8s**，延迟判据钉这个函数而不是钉常数。（这一句在离线判据之外 —— SDK 里没有 `AXUIElementGetMessagingTimeout` 可以核对，见 §6 的 M93。）
- `-25212` 单独立档 `.noSelectedTextValue`（新增 `.noElementUnderCursor` 一档给探测没打中用）；`shouldProbeUnderTheCursor` 只放行 `.selectedTextUnsupported` 与 `.noSelectedTextValue` 这两档，**请开接口和换系统级都不上场**（接口本来就开着；换来源读到的还是同一个元素）。三手里最贵的（重读那一棵、探测）都只多一格预算，`maximumReadAttemptsOnTheFailurePath` 还是 2。
- 探测也没答上来时**报第一次的错**：第一次那句带 `role=`，比「鼠标点没命中」有信息量。
- 成功那行日志换成 `读到了：N 个字符 —— <包名> pid=…（<哪一手答上来的>）`，正文抽成 `SelectionBubbleController.successLogLine(...)` 纯函数（不然这句话只能靠肉眼核日志，删掉 App 名也没人红）；来源记在 reader 身上（`answeredFrom`），只有**真读到字**才记 —— 记早了会把「探测读回空」也算成探测答的。
- `readerFactory` 多一个参数：松手点 `CGPoint?`。reader 跑在后台队列上，读回来时指针早飘了，坐标只能从事件那一路带进来；快捷键那一路给 nil，没坐标就**压根不探测**（`.zero` 是屏幕左下角，在那儿命中一个元素再把它家的选区弹到用户眼前，既读错人又白排队）。

### 离线取证

新增 18 条（SelectedTextReader 35、Controller 26），`swift test --filter "SelectionPopupTests|SelectionBubblePreferencesTests"` = **122 条全绿**。反向变异两批共 20 行（`/tmp/mut_reader3.py` 跑 M76–M92 共 17 条、`/tmp/mut_reader4.py` 跑 M91b/M93/M94），断言红抓到 16：M91 第一版是**编译红**（`switch must be exhaustive` —— 把 `.noSelectedTextValue` 从 `shouldAskAgain` 的 `true` 组删掉就不再穷尽，抓到的是「Swift 不许这么写」，换成挪进 `false` 那一组的 M91b 才构成行为差别，9 条红）；M92/M93/M94 是**有意抓不到**（三条改的都在 `readAtPoint` 函数体里，测试用 `readSourceOverride` 把 `.atPoint` 那一档接走了，那一段一行也不执行）。逐行见 §6 那张表，两处取证空洞见 §6「第五批往后」那段。

两处取证上的交代：

- **假件的 `.atPoint` 分支默认答「失败」**（`Script.read` 里那句 `atPoint.isEmpty ? .unavailable(.noSelectedTextValue)`）。第一轮写成默认答「成功」时，`testAnElementThatAlreadyRefusesSelectionGetsNoSecondLook` 那类「只断言报第一次的错」的用例会被探测的答复悄悄改写 —— 于是加进去的 6 条旧用例全绿，但它们其实从没验过第一次的归因。默认答失败，旧用例的语义才保持不变，新行为由新用例单独钉。
- **M92 预期抓不到**：它改的是 `readAtPoint` 里那道 pid 归属闸，而那三行只有真元素树才走得到，`swift test` 里这一段压根不执行。故意放进批次里是为了给「这一档靠装机日志核」一句留出处，别让读方案的人以为它测过了。同理，「往上走到第几格才碰到持有选区的元素」也只能装机时看 `role=` 那行。

### 装机清单（第三轮，接在第 15 步之后）

1. **先确认装的是新版**：`plutil -extract CFBundleShortVersionString raw /Applications/MacStroke.app/Contents/Info.plist` 该给 `3.2.2`；再 `grep -a -c "鼠标点那一棵也没答出选区" /Applications/MacStroke.app/Contents/MacOS/MacStroke` 该是 1（旧版没这句）。
2. 邮件里选一段正文 → 看日志：`/usr/bin/log show --last 5m --predicate 'process == "MacStroke"' --style compact | grep SelectionBubble | tail -20`。校验值：出现 `读到了：N 个字符 —— com.apple.mail pid=…` 就是这一手把容器那一档绕过去了；还是一句 `读选区失败` 就把它**上面**那行 `pid=… 鼠标点 (x, y) …` 抄回来（`没命中元素` 和 `打到的是 pid=` 是两种不同的坏）。
3. 同样划一次 Chrome、一次 Docker Desktop（Electron）。校验值：同第 2 步；Electron 头一次仍然是「无障碍树还在建，这一次划词不弹」，**第二次划词**才看结果。
4. **回答「现在什么软件里才有效果」这一问**：`/usr/bin/log show --last 1d --predicate 'process == "MacStroke"' --style compact | grep -a "读到了" | sed 's/.*—— //' | sort | uniq -c | sort -rn`。这一句列出的就是**逐个 App 的成功次数**（旧版统计不出来，因为成功那行不带包名）。把这张表和失败那张（`grep "读选区失败"`）一起贴回来，就能定出下一轮改哪一档。
5. 手感核对：新那一手最坏多等 1.2s，但**只在读不上来的时候**。校验值是「弹出来的那一条仍然跟手」—— 在 TextEdit/Notes 里连续划三次，`划词到位` 与 `读到了` 两行的时间戳差该在 0.3s 上下（250ms 延迟 + 一次读），跟这一版之前一样。如果那一档也慢了，说明探测被误放进了成功路径（M76/M77 那两条变异就是钉这个的）。

**还没验的（别当已修）**：`AXUIElementCopyElementAtPosition` 在邮件那种 WebArea 上打不打得中、往上三格够不够到持有选区的祖先 —— 这两件事只有装 3.2.2 之后真划一次才知道。这一版能保证的是：如果还不行，日志会说出它卡在哪一格、命中了谁。

## 12. 装机第四轮：邮件还是不行，Chrome 正常 —— 本轮只取证，不改代码

用户报「**刚刚测试了邮件不行，chrome正常**」。日志两边都对上了：

- Chrome：`读到了：3 个字符 —— com.google.Chrome pid=37471（App 焦点元素）` —— 注意括号里是**主读**那一手答的，不是本轮新加的探测。
- 邮件（pid=48317）4 条失败，全停在 `焦点元素 role=AXWebArea 不给选中文字（code=-25212）` → `鼠标点那一棵也没答出选区，报焦点那一次的错`；其中一条是 `鼠标点打到的是 pid=412，不是 pid=48317`。

`ps -p 412` 查出来那个 pid 是 **Dock**；而邮件挂着 3 个 `com.apple.WebKit.WebContent.xpc` 助手（36156 / 48329 / 72198）。据此我当时的假设是：正文在助手进程里，第 0 格那道 pid 闸把唯一持有选区的元素挡在门外。**这一轮就是去验这个假设 —— 结论是它错了，五个探针实验（源码 `/tmp/ax_mail_tree.swift`、`/tmp/mail_focus.swift`、`/tmp/mail_body.swift`、`/tmp/mail_hit.swift`、`/tmp/ax_sel_tree.swift`，全部只读、跑完把写过的属性还原）量出的是别的形状。**

### 四条实测

1. **假设证伪：邮件的正文就在邮件自己的 pid 里。** 从邮件窗口沿 `AXChildren` 往下扒 260 格（深度 ≤ 12），每一格 `AXUIElementGetPid` 都是 48317，一个都不是助手。反过来从助手那头读：三个 pid 的 App 元素 `AXChildren` 给 0 个孩子、`AXFocusedUIElement` 给 -25212 —— 读助手根本不是一条路。那条 `pid=412` 是**松手点真的落在 Dock 上**，闸在做它该做的事。**pid 闸不是邮件的堵点**，别为它改代码。
2. **树里唯一答得出 `AXSelectedText` 的一格，在容器的下面，不是上面。** 那一格的路径是 `窗/0+AXSplitGroup/2+AXSplitGroup/3+AXScrollArea/0+AXGroup/0+AXGroup/0+AXTextArea`（窗口往下第 6 格，5 个孩子，`AXValue` 75 字，没选区时 `AXSelectedText` 给 code=0 空串、`AXSelectedTextRange` 给 `{0,0}`）。而它的**每一格祖先**（AXGroup / AXScrollArea / AXSplitGroup / AXWindow）这一属性报的是 **-25205：属性压根不支持**；同一层的兄弟 `AXStaticText` 报 -25212。也就是说 `.atPoint` 那一手「命中之后只往上走」的方向，对邮件这种形状是**反的** —— 往上走到哪儿都不会碰到持有选区的那一格。这是本轮唯一站得住的方向性结论，但它还没被真选区验过（见下）。
3. **§10 那根修好 Chrome 的杠杆，对邮件确认无效。** 邮件的 App 元素属性表里**有** `AXEnhancedUserInterface`（当前值 0 = 没开），真把它写成 1（写回 code=0、读回 1），等 0.5s 再扒一遍：能答 `AXSelectedText` 的还是那 1 格、孩子数一模一样 —— 树**一点没变**，跑完已还原成 0。`AXManualAccessibility` 在邮件的属性表里根本没有（读它报 -25205）。所以「焦点是容器时也去请对方开接口」这一档对邮件不会有任何效果，别为它再花一轮。
4. **坐标这条教训值得单记，探针差点因为它下错结论。** `AXPosition`/`AXSize` 和 `CGWindowList` 的 bounds 都是**左上原点**，只有 `NSEvent.mouseLocation` 是左下原点。探针 v1/v2 把从 AX 读回来的坐标又按 AppKit 那套翻了一次 `y`，打回来的全是上下镜像处的**别人家窗口**（Chrome pid=37471、Qoder pid=31771），差点据此写「邮件命中不了」。生产代码只翻鼠标那一次（`cgPoint(appKit:primaryHeight:)`），是对的。另外：邮件的窗口在这台机器上被完全盖住 —— 按窗口 24×18 扫 432 个采样点，露在最上面的有 **0** 个。所以「按屏幕点」那一类取证在邮件上根本取不到证，只能改从焦点那一头取。

### 还缺的那一个数

上面第 2 条是从「没选区」的树推出来的。**真按住一段选区时，到底哪一格答出字、它在焦点的上面还是下面第几格** —— 这个数只能用户在邮件里选中一段字之后跑一次探针才拿得到（`/tmp/axsel com.apple.mail`，见下面的清单第 6 步）。三种结果对应三种改法，提前写死在这里，免得数回来了再临时想：

- **焦点那一格自己就答出**（探针打 `>>> 主读就该中`）→ 说明失败那几次撞的是另一种消息形状（邮件正文至少有两种：这棵树里**没有** `AXWebArea`，可日志报的焦点 role 偏偏是 `AXWebArea`）。改法是给主读补「从焦点往下扒」的一手，`.atPoint` 保持不动。
- **焦点不行、下面某格答出**（探针打 `>>> 第 N 格 …  —— 要读的就是这一格`）→ 给 `.atPoint` 补往下的一手：只在孩子数 ≤ 8 的格上往下、最多 2 层、每格沿用 0.2s 短超时，`worstCaseWaitSeconds()` 重算并被延迟判据钉住（这条不能含糊，往下扒是最容易把「不弹」拖成「卡半天」的一手）。
- **90 格里没有一格答出**→ 邮件正文这条路在无障碍上没有出口，按 §1 的口径写进「一期做不到 / 不承诺」，不再往层数上赌。

### 装机清单（第四轮，接在第 15 步之后）

6. **邮件取证（不改设置、不装新包，两分钟）**：
   1. 打开邮件，任选一封，在**正文**里拖选一两句（选中状态别丢）。
   2. 立刻在终端跑：`/tmp/axsel com.apple.mail > /tmp/mail-sel.txt 2>&1; tail -30 /tmp/mail-sel.txt`（探针源码在 `/tmp/ax_sel_tree.swift`，只读，不写任何属性）。
   3. 校验值：把 `/tmp/mail-sel.txt` 贴回来。要看的是三样 —— 第二行 `读 AXEnhancedUserInterface … 值=` 是不是变成了 1、`[S] 焦点 = …` 那行的 role、以及有没有 `>>>` 那几行（`>>> 主读就该中` / `>>> 第 N 格 …`）。
   4. 如果第一行就是 `AXFocusedUIElement code=-25212`：那是选区掉了（切过窗口、点过别处），重新选中再跑一次；连着两次这样就先跑 `/tmp/axsel`（不带参数，探针取当前前台）确认探针本身没问题。
7. 同一个探针在 **Chrome** 里再跑一次（`/tmp/axsel com.google.Chrome`）。Chrome 是这一版**确认能用**的那一家，它的结构就是邮件该长成的样子 —— 两份贴回来一比，改哪一手不用猜。

## 13. 第五轮：邮件换机制 —— 静默代按 ⌘C（3.2.3）

第四轮那个数回来了，落在预写的**第三种**：`/tmp/axsel2 com.apple.mail 25` 把焦点子树 90 格全扒了一遍，`>>> 全树没有一格答出非空选区`（有 `AXSelectedText` 的那一格只给空串 + `{0,0}`）。邮件正文在无障碍上没有出口 —— 按 §1 的口径写进「不承诺」，把 ⌘C 这条路交给用户选。用户选的是「静默代按 ⌘C」，原话口径：**先把你剪贴板原样存下 → 代按一次 ⌘C → 读到新内容后立刻把原内容放回去**，并且给我们的粘贴板历史加一道「这次不记录」的闸门。

### 动手的那一手长什么样（`Sources/SelectionPopup/SelectionCopyReader.swift`）

次序是判据的主体，写死在这里：

1. **四道闸**（任一命中就一行都不动粘贴板）：认不出前台 → 前台是 MacStroke 自己 → 前台已换人 → 粘贴板上现在是**文件**。再加一道**单飞占位**（`claimCopyHand()`，NSLock 后面的一个布尔）：已经有一路在动粘贴板时，第二路直接放弃。判文件的只读那一下排在占位**之前**，所以挡下来的那一路留下的只有 `files?` 一次查询。
2. `snapshot()` 抄下粘贴板原样 → `beginSuppression()` 打开历史闸门。
3. `defer { restore(snapshot); endSuppression() }` —— **成功、每一支失败、甚至提前 return，都走同一句还原**。这是这一手唯一「弄坏用户东西」的机会，也是它全部的可辩护性。
4. `writeSentinel(sentinelText(from: pasteboard.text()))`：哨兵写的就是**用户原来那份文本**（原来没有文本才写 `MacStrokeSelectionProbe`）。写哨兵的目的是让「对方到底复制了没有」变成可判的：没复制时粘贴板上还是哨兵，`text()` 回来的东西一眼能认。
5. **`let mark = pasteboard.changeCount` 必须取在写哨兵之后**。取早了，用户十分钟前的那一次复制会被当成这次划的词（M95 就是专门咬这一格的）。
6. `postCopyKeys()` 投 ⌘C（keyDown+keyUp，`keyCode = 8`，只带 ⌘）到 **`.cgSessionEventTap`**，轮询 `changeCount <= mark` 直到 `pollTimeout`（上限 `pollTimeoutCeiling = 0.35`s，间隔 0.02s）。
7. 跳了才读：先 `holdsFileURLs`（对方复制了文件就不弹），再 `text()`；还是哨兵 → `.nothingSelected`（**当成答复收下**，报「选区为空」，不再往下按无障碍归因）；跳了但没文本 → `.copyNotText`。

### 它排在失败链的哪一格，代价多大

`AXSelectedTextReader.read()` 的最后一段：无障碍那几手（App 焦点 → 系统级 → 鼠标点命中）**全都拿不到字**时才上这一手，且只有 `shouldCopyInstead` 认的那五档失败才上：`accessibilityNotEnabled / noFocusedElement / selectedTextUnsupported / noSelectedTextValue / noElementUnderCursor`。**超时（`.timedOut`）和原始错误码（`.apiError`）不上** —— 对方只是慢或回了个没听过的码，不是读不到，这时候去动粘贴板是白挨一次 ⌘C（M100/M112 咬这两格）。

代价是**能算出来的**：`worstCaseWaitSeconds(includesCopyHand:)` = 1.8s（不上这一手）→ 2.15s（上）。判据钉死「多等的正好是轮询上限」，且不上这一手时仍 ≤ 2.0s（弹得出来的那一档还在原来那一拍之内）。

### 不侵入手势路径（这是硬线）

- 这一手不新增任何左键监听：划词的触发判定仍走 `NSEvent.addGlobalMonitorForEvents`（只读，不吞），HID `.cghidEventTap` 上一颗左键事件都不加，手势的识别与耗时不受影响。
- 投出去的是**键盘**事件，且走 session 层（与远程控制那条一致）。
- 拆环的那道闸：`SelectionBubbleSettings.isPlainCommandC(_:)` 比 keyCode + 修饰键掩码（`⌃⌘C` 不算单纯 `⌘C`），`canUseCopyFallback = enabled && copyFallbackEnabled && hasCells && !isPlainCommandC(shortcut)`。**气泡快捷键被录成单纯 ⌘C 时这一手绝不上场**，否则我们代按的那一下会又被自己监听成一次唤出，转圈动用户的粘贴板；页面上这种情况有一句橙色警告说破（开关开着却一次都不生效，是最难查的那类坏）。

### 粘贴板历史那道「这次不记」

`HistoryClipboardManager` 加引用计数闸门：`beginRecordingPause()` / `endRecordingPause()` / `isRecordingPaused` / `resetRecordingPause()`（测试用），配 `recordingPauseCeiling = 5`（有上限能自愈，防止某路异常没退干净把闸门永久关上）和 `recordingPauseGrace = 0.6`s（宽限期必须大于 0.5s 一跳，否则「还原」那一写会被下一跳记成用户复制）。`handleTimer` 在暂停窗口里**仍然推进 changeCount、只是不入库** —— 只跳过不认账的话，暂停一结束下一跳会把我们自己的写补记成一条用户复制（M110/M111；这两条桩里没定时器，只能装机按历史列表核）。

### 离线取证

新用例进仓库：`Tests/SelectionPopupTests/SelectionCopyReaderTests.swift`，29 条，主题就是**次序与闸门**（不是「读得到读不到」—— 读得到与否在界面上全都一样，只有出手没出手这一格能把四种情形分开）。同模块 `Tests/SelectionPopupTests/` 当时共 **140 条用例、0 条断言红**（第六轮之后是 161 条，见 §14）。

`swift test` 在本机跑不了（见下），这 140 条是用 `/tmp/xctstub` 那套 XCTest 桩件（复刻 `XCTAssert*` 签名 + 生成显式调用的 main）编译**未改动的仓库用例**跑出来的。桩件本身先自证：故意写反的 6 条全红、写对的 8 条全绿（`/tmp/xctstub/check.swift`），否则「140 全绿」这三个字没有意义。

反向变异 **19 条（M93–M112，表在 `/tmp/msprobe/mut_copyhand.py`，执行器 `/tmp/xctstub/mut_suite.py`）对着仓库真用例重跑**：19 条里预期该抓到的 17 条**全部抓到，漏 0**（M110/M111 如预期没抓，见下）。规矩照旧：起跑前备份 + 记 SHA，每条跑完立刻还原并核对 SHA，**编译红不算抓到**；M110/M111 预期桩抓不到（没有定时器），注明靠装机日志核。

### 工具链：这台机器现在是「只有 CommandLineTools」

- **没有 XCTest**（2026-10-22 升级 CLT 之后）：`swift test` / `swift build --build-tests` → `no such module 'XCTest'`。本轮所有用例走桩件；Xcode 装回来之后同样的判据直接搬回 `swift test`，用例文件本来就是标准 XCTest 写法。
- **没有 xcbuild**：`swift build -c release --arch arm64 --arch x86_64` → `xcbuild executable ... does not exist`，通用包做不了。`build_app.sh` 因此加了单架构回退（本机是 Intel，产物 x86_64，照样能装能用）。**正式发版不受影响**：`release.yml` 的 runner 带 Xcode 走通用那一条，出包之后自己再 `lipo` 校验 arm64+x86_64，真回退到 CI 上会直接红。
- **全量回归（724/828 那一档）本轮没跑**，这是没做完的事，不是跑过了。

### 3.2.3 出包装机，以及一处必须写下来的坑

上一趟（11:22 那次）`build_app.sh` 打出的「3.2.3」包**装的是 10 月 21 日的旧二进制**：产物目录那一段是「按固定顺序取第一个存在的」，而 `.build/apple/Products/Release`（上次装 Xcode 时留下的通用包）排在最前，这次只做了单架构构建，新产物在 `.build/x86_64-apple-macosx/release`。版本号正是用户区分新旧的唯一依据，所以这段改成：**候选全列（含时间）→ 取最新的 → 只要还有比它更新的 `.swift` 源文件就红 → 二进制里必须能 `grep` 到新代码的哨兵串**。这趟实测选中的是 `.build/x86_64-apple-macosx/release`（10-23 11:22，`MacStrokeSelectionProbe` / `代按` / `暂停` 三串都在；10-21 那份通用包里三串全 0）。

装机实测（本机已装并跑起来）：`/Applications/MacStroke.app` 的 `CFBundleShortVersionString` = **3.2.3**，`Authority=MacStroke Self Signed`（cdhash 不变，辅助功能授权不重置），`lipo -archs` = `x86_64`，FinderSync 扩展 `pluginkit` 注册到 `net.mtjo.MacStroke.FinderSyncExtension(3.2.3)`。

### 版本号规矩（10-23 用户定的，本轮起生效）

**一轮功能 = 一号**：装机调试期间反复覆盖同一个号，验收通过才由 `release.yml` 真发。基准取**线上那一号 + 1**（`gh release list` 实测线上最新 = 3.1.9），所以第五轮（代按 ⌘C）和第六轮（搜索引擎）合起来就是 **3.2.0**。上面那些 3.2.1 / 3.2.2 / 3.2.3 是我当时每装一次就加一号留下的，**从未发布**，装机的机器上现在已被 3.2.0 覆盖 —— 下面清单里凡出现版本号的地方，按 3.2.0 读。

### 装机清单（第五轮，接在第 15 步之后；只有这一轮能验「邮件到底通不通」）

前置：偏好设置 → 划词气泡 →「启用划词气泡」开、「划完字自动弹出」开、段落「读不到选区时」→「替我按一次 ⌘C 取字」开。日志一律用：```
/usr/bin/log show --last 5m --info --debug --style compact \
  --predicate 'process == "MacStroke" AND (eventMessage CONTAINS "[SelectionBubble]" OR eventMessage CONTAINS "[HistoryClipboard]")'
```
两个坑：**不带 `--info --debug` 会漏**（这些行是 Df 级，别据此说「一次都没跑」）；**必须限定 `process == "MacStroke"`** —— 取证用的桩件二进制也叫 `[SelectionBubble] …`（本轮实测：不限时 6 分钟里 285 行，绝大多数来自测试 `runner` 和 `log` 自己的 argv），拿它当装机证据就是自证。

16. **先确认装的是真 3.2.0（不是壳新货旧）**：
    ```
    plutil -extract CFBundleShortVersionString raw /Applications/MacStroke.app/Contents/Info.plist
    grep -a -c "MacStrokeSelectionProbe" /Applications/MacStroke.app/Contents/MacOS/MacStroke
    grep -a -c "sogou.com/web?query=" /Applications/MacStroke.app/Contents/MacOS/MacStroke
    ```
    校验值：`3.2.0`、`1`、`1`。后两句分别是「代按 ⌘C」和「搜索走哪一家」那张表的哨兵串 —— **只有版本号不够**（10-23 那次「3.2.3 的壳装 3.2.2 的货」就是这么漏的），`build_app.sh` 现在也拿这两串当出包前的最后一道闸，摸不到直接红。
17. **邮件里跑通这一手（主判据，三句都要有）**：邮件任选一封，正文里拖选一两句，松手别点别处。等约 1 秒看日志：
    ```
    /usr/bin/log show --last 2m --info --debug --style compact \
      --predicate 'process == "MacStroke"' | grep -aE "代按|读到了|暂停窗口" | tail -12
    ```
    校验值（三句缺一句都要报回来）：`[SelectionBubble] 代按 ⌘C 读到 N 个字符`、`[SelectionBubble] 读到了：N 个字符 —— com.apple.mail pid=…（代按 ⌘C 取回）`（括号里必须是**代按 ⌘C 取回**，写成「App 焦点元素」就是走错了档）、`[HistoryClipboard] 暂停窗口内的一次粘贴板变化，不记入历史`（至少 1 次，多半 1–3 次 —— 历史那边 0.5s 一跳，一个暂停窗口里最多撞上哨兵/对方复制/还原三写）。
    气泡此时应真的弹出来，上面划的那段字能点「复制」。
18. **粘贴板原样放回（这一手最贵的代价，必须直接验）**：先在随便哪个文本里手动 ⌘C 复制一句**已知的**文本 A（记住它），再去邮件里划词，**不要点气泡**，等气泡自己消失，然后在文本框里 ⌘V。
    校验值：贴出来的是 **A**。贴出划的那个词 = 没还原；贴出 `MacStrokeSelectionProbe` = 哨兵没被还原盖掉，两种都是坏，把第 17 步那段日志一起贴回来。
19. **我们的粘贴板历史没记这几笔**（M110/M111 只能在这一步核）：按 ⌥⌘V 打开历史列表。
    校验值：列表最上面还是 A 那条，**不该**多出划的那个词，也不该多出 `MacStrokeSelectionProbe`。多点几次划词再看一次，一次都不该进。
20. **负向：粘贴板上是文件时压根不动手**：Finder 里选中一个文件 ⌘C，然后去邮件（或 Chrome）划一段字。
    校验值：日志出现 `代按 ⌘C 跳过：粘贴板上现在是文件`，且**没有**「读到 N 个字符」；回 Finder 按 ⌘V 还能贴出那个文件（我们没动过它）；历史列表里那个文件条目没变成文本。
21. **负向：不注入自己**：打开偏好设置，在任意文本框/说明里选中一段字。
    校验值：日志出现 `前台是 MacStroke 自己，不能把正在编辑的框抄进粘贴板`，粘贴板内容不变（再 ⌘V 验一次）。
22. **拆环那道闸**：偏好设置 → 划词气泡 → 快捷键，录成**单纯的 ⌘C**。
    校验值：页面出现橙色那句「上面的快捷键被录成了单纯的 ⌘C，这一手不能上场…」；此后划词日志里**一句 `代按 ⌘C` 都不该出现**（既没有「读到」也没有「跳过」，因为压根没进这一手）。验完改回 ⌃⌘B。
23. **老账不能翻（读得上的那些次不许动粘贴板）**：Chrome、TextEdit 各划三次。
    校验值：`读到了：… （App 焦点元素）` 照常，**旁边不出现任何 `代按` 字样**；「弹出来的那一条」仍然跟手（`读到了` 与划词那行的时间戳差在 0.3s 上下）。只有邮件那种读不上来的才多等 —— 上限 0.35s（轮询封顶），整体最坏 2.15s。
24. **手势不受影响（硬线，与 3.2.2 那轮同样的口径）**：右键手势照常做几次（含一个长的），识别与抬手速度不该有任何变化；这一手不加任何左键监听，投的是 session 层的 ⌘C。
    校验值：手感与 3.2.1/3.2.2 一致。若出现「做手势时粘贴板被动了」或「抬手变慢」，那是这条硬线破了，立刻报回来并把第 17 步的日志一起贴。

**这一轮验不上的一件事**：邮件正文如果连真按 ⌘C 都复制不出东西（对方 App 自己不吃这一键），这一手照样拿不到字 —— 表现是日志出现 `代按 ⌘C 之后粘贴板没动（350ms 内）——按没选中东西处理`。那不是 bug，是这一条路的边界；出现这句请把邮件版本（帮助 → 关于邮件）一起报回来。

## 14. 第六轮：「搜索」那一格走哪家 —— 六家引擎 + 八家网页 AI + 一条自定义 URL

用户提的原话是两句：「**搜索功能要支持各大引擎和网页 AI**」「**应该还自动自定义的 url**」。评审答复定了形态：**不加第五格**，气泡上还是那颗放大镜，「走哪一家」写成偏好页的配置项；名单四组全选。

### 一张表就是全部行为

`Sources/SelectionPopup/SelectionBubbleSearchEngine.swift` 里 15 个 case，每 case 一条模板：

- 搜索六家（都稳定吃 URL 查询参数，但**参数名各家不一样** —— 这是不做成「一家一段 if」的直接理由）：google `?q=`、bing `?q=`、duckduckgo `?q=`、baidu `?wd=`、sogou `?query=`、360 `?q=`。
- 网页 AI 八家：chatgpt `https://chatgpt.com/?q=`、copilot `https://copilot.microsoft.com/?q=`、perplexity `https://www.perplexity.ai/search?q=`，gemini / deepseek / doubao / kimi / tongyi 只给到页面本身（**没有 `{query}`**）。
- `custom` 一条，模板就是偏好页那个文本框里那串。

**行为只看模板，不看名单**（整条功能唯一的规则，写在一个纯函数里）：模板含 `{query}` → 拼进 URL 打开；不含 → 只打开那一页，并**先把选中的字写进粘贴板**让用户 ⌘V。判据是 `SelectionBubbleLinks.prefillsQuery`，拼装那一头和「该不该复制」那一头共用这一句 —— 两边各写一遍 `contains("{query}")`，将来改占位符名只会改到一处，另一处静默失效（M113 咬的就是这一格）。

因此表里加一家只要在声明处补 case + template，控制器不用碰；用户从偏好页改一个占位符就能把「只开页」切成「预填」。

### 三条当时的取舍，写下来免得验收时重新讨论

1. **删掉了旧版「模板不带占位符就自动追加 `&q=`」那一手**。看着贴心，实际是猜用户想要的参数名：猜错了就是「页面打开了、字没进去、也没人替他复制」，三头不讨好。现在规矩只有一条 —— 不带占位符就老实复制一遍再开页。
2. **AI 那八家一律先复制**（`kind == .ai` 直接决定 `copiesTextFirst`，哪怕模板带了占位符）：社区里 ChatGPT 的 `?q=` 属于「有时认、有时不认、还会把参数吞掉」，官方没文档承诺。多复制一次的代价是粘贴板里多一条**正常**记录（这一家本来就是用户要点「搜索」的行为），换来的是「哪天又不认了，页面打开后 ⌘V 照样能问」。搜索那六家绝不碰粘贴板 —— 结果页不需要，多写一次只是弄脏用户刚复制的东西。
3. **`.custom` 单列一类**，不归进搜索也不归进 AI：它复制不复制要看模板。归进任何一组，下拉的 `searchEngines` / `aiEngines` 两个分组就会多出一条不该有的行（M117 咬这格）。

### 认不出的值往哪退，两边必须是同一个答案

- 库里存了个不认识的 id（手改 plist、别的版本带过来）→ `from(rawValue:)` 退回 `StorageDefaults.selectionPopupSearchEngine`（实测现值 `google`），**代码里没有第二处硬编码退回 google**；偏好页那个下拉的 `get` 走同一句，所以「库里那串」在界面和消费端退回同一家（画成一条空白下拉会看着像页面坏了）。
- 选了自定义但那栏不像网址 → `resolvedTemplate` 退回默认那一家，同时页面出现黄字。黄字的判据用的是**同一个** `looksLikeURL`（它就是为这个才 public 的），页面自己再判一遍就会出现「黄字说 A、实际开 B」。
- `looksLikeURL` 只查一样：`://` 之前得真有东西。不做域名校验（`127.0.0.1:8000/?q={query}` 这类真能用），也不限制第二个 `://`（`https://go/?u=http://x` 把网址当参数是真需求）。M119 咬「退回成 `contains("://")`」这一种坏法。

### 控制器就三行，测试里不会真开浏览器

`SelectionBubbleController.search(_:)` 问 `settings.searchTarget` 拿 `(template, copiesTextFirst)` → 要复制就先 `write(text)` → `open(url)`。`openURL` / `pasteboardWrite` 都是可变接缝，**测试那个 init 里默认就是两个空函数**：忘了传假件也不会真弹出浏览器、真弄脏用户粘贴板（M122–M125 逐格咬次序与条件）。

### 离线取证（本轮第一次把偏好页那份用例真跑起来）

- **模块侧**：`Tests/SelectionPopupTests/` 变异跑完时 **161 条 / 0 红**（第五轮那趟是 140 条，本轮 +21），加上后面那 4 条日志用例是 **165 条 / 0 红**。现在每个文件的条数：SelectedTextReader 35、Controller 36、CopyReader 29、Settings 17、Links 11、Layout 10、**SearchEngine 10（本轮新增这一份，整表逐行核模板与 `copiesTextFirst`）**、Render 9、Trigger 8。
- **偏好页侧**：`Tests/WindowManagerTests/SelectionBubblePreferencesTests.swift` **16 条 / 0 红**，用新写的 `/tmp/xctstub/run_prefs.sh` 跑。这一份以前从没离线跑过（`swift test` 挂了之后只跑了 SelectionPopup 模块），M129–M132 那四条页面变异当时是没有判据的 —— 本轮补上。
- **桩件两处事实**（不是产品 bug，但直接影响判据，写下来）：
  1. **本地化 bundle**。`L()` 找的是「可执行文件旁边 `*.bundle/xx.lproj/Localizable.strings`」。桩件里没摆，15 家引擎全画成同一个截断 key，`testTheEnginePickerShowsTheChosenEngine` 量出**0 个变化像素**（一度看着像「下拉没接线」）。修法：`run_prefs.sh` 里把仓库那两份 .strings 复制成 `/tmp/xctstub/StubResources.bundle/{en,zh-Hans}.lproj/`。
  2. **对象文件按清单筛**。`.build/debug/*.build/*.o`  glob 全链会把**已删除源码的旧产物**链进来（实测捞到 4 份：EventCapture/CanvasCaptureProbe、Preferences/DrawGestureView、Screenshot/ScreenshotEditor、Storage/ClipboardHistory），链接期报「Undefined symbols: Screenshot.ScreenshotToolbarView.sync…」那种看不懂的红。改成拿每模块的 `sources` 清单过一遍，不在清单里的 .o 一律不链。
- **像素差分改成「带内」判**（M52 那一课的落地）：整页差分会被旁边该变的那一块盖掉。本轮实测 1x 渲染（桩件的 `cacheDisplay` 出 760×1600），带子按**页面高度分数**取而不是像素 —— 三条带：`engineBand 0.47…0.57`（下拉行 y≈784..794）、`urlRowBand 0.54…0.58`（自定义框 y≈888..906）、`belowEngineBand 0.59…1.0`（下面「代按 ⌘C + 读取延迟」两块）。**带子先自证**：新用例第一步是「换一家引擎，差必须落在 engineBand 内」，落不进就是带子画错了，用例红得有道理；然后才用它判「关掉搜索格该把整块灰掉」和「自定义框填好之后下面两块该归位（空 URL 时 >20 变化行、填好后 <20）」。

### 反向变异 M113–M132

表 `/tmp/msprobe/mut_engine.py`（20 条），执行器 `/tmp/xctstub/mut_engine_suite.py`：起跑前备份 5 个文件并记 SHA，每条跑完立刻还原并核对 SHA；**每条会真跑模块那 161 条**，模块全绿或改的是 `Sources/Preferences/` 下那份时再跑偏好页那 16 条；**编译红不算抓到**。覆盖的是这张表真正的坏法：占位符那一判失效（M113）、旧版自动追加 `&q=` 复活（M114）、AI 不复制（M115）、搜索也复制（M116）、`.custom` 归进搜索组（M117）、自定义不退回（M118）、`looksLikeURL` 退化成 `contains("://")`（M119）、两个下拉分组筛反（M120）、控制器 write/open 次序与条件四处（M122–M125）、快照四处键不读（M126–M128）、页面四处接线（M129 下拉 get、M130 URL 行 disabled、M131 黄字常驻、M132 引擎块不看搜索格开关）。

**结果**（`/tmp/xctstub/mut_engine_log_1792735202.txt`；起跑前备份 5 个文件并记 SHA，每条还原后逐条核对，五项基线 `SE 393f76e320 / BL 4f614503d5 / BC 0cebc724be / BS 62eb773f58 / PV 71e5d62cf1` 全部对上）：**预期该抓到的 19 条里，第一轮抓到 18 条、漏 1 条（M132）**；M121 当场声明为等价变异（默认值此刻正是 `google`，改完行为一模一样，它咬的是「将来换默认引擎」那天，靠注释 + M127 兜）。多数几条是**一屏全红**级别的坏法：M120 下拉分组筛反 → 模块 40 条 + 偏好页 2 条，M125 `open` 接缝丢失 → 43 条，M127 快照不读引擎键 → 模块 9 条 + 偏好页 8 条。

**M132 漏了，坏在我的判据而不是产品代码**（这一条值得单独留字，因为它和 M52 那一课是同一件事的另一面）。那条用例中段写了 `apply().selectionPopupSearchEngine = "bing"` 却**没还原**，于是「关掉搜索格」那一次对比的两张 PNG 本来就是**两家不同的引擎**，`engineBand` 里那几十个变化像素全部来自下拉上那个字（`/tmp/rowdiff.swift` 量到 y 788…792 → 0.492…0.495），「整块有没有灰」压根没进判据 —— 变异跑完全绿就是这么来的。修法分两步：三步渲染**都钉在同一家**（`pinnedEngine`，两端各显式写一次），并且把「换一家引擎，差必须落进 `engineBand`」提成用例的**第一条自证**，带子跑偏就先红、不给后面那条判据说话的机会；另外三条渲染用例也各钉一次，把「库里那一家是上一份用例的残留」这层不确定一并去掉（这条改完 `testTheEnginePickerShowsTheChosenEngine` 自己就先红了 —— 它原来依赖默认值）。改完拿 M132 那份变异**单独重跑**：失败断言 1（`关掉搜索格，引擎区块没灰`），再量那两张 PNG 的差异行，只剩 0.323…0.333（「搜索」那一格自己那一行），证明红的是灰度那一条，不是又撞上别的。

**跑完之后才加的**：`searchLogLine`（装机清单第 26–31 步唯一的凭据，要把「选的那一家 / 实际用的模板 / 拼没拼进 URL / 动没动粘贴板」四件事分开说清）。它不在 M113–M132 的覆盖内，为它补了 4 条用例（四格组合各一句、自定义退回时前半句仍写 custom 而箭头后是 google、自定义可用时显示自己那条模板、逐行核「每一家的自述和它实际的行为一致」），模块侧因此从 161 条涨到 **165 条**；两套用例在干净树上复跑 `165 / 0` 与 `16 / 0`。**本轮没跑全量回归**（本机工具链无 XCTest，`swift test` 起不来），这一格要在验收时说破。

**为什么这一句日志值得单独测**：`NSLog` 在 `swift test` 里拿不到，抽成纯函数才能验。上一轮「读到了」那一行就是因为留在 `showPanel` 里，装机后用户问「现在什么软件里才有效果」时日志答不上来（同 `successLogLine` 的先例）。这一轮旧写法更隐蔽：`prefillsQuery ? "查询拼进 URL" : "已放进粘贴板"` 是一句三元，对 ChatGPT 那种「模板带占位符、但仍然要先替他复制」的组合会把后半句**说反** —— 三件事各自独立，日志里合写成一句就是错的，而错的日志比没有日志更坏（装机清单全靠它判）。

### 装机清单（第六轮，接在第 24 步之后；验的是「点放大镜到底开哪条网址、动没动粘贴板」）

日志口径同第 16 步那句（限定 `process == "MacStroke"`、带 `--info --debug`），本轮只看这一句：

```
/usr/bin/log show --last 2m --info --debug --style compact --predicate 'process == "MacStroke"' \
  | grep -a "搜索走" | tail -6
```

句式的读法：**「搜索走」后面是偏好里选的那一家，箭头 `→` 后面是实际用的那条模板**，破折号后面说清两件独立的事（查询有没有拼进 URL、有没有动粘贴板）。箭头那半句是本轮加的，为的就是第 31 步那种「选了自定义、实际开的是退回那一家」的情形只看前半句会读错。

25. **先看页面形状（不用日志）**：偏好设置 → 划词气泡 → 「搜索走哪一家」。校验值：下拉里两组共十四家（搜索引擎六 + 网页 AI 八）加「自定义」；只有选了「自定义」，下面那条「自定义 URL 模板」才编辑得动；换成别家时黄字消失，且再下面的「读不到选区时」「读取时机」两块**位置不动**（空 URL 那一栏常驻占位，填好填坏都不该把整页顶上去 —— 这条是 `testFillingInTheURLRestoresTheRestOfThePage` 的量判据）。
26. **搜索引擎那六家里挑一家（判据两半都要）**：选「必应」，在 Chrome 划一句 → 点放大镜。校验值：日志 `搜索走 bing → https://www.bing.com/search?q={query} —— 查询拼进 URL，不碰粘贴板`；浏览器开的是必应结果页、查询词就是划的那段；**粘贴板还是划词前那句 A**（回文本框 ⌘V 验）。百度/搜狗/360 各自吃的参数名不一样（`wd` / `query` / `q`），换着点两家就知道「一张表」不是话术。
27. **网页 AI：模板带占位符那三家（ChatGPT / Copilot / Perplexity）**：选 ChatGPT，划词 → 点放大镜。校验值：日志 `搜索走 chatgpt → https://chatgpt.com/?q={query} —— 查询拼进 URL，同时把这段字放进粘贴板备着 ⌘V`；页面打开后输入框里有那句（**这家预填本来就时灵时不灵**，没进去也别说坏，⌘V 能贴出就算这一手成立）。
28. **网页 AI：模板不带占位符那五家（豆包 / DeepSeek / 通义 / Gemini / Kimi）**：选豆包。校验值：日志 `—— 这一页不吃 URL 预填：已放进粘贴板，打开后 ⌘V`，粘贴板里就是划的那段字，页面打开后 ⌘V 能问。**这一条会正常进粘贴板历史**（是用户自己点了「搜索」，与第五轮那种代按不是一回事，别拿第 19 步的判据来判它）。
29. **自定义，带占位符**：自定义 URL 模板填 `https://www.ecosia.org/search?q={query}`，选「自定义」。校验值：日志箭头后必须是**这一条**而不是 google 那条，后半句是「查询拼进 URL，不碰粘贴板」。
30. **自定义，不带占位符**：同一栏改成 `https://kimi.moonshot.cn/`。校验值：后半句立刻换成「这一页不吃 URL 预填：已放进粘贴板」—— 行为只看模板，不看这一家是谁。
31. **自定义留空 / 写得根本不像网址**（改成 `abc`）：校验值：页面出现那句黄字，日志是 `搜索走 custom → https://www.google.com/search?q={query} —— 查询拼进 URL，不碰粘贴板` —— **前半句是你选的，箭头后是实际开的**，这一格配坏了仍有一家有反应。
32. **搜索不许把「代按」牵进来**：以上随便哪家点几次。校验值：日志里**不出现** `代按 ⌘C` 字样（那一手只属于「读不到选区」那一路，与走哪一家无关）。出现了就是把两条链并错了。
33. **收尾**：URL 栏清空、引擎改回默认那一家（Google）、快捷键改回 ⌃⌘B，再照第 24 步做一次右键手势。校验值：手感不变。

## 15. 第七轮：那一步没人替用户按 —— 「打开之后自动补一次 ⌘V」（同一号 3.2.0 的第二轮）

用户 10-23 的实测反馈是「我测试了为什么只有搜索引擎才可以，AI 网页的没有带关键词过去」。这不是坏：第六轮那张表里「模板不带 `{query}`」的那些家（网页 AI 七家 + 没写占位符的自定义）本来就只做两件事 —— 把字放进粘贴板、打开那一页，**键入那一步留给人**。当时给的两个选项里用户挑了「自动补一次 ⌘V」，于是本轮加一颗偏好开关，把那一步也替他按掉。

### 版本号：同一号里的第二轮，靠第三道哨兵分新旧

10-23 定的规矩是「一轮一号，线上是什么加一个上去」（线上 3.1.9 → `APP_VERSION="3.2.0"`），本轮不另开号，仍编 3.2.0。代价很具体：**装了 3.2.0 的人无法从版本号看出自己吃没吃到这一手**，`plutil` 那条判据在这里失效。补法是把「这一手在不在二进制里」做成第三道哨兵 —— `build_app.sh` 现在还要 `grep -aq "selectionPopupAutoPaste"`，摸不到就红着不出包。选键名而不是选那句日志正文：日志是格式串，改文案就假红（第六轮那句 `sogou.com/web?query=` 是同一个道理），而键名要落盘、要进注册表，删不掉也不会改。

### 一个开关，两半判据（**排不排** 与 **投不投** 是两件事）

`SelectionBubbleSettings.searchAutoPaste` 只管「点下放大镜之后要不要排这一次」，五条各挡一种真实坏法：

- `enabled && hasCells` —— 功能整个关掉、或四格全关时，不该有任何按键进得了事件流；
- `autoPasteAfterOpen` —— **用户没点头就不碰他的键盘**（这一颗默认关，理由和 ⌘C 那颗相反：⌘C 那一手不做就是没功能，这一手不做只是让用户自己按一下）；
- `searchTarget.copiesTextFirst` —— **只有那种「字是我们放进粘贴板的」页面才贴**。真能 URL 预填的六家压根没写粘贴板，这时候补一刀 ⌘V 贴出去的是用户本来就自己复制着的东西，那不是贴心，是往他没打算填的框里填别人的内容；
- `!isPlainCommandV(shortcut)` —— 拆环（见下一格）。

到点那一刻再由 `pasteGate` 判「投不投」，两道闸**同时不过**时只报一个原因，顺序定死为**粘贴板先**：贴错内容（把别人刚复制的东西打进一个他没准备的框）比贴错窗口（贴进我们自己的面板，什么也不会发生）更坏。这道顺序写进纯函数、也写进日志文案，装机时那句「为什么这次没贴」全靠它分锅（M138 咬反序）。

### 拆环那一条：为什么是「压根不上场」而不是「加冷却」

我们投出去的那一下**就是**不带别的修饰键的 ⌘V，它会进全局事件流，被 `ShortcutMonitor` 收走。用户要是把气泡快捷键录成单纯 ⌘V，就成了「点搜索 → 打开页面 → 自动 ⌘V → 监听命中 ⌘V → 又读选区 → 又点搜索…」，每一圈都在动键盘和浏览器。冷却只把环变慢，所以这一档直接判否。`isPlainCommandV` 是 `isPlainCommandC` 的同一件事换个键码（V=9，C=8），比的是**全套标准修饰键**（掩码 `0x1E_0000`，恰好只剩 ⌘）：默认那组 ⌃⌘B 不命中，粘贴板历史那组 ⌥⌘V（`flags=1572864`）也不命中 —— 这一条不做成「含 ⌘ 就算」，否则误伤后者（M143）；也不做成逐位比全套 flags，否则录成左 ⌘V 的人以为躲开了（M144，设备位那一位实测在 1048584）。

界面对应一句橙色说破：**开关开着却一次不生效**必须写出来，不然用户只会以为这一手坏了（同第五轮「代按 ⌘C 被快捷键挡住」那一处）。

### 1.2 秒这个数，以及为什么不给它铺滑杆

`SelectionBubbleSettings.autoPasteDelay = 1.2`。取这个数是照装机那类页面来的：聊天/AI 页从被激活到把光标落进输入框，快的几百毫秒，慢的要在登录态里绕一圈；再长就长成「点了放大镜半天没反应」的手感，再短则抢在页面落光标之前 —— 那一下 ⌘V 打进的是地址栏。它是**手感阈值**不是用户能配的偏好（铺了滑杆也没人知道该调成多少），所以不进偏好页；用例钉三件事：等于文档那个数、短于气泡自身寿命那一档、长于读取延迟（M141 与 M149 一头一尾：常数改掉、消费端写死 0.3 都会红）。

### 投出去的是哪两下按键（`pasteEvents()` 为什么值得单独拆一层）

`postPasteKeysToSession()` 拆成「造事件」+「投事件」两半，因为写坏的方式恰好是别的层看不到的那几种：漏掉 `.maskCommand` 就是往别人的输入框里打一个字母「v」；键码抄成 8（C）就是再替用户复制一次、把他刚复制的东西覆盖掉；只投按下不投抬起，前台看到的就是「⌘V 一直按着」。这三样在测试进程里只有把 `CGEvent` 交出来才能断言，于是 `testTheInjectedPasteIsCommandVUpDown` 逐条核：键码 = 9、按下与抬起都在、两处修饰键都只剩 ⌘。

**投递仍走 `.cgSessionEventTap`**（硬线没动，同 ⌘C 那一句）：不穿过我们自己那只 head-insert 的 HID tap，所以「识别执行与耗时不许受影响」这条不变；也不往 `EventCapture.mouseEventMask` 加任何左键事件，气泡只读 `NSEvent.addGlobalMonitorForEvents`。这一层的落点**用例看不见**，M155 因此故意抓不到，靠装机清单第 41 步验。

### 界面上那一行摆在哪、什么条件才亮

摆在「搜索走哪一家」那张卡片的最后一行（不摆进「读不到选区时」那一节：那一节管**取字**，这一行管**把字交出去**，混在一起会让人以为它和代按 ⌘C 是同一手的两半）。可用条件 `canUseAutoPasteRow = canUseEngineRow` —— **和「搜索走哪一家」同一档**，搜索那一格关掉时这里没有对象可贴。这里**不看**下拉选的是哪家：真能预填的六家点了这颗开关也确实什么都不会发生（`searchAutoPaste` 里 `copiesTextFirst` 挡着），但那属于「这一家轮不到」，不是「这一格坏了」，画成灰的反而让人以为按不动是毛病。

### 离线取证（本轮）

- **模块侧 181 条 / 0 红**（`/tmp/xctstub/run.sh`）。比第六轮那趟（165 条）多 16 条：Settings 17 → **23**（五条判据各挡一次、四种闸门组合、单纯 ⌘V 那七种 flags、那两个数字、键名不与他键冲突、快照读写两头）、Controller 36 → **45**（排期次序/延时/到点重判/两道闸/自定义看模板/名单筛一遍）、CopyReader 29 → **30**（`pasteEvents()` 那一串断言）。
- **偏好页侧 18 条 / 0 红**（`/tmp/xctstub/run_prefs.sh`），比上轮 +2：`testTheAutoPasteRowGreysWithTheSearchCell`、`testAPlainCommandVShortcutWarnsBelowTheEngineCard`。
- **带子又量了一遍**（M52 那一课换了个方向重演：这次不是带子没罩住，而是**新行插进来了，旧带子的下沿压到了它**）。实测 1x 离屏渲染（760×1600）：自动贴那颗开关的滑块在 y≈980..996（页高分数 0.6125..0.6225），于是 `autoPasteRowBand = 0.60…0.64`；`belowEngineBand` 的下界从原来的 0.59 **抬到 0.69**（引擎卡片以下第一块内容实测在 y≈1112 = 0.695），否则「有没有那句黄字」的判据能靠这颗开关自己动一下蒙过去。两条带子各钉一次边界：只拨这颗开关时 `belowEngineBand` 必须 <20 个变化点（实测 0），只换快捷键时 `autoPasteRowBand` 必须 <20（实测 0）。判据不是「差值过阈值」就完事 —— 每条都先用一次「该动的动了」自证带子位置，再用一次「不该动的没动」钉边界（那两份计数由 `/tmp/xctstub/band_counts.swift` 复核：178 / 113 / 0 / 17308 / 17308 / 0 / 0）。
- 桩件里 `pasteScheduler` 那一条接缝记了一笔 `"schedule"` 到事件序列里。不记就演不出「先排贴、后开页」那种坏（本轮写变异时才发现，M147 原来会逃）：贴那一手是排在延时里的，序列里看不见它**什么时候**排的，`[write, open]` 这个断式对两种次序都成立。改完点完格子那一刻序列是 `[write, open, schedule]`，放行之后才多出一笔 `paste`。
- **本轮仍没跑全量回归**（本机只有 CommandLineTools，`swift test` 起不来）。离线两套是 SelectionPopup 模块 + 划词气泡偏好页，其余模块没动过源码。

### 反向变异 M133–M165（33 条，表 `/tmp/msprobe/mut_autopaste.py`）

执行器还是 `/tmp/xctstub/mut_engine_suite.py`（本轮把它改成从环境变量取表与根目录：`MUT_TABLE` / `MUT_ROOT`，位置参数仍是「用例号白名单」）。规矩同前：**起跑前先备份 6 个文件并记 SHA**，每条跑完立刻还原并逐条核对，编译红不算抓到，预期抓不到的故意列出并注明靠什么核。两套桩件都真跑：模块 181 条 + 偏好页 18 条（模块全绿、或改的是 `Sources/Preferences/` 下那两份时，偏好页那一套才跑）。

**结果**（`/tmp/xctstub/mut_r7.log` 与补录那一条的 `/tmp/xctstub/mut_r7_M164.log`；起跑前基线 `Preferences d807d0488d / TabView 33a0cdd2e4 / Controller c563b36145 / Settings fdc16e760e / CopyReader 97359da3ba / Storage 5b7147fcfb`，跑完六项全部对上）：**33 条里预期该抓到的 31 条全部抓到，0 漏**；两条故意不抓（下面第 3、4 格）。总耗时 5585 秒。抓到时的红条数大多很小（**一条**就够 —— 判据是各挡一格的，不是铺一堆重复断言），最响的两条是 M146「无条件排一次贴」→ 模块 32 条，M133「用户那颗开关不算数」→ 模块 18 条 + 偏好页 1 条。

四条值得单独留字的：

1. **M147「先排贴、后开页」原来会逃 —— 是写变异时才发现的**。那条次序用例原先断的是 `sink.events == [write, open]`，可排贴这一手是**排在延时里**的，闭包攥在 `sink.scheduled` 里，序列里根本看不见它什么时候排的 —— 两种次序下这句断言都成立。修法：桩件的 `pasteScheduler` 假件多记一笔 `"schedule"`，点完格子那一刻序列钉成 `[write, open, schedule]`，放行之后才多出一笔 `paste`。顺带把另一条也变响了：M133 现在还会撞 `testAnAIEnginePutsTheTextOnThePasteboardBeforeOpening`（事件数 2 → 3）。
2. **M164 第一版是编译红，不算抓到，而且说明一句断言是空的**。我原来演的是「enum 里把 `selectionPopupAutoPaste` 的 rawValue 写成和 `selectionPopupCopyFallback` 同一个串」—— Swift 对字符串原始值重复**直接编译报错**，演不出来。推论写在这儿：`testAutoPasteIsOffByDefaultAndHasItsOwnKey` 里那句 `XCTAssertNotEqual(rawValue, rawValue)` **挡不住任何真实坏法**，它只防将来把键名提成常量之后再抄错。真会发生的撞键走的是**读取侧**（`current(from:)` 去读另一把键），改成那一版就红了：模块 3 条 + 偏好页 5 条。写侧的撞键是 M161（`didSet` 写到另一把键），也是红的。
3. **M155「投到 HID 层」故意抓不到**，而且**没有**任何用例能抓：测试进程里看不见事件落到哪一层。它踩的是那条死线（HID 层要穿过我们自己那只 head-insert 的 tap，识别执行与耗时会被影响）。核对方式只有两条 —— 代码走查（`SelectionCopyReader.postPasteKeysToSession` 里两处 `post(tap:)` 都写死 `.cgSessionEventTap`）+ 装机清单第 41 步（开着自动贴连点五次，再画一次原来的右键手势读耗时）。
4. **M165「注册表里漏掉这一档」当场声明为等价变异**：本模块一律经 `Storage` 读（`getBoolOptional ?? StorageDefaults`），`registerUserDefaultsDefaults()` 那份只服务 raw UserDefaults 的读取方；全量回归里那条 register 断言点到的也是粘贴板那几颗键。它咬的是「将来有人用 raw UserDefaults 读这颗键」那天。

另外两处不是「抓到」而是「红得有意思」，留作下一轮的判据参考：M143（修饰键只查含不含 ⌘）与 M144（不做掩码、逐位比全套 flags）都是从 `testPlainCommandVMatchesOnlyBareCommandV` 那一格红的 —— 那一条把七种 flags 各钉了一次，两个方向的坏法各自只撞其中一格；M141（常数 1.2 → 8.0）只红 `testAutoPasteDelayIsTheDocumentedNumberInsideTheBubbleLifetime` 一句，而 M149（消费端写死 0.3）反过来只红控制器那一句 —— 这两条合起来才是「常数只此一处」的完整判据。

**跑完之后在干净树上复跑两套**：模块 **181 条 / 0 红**、偏好页 **18 条 / 0 红**（本轮仍未跑全量回归，本机没有 XCTest）。

### 装机清单（第七轮，接在第 33 步之后；验的是「那一下 ⌘V 到底有没有替我按、不该按的时候有没有忍住」）

日志口径同第 16 步那句（限定 `process == "MacStroke"`、带 `--info --debug`），本轮只看这两句：

```
/usr/bin/log show --last 2m --info --debug --style compact --predicate 'process == "MacStroke"' \
  | grep -aE "搜索走|自动贴" | tail -8
```

34. **先确认装到的这一版带这一手（版本号在这里不够用）**：
    ```
    plutil -extract CFBundleShortVersionString raw /Applications/MacStroke.app/Contents/Info.plist
    grep -a -c "sogou.com/web?query=" /Applications/MacStroke.app/Contents/MacOS/MacStroke
    grep -a -c "selectionPopupAutoPaste" /Applications/MacStroke.app/Contents/MacOS/MacStroke
    ```
    校验值：`3.2.0`、`1`、`4`（第三串实测在这份二进制里出现 22 次、落在 4 行上，`grep -a -c` 数的是行 —— **≥1 就算有**）。第三句是本轮加的：**这一轮和上一轮同一号，版本号看不出吃没吃到**，只有这一串能分。「页面打开后替我贴一次」那一行也要在界面上看得见 —— 偏好设置 → 划词气泡 → 「搜索走哪一家」卡片**最后一行**，默认**关**，且关掉「搜索」那一格时它变灰。
    本轮装机踩到一个坑，写下来免得下次再踩：`rsync -a ./MacStroke.app /Applications/MacStroke.app`（两端都不带 `/`）在目标已存在时会**套一层**成 `/Applications/MacStroke.app/MacStroke.app`，外面那一层还是旧包 —— 脚本照打「复制完成」、`open` 照样起得来、`plutil` 照样读 `3.2.0`，**只有第三句哨兵数出 0 次**才暴露。正确写法是两端都带 `/`（`rsync -a --delete ./MacStroke.app/ /Applications/MacStroke.app/`），装完再 `shasum` 两边比一次。
35. **开着开关 + 选一家不吃预填的（豆包）= 主力判据（两句都要有）**：打开那颗开关，引擎选豆包，Chrome 里划一句 → 点放大镜。校验值：先是 `搜索走 doubao → https://www.doubao.com/ —— 这一页不吃 URL 预填：已放进粘贴板，打开后 ⌘V`，**过约 1.2 秒**再来两句 `自动贴：投一次 ⌘V（粘贴板还是那句 N 个字符，前台不是我们自己）` + `自动贴：已投出 ⌘V`，页面输入框里就是划的那段字。**这个 1.2 秒要数一下**：明显更快（像 0.3 秒，抢在光标落位前）或明显更慢（常数被改）都算不符。
36. **真能预填那六家不许多按一次键**：引擎换成 Google（开关仍开着），划词 → 点放大镜。校验值：日志只有 `搜索走 google …` 那**一句**，**不出现**「自动贴」；粘贴板还是划词前那句 A（回文本框 ⌘V 验）。这条是本轮最要紧的负向判据 —— 它坏了就是「往他没准备的框里填别人的内容」。
37. **那 1.2 秒里你又复制了别的东西 → 什么都不投**：点完放大镜立刻在别处 ⌘C 一句话。校验值：`自动贴没做：粘贴板里已经不是刚复制的那 N 个字符 —— 这时候贴出去的是别人的东西`，且页面里**没有**你刚复制那句。这一格没有第二条路可验，只能演出来。
38. **前台已经换成我们自己的窗口 → 不投**：点完放大镜立刻点开偏好设置那个窗口、把光标落进「自定义 URL 模板」那栏。校验值：`自动贴没做：前台是我们自己的窗口，那一下 ⌘V 不该打进这里`，那个文本框里没被贴进内容（坏了的样子就是「搜索完，粘贴板里那句话跑进了设置窗口」）。
39. **等的时候把这一步关掉 → 不投**：点完放大镜立刻把那颗开关拨回关。校验值：`自动贴没做：等的时候这一手已经关了`（判据取的是**当下**那份快照，不是点下去那一刻）。
40. **气泡快捷键录成单纯 ⌘V = 整档不上场，且界面要说破**：把「唤出气泡」那颗快捷键录成单纯 ⌘V，那颗开关保持开。校验值：那一行下面出现橙色那句「…这一手不能上场…」（同时验另一半：改回 ⌃⌘B 后那句要消失）；划词点放大镜后**不出现**「自动贴：投一次 ⌘V」。**这一条还有第三个判据**：改完之后气泡不能自己转圈开浏览器 —— 真环起来就是拆环没做成（M137 咬的就是这一格）。做完把快捷键改回 ⌃⌘B。
41. **那条死线（本轮唯一能验落点的地方）**：开关开着、引擎豆包，连点五次放大镜、每次都等它贴完，然后照第 24 步做一次原来的右键手势并读一次耗时。校验值：识别照常、手感不变。这一手投的是 session 层，**用例看不见落在哪一层**（M155 故意抓不到），只有这一步能验；若画手势出现明显迟滞或误识别，先把那颗开关关掉再回报。
42. **收尾**：那颗开关拨回关、引擎改回 Google、URL 栏清空、快捷键改回 ⌃⌘B，退出偏好设置再进一次。校验值：那颗开关还是关的（库里没写脏），并且第 35 步那两句日志不再出现。

**这一轮验不上的一件事**：网页 AI 那几家多数要先登录才有输入框，未登录时页面停在登录墙 —— 那不代表这一手坏了，判据是「粘贴板里躺着划的那段」（第 27、28 步那句 ⌘V）。真想知道哪家预填有效，得各家账号各自试过，这一期只保证：拼得出的就拼，拼不进的就替你复制好。
