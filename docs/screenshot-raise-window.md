# 截图吸附时把那一扇窗提到最前（3.2.5）

2026-11-05 用户要求：「现在的截图当智能吸附的时候添加一个功能将窗口提到最前，功能默认开」。
第一版做成「按下快捷键那一刻提一次」，用户实测后修正口径：

> 现在的结果不符合我的预期，现在只在按下快捷键的时候触发，我希望的是吸附到哪个窗口
> 哪个窗口就提到最前。

于是这一手改成**跟着吸附走**：遮罩里吸附框落到哪一扇被压住的窗，就把哪一扇提到最前，
再把整块屏重拍一帧换给遮罩 —— 选区里看到的、最后截出来的都是提完的样子。快捷键那一刻
那一次保留（进遮罩时指针下那扇已经被吸住，不该等用户先动一下鼠标）。

2026-11-06 用户验收后追加要求：「把功能设置默认关闭」。**默认值已翻成 `false`**
（提窗会切一下前台，是有外部可见副作用的一手）；功能本身不变，想要的人在偏好页打开。
下文凡是写「默认开」的地方，都以这一条为准。

## 一、口径

- **吸附到哪扇提哪扇**：悬停换到另一扇够格的窗时排一次提窗（120ms 去抖）。快速扫过去
  不会把桌面来回翻个遍；停住就走到。
- **只提被压住的**：同层、更靠前的够格窗与它相交时才动。自己就在最前时不提 ——
  提了只会白切一次前台，画面一模一样。
- **提完必须重拍**：遮罩铺的是冻结帧，不重拍画面不会跟着变 —— 看起来像提了，截出来
  照样只有露着的那半扇。重拍期间遮罩自己 `sharingType = .none`，暗底和高亮不进采集。
- **更高的层不提**：贴图、面板这类层级更高的窗压出来的那块，把普通窗提上来也压不过它。
  别家浮窗根本不进候选表；自家的浮窗（贴图 3）在候选表里，靠 `layer == target.layer` 挡掉。
- **不换用户的前台**：提窗只是工具性的。抓完帧立刻把 key 收回遮罩；整场结束仍按
  issue #78 的口径把焦点交还给按快捷键前那家应用，不留在被提上来的那家。
- **只提光标指向的那扇**：判定取「光标下第一个够格的窗」（与吸附共用 `isSnapCandidate`）。
  那扇窗之外的窗口一概不动。

## 二、实现

### 偏好

- `Sources/Storage/Storage.swift`
  - 新键 `screenshotRaiseWindowBeforeCapture`（原始串同名），默认 `false`（2026-11-06
    用户验收后要求默认关）；
  - 进 `registeredUserDefaultsValues()`，老用户没这个键时读到关。
- `Sources/Preferences/Preferences.swift`
  - `@Published screenshotRaiseWindowBeforeCapture`，`didSet` 写库；init 走「读不到用默认」，
    不往库里回写（与截图页其它开关同一套规矩）。
- `Sources/Screenshot/ScreenshotSettings.swift`
  - 快照加 `raiseWindowBeforeCapture`；`current()` 每次会话现读库。
- `Sources/Preferences/ScreenshotTabView.swift`
  - 「吸附」那行下面新增一行，右端 `TrailingSwitch`；吸附关掉时 `.disabled` 并画出灰态。
- 中英两张 `Localizable.strings`：`Screenshot raise window` / `… hint`。

### 判定（`Sources/Screenshot/ScreenshotWindowProbe.swift`）

- 记录加 `pid` 与 `windowNumber`：提别家窗要按 pid 找应用，提自家窗要按编号在
  `NSApplication.windows` 里认。
- 抽出 `isSnapCandidate(_:)`：采集性、alpha ≥ 0.99、层级门槛（别家 layer 0；自家 < 25）、
  ≥ 8×8。吸附与提窗共用同一批窗，不会出现「吸得到却提不到」。
- `SnapCandidate`（窗记录 + 视图矩形）与 `candidates(...)`：悬停要答「吸到的是哪一扇」，
  只给矩形答不出来。`candidateRects` 改为 `candidates.map(\.rect)`，两张表永远同长同序。
- `frontmostCandidate(at:in:)`：按光标取第一个够格的窗。
- `isAheadOfSameLayerCovers(_:in:)`：提窗「成没成」的判据 —— 目标前面不再有同层且与它
  相交的够格窗。别拿「光标下第一个够格的窗是不是它」当判据：`raiseTarget` 挑中它的
  那一刻这句就成立（压着它的那扇并不含光标点），提窗完全失败也照样成立，是自证的假绿
  （2026-11-05 装机实测踩到，见 §四 第 3 条）。
- `raiseTarget(windows:point:)`：找到光标下最前的够格窗，再看它前面有没有**同层**够格窗
  与它相交；有才返回目标。
- `snapshot()` 由 private 改为模块内可见（提窗要现取一张表）。

### 提窗（`Sources/Screenshot/ScreenshotWindowRaiser.swift`，新建）

- 别家窗：`AXUIElementCreateApplication(pid)` → 按 `AXPosition`/`AXSize` 与
  `kCGWindowBounds` 的矩形配对（都是主屏左上原点，容差 4pt）→ `AXRaiseAction`，
  再写应用元素的 `kAXFrontmost`。只 `AXRaise` 改不了前台（FocusMover 的实测结论），
  两条都做：前者管同一 App 内的兄弟窗，后者把整家提到前台。
- 自家窗：`NSApplication.activate` + 按 `windowNumber` 找到实例 `makeKeyAndOrderFront`。
- 单次 AX 调用超时 150ms，整体等待上限 150ms，5ms 一轮；判据取「目标前面不再有同层
  相交的够格窗」，不读 `NSWorkspace.frontmostApplication` 或 `isActive`（同一瞬还报旧值）。
- 判据绿了之后再等 50ms（`compositorSettle`，60Hz 下 3 帧）才放行抓帧。窗口服务的
  前后顺序在 `CGWindowList` 里是当场就变的，但屏幕上呈现的那一帧要等下一次合成；
  `CGDisplayCreateImage` 抓的是呈现出来的帧。2026-11-05 17:45 装机实测：新判据报
  「已到最前」，冻结画面里却还是原来那半扇 —— 顺序落了、合成没跟上。离线桩件里没有
  窗口服务与显示器，这一段只能靠装机清单（§五）。
- 超时/失败不抛不回滚：冻结帧拍原样，等于这一手没发生。没有辅助功能权限时先问
  `AXIsProcessTrusted()` 并直接跳过（不再白等 150ms），日志写明缺权限；AXRaise /
  AXFrontmost 的错误码也进日志，免得「没效果」只能靠猜。
- 控制器在判定返回 nil、而光标下确有候选窗时记一行「本来就在最前，跳过」，把
  「开关开了却没反应」最常见的归因留在日志里。

### 接线（`Sources/Screenshot/ScreenshotController.swift`）

进遮罩那一段的顺序固定为：权限门 → 取屏 → 读设置 → **提窗** → 抓帧 → 取候选窗表：

```
captureFocusOwner()
guard ensureScreenRecordingPermission() else { return }
guard let screen = ScreenshotGrabber.targetScreen() else { return }
let settings = ScreenshotSettings.current()
raiseWindowUnderPointerIfNeeded(settings: settings)   // 快捷键那一刻那一次
guard let shot = ScreenshotGrabber.grab(screen: screen) else { return }
applySnapCandidates(to: view, screen: screen, settings: settings)
```

- 设置快照提前到抓帧之前，吸附开关与提窗开关用同一份，不会拍到一半设置变了。
- 候选窗表在提窗之后现取：顺序变了，不能沿用提窗前那张。
- 鼠标换算：AppKit 主屏左下原点 → 窗口服务主屏左上原点，`y = 主屏高 - y`。
- 两道偏好闸收成静态 `shouldRaiseOnSnap(_:)`，快捷键那条与悬停那条共用；
  `raiseWindowUnderPointer(settings:pointer:windows:raise:)` 保留注入式提窗，离线能钉住
  「关了就不许碰」。

### 悬停吸附即提窗

- `ScreenshotSelectionView.onSnapWindow`：吸附框换到**另一扇真窗**时回调一次。落到桌面
  （整屏兜底）不报 —— 那不是能提的窗。同一扇里继续移动也不报，否则去抖形同虚设。
- `ScreenshotController.scheduleRaiseForSnappedWindow`：`snapRaiseDelay = 0.12` 秒去抖。
  快速扫过一排窗时由下一次换窗撤掉上一次；停住就走到。
- `raiseSnappedWindow`（顺序不能换）：
  1. 复核光标 120ms 后是否还在这扇里（中途离开就算了）；
  2. 现取窗口表，按编号找到它；已经不在最前（`isAheadOfSameLayerCovers`）就什么都不做；
  3. `ScreenshotWindowRaiser.raise`（内部已含顺序确认 + `compositorSettle`）；
  4. **先** `ScreenshotGrabber.grab` —— 这一刻目标 App 才是激活态（标题栏不灰）；
  5. **再** `restoreOverlayFocus` 把 key 收回遮罩。成功、失败、抓帧失败三档都要收：
     自家窗那条走的是 `makeKeyAndOrderFront`，验没验成都已经换了 key，不收 Esc 就落到
     刚被提的 App 上；
  6. `view.replaceCapture` 把底帧、候选矩形、窗记录三张一起换掉（放大镜自己攥着一张帧，
     同一步里 `replaceShot`）。
- `ScreenshotOverlayWindow.sharingType = .none`：重拍时遮罩自己还在屏上，不排除的话
  暗底与吸附高亮会被拍进底图。与录屏描边/胶囊同一条规矩。
- `snapRaiseWork` 在 `close()` 里取消：会话已经收了，别再为一场不存在的截图翻前台。

## 三、判据

### `Tests/ScreenshotTests/ScreenshotRaiseWindowTests.swift`

| 用例 | 咬住什么 |
|---|---|
| `testCoveredWindowIsRaisedExactlyOnce` | 被同层压住的那扇要提，且只提一次 |
| `testNothingHappensWhenSnappingIsOff` | 关吸附时一下都不碰（连目标都不找） |
| `testNothingHappensWhenTheRaisePreferenceIsOff` | 关提窗时一下都不碰（不许顺手切前台） |
| `testNothingIsRaisedWhenTheWindowIsAlreadyInFront` | 自己就在最前时不动 |
| `testPointerConversionFlipsAroundTheMainScreenTop` | 主屏与主屏上方副屏的 y 换算 |

### `Tests/ScreenshotTests/ScreenshotSnapRaiseTests.swift`（本轮新增，8 条）

| 用例 | 咬住什么 |
|---|---|
| `testCandidatesKeepEachRecordPairedWithItsRect` | 窗记录与矩形一一对齐、同长同序；`candidateRects` 与配对的矩形逐项相同 |
| `testHoverReportsTheSnappedWindowOnlyWhenItChanges` | 吸到哪扇报哪扇；同一扇里继续移动不再报；换扇才报 |
| `testHoverOnDesktopDoesNotReportAWindow` | 桌面那条整屏兜底不报 —— 那不是能提的窗 |
| `testHoverIgnoresRowsWithoutARecord` | 记录表短一截时不越界、也不报到别的那扇上 |
| `testReplaceCaptureSwapsBackdropAndCandidates` | 重拍换帧：底图、候选矩形、窗记录一起换 |
| `testReplaceCaptureAlsoMovesTheMagnifierToTheNewFrame` | 放大镜跟着换帧（色值从新帧上取），不是停在提窗前那张 |
| `testOverlayIsExcludedFromScreenCapture` | 遮罩 `sharingType == .none`、层级仍在 shielding 档 |
| `testRaiseGateRequiresBothPreferences` | 悬停与快捷键共用同一道偏好闸（四种组合） |

### `Tests/ScreenshotTests/ScreenshotWindowProbeTests.swift`

- `testRaiseTargetOnlyWhenTheWindowIsCoveredByTheSameLayer`：被压住要提 / 在最前不提。
- `testRaiseTargetIgnoresCoverFromAHigherLayer`：别家浮窗不进候选表，压不出来目标。
- `testRaiseTargetIgnoresCoverFromAHigherOwnLayer`：自家贴图（layer 3）压着偏好设置（layer 0）——
  同层判据的真摆法；别家浮窗那条量不到它。
- `testRaiseTargetSkipsWindowsMissingFromTheFrame`：`.none` 浮窗既不当目标，也不算「被压住」；
  「到没到最前」那一读也要跳过它。
- `testRaiseTargetIncludesCoveredOwnWindows`：自家偏好窗被别家普通窗压住时按编号置前。
- `testRaiseTargetIsNilWithoutAnEligibleWindowUnderThePointer`：桌面、程序坞、空表都不动。
- `testFrontmostCandidateOnlyAnswersForThePoint`：按光标取，不拿表里第一扇。
- `testAheadOfSameLayerCoversDistinguishesAFailedRaise`：同层窗还挡在前面时为 false、
  提到最前后 true、目标已不在表里也为 false —— 成功判据必须能分辨「提窗没成」。
- `testAheadOfSameLayerCoversIgnoresHigherLayers`：更高层浮窗挡着不算没提成，别把等待拖到超时。

### 偏好与默认值

- `Tests/ScreenshotTests/ScreenshotSettingsTests.swift`：新装读到 `false`，库里不写键；
  库里写 `true` 后 `current()` 读回 `true`（默认关，只能靠打开这一档来证明确实读了库）。
- `Tests/WindowManagerTests/ScreenshotPreferencesTests.swift`：默认关；打开后落库可读回；
  关吸附、开提窗时两格互不串写。

### 页面像素取证 `Tests/WindowManagerTests/ScreenshotRaiseRowTests.swift`

离屏挂整个截图页（720×1600），导出 `/tmp/macstroke-raise-row-check/`：

- `raise-on.png` / `raise-off.png`：两张的差异包围盒必须 > 30 像素、落在行右端 3/5 之外、
  高度 ≤ 60 行（是开关那一小枚，不是整页文字或布局被顶动）；
- `snap-on.png` / `snap-off.png`：吸附关掉后，提窗开关那一带必须变（开关转灰）。
  实测 `snap-off.png` 里旋钮仍在右侧（值还是开），整枚被画淡 —— 正是 `.disabled` 该有的样子。

## 四、反向变异

表：`tools/mutation/screenshot-raise.json`（22 条；RS18–RS22 是本轮悬停链路补的）。
跑法：`python3 tools/mutation/mutate.py tools/mutation/screenshot-raise.json`。

| 编号 | 坏法 | 结果 |
|---|---|---|
| RS1 | 吸附关掉时仍去提窗 | KILLED |
| RS2 | 提窗偏好关掉时仍去提 | KILLED |
| RS3 | 够格条件不看 `isCapturable` | KILLED |
| RS4 | 没被压住也提窗 | KILLED |
| RS5 | 压住判定不看同层 | KILLED（补自家浮窗用例后） |
| RS6 | 验「到没到最前」不看光标 | KILLED |
| RS7 | 默认值翻成开 | KILLED |
| RS8 | 会话现读设置无视库里的关 | KILLED |
| RS9 | 吸附关掉时提窗开关没画成禁用 | KILLED |
| RS10 | 新增行绑到吸附的开关 | KILLED（补 guard 后） |
| RS11 | 关提窗写进吸附那一格 | KILLED |
| RS12 | 启动从吸附那一格读提窗 | KILLED |
| RS13 | 提窗挪到抓帧之后 | SURVIVED（离线无 GUI，留装机清单） |
| RS14 | 只 AXRaise 不写 AXFrontmost | SURVIVED（同上） |
| RS15 | 提完不等窗口服务落位 | SURVIVED（同上） |
| RS16 | 成功判据不比前后的窗（回到自证假绿） | KILLED（补成功后重跑） |
| RS17 | 成功判据不看同层 | KILLED |
| RS18 | 每动一下就报一次吸附窗（120ms 去抖形同虚设） | KILLED |
| RS19 | 悬停回调报到别的窗上（吸到右边却报左边） | KILLED |
| RS20 | 重拍之后候选表不换（还圈着提窗前的矩形） | KILLED |
| RS21 | 重拍之后放大镜还用旧帧（取景/色值与底图错开） | KILLED |
| RS22 | 遮罩自己进了采集（重拍把暗底和高亮拍进底图） | KILLED |

三处判据洞是变异趟与装机实测自己揪出来的，已补：

1. **RS5 第一次跑成 SURVIVED**：原「更高层浮窗」用例用的是别家 layer 3 的窗，
   它本来就不进候选表 —— 同层这一半判据在它身上量不出来，等于没测。补了
   `testRaiseTargetIgnoresCoverFromAHigherOwnLayer`（自家贴图 3 压自家偏好 0）。
2. **RS10 第一次跑成 TRAP**：第一个断言失败后代码继续拼 `band.minY...band.maxY`，
   空差异的 `maxY` 是 -1，区间构造直接 trap，整趟报「用例 0」。加了 `guard … else { XCTFail; return }`。
   崩溃不是绿，这只用例原先会把「该红」伪装成「进程崩了」。
3. **装机实测揪出成功判据是自证的**（2026-11-05 14:26 那一条日志）：`waitUntilFront`
   原来问「光标下第一个够格的窗是不是目标」—— `raiseTarget` 挑中目标的那一刻这句就成立
   （压着它的那扇并不含光标点），AX 完全没动也照样在第一次轮询就返回真，日志写「已到最前」。
   改成 `isAheadOfSameLayerCovers`（目标前面不再有同层相交的窗）才有分辨力；RS16 把判据
   换回「只看编号在不在表里」，RS17 去掉同层条件，两条都被补充的用例抓住。
   同时把 `AXIsProcessTrusted()` 与 AXRaise/AXFrontmost 错误码写进日志 —— 这一轮「开关开了
   却没反应」就只能落在两档上：判据说没被压住（含光标停在上面的遮盖窗上），或 AX 没执行成。

2026-11-05 17:58 最后一趟（代码含 `compositorSettle`）：14 条该抓的全 KILLED，RS13/RS14/RS15
按预期 SURVIVED。RS14 的锚点随错误码日志改过一行（现在是 `let front = …`），第一次自检报
SKIP —— **锚点未命中不等于通过**；更新锚点后单跑，确认变异能编译、用例仍全绿（SURVIVED）。

2026-11-06 09:38 悬停链路落地后的整趟（22 条，证据 `.build/mutation/20261106-093803`）：
**预期该抓的 19 条漏 0 条**，编译红 / TRAP / 无记账 / 锚点 SKIP 均无，还原核对全部文件 SHA
回到起跑前；RS13–RS15 三条照旧按设计 SURVIVED（离线无 GUI，见第五节）。

2026-11-06 10:09 默认值翻成关之后，只重跑了受它影响、以及两格串键的五条
（`--only RS7,RS8,RS10,RS11,RS12`，证据 `.build/mutation/20261106-100936`）：**5 条全 KILLED**，
SHA 还原。RS7 的锚点随默认值一起改成 `= false`（变异成 `true`）。默认关之后，
「关掉提窗读回关」不再有分辨力，两条偏好用例改成**打开提窗**再读回；串键那条改成
「关吸附 + 开提窗」，反着设才咬得住 RS11/RS12。

RS18–RS22 分别打在悬停回调的「只在换窗时报」、记录与矩形的配对、重拍时底帧/候选表/放大镜
三处同步、以及遮罩 `sharingType = .none` 上。RS18 若换了 `if next != hover`，用例里「同一扇
里继续移动不再报」立刻红 —— 这条正是 120ms 去抖有没有意义的前提；RS21 若删掉
`magnifierView?.replaceShot(frame)`，放大镜色值停在旧帧（用例比对重拍前后的 `colorText`）。

方法学补记：**不要 kill 变异进程**。`mutate.py` 的还原在 `finally` 里，SIGTERM 会跳过它，
源码会停在某一处变异上（本轮就被打断过一次，`shouldRaiseOnSnap` 留在 `settings.snapToWindows`，
`.build` 里的对象也跟着脏）。中途停掉之后必须 `git diff` 核对文件、必要时手工还原，
单跑一遍受影响用例确认全绿再继续。

## 五、取证边界

- 桩件里没有 GUI 会话：真 AX 提窗、窗口服务前后顺序、自家窗激活、以及
  「提窗相对抓帧的次序」只能靠装机清单。RS13–RS15 三条 `expect=false` 就是记这个账。
- 悬停那条真链路整条都在离线判据之外：`pointerMoved` 之后的 120ms 去抖、去抖到点时
  重新核对光标、`raiseSnappedWindow` 里的抓帧与 key 回收、重拍时 `sharingType = .none`
  是否真把遮罩排除掉 —— 用例只钉住「报哪一扇、换没换帧」这两端，中间靠装机实测。
- 顺序确认之后再等的那 50ms（`compositorSettle`）也无法离线取证：桩件里没有显示器、
  没有合成器。RS15 只覆盖「等不等窗口服务的顺序」，够不到「等不等屏幕上那一帧」；
  这一段靠 2026-11-05 17:45 的装机实测（判据绿、冻结画面没变）记在案。
- 悬停重拍是**整块屏**重抓。光标停在被提的窗里时不会把自己的鼠标指针拍进去
  （`CGDisplayCreateImage` 不含指针），但重拍那一瞬屏幕上别的变化（视频帧、时钟秒数）
  会跟底图其余部分一致地更新，选区里不会出现新旧两块拼在一起。
- 「只提被压住的」只按**候选表**里同层的窗算。别家浮窗不进候选表，所以：
  它压住目标时这一手不会为了它去提窗；如果同时还压着同层的普通窗，照样会提，
  但提完浮窗仍在上 —— 冻结帧里那一块还是浮窗的像素。这一条在文案里没写成承诺。
- 没有辅助功能权限时整手静默跳过。不会弹框、不会失败，截图行为与旧版一致。

## 六、全量回归

2026-11-06 悬停链路落地后的整趟（变异表跑完、源码 SHA 核对还原之后）：
`pkill -x MacStroke; python3 tools/xctstub/xct.py regress`。合计 **1256 用例 · 红 0 · 跳过 1（11 套）**：

| 套件 | 用例 | 红 |
|---|---|---|
| GestureEngineTests | 27 | 0 |
| EventCaptureTests | 73 | 0 |
| RuleEngineTests | 138 | 0 |
| StorageTests | 91 | 0 |
| AppleScriptRunnerTests | 36 | 0 |
| RightClickMenuTests | 7 | 0 |
| WindowManagerTests | 258 | 0 |
| ScreenshotTests | 306 | 0 |
| SelectionPopupTests | 181 | 0 |
| ProximityLockTests | 79 | 0 |
| RemoteControlTests | 60 | 0（跳过 1 条） |

Screenshot 套件从 298 涨到 306（+8，本轮新增 `ScreenshotSnapRaiseTests`）。

两处与代码无关的观察，记下来免得下次误判：

- 单独先跑 ScreenshotTests 那一趟，`testScrollLoopStitchesEveryScrolledScreenAndStopsAtTheBottom`
  红过一次（定时器驱动的循环在整机负载下没在 `loopBudget` 内收场，滚了 4 次、读数列全对）。
  用 `--only` 单跑 3 秒绿；随后全量回归里也绿。这是长截图循环用例的**负载敏感**，不是提窗改出来的。
- 上一趟（2026-11-05）红 3 的 `RemoteControlServerE2ETests` 三条，本趟红 0：固定端口
  stop/start 竞态与 `kCGSSessionSecureInputPID` 环境都按偶发处理，本轮没动 `Sources/RemoteControl/`。

2026-11-06 10:15 默认值翻成关之后的整趟（同一个命令）：**1256 用例 · 红 2 · 跳过 1（11 套）**，
ScreenshotTests 306 / 0、WindowManagerTests 258 / 0。红的两条仍在 `RemoteControlServerE2ETests`，
且**每次跑换一对用例**（`testWarpMovesTheCursorToAnAbsolutePoint` / `testScrollPostsAWheelEvent…` /
`testTwoCommandsInOneWriteAreBothHandled` / `testMirrorWithoutPermission…` / `testPingIsAcked`），
报错是固定端口 48849 的「空回执」或「连接被拒」；把红过的用例各自 `--only` 单跑，**全绿**。
同一套连跑三次分别红 2、2、3 条 —— 是端口 + 启动时序的已知竞态，与默认值改动无关
（本轮没碰 `Sources/RemoteControl/`，且翻默认值之前那趟这套红 0）。

## 七、装机验收清单（3.2.5，悬停即提窗）

装的是 `/Applications/MacStroke.app`，`CFBundleShortVersionString` = `3.2.5`。逐条做，任一条不对就停在那条：

1. **确认版本**：点菜单栏 MacStroke 图标 →「关于」应显示 3.2.5。
2. **打开两格**：偏好设置 →「截图/录屏」→「智能吸附」保持开；「定格前提窗」**默认是关的**（2026-11-06 起），把它打开。打开后下面第 5–10 步才成立。
3. **准备覆盖场景**：开两个不同 App 的窗，让 A 把 B 盖住一部分（例如浏览器在前面，备忘录在后面），B 要露出可见的一块。
4. **进截图**：光标停在桌面空白处，按 ⌘⇧A。整块屏暗下来，光标下的窗有高亮框。
5. **悬停到被盖的 B**：把光标移到 B 露出来的那块上，停住约 0.2 秒。预期：B 被提到最前，暗底跟着**重拍**——B 原来的位置不再是被盖住的旧像素，高亮框贴到 B 现在的整扇窗上。
6. **换窗只提那一扇**：光标移到 A 上，A 被提起；再移回 B，B 再被提起。全程只有光标指到的那一扇动，别的窗不闪、不跳。
7. **桌面不触发**：光标移到没有窗的桌面区域，高亮兜整屏，但没有任何窗被提起。
8. **重拍后哪张图都新**：开着放大镜时，提窗后移动光标，放大镜里的取景和右下角色值应与新画面一致（不是提窗前那一张）。
9. **选出来的是提后的画面**：拖选刚被提起的 B 并回车（复制），粘贴出来的图里 B 是完整的，不带 A 的遮挡。
10. **键盘不跑丢**：提窗之后直接按 Esc 取消、或拖选后按回车，都不应落到被提的那个 App 里（遮罩始终拿着 key）。
11. **关掉提窗**：偏好里关「定格前提窗」→ 重进截图，悬停换窗只换高亮，画面不动、前台不换。
12. **关掉吸附**：偏好里关「智能吸附」→ 重进截图，没有高亮框，提窗开关那一格变成不可点。
13. **没权限的降级**：若系统「辅助功能」里没勾 MacStroke，以上提窗整手静默跳过，截图仍能正常截/存（与旧版一样）。
14. **日志核对（可选）**：控制台过滤 `MacStroke`，提窗成功应有 `[Screenshot] 吸附提窗：pid … 窗 … 已到最前`；没提起来是 `没提起来`；光标下的窗本来就在最前则不写「已到最前」。

已知边界：只提**同层**且被压住的普通窗；别家的浮窗（如系统面板）不在候选表里，提完它仍可能压在上面；`compositorSettle` 等 50ms 是给合成器落位用的，提窗后立刻松手拖选偶尔会拍到半帧旧内容，再动一下就好。
