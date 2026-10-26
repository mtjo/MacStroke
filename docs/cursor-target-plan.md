# issue #22：手势该打到「光标下那一扇窗」，不是抬手那一刻的前台

用户 2021 年报的问题原话：**「手势动作应打到光标下的窗口，而不是当前活跃窗口」**，并举例
「光标停在浏览器上画手势，快捷键却打进 IDE」。移植版老行为照抄原版：抬手那一刻读
`NSWorkspace.frontmostApplication`，规则按那一家匹配、注入的键也按那一家落地 —— 于是画出轨迹的
那扇窗和真正挨了一下键的那扇窗可以完全不是一回事。

本轮状态：**已实现、默认关、离线取证与变异跑完、3.2.2 的包已装机，等用户按 §10 实测**。用户 10-25
定的两条口径写在这儿，免得下次顺手做过头 —— 「我看好方案再确认，也不要回复用户」，所以 issue 上
**一个字都没回**（#22 现况 `closed`，是用户自己 2026-09-24 关的，2 条评论，本轮没动过它）；版本号按
「线上是什么就加一号」的规矩走：线上 `gh release` 是 3.2.1，本轮 = **3.2.2**，装机调试期间反复覆盖这同一个号，验收过了才由
`release.yml` 真发。

## 0. 先回答「macOS 支持吗」

支持，但要走对那一手。注入的键走 **session 层**（`ActionExecutor` 里那两条注释说了为什么不能投
HID 层：会卡住我们自己的 head-insert tap），而 session 层按「谁是活跃 App」派发。焦点还在 IDE 时
往 session 层投 ⌘S，保存的就是 IDE。所以「打到光标下那扇窗」= **投动作之前把活跃 App 换成那扇窗
的主人**，没有第二条路能把 session 层的键塞给一个非活跃 App 的某扇特定窗。

三条真能走的路，实测数字在 `/tmp/xctstub/ax_focus_methods.swift`（焦点那一半）与
`/tmp/xctstub/ax_key_latency.swift`（落键那一半）：

| 方案 | 做法 | 实测 | 采不采 |
|---|---|---|---|
| A 一次性改投 | 投之前写目标 App 的 `AXFrontmost`，投完按设置决定还不还 | 跳转后 Chrome **222ms**、邮件 **491ms** 把键变成可见动作；跳转本身 **1～94ms** | **采**（用户 10-25「按你的推荐方式做」） |
| B 直投 pid | `CGEventPostToPid` 绕过活跃 App | 也能落到（Chrome **1315ms**、邮件 **732ms**），但那是「非活跃 App 自己收键」，逐家行为不一致，**文本要落进输入框还得靠 key window** | 不采：慢一截 + 逐家不可预期 |
| C 骗一次点击 | 原版 `CanvasWindowController.m:155-157`：合成一次左键把焦点骗过去 | —— | 不采：用户画完手势凭空多点一下，踩到的是别人家的按钮 |

## 1. 分成三层，每层都能单独问「为什么没生效」

`Sources/RuleEngine/CursorTarget.swift`（抓取 + 判定）、`Sources/RuleEngine/FocusMover.swift`
（挪焦点 + 还焦 + route 那张安排表）、App 层只有 `main.swift:1052-1093` 那一小段接线。
抓与判分两半，判定那一半是纯函数、一个系统调用都不碰：装机时日志里要能分清「功能没开」「那个
位置压根没窗」「只有我们自己的窗」「那家不是可激活的普通 App」「那家被黑名单排掉了」「本来就是
同一家」—— 这六种在界面上长得一模一样（什么都没发生），统计全靠 `Reason` 那七档。

`CursorTarget.attribute` 逐条往下找**第一个够格**的窗，不是只看最上面那一扇（自家透明画布就压在
指针上，只看最上等于永远归给自家）。五道门槛顺序钉死，每道只挡一种真实坏法：
`globalBounds.contains(point)` → 不是自家 pid → `layer == 0 && alpha >= 0.99` → `isRegularApp` →
bundleID 非空 → 黑白名单放行 → 才谈 `sameAsFront` 还是 `cursorWindow`。
黑名单要在**判定阶段**就问：黑名单的语义是「别在这家里动手」，光标压在黑名单的 C 上、前台是 A 时
跳过去，等于用一条 A 的规则往用户明确排除的 C 里注入键（M171 咬这一格）。

## 2. 匹配也用那一台

`CursorTarget.ruleBundleID(attribution, frontBundle:)` —— 归给光标下的窗时**规则也按那一家挑**。
动作要落在那家、规则却按隔壁那家挑，就成了「用 IDE 的规则往浏览器里投 IDE 的快捷键」，解释不通。
用户画在哪家上，用的就是哪家的规则。关着或判不出别家时 = 前台那家（老行为一字不变）。
接线点在 `main.swift:1077`，**这一手用例够不到**（见 §7 的 M196），靠装机清单第 4 步验。

## 3. 挪焦点：四条从实测钉下来的规矩

`FocusMover.swift` 头部把这四条写全了，改这段代码前先读：

1. 只 `AXRaise`、或只写窗口 `AXMain`，**都改不了前台**（返回码都是 0，看着像成功）。真正生效的是写
   App 元素的 `AXFrontmost`（单独写 61～94ms，配合先 `AXRaise` 是 1～3ms）。
2. 成没成**不能**问 `NSWorkspace.frontmostApplication`：实测它在同一瞬间还报旧家；
   `NSRunningApplication.isActive` 是异步通知喂的缓存，而这一段跑在手势的 HID/CGEventTap 回调里，
   回调没返回 runloop 就不转，缓存可以整段预算期都是旧的。判据只取「此刻的真实」两条：目标自报的
   `AXFrontmost` + 窗口服务里层 0 最前那扇窗的主人，两条里有一条说「是」才算跳成。
3. 还焦不能紧接着投完就做：键从 session 层走到目标 App 变成可见动作要 222～491ms，提前抢回来
   等于把刚投出去那一发也抢回自己家。所以还焦走延迟队列（`restoreSettleSeconds = 0.6`），
   **绝不在这里 sleep** —— 睡多久用户就白等多久。
4. 还焦还有一道闸：到点时前台已经不是我们跳过去那一家 → 用户自己动过了，这一手让位
   （`scheduleRestore(onlyIfFrontStill:)`）。无脑抢回「抬手时那家」= 替用户做了一次他没做过的切换。

跳转失败**不推翻用户的动作**：照样投（等于老行为，落回原前台那家），日志写明「没跳过去（raise=…
写 AXFrontmost=…）、这一发按老行为投给了谁」。静默丢掉动作比跳错家更难查（M184 咬这一格）。
`activateBudgetSeconds = 0.25`、单次 AX 调用超时 0.15s、轮询 5ms 一格 —— 预算再长就是在 HID 回调里
干等（M176 把 3 秒那一版咬红）。

次序是这段唯一的命门：**挪焦点 → 投动作 → 安排还焦**。所以 `StrokeRouter.execute` 把动作本体做成
注进来的闭包，用 `FakeFocus` 记下调用序列，断 `["activate:200", "action", "restore:100"]`
（M183 演「先投再挪」，次序反了真机上表现为「时对时错」，肉眼不可能复现）。

## 4. 哪些动作参与：`RuleAction.needsCursorAppFocus`

只有「会往活跃 App 投东西」的四档需要跳：`keyPress / shortcut / text / password / applescript`。
其余四档按类型判 false，界面上不给铺勾选 —— 铺了只会让用户以为勾上就能让「复制文本」也去跳焦点：

- `mouseClick` 本来就按坐标打，点哪家就是哪家（点下去那一下自己就把它变前台）；
- `copyToClipboard` 只写粘贴板，与谁是前台无关；
- `screenshot` **必须不跳**：这一档弹的是我们自己的全屏遮罩，遮罩正摊开时延迟还焦会把焦点从截图窗
  抢走（M180 专门咬这一格，`testScreenshotNeverMovesFocusEvenWhenAttributedElsewhere` 还留了另一半：
  **规则仍按光标下那家匹配**，只是不动焦点）；
- `none` 没有动作。

## 5. 死线：关着的时候一次 `CGWindowList` 都不许花

`StrokeTargetSettings.needsWindowProbe`（就是 `enabled`）把抓取挡在 App 层外面
（`main.swift:1059`）。这条不是洁癖：issue #43/#68 那两轮量过，**抬手响应时间是这条功能的死线**，
一台机器几十到上百条窗口记录，每笔手势多一次 `CGWindowListCopyWindowInfo` + 逐条问
`NSRunningApplication` 是实打实的开销。而且它**在界面上完全看不出来** —— 行为照旧、日志照旧，
只有代码里那一句条件在动，所以把判据做成模块里的一个属性（而不是把条件抄在调用处），
M174 才有地方咬（关掉时 `needsWindowProbe` 必须 false，三种组合都钉）。

## 6. 抬手点必须和 `kCGWindowBounds` 同一把尺

`EventCapture` 为了画布与识别，把 y 翻成 AppKit 的左下原点（`EventCapture.swift:374`：
`appKitY = primaryScreenHeight - cgY`，`primaryScreenHeight = NSScreen.screens.first?.frame.height`）。
命中判定吃的是窗口服务那套（主屏左上原点、y 向下），所以 `CanvasManager` 在派发 delegate 之前
**必须翻回去**（调用点在 `CanvasManager.swift:353`）：差一个 y 就是「明明压在窗上却判成没窗」，而且只在
非主屏区域或窗口上下位置不同时出现 —— 装机时看着像「这功能时灵时不灵」。

`releasePoint` 因此进了 `CanvasManagerDelegate` 的签名（三个 delegate 假件同步改了签名）。
翻那一手今天钉成纯函数 `CanvasManager.windowServerReleasePoint`（`CanvasManager.swift:58`），
`CanvasManagerTests` 用字面数字断三件事：翻得对、翻两次回到原处（防「轨迹点已经被翻过又翻一次」）、
x 不许动；第三条判据另取「delegate 实际收到的那个 y」，参照物是屏高的来源而不是被测函数自己。

## 7. 偏好与界面：一个能力一组控件，只灰不藏

「右键增强」页（3.2.1 从「右键菜单」改的名）滚轮那一组下面新起一张卡
（`PreferencesView.swift:1618-1634`，挂在 `RightClickMenuTabView` 末尾的 1605 行），两颗开关：

- `Stroke Target master`「归给光标下那扇窗」= `strokeTargetsCursorWindow`，**默认关**。开着它会改
  「动作落到哪家」这条所有老规则都依赖的语义，还会让人看到焦点跳一下，不能替用户默认打开；
- `Stroke Target restore row`「投完把焦点还回去」= `strokeTargetRestoresFocus`，默认还。关掉它 =
  「画一次手势」等价于「点一下那个窗口」，接下来的打字都打进被跳过去那一家。`.disabled(!master)`
  只灰不藏（滚轮那组、划词气泡那页同一条口径）。

两个数**不给界面铺控件**：`restoreSettleSeconds = 0.6`（实测落键时间 0.2～0.5 秒，铺了滑杆也没人
知道该调成多少，钉成常量）、`activateBudgetSeconds = 0.25`。文案里把这两个数说破，是因为
「为什么过了半秒才还」用户一定会问。

## 8. 离线取证

本机只有 CommandLineTools（不带 XCTest），沿用 `/tmp/xctstub` 那套桩件 + 生成显式调用表；
计数只认「用例数：」那一行，`check.swift` 那 6 条 FAIL 是桩件自证、不算红。

| 套 | 跑法 | 条数 |
|---|---|---|
| 归属判定 / route / execute 次序 | `zsh /tmp/xctstub/run_stroke_target.sh` | **29** |
| 落盘与 App 层读取写法 | `zsh /tmp/xctstub/run_stroke_prefs.sh`（`StrokeTargetRowsTests`） | **7** |
| 偏好页像素 | 同上（`StrokeTargetPreferencesTests`） | **5** |
| Storage 那两把键 | `FILES=…/StorageTests.swift zsh /tmp/xctstub/run_stroke_prefs.sh` | **3** |
| 抬手点坐标翻转 | `zsh /tmp/xctstub/run_canvas.sh`（`CanvasManagerTests`，EventCapture + GestureEngine 链进桩件） | **23** |

上一轮（3.2.1）那 10 套 + 本轮新加的 canvas 套 = 11 步一次跑完，脚本 `/tmp/xctstub/regress_stroke.sh`。
实测（日志 `/tmp/xctstub/regress_issue22_123413.log`，12:34:13→13:01:15）：**12 行「用例数」合计 645 条**
（181 / 18 / 29 + 19 / 33 / 274 / 7 / 17 / 29 / 12 / 3 / 23），其中 **641 条零红**；唯一那 4 条红落在
`ScreenshotModeTests.testScrollLoopStitchesEveryScrolledScreenAndStopsAtTheBottom`（长截图那个
**定时器驱动的圈**，判据带 `pump(timeout: loopBudget(steps: 4))` 这种墙上时钟预算），报的是
「循环没自己收场：滚了 1 次」—— 同一套单独重跑 `zsh /tmp/xctstub/run_shot.sh ScreenshotModeTests`
是 **43 条零红**（13:03–13:05），04:41 那一轮它也是零红。这条红**不是本轮改出来的**（本轮没碰 Screenshot），
但要说破：那趟全量回归是紧接一次 48 秒的全目标 `swift build` 之后跑的，机器正忙，墙上时钟预算的圈被挤掉
是这类用例的固有弱点。**待办**：把这条用例的预算从「墙上时钟」改成「步数」，或者在表里注明它在负载下会假红。

两个坑单独记一下：

- **跑法必须重建 RuleEngine**。`run_rows_fast.sh` 只 `--target Preferences`，而这两份偏好页用例
  `@testable import RuleEngine` 拿 `StrokeTargetSettings` 的默认值当跨层契约；变异改了
  `CursorTarget.swift` 时若不重建 RuleEngine，链接吃到改动前的旧 `.o` —— 「变异没被抓到」其实是
  「变异压根没进二进制」，这种绿比红更坏。所以新写一份 `run_stroke_prefs.sh`，逐个 `--target`
  建三遍（多个 `--target` 只生效最后一个）。
- **App 层那一句读法要单独演**。`UserDefaults.bool` 对从没写过的键返回 false，而
  `getBoolOptional` 返回 nil；`strokeTargetRestoresFocus` 的默认是 **true**，用 `bool()` 读就分不出
  「用户明确关掉」和「压根没配过」。`StrokeTargetRowsTests.appLayerSettings()` 逐字照抄
  `main.swift` 那一读的写法，另有一条用例专门把错写法演出来（`getBool` 直接读 → false）。
  「重置为默认」那两条还钉 `object(forKey:) != nil` —— 只断值不键存在，写漏一次落盘也照样绿。

页面像素（1x 离屏渲染，`NSHostingView` 挂 borderless `NSWindow` 760×1000，`cacheDisplay` 导 PNG，
分带差分：按页高分数取带、采样步长 2、delta > 0.03）。带子实测：总开关那一行 **y 599…620**
（0.598…0.626）、两条提示 **626…700**、还焦那一行 **706…727**。四条判据各挡一种坏法，
每条都先「该动的动了」自证带子位置、再「不该动的没动」钉边界：

| 判据 | 实测（变化点数） | 挡的是 |
|---|---|---|
| S1 拨总开关：本行动 + 还焦那行变灰 | 174 / 113 | 绑定没接上（M192/M193）、`.disabled` 没传（M194） |
| S2 只拨还焦：只动自己那一行 | 178，上方两段带子 25 / 0 | 两行共用一份绑定（M195） |
| S3 灰档动幅 < 亮档一半 | 25 对 178 | 只画灰没禁点、或反之（M194） |
| S4 这两颗开关不碰上面那两段 | 0 | 新卡把滚轮那组顶歪了 |

S3 那条为什么值得单独留：`Toggle` 的 `.disabled` 既画灰也挡点，但**灰档拨一次滑块照样会动**
（实测 25 点 vs 亮档 178 点）—— 只看「有没有变化」会放过「压根没禁点」，只看「灰没灰」又放过
「灰了还能拨」，所以判据取两边比值（`grey * 2 < live`）。

## 9. 反向变异 M166–M199（34 条，表 `/tmp/xctstub/mut_stroke_cases.py`）

执行器 `/tmp/xctstub/mut_stroke.py`（从 `mut_wheel.py` 抄，四套用例按表里的 `suites` 选：
`logic` / `prefs` / `storage` / `canvas`）。规矩同前几轮：**起跑前**备份被测文件并记 SHA，每条跑完立刻
还原并逐条核对，编译红不算抓到，抓不到的故意列出并注明靠什么核，每轮日志一个带时间戳的目录
（`/tmp/xctstub/mut_stroke_logs/<stamp>/`），全程只有一条 `swift build` 在跑。
起跑前先 `--check` 一遍锚点唯一性：**34 条坏 0 条**（12:26 那一趟）。

**第一趟（M166–M196，31 条）**：`/tmp/xctstub/mut_stroke_progress_20261025-115112.log`，起跑前 SHA
`main=43c9bce8cc / Preferences=13b02326ce / PreferencesView=69fecad4af / CursorTarget=be68fb6443 /
FocusMover=88967758eb / Storage=320b16fc56`，跑完六项全部对上：
**31 条里预期该抓到的 30 条全部抓到，0 漏、0 编译红、0 锚点跳过**，总耗时约 12 分钟
（单条 12～72 秒）。红条数普遍很小（一条就够 —— 判据各挡一格，不铺重复断言），最响的三条是
M191「还焦那行写到总开关的键上」12 条、M188「还焦默认改成不还」10 条、M189「总开关默认改成开」9 条。

**第二趟（M197–M199，补的是 §6 那处坐标翻转）**：`/tmp/xctstub/m197_199_driver.out`，12:32:14→12:33:52，
起跑前 SHA `CanvasManager.swift=c426a20571`，跑完对上：**M197 抓到（5 条红，32 秒）**、
**M198 抓到（1 条红，28 秒）**、**M199 与表里声明一致 —— 抓不到**（本机单屏，
`screens.first` 与 `NSScreen.main` 同一块屏、同一个值，副屏上才翻错，交装机清单第 10 步）。

**一条事故必须留字在这儿**：M166–M196 那 31 条的**表定义**在我补录 M197–M199 时被自己的脚本切掉了 ——
对 `rstrip()` 之后的字符串取 `rfind("]\n")`，命中的却是原文里 `PREFS = ["prefs"]` 那一行末尾，整张
`CASES` 被截（残file 留作 `/tmp/xctstub/mut_stroke_cases.py.bak-truncated-1205`）。执行证据没丢
（进度日志 + 31 份逐条日志，含每条红在哪一条断言、第几行）。表已按「逐条日志那句坏法 + 源码」重建，
34 条锚点自检坏 0 条。**两件事分开记**：11:51 那一轮证明「这些坏法当时确实被抓到」；重建后的表要
**再跑一趟 34 条**才能证明「这张表现在没写错」—— 这一趟还没跑（跑它要连续 34 次 `swift build`，
会和装机验收要测的「抬手响应」抢 CPU，排在用户实测之后）。跑完把新日志名补在这一段末尾。

四条值得留字：

1. **M196 结构性抓不到，而且没有任何用例能抓**：演的是 `main.swift:1077` 匹配时不看归因。
   `MacStrokeApp` 这个目标不链进桩件二进制（常驻 App 的 delegate 进不了测试进程），改 `main.swift`
   时三套用例连编译都没走过它。判定本身由 **M173** 在 RuleEngine 那头咬住（`ruleBundleID` 反了 →
   2 条红），接线这一手只有装机清单第 4 步能验。
2. **同一条坑从两头各钉一次**才算钉住：延迟取常量（M175 把 0.6 → 0.05）与延迟取错来源
   （M186 在 `execute` 侧写死 0.05）是两种坏法，各自只红一句；预算那一档同理（M176 改常量，
   `testSettleCoversMeasuredDeliveryLatency` 两头都断：`>= 0.5` 盖住实测最慢那档、`<= 0.25` 不许在
   HID 回调里干等）。
3. **默认值有两处，两处都要钉**：`StorageDefaults`（落盘侧，M188/M189）与
   `StrokeTargetSettings.defaults` / `init()`（模块兜底，M177）。后者单独钉那一条跨层契约用例
   `testRuleEngineFallbackDefaultsMatchStorageDefaults` 也在同一轮红 —— 「离线用例验的是另一套默认值」
   正是装机行为与绿条分家的入口。
4. **抓不到的东西要说破，不许靠加重复断言糊**：本轮把「关着也抓窗口表」（M174）做成了可抓，
   靠的是把条件做成模块属性；而「投出去的键落在 session 还是 HID 层」这类**落点**问题依旧只有装机
   能验（同上一轮 M155）。§10 那一步就是为它留的。

## 10. 装机清单（验的是「到底有没有跳对家」——离线只能证到判定，证不到落点）

前置：本轮的包**版本号是 3.2.2**（线上 3.2.1 的下一号，装机调试期间反复覆盖同一个号，不再往上加）。
版本号能当判据，但也要顺带核第三道哨兵：

```
plutil -extract CFBundleShortVersionString raw /Applications/MacStroke.app/Contents/Info.plist
grep -a -c "strokeTargetsCursorWindow" /Applications/MacStroke.app/Contents/MacOS/MacStroke
```

校验值：`3.2.2`、**≥1**（第二串实测落在多行上，`grep -a -c` 数的是行）。界面上还要看得见
偏好设置 → 右键增强 → 最底下那张「手势打到光标下的窗口」卡（在滚轮那一组下面）：**两颗开关，
第一颗默认关**，第二颗在第一颗关着时是灰的。

日志口径同前几轮（限定进程、带 `--info --debug`，不带会漏 Df 假成「0 次」）：

```
/usr/bin/log show --last 2m --info --debug --style compact --predicate 'process == "MacStroke"' \
  | grep -aE "\[StrokeTarget\]" | tail -20
```

1. **先证明「关着 = 老行为，且一分钱没多花」**：两颗开关都别碰（默认状态），IDE + 浏览器并排，
   光标压在浏览器上画一次原来的右键手势。校验值：**一条 `[StrokeTarget]` 都没有**（「功能没开」
   那档特意不写日志，免得把有用的行埋掉）；动作打进 IDE（前台那家）；抬手手感和 3.2.1 没有区别。
2. **开总开关、还焦保持开 = 主力判据**：拨开第一颗，同样并排摆，光标停在浏览器正文上画那条
   快捷键规则（⌘ 系）。校验值：日志出现 `归给光标下的窗口（抬手点 …；前台 …；匹配用 …）`（逐字取自
   `Reason.attributed` 的 rawValue，后面那段是 `main.swift:1068` 拼的）+ `已挪到 pid …（N ms）` +
   约 0.6 秒后 `还焦 已回`；**浏览器真的动了**（⌘N 开新标签页），IDE 没动。`N` 应该在 **1～94ms**
   这一档；若稳定读到 250ms（= 预算耗尽）说明「跳过去了」这句判据有水分，回报时带上这一列。
3. **打字那档要落进光标下那家的输入框**：规则换成「输入文本」，浏览器里点进搜索框再画手势。
   校验值：字落在浏览器那个框里，而不是 IDE。这一条验的是方案 B 被排除的那一半 —— 非活跃 App
   收键与 key window。
4. **匹配也用那一台（§2 那一手，M196 唯一能验它的地方）**：给浏览器单独配一条**只有浏览器有**的
   规则（比如同一个轨迹在 IDE 里配 ⌨S、在浏览器里配 ⌨T）。光标压在浏览器上画 → 出 **新标签页**；
   光标压在 IDE 上画同一条 → 出 **保存**。两个方向都要对，只对一个就是接线没吃归因。
5. **关掉「投完把焦点还回去」**：只拨第二颗。校验值：画完之后**前台就是浏览器**，接下来的打字全进
   浏览器；日志里 `已挪到` 有、`还焦` 一句**不出现**。这就是「画一次手势 = 点一下那扇窗」。
6. **中途自己切走 → 那一手让位**：还焦保持开，画完立刻用鼠标点第三家（比如访达）并在 0.6 秒内
   点进去。校验值：日志 `还焦 没回（… 前台已经换到 pid …，按闸不还）`，焦点留在访达。
   坏了的样子是「我明明点了访达，半秒后又被抢回 IDE」。
7. **负向对照四种，一种都不许多跳一次焦点**（判据都是「`已挪到` 这句不出现」）：
   - 动作是**按坐标点击**（`mouseClick`）：画在隔壁家上也不跳；
   - 动作是**复制文本**：粘贴板有内容，但前台没换；
   - 动作是**截图**：遮罩正常弹、能正常框选，**焦点不许被 0.6 秒后那一手抢走**（这是
     `screenshot.needsCursorAppFocus = false` 的全部理由，M180 咬住代码、这一步咬住手感）；
   - 光标压在**我们自己的窗**上（画布/气泡/偏好窗）：日志 `松手点上只有我们自己的窗`。
8. **黑名单那一格**：把浏览器加进过滤页黑名单（沿用现有那套黑白名单），光标压在浏览器上画。
   校验值：`那家被黑白名单过滤掉了，按老行为投前台`，动作仍旧打在 IDE。
9. **全屏与遮挡两种边角**：目标 App 全屏（覆盖整块屏）时画 → 判给那家；被别的窗完全挡住的那家
   光标压在**遮挡者**上 → 判给遮挡者而不是挡住它的那家（`CGWindowList` 从前到后第一个够格的）。
10. **多屏那一刀（§6 那个 y 翻转）**：有副屏就把浏览器拖到副屏上、上下各试一次。
    校验值：`归给光标下的窗口` 在副屏上半部与下半部都要出现；若只在某一条水平带里成功，
    就是坐标系翻错 —— 这条判据离线给不了（桩件里 `NSScreen` 不可信）。
11. **不匹配时不许有副作用**：画一条没配过的轨迹（且「不匹配吞点击」保持关）。
    校验值：焦点没跳过（`[StrokeTarget]` 里连 `已挪到` 都不该出现），右键仍旧正常回放。
12. **收尾**：把总开关拨回关，重开偏好设置确认还是关的；`defaults read` 那两把键应回到
    默认（或压根没写）。
    ```
    defaults read net.mtjo.MacStroke strokeTargetsCursorWindow 2>/dev/null || echo "没写过"
    defaults read net.mtjo.MacStroke strokeTargetRestoresFocus 2>/dev/null || echo "没写过"
    ```
    （域就是 App 的 bundleId，`Storage` 走 `UserDefaults.standard`；「重置为默认」会把两把键**写成默认值**，
    所以这里读到 `0` / `1` 也算对，读到「没写过」同样对 —— 关键是别停在 `1` / `0` 之外的值上。）

**这一期验不上 / 不承诺的**：

- 焦点**跳过去那一下看得见**（会闪一下对方窗口），这是方案 A 的固有代价；想完全无感只有走 B
  （直投 pid），而 B 的实测慢一截且逐家行为不一致。
- 目标 App 拒接无障碍写入（个别沙箱/系统组件）时会读到 `没跳过去`，这一发按老行为投给前台 ——
  不是「动作丢了」。
- 「跳过去之后 0.6 秒内自己又切走」那一手我们让位（第 6 步）；反过来，**0.6 秒内什么都不做**
  才会有还焦。这个数是实测 0.2～0.5 秒往上留的余量，不是「手感偏好」。
- 按坐标点击、复制文本、截图三类动作**不参与**（§4），界面上也不给它们铺勾选。
