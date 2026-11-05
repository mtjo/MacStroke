# issue #78「使用建议」：这一版（3.2.4）做了什么、验到什么程度

写于 2026-11-02。issue #78 一共五条建议，本轮按 mtjo 定的范围做前三条（1、2、3 一起进一个版本），
4、5 只出方案不动手。台账口径与 #75 那份一致：每条结论都标它是**实测**、**读码**还是**推断**；
装机实测的判据一律取外部观测，不取自被测对象自己声明的状态。

## 一、五条建议的处置

| # | 用户原话（摘要） | 本轮 |
| --- | --- | --- |
| 1 | 截图完成后会把主程序切到前台，希望还在后台 | **做了**：遮罩收掉/存盘面板关掉时把焦点交还给按快捷键前那家 |
| 2 | 滚轮也能像普通手势一样配规则，统一配置处、按应用过滤、能执行 AppleScript | **做了**：规则新增「瞬时手势」这一档（按住起手键 + 上滚 / 下滚）；「右键增强」页原来那两档整并进规则表，升级时自动迁移 |
| 3 | 部分全局快捷键录不到，希望能手填；`volume_decrement` 这类键能不能也用 | **屏幕键盘做了**（双击弹出，手填降为兜底）；**音量做了动作档**（`+1 档` / `−1 档`）；**音量键作为触发条件没做**，见 §8 |
| 4 | 每条手势单独选起手键 | 不做，待方案（§8） |
| 5 | 鼠标反向滚动 / 平滑滚动 | 不做，待方案（§8） |

另外两条不在 #78 那五项里，是 mtjo 这轮实测时撞出来的，一起进了 3.2.4（细节与判据见 §十）：
截图保存那条提示气泡带完整文件名时**字顶出黑框**；从别的 App 里双击快捷键格那一下（窗口还不是
键窗）**把现有快捷键默默重写了一遍**。

这六条改动全默认等于原版行为：不配滚轮规则、不勾音量档、不双击开键盘、不触发截图时，链路上一个
新监听都不挂，识别耗时与 3.2.3 一致。

## 二、第 1 条：截图后把焦点交还原来的那家

**读码**成因：`ScreenshotController.start(mode:)` 里那句 `NSApp.activate(ignoringOtherApps:)`
（遮罩要吃到键盘，必须先把 App 激活）把主程序拉到前台；关掉遮罩后没有人把它放回去。
存盘面板那一路还有一次 `NSApp.activate`。

**落法**（`Sources/Screenshot/ScreenshotController.swift`）：

- `captureFocusOwner()` 记账「按下快捷键那一刻的前台 pid」，**排在 `NSApp.activate` 与权限门
  之前** —— 激活一按，前台就读到的是我们自己，该还给谁就再也问不出来（变异 SF1 咬的就是这个次序）。
- 三处交还：`close()`（正常收遮罩）、权限弹窗那一路（这一场压根没铺遮罩，用户按的那一下不该留痕迹）、
  存盘面板的 `defer`（存成功、写失败、取消三条路都要走）。
- 两道闸：记账为 0（读不到前台 / 前台本来就是我们）不交还；交还时前台已经不是我们（用户自己切走了）
  也不交还 —— 硬拉回去比原缺陷更烦人。
- 接缝：`ScreenshotController.frontmostPIDReader` / `focusRestorer` 两枚 static 闭包 +
  `focusOwnerBeforeOverlay`，都留成模块内可见。**为什么必须走接缝**：桩件进程没有 GUI 会话，
  `NSWorkspace.frontmostApplication` 在那儿读不到有意义的答案，判据只能从接缝进。
  默认取值与改动前的读法一字不差。

用例：`Tests/ScreenshotTests/ScreenshotFocusReturnTests.swift` 8 条（记账、两种不记、三种交还分支、
逐场重算、两次 close 幂等）。

## 三、第 2 条：滚轮也能配规则（瞬时手势）

### 3.1 数据形状

- `Sources/GestureEngine/InstantGesture.swift`：`wheelUp` / `wheelDown` / `middleClick` / `backClick` /
  `forwardClick` 五档。放 GestureEngine 这层是因为捕获层要按方向点名它、规则层要把它存进
  `rules.json`，放任何上层都会让下层反过来依赖上层。中键 = CG 按键 2、后退 = 3、前进 = 4；
  滚轮两档没有按键编号，`isWheel` 只对它们为真。
- `Rule.instantGesture`（`Sources/RuleEngine/Rule.swift:227`）：非 nil 时这条规则靠瞬时手势触发，
  `template` 里的点一律不参与轨迹匹配；nil = 原版的轨迹规则，与旧 `rules.json` 同义。
- 持久化键 `instant_gesture`，**只有瞬时规则才写这一格**（`if let instantGesture` 包着）：
  轨迹规则（含原版预置那 15 条）导出的 JSON 与 3.2.3 逐字节相同。变异 R2 咬「所有规则都写」——
  那种坏法界面上没有任何征兆，只有拿旧版导入导出比对才看得见。
- 读回来：缺键 → nil；认不出的取值（手改文件、将来新档）→ **也当 nil**，不让它炸掉整份规则文件
  （R3/R4 两条判据）。判空的原则与 issue #76 那轮一致：一条规则退化成轨迹规则，远比连别人的手势
  一起没轻微。

### 3.2 匹配

`RuleEngine.match(instant:bundleID:)`（`Rule.swift:573`）与轨迹匹配差两处，其余共用：

- 没有分数可比 → 按**列表顺序取第一条**（新规则插在顶上，所以「后配的赢」，与原版一致）；R8 咬 first⇄last。
- 门槛仍是同一条 `BlackWhiteFilter.shouldHookMouseEventForApp` + 同一条按 App 过滤（`matchesFilter`
  提成 static 供两边共用）。**在过滤页把某个软件拉黑，它的滚轮规则跟轨迹规则一起失效**，
  不会出现「黑名单只管一半」。
- 轨迹匹配的两处 `if rule.instantGesture != nil { continue }`（`match(stroke:)` 与
  `match(stroke:bundleID:)`）：空模板一旦参与打分就是 R9/R10 那两条坏法，见 §5.3。
- `RuleStore.hasWheelInstantRule`（`RuleStore.swift:145`）只看「有没有启用的**滚轮**规则」，不看黑白名单 ——
  名单留给真正匹配时判，这里只回答「这段窗口要不要花一次 tap Enable」。中键/侧键走主 tap，
  不需要为滚轮那条二级 tap 上膛，所以不计入；只有中键规则的库不该把滚轮监听叫醒（R11 咬这一格）。
- `RuleStore.instantGestureConflicting(withTriggerButton:)`：同一颗鼠标键既是起手键、又是启用中的
  瞬时规则时返回那一档；起手键优先（§3.6），偏好页据此给冲突提示。停用的规则不算（E5）。

### 3.3 界面

- 「绘制手势！」面板底部一栏「瞬时手势（不用画）」：五格（上滚 / 下滚 / 中键 / 后退 / 前进）+
  标题 + 两行说明，网格底边从 46 抬到 `46 + instantBandHeight`（`PresetGesturePickerPanel`）。
  `Choice` 从 `String` 变成 `(name, stroke, instant)`，选了瞬时档时 `stroke` 是 nil。
- `GestureRecordFlow.applyInstantGesture`：写档位、**清掉旧轨迹点**（一条规则只留一个手势来源，
  留着的话哪天 `instant_gesture` 被手工删掉，那条早就没人认的轨迹会静默复活 —— P3 咬这一手）、
  其余字段原样搬（filter / action / note / 启用态，P1、P2 各咬一格），最后发
  `macStrokeRuleStoreDidChange`（P5：不发就库里改了、屏幕上还是老样子）。
- 规则页那一格换成 `InstantGestureThumbView`（`WheelGestureGlyph` 自绘胶囊 + 一行读法）：
  滚轮是竖直箭头，中键是胶囊中央一枚实心药丸，后退/前进是左右水平箭头；
  **双击**才打开面板，单击留给选行（B5、G1–G4、G9–G11 咬方向、形状与点击口径）。
  读法用 10pt —— 英文 "Forward Button" 在 84pt 格里 11pt 会被截尾。
- 行签名 `currentSignature` 加算 `instantGesture`（B2：少算这一格，库里换了档表格不重建）。
- 选了与起手键相同的中键/侧键档时：面板照常存规则，同时弹一条系统通知
  （`GestureRecordFlow.warnIfConflicting`）；「常规 → 手势起始按键」下面还会常驻一行橙色提示，
  读的是 `RuleStore.instantGestureConflicting(withTriggerButton:)`。两处文案
  `Gesture Trigger Conflicts With Instant Rule` 两表都有（含在文案表用例里）。

3.2.4 收尾时按 mtjo 的决定把「右键增强」页的滚轮段**整段删掉**：方向只在规则页配，页面上
只留 Finder 卡片与「手势打到光标下的窗口」。`WheelGestureActionKind` 的原始值与两条方向文案
仍保留 —— 前者是旧 plist 的判读依据，后者由手势选择面板与迁移出来的规则名共用。

### 3.4 归属与上膛（App 层）

- 滚轮那一格算给**按下起始键那一刻**的前台应用：`CanvasManager.gestureBundleID` 在
  `handleTriggerMouseDown` 里赋值（`CanvasManager.swift:333`），抬手那一下仍现读（issue #22
  的归属判定不在本轮范围）。新增 `frontBundleReader` 接缝只为把这一手钉住（W1–W3）。
- 上膛条件只剩一条：`ruleStore.hasWheelInstantRule`（`main.swift:189`，只看「有没有启用的滚轮规则」）。
  3.2.4 起没有第二套入口了 —— 一条滚轮规则都没有时这一层连第二条 tap 都不挂，滚轮原样
  交给前台应用，回到原版行为。规则是每次按下起始键时现查的，偏好里加/删规则下一次按下就生效。
  中键/侧键走主 tap（`otherMouse*` 本来就在监听掩码里），不需要这条二级 tap（R11/E1）。
- 中键/侧键命中后执行 `fireInstantRule`，动作与提示共用 `makeActionExecutor()` /
  `showGestureNote(for:)`；命中时 down/moved/up 三相位一起吞（`instantClickButton`），
  否则前台应用会收到一个没有 down 的 up（E3/E4）。没命中就整击放行 —— 中键照样开链接、
  侧键照样后退。
- 与起手键同一套闸门：停用、录制起手键期间挂起、「画手势」录制态、修饰键让位、黑白名单/
  按应用过滤不通过，都原样放行（E8–E10）。
- 旧页面那两档由启动段一次性迁移（§3.5），之后旧键不再参与匹配。

### 3.5 旧设置一次性迁移

`RuleStore.importLegacyWheelGesturesIfNeeded`（`Sources/RuleEngine/LegacyWheelGestureImport.swift`）：

- **触发判据只认持久域**：`defaults.persistentDomain(forName:)` 里 `wheelGestureEnabled == true`
  才迁。`object(forKey:)` 会读到注册域 —— 全新安装也会凭空多两条规则（N1 咬的就是这一手；
  与 issue #76 黑名单幻影迁移同一条教训）。五个旧键同时从 `registerUserDefaultsDefaults()` 摘掉。
- **先关闸再干活**：读到 true 后立刻写回 false，之后就算一条规则都没生成也不会再猜第二遍
  （N2：不关闸 → 每次启动重复迁移）。
- **迁成什么**：上一个/下一个标签页 → ⌘⇧[ / ⌘⇧]；音量 ±1 档 → `.volumeUp` / `.volumeDown`；
  自定义快捷键走调用方注入的 `ShortcutMonitor.parseShortcut`。规则 `filter = "*"`、启用、
  空模板，名字取「上滚 / 下滚」（重名加序号，N3–N7 各咬方向、缺省档位、启用态、filter 与去重）。
- **不迁什么**：「无」与解析不出来的自定义键不生成规则；同一方向规则表里已有瞬时规则（用户
  后来手配过）也跳过，不跟新版手配的那条撞车。

装机实测（这台机器 3.2.3 的旧开关在升级前就是开着的）：3.2.4 第一次启动的日志打出
`把旧滚轮设置迁移成 2 条规则：上滚, 下滚`，`rules.json` 顶上两条分别是
`instant_gesture=wheelUp / shortcut 33 / flags 1179648` 与 `wheelDown / 30 / 1179648`，
`filter=*`；`defaults read net.mtjo.MacStroke wheelGestureEnabled` 已是 `0`。第二次启动不再新增。

### 3.6 起手键优先与冲突提醒

同一颗鼠标键可以既被选作起手键、又在某条规则里配成瞬时档。两者的语义打架：按下它到底
是「开始画一条手势」，还是「直接执行那条规则」？

- **运行时起手键优先**：`CanvasManager` 在 `.down` 分发时先问 `isTriggerAllowed`，命中就进
  「画一条」那条路，瞬时回调一次都不叫（E2 咬这个次序 —— 反过来先判瞬时，画手势那一路被抢掉）。
  滚轮两档没有按键编号，永不与起手键冲突。
- **配置时提醒**：用户从面板里选了与起手键同编号的档（例如起手键已是中键，又给一条规则选中键），
  `applyInstantGesture` 仍把规则存下来（他可能正要回去换起手键），但立刻弹一条系统通知；
  常规页起手键那一行下面也常驻一条橙色提示（E6：不提醒 = 规则配了却按不出来，且毫无解释）。
  不冲突的档必须安静（E7：每选一档都提醒等于把提醒关掉）。
- 判定本身只看**启用中**的瞬时规则（E5：停用那条不该再阻止/提示）。

用例：`InstantGestureRuleTests` 20、`WheelRuleGestureFlowTests` 17、`WheelRuleGestureGlyphTests` 14
（含离屏渲染：滚轮两档箭尖分别在上下两半、侧键两档水平箭头左右翻号且两撇朝尾端张开、
中键与两种箭头各有像素差）、
`InstantButtonGestureTests` 12（命中/放行/起手键优先/四道旁路闸门）、`WheelGestureTests` 31（本轮 +2）、
`LegacyWheelGestureImportTests` 12。原来量「右键增强」页滚轮段的两份像素用例随页面段一起删除。

## 四、第 3 条：快捷键屏幕键盘（手写降为兜底）+ 音量两档

### 4.1 屏幕键盘（`Sources/Preferences/ShortcutKeyboardView.swift`）与手写兜底

**成因（两层）**：

1. 录制框收不到某些组合键：⌃↑（切桌面）、⌘⇧2（系统截图）这类在到达录制框之前就被系统或前台
   应用吃掉，`keyDown` 压根收不到那一下 —— 框里点破了也录不进。
2. 手写要求用户先知道「⇧ 怎么写、数字 2 是主键区那格」。多数人只是想把眼前那几个键点出来。
   所以双击的默认入口换成一块 Mac 键盘；手写留作**兜底**，给键盘表里没有的键（F13 以上、小键盘）。

**键盘面板**（不带小键盘的那块妙控键盘，随 iMac 出货、也是多数人桌上那块）：

- 六行主键区：功能键行（⎋ + F1–F12，照真机短 1.5 格）、数字行（` 1–0 - = 与 ⌫1.5u）、字母三行
  （⇥1.5u / ⇪1.5u 占位 / ⇧2.25u / ↩2u）、底行 `fn ⌃ ⌥ ⌘ space4.25 ⌘ ⌥` + 右下角方向键。
- 方向键照真机摆：← / → 整高，↑ / ↓ 是同一列里的两颗半高键（13pt，字号跟着格高收）。
  编辑键区（⌦ ↖ ⇞ ↘ ⇟）与多余的功能键不画 —— 绑定模型用不到，真要用就「改成手写…」。
- ⇪ 只在画面上占位（灰、点不动）：本 App 的五个修饰位里没有 Caps Lock，摆成能点会让人以为录上了。
- 交互：点修饰键切换选中（可多选、再点取消），点主键即提交 `(keyCode, flags)`；
  一个修饰键都不选时点主键提交裸键（与录制框同口径）。修饰键模式（`modifiersOnly`）只摆五个修饰键，
  点「完成」提交 `(0, flags)`；一个都没选时「完成」是灰的、点了也不提交。
- Esc / 点气泡外面：收起键盘，旧值原样留着，一次回调都不发。
- 录制提示气泡：录制中框里只放短句「录制中…」（按住修饰键时给 ⌃⇧… 符号回显，原版行为），
  完整的「请按下快捷键（双击打开键盘，Esc 取消）」挪到框上方的气泡里 —— 长句塞回小格会漫出去盖住旁边的列
  （3.2.4 装机实测）。气泡是 `.applicationDefined`：点外面不收，生死只跟录制态走
  （开始录制挂上、取消/录完都收）；明暗同键盘那条 `drawAppearance ?? window.effectiveAppearance`。
  修饰键档的气泡文案是另一句「请按住修饰键（双击打开键盘，Esc 取消）」。
  「双击打开键盘」必须写进气泡：双击是屏幕键盘的唯一入口，框子闲时只有悬停 tooltip 提它，没人看得见。
- 气泡壳：`.transient`（点外面就收）、尺寸取 `panel.preferredSize`、明暗取
  `drawAppearance ?? window.effectiveAppearance` —— 偏好页是深色时不能弹出一块浅色键盘。
- 落库只有一条路：`commitKeyboardShortcut` 改模型 + 恰好一次 `onShortcutChanged`，与录制、手写同口径。

**手写兜底**（`Sources/GestureEngine/KeyboardShortcutText.swift` + `ShortcutRecorderView`）：

- 入口：键盘面板左下角「改成手写…」；框子闲时的 tooltip 改成
  `单击录制 · 双击打开键盘`（不再是「双击手填」）。灰态（`controlEnabled == false`）
  进不去，且进灰时连正在进行的录制、键盘与手填一起退出 —— 不给「看不见却在生效」的抓手（RC1、RC5）。
- 解析形状：分隔符（空格 `+` `-` `,` `_`）切段，连写的修饰符号（⌘⌥⌃⇧）各自成段；
  名→键码一张表（26 字母按 ANSI 逐个写死 + 数字 + 标点 + F1–F12 + 特殊键的「原名 / 录制框显示的字形」
  两份 + 小键盘只给名字）；修饰别名 ⌘/cmd/command、⌥/opt/option/alt、⌃/ctrl/control/^、⇧/shift、fn/function。
- 逃生口 `key(105)`：表里没名字的键（F13 以上、小键盘以外的 HID 键）按数字填，越界一律拒、不截断（K3）。
- 三种拒法都写进 tooltip：认不出哪一段、只有修饰键、一串里两个键。**认不出的串绝不写进模型**，
  但也不静默吃掉：原文标红留在框里，描边转红（否则「按了回车什么都没变」会被读成「这功能坏了」）。
- 空串不当「清除快捷键」：那一手是右端那把叉的职责（RC2）。
- 预填不抄显示串：`displayString` 有几处**有损** —— 小键盘 0–9 显示成主键盘数字、两种回车都显示成 ↩，
  直接抄的话「双击进去一个字没改就回车」会把 36 换成 76（RC4）。改用 `KeyboardKeys.name(for:)` 反查名字。
- 表只有一份：`ActionExecutor` 原来那张私有的名→键码表被删掉、改吃 `KeyboardKeys`
  （合并时漏一个字母，界面上毫无征兆，只有那条 `keyPress("o")` 规则按下去没反应 ——
  #75 那轮真就这么丢过 o 与 u，K1 钉住 26 个字母逐个取值）。

用例：`ShortcutManualEntryTests` 24 条（A 表：名→键码；B 解析：成功形状与四个失败分支；C：录制框交互），
`ShortcutKeyboardTests` 30 条（A 布局表：字母数字/特殊键/方向键的 ANSI 键码、行宽、⇪ 不可点；
B 面板语义：修饰键切换、主键提交恰好一次、修饰键模式三道闸、取消不落库；C 接进录制框；
D 录制提示气泡：框内短句/修饰键回显、气泡壳 applicationDefined/明暗/文案两档、生命周期跟着录制态；
E 两档外观的离屏渲染 + 选中像素差 + popover 壳的尺寸/明暗/行为）。

### 4.2 音量两档

- 规则动作新增 `volumeUp` / `volumeDown`，持久化 `actionType` 5 / 6，动作下拉第 6、7 项
  （截图是第 5 项，`ScreenshotTriggerTests` 把 7 项的下标逐个钉住；B3/B4/R5/R6 各咬一处串线）。
- 档位大小取 `SystemVolume.volumeStep`（0.05）这**同一个数**（3.2.3 及以前滚轮音量档也是它）；
  两处各写一份的话，改一档只改得动一处（V1）。
- 执行走 `ActionExecutor.volumeStepper` 接缝，默认 `SystemVolume.step(by:)`（直接读写默认输出设备的
  CoreAudio 标量）。**不投「音量+」多媒体键**：#75 那轮实测命令行进程投不动那条键（V4 咬旁路接缝）。
  读不到默认输出设备（没插扬声器）时留一行日志，动作是 fire-and-forget，没有「交回事件」这条退路。
- `needsCursorAppFocus` 把两档归进「不需要焦点」：改的是设备，与谁是前台无关（V5）。

## 五、反向变异：121 条（92 + 屏幕键盘 22 + 录制提示气泡 7）

### 5.1 跑法与表的构成

表在 `tools/mutation/issue78.json`，121 条（屏幕键盘追加 KB1–KB21 与对称的 KB9b；
录制提示气泡追加 KB23–KB29），执行器 `tools/mutation/mutate.py`：

```
python3 tools/mutation/mutate.py tools/mutation/issue78.json          # 整表
python3 tools/mutation/mutate.py --only W1,R1 tools/mutation/issue78.json   # 挑着跑
python3 tools/mutation/mutate.py --list tools/mutation/issue78.json   # 只列不跑（也会做锚点/tests 自检）
```

按分组（`expect=false` 即「免跑」—— 这一条的判据注定在桩件之外，不参与漏检分母）：

| 组 | 条数 | 该抓 | 咬的是什么 |
|---|---|---|---|
| W | 3 | 3 | `CanvasManager` 滚轮归属：按下那一刻记账、不用现读的、不复用上一段的 |
| R | 12 | 12 | `Rule` / `RuleStore`：`instant_gesture` 的编解码、`actionType` 5/6、瞬时匹配与轨迹匹配互不串线、启停与 filter |
| P | 5 | 5 | `PresetGesturePickerPanel` 交出的是哪一档、有没有把 filter/动作/旧轨迹带坏 |
| B | 5 | 5 | `RulesTable` 那一格：图标渲不渲、行签名算不算档位、音量两档在下拉里串不串、双击才弹面板 |
| G | 11 | 11 | `GestureRecordFlow` / `WheelGestureGlyph`：档位网格五档齐全、点下去交出什么、滚轮箭头朝上朝下、侧键箭头朝左朝右且两撇朝尾端张开、中键不画成箭头 |
| K | 7 | 7 | `KeyboardShortcutText`：名→键码表不缺字、显示字形不映射错、`key(N)` 越界拒、修饰位、两个键拒、只有修饰键拒、连写符号分段 |
| V | 5 | 5 | 音量：档位只认 `SystemVolume.volumeStep`、两档符号、一次只推一下、走接缝不走私货、不算成「需要焦点」 |
| RC | 6 | 5 | 录制框手填（`ShortcutRecorderView`）：双击才进、清空不等于清除、灰着进不去、预填串落回同一个键、**编辑没起来那次不当提交**（RC6）。RC3 免跑，见 §6 第 4 条 |
| SF | 5 | 3 | 截图焦点（`ScreenshotController`）：记账次序、0 与「不是我们」两道闸、收遮罩必交还。SF1/SF5 免跑，见 §6 第 3 条 |
| T | 9 | 9 | 气泡排版（`ToastManager.metrics` / `makeContainer`）：框高按行数给足、一把尺、框宽不冲上限、文字让开图标列、图标列隐藏也预留、短消息按内容收缩、文字与图标各自居中、单行框宽付 label cell 内边距（T9） |
| S | 3 | 2 | 两张 `.strings`：栏标题不抄错语言、不缺条目（S3 免跑，见 §6 第 1 条） |
| M | 3 | 0 | App 层闭包（上膛条件 / 命中后查规则表 / 归属传参），全免跑，见 §6 第 2 条 |
| N | 7 | 7 | 旧滚轮设置迁移：持久域判据、只迁一次、同方向去重、方向与缺省档位、启用态、filter |
| E | 11 | 11 | 中键/侧键：编号映射、起手键优先、整击三相位一起吞、冲突查询与提醒、录制/修饰键/过滤三道闸、编号 5 以上不接管 |
| KB | 29 | 29 | 屏幕键盘：布局表（ANSI 键码/行宽/⇪ 不可点）、面板语义（切换/提交一次/修饰键模式/取消）、popover 壳（transient/尺寸/明暗）、录制框接线（双击入口/灰态两道闸/禁用即收/改成手写）、录制提示气泡（KB23–KB29：挂气泡/框内短句/applicationDefined/取消即收/两档文案/两档各带双击入口） |

跑这一趟之前踩了一次表自身的坑，值得记：**`tests` 一个文件只能占一个元素**。原先 R5/B3/B5/S3 写成
`"Suite:/a,/b"` 一个元素塞两个文件，执行器用 `partition(":")` 取套件名，逗号后半截被当成路径交给桩件
→ 桩件 `FileNotFoundError` → 记 `NO-SUMMARY`。这种行**看着像判据有洞，其实一条用例都没跑**，是最容易
骗人的一种红。修表的同时给执行器加了起跑前的 `check_specs`（`tools/mutation/mutate.py`）：形状不对、
套件名不在 `suites.json`、用例文件不存在，三类当场退出并逐条点名，一条都不跑。

### 5.2 结论表（92 条那一趟）

| 结果 | 条数 | 账 |
|---|---|---|
| KILLED | 82 | 判据咬住了 |
| SURVIVED（等价变异） | 1 | W3，见 §5.3 |
| TRAP | 2 | R9 / R10，变异体在构造期崩进程，不是绿 |
| 免跑 | 7 | RC3 / SF1 / SF5 / S3 / M1 / M2 / M3，见 §6 |
| 合计 | 92 | 该抓 85：咬住 82、等价 1、构造期崩 2；没有「判据太松放过去」的 |

账是两趟合成的：前面那趟跑 78 条里的 77 条（M1 锚点过期，改完单跑按免跑记）；补中键/侧键之后
又跑了一趟增量 19 条（改了锚点的 R11 / G1 / G2 / G6 / M1，新增的 E1–E11 与 G9–G11）。增量趟
第一遍有 G6 / E1 / E11 因**锚点过期**命中 0 次被跳过、G10 当场 SURVIVED；前者修锚点单跑补齐，
后者补判据后重跑 KILLED（见 §5.3）。判断分母时要看清执行器的口径：**SKIP 不进分母**
（`ran` 把 SKIP 滤掉了），所以第一遍报的「该抓 15 条里漏 1 条」并不包含那 3 条跳过的 ——
跳过不等于咬住，补齐才算。两趟的源码 SHA 都逐文件核对回起跑前。

### 5.3 逐条处置

- **W3 SURVIVED → 等价变异**：它咬的是复位里那句 `gestureBundleID = ""`。读码：复位之后、
  下一次按下 `gestureBundleID = frontBundle` 之前，没有任何读取（唯一读处在 `CanvasManager.swift:691`，
  前面还压着 `shouldShow / isCapturing / isEnabled / !isSuspended` 四道闸）。写进去的值活不到被读，
  改与不改行为相同。产品代码不动；只在 `WheelGestureTests` 那条用例的注释里写明「它咬的是按下时重新赋值，
  不是复位清空」，免得后人把这条等价变异误记成漏检。
- **G10 先 SURVIVED、补判据后 KILLED**：它把水平箭头的两撇画到箭尖**外侧**（箭头看着指反）。
  原来的判据只比「左半 / 右半」两带的墨量：箭尖和两撇一起翻过去，差值照样翻号，所以看不见这一种坏。
  新增 `testSideButtonArrowWingsOpenTowardTheTail`（`WheelRuleGestureGlyphTests`）：在撇端点附近取
  两个 2×2 的小窗 —— 内侧必须有墨（先证这一格真画了箭头），外侧必须一点墨都没有；胶囊弧线在窗子
  外还留了 0.9pt 的余量。实测：正确代码两窗 0/有墨，变异体两窗 3/0，两条断言当场红。
- **锚点过期这一课**：锚点是源码原文的子串。这一轮把 `hasInstantRule` 改名成 `hasWheelInstantRule`、
  把瞬时候选数组改成多行写法、把中文栏标题从「滚轮档（不用画）」改成「瞬时手势（不用画）」，
  G6 / E1 / E11 / S1 四条锚点当场失配。执行器的 `--list` 只查 `tests` 的形状/套件/文件，
  **不查锚点命中**；命中是在 `run_case` 里现数、数不对就记 SKIP。所以「表看着没问题」不等于
  「每条都真跑过」，跑完必须看一眼 SKIP 行。
- **R9 / R10 TRAP**：两条都替换瞬时规则的构造，把空模板送进 `compare()`，撞上
  `GestureEngine/Stroke.swift:24` 的 `assert(!points.isEmpty)`，进程当场崩（用例 0 条）。
  这不算「判据太松」，也不算「判据咬住」—— 是变异体活不过构造期，行为不可观测。表里原样保留，
  跑的时候会再度记成 TRAP 而不是绿。
- **RC3 免跑**：见 §6 第 4 条（裸进程成不了 key，真编辑态演不出来），由 §8 第 11、12 步在真窗口覆盖。
- **T9 新增**：15pt 单行气泡的自测（§10.1）发现 label cell 有 8.35–8.68pt 水平内边距，
  旧单行分支只按字符串宽定格 → 真机折行 → 第二行被裁、文件名尾部消失。T9 把
  「单行框宽不付 `labelCellPadding`」钉死，T2/T6 的锚点同步挪到新代码上。
- 其余 KILLED 逐条见 `.build/mutation/<时间戳>/results.json`（一条：改哪一行、预期抓到什么、实测哪套用例红）。

### 5.4 屏幕键盘那一趟（22 条，2026-11-04）

跑法：`pkill -x MacStroke; python3 tools/mutation/mutate.py --only KB1,...,KB21 tools/mutation/issue78.json`
（KB9b 由对称探查单跑补入，证据 `.build/mutation/20261104-173259` 与 `...-175003`）。

| 结果 | 条数 | 账 |
|---|---|---|
| KILLED | 20 | 布局表 4（键码/行宽/⇪）、面板语义 7、popover 壳 3、录制框接线 6 |
| SURVIVED（等价变异） | 2 | KB9 / KB9b，见下 |
| SKIP / TRAP / 编译红 | 0 | 21 条首趟 + 1 条对称探查，锚点全部恰好命中一次，还原核对 SHA 全回起跑前 |

**KB9 / KB9b 是同一处判据的一对等价变异**：灰态不许开键盘这件事写了两道闸 ——
`click(at:)` 入口一道、公开的 `presentShortcutKeyboard()` 里又一道。第一次只摘入口那道（KB9）
全绿；补一条只摘公开入口那道（KB9b）同样全绿。两条各自被对面那道挡住，**任摘一道都不会放行**，
所以行为不可观测，不是判据洞。产品代码不动（两道闸分别防「鼠标路径」与「编程调用」）；
用例 `testADisabledRecorderRefusesTheKeyboardOnDoubleClick` 走的是真实鼠标路径，判据本身有效。

其余 20 条逐条见 `.build/mutation/20261104-173259/results.json`。值得留意的是 KB1（单击变双击）
只红 1 条、KB5（丢修饰位）只红 2 条 —— 判据里「恰好一次 + 键与位都在」各只有一条用例正面盯着，
再拆细就会把这两处坏法同时放过去。

### 5.5 录制提示气泡那一趟（5 条，2026-11-05）

跑法：`pkill -x MacStroke; python3 tools/mutation/mutate.py tools/mutation/issue78.json --only KB23,KB24,KB25,KB26,KB27`。

动机：装机实测发现录制中长提示「录制中…请按下快捷键（Esc 取消）」漫出小格、盖住旁边的列。
改版：框内只留短句「录制中…」（按住修饰键仍给 ⌃⇧… 符号回显），整句提示挪进框上方的气泡
（`.applicationDefined`，点外面不收，生死只跟录制态走）。

| 结果 | 条数 | 账 |
|---|---|---|
| KILLED | 5 | KB23 开始录制挂气泡 / KB24 框内换回长句 / KB25 transient 点外面收 / KB26 取消不收 / KB27 两档文案串线 |
| SKIP / TRAP / 编译红 | 0 | 锚点全部恰好命中一次，还原核对 SHA 全回起跑前 |

证据 `.build/mutation/20261105-100241`。KB24 的判据是双保险：正面断言框内是 `L("Recording…")`，
再量 12pt 字宽必须收进格宽 —— 两句各自咬住一半。新增离屏证据 `/tmp/shortcut-recording-hint.png`
（气泡内容渲成 PNG，字在框内不被裁）。

### 5.6 气泡补双击入口那一趟（2 条，2026-11-05）

跑法：`pkill -x MacStroke; python3 tools/mutation/mutate.py tools/mutation/issue78.json --only KB27,KB28,KB29`。

动机：用户看完 5.5 的气泡改版后指出「也要提示双击的作用啊，不然谁知道入口」——双击是屏幕键盘的
唯一入口，原先只在框子闲时的悬停 tooltip（`单击录制 · 双击打开键盘`）里提，没人看得见。
改版：两档气泡文案各补「双击打开键盘」——「请按下快捷键（双击打开键盘，Esc 取消）」/
「请按住修饰键（双击打开键盘，Esc 取消）」。KB27 锚点跟着改成新文案重跑（语义不变：两档串线）。

| 结果 | 条数 | 账 |
|---|---|---|
| KILLED | 3 | KB27 两档文案串线（重跑）/ KB28 普通档退回无双击入口的旧句 / KB29 修饰键档退回旧句 |
| SKIP / TRAP / 编译红 | 0 | 锚点全部恰好命中一次，还原核对 SHA 全回起跑前 |

判据：气泡壳用例正面断言 `L(...)` 全串 + `contains("double-click")`（离线桩件只读 en 表，
中文「双击打开键盘」按两表对账 + 装机实测兜）。离屏证据 `/tmp/shortcut-recording-hint-dblclick.png`
（不复用上一趟的文件名，旧证据保留）。证据 `.build/mutation/20261105-105825`，3/3 KILLED、
还原核对 SHA 全回起跑前。

### 5.7 起跑前的基线（逐套件全绿）

整表开跑前这一棵源码树的 11 套件。滚轮并入规则那一趟是 1156 用例；补中键/侧键之后
又加了 23 条（EventCapture +12、RuleEngine +5、WindowManager +6），最终基线 **1179**：

| 套件 | 用例 | 套件 | 用例 |
|---|---|---|---|
| GestureEngine | 27 | Screenshot | 282 |
| EventCapture | 73 | SelectionPopup | 181 |
| RuleEngine | 138 | ProximityLock | 79 |
| Storage | 91 | RemoteControl | 60 |
| AppleScriptRunner | 36 | WindowManager | 205 |
| RightClickMenu | 7 | | |

合计 1179。§10.3、§10.4 的取证是这之后补的（WindowManager 207），最终源码树 1181，见 §7。
RuleEngine 从 125 涨到 138（迁移、瞬时规则、音量动作、中键/侧键与冲突提醒），
WindowManager 从 215 降到 205（两份旧滚轮页面用例随页面段删除，新增的手填/滚轮规则/图标
用例在别的文件里），EventCapture 从 61 涨到 73（`InstantButtonGestureTests`）。

## 六、离线咬不住的那几条，靠装机清单兜

四条硬限制，都是**读码**或**探针**得出的结构性结论，不是「还没找到判据」：

1. **桩件里的 `L()` 只吃 en 表**，中文表只能当数据读（`NSDictionary(contentsOf:)`）。所以
   「两张表里同义 / 撞串」这类坏法（S3：en 表音量两档填成同一个词）离线咬不住；
   S1、S2 用「两张表互相比」的方式咬住了（判据不写死任何一句中文）。
2. **App 层的闭包在 app target 里**，桩件够不到 → M1（上膛条件恒 false）、M2（命中后不查规则表）、
   M3（归属传成空串）只能装机验。
3. **`NSApp.activate` / 面板 / 真链路的时机**：SF1（记账排在权限弹窗与抓屏之后）、SF5（close 里不
   交还）在桩件里都能编译能跑，判据却测不到「遮罩真摊开时前台是谁」→ 只能装机验。
4. **真的 field editor 编辑态**：RC3（`cancelManualEntry` 里「交还焦点前先把委托摘掉」那一行）。
   探针实测：桩件这个裸二进制进程 `NSApp.isActive` **恒为 false**（`setActivationPolicy(.regular)` +
   `activate(ignoringOtherApps: true)` 都拉不起来 —— 它不是带 bundle 的前台程序），窗口成不了 key，
   `makeFirstResponder(文本框)` 被当场拒掉。于是「编辑真的起来过、再被 Esc 打断」这一段在离线上演不出来。
   上一轮为补这个洞写的「挂进窗口再取消」那条用例经探针判定是**假绿**（视图不在窗口里时
   `removeFromSuperview` 惊不动 first responder；挂进窗口后又因为成不了 key 而压根没进编辑态），
   本轮把它换掉：改成咬「编辑没起来那一次也不能当提交」（RC6，探针实测旧代码 `commits=1`），
   RC3 标免跑，由 §8 第 11、12 步在真窗口里覆盖。

这四类在 §8 的清单里各有一条对应的人工步骤。

## 七、全量回归

补中键/侧键、走完增量变异、再修完 §10.3 两场关窗事故（先崩溃、后卡死模态）之后的一趟
（`pkill -x MacStroke; python3 tools/xctstub/xct.py regress`），
证据 `/tmp/regress-78-closefix2.log`：

合计 **1180 用例 / 红 0 / 跳过 1**（11 套）。

| 套件 | 用例 | 红 | 跳过 |
|---|---|---|---|
| GestureEngine | 27 | 0 | 0 |
| EventCapture | 73 | 0 | 0 |
| RuleEngine | 138 | 0 | 0 |
| Storage | 91 | 0 | 0 |
| AppleScriptRunner | 36 | 0 | 0 |
| RightClickMenu | 7 | 0 | 0 |
| WindowManager | 206 | 0 | 0 |
| Screenshot | 282 | 0 | 0 |
| SelectionPopup | 181 | 0 | 0 |
| ProximityLock | 79 | 0 | 0 |
| RemoteControl | 60 | 0 | 1 |

紧挨着的前一趟（`/tmp/regress-78-midclick.log`，修关窗崩溃之前）是 1179 用例、1 红，
红的是 `RemoteControlServerE2ETests.testWarpMovesTheCursorToAnAbsolutePoint`（「没读到回执行」）。
这一套每条用例都在 `setUp/tearDown` 里对固定端口做异步 stop/start，连跑时撞上监听还没落定
就会这样 —— 是这一套早就有的竞态，不是本轮代码：本轮没动 `Sources/RemoteControl/`。
复跑取证（先 `pkill -x MacStroke`，`xct.py run RemoteControlTests --no-build`）：
**60 用例 0 红 1 跳过**；收尾这一趟整套连跑也绿，未再复现。

那 1 条跳过是 `testMirrorFramesFollowTheSwitch`：测试进程是裸二进制，没有「屏幕录制」权限，
服务端只会回 `noScreenPermission`（与往轮相同）。

修完 §10.4 图标格几何之后又跑了一趟最终回归（`pkill -x MacStroke; python3 tools/xctstub/xct.py regress`），
证据 `/tmp/regress-78-cellgeom.log`：

合计 **1181 用例 / 红 2 / 跳过 1**（11 套），红的 2 条全在 RemoteControl E2E
（`testWarpMovesTheCursorToAnAbsolutePoint` / `testScrollPostsAWheelEventWithTheGivenDelta`，
「没读到回执行」/ connection refused），是 §10.3 那趟已经定性过的固定端口 stop/start 竞态 ——
本轮没动 `Sources/RemoteControl/`。复跑取证：整套再跑一遍红的是**另外两条**
（`testTwoCommandsInOneWriteAreBothHandled` 替掉了 scroll），红名单随趟漂移、正是竞态的面相；
把红过的两条各自单跑（`--only`）均绿。这与往轮「连跑必偶发红 1–2 条、单跑即绿」的记录一致，
非本轮代码引入。除 RemoteControl 外 10 套全绿（WindowManager 207，含 §10.4 新判据
`testTableHostedThumbKeepsItsCellGeometry`）。

前一趟（closefix2）11 套全绿，含本轮全部新增判据：滚轮规则、旧设置迁移、快捷键手填、音量两档、截图焦点、
中键/侧键瞬时手势与起手键优先、冲突提醒、图标离屏像素、气泡排版（40pt / 15pt 两档离屏像素）、
选择面板红叉/⌘W 只结束模态（§10.3）。WindowManager 的像素带子已按删掉滚轮段后的新布局重测，
`StrokeTargetPreferencesTests` 的四条判据改量 Finder 卡片与本段自身，不再引用已删除的滚轮段。

**屏幕键盘这一轮之后（2026-11-04，最终一趟）**：`pkill -x MacStroke; python3 tools/xctstub/xct.py regress`，
证据 `/tmp/regress-78-keyboard.log`

合计 **1225 用例 / 红 0 / 跳过 1**（11 套）：WindowManager 250（+44：屏幕键盘 25、手填改名与
本轮其余判据随前几趟累加）、Screenshot 283（+1，前趟已记的格内图标几何）、其余套件与此前一致。
跳过仍是 RemoteControl 那条 `testMirrorFramesFollowTheSwitch`（裸进程没有屏幕录制权限），
RemoteControl E2E 这一趟没撞上固定端口竞态。

**录制提示气泡这一轮之后（2026-11-05）**：`pkill -x MacStroke; python3 tools/xctstub/xct.py regress`，
证据 `/tmp/regress-78-recordinghint.log`

合计 **1230 用例 / 红 2 / 跳过 1**（11 套）：WindowManager 255（+5 录制提示气泡）、其余套件与上一趟一致。
红的 2 条全在 RemoteControl E2E（`testWarpMovesTheCursorToAnAbsolutePoint` /
`testTypeAndKeyReachTheEventStream`，「Connection refused」Code=61），是 §10.3 定性过的固定端口
stop/start 竞态 —— 本轮没动 `Sources/RemoteControl/`；两条各自 `--only` 单跑均绿（2s / 2s），
红名单随趟漂移的面相与往轮一致，非本轮代码引入。跳过仍是 `testMirrorFramesFollowTheSwitch`。

**气泡补双击入口这一轮之后（2026-11-05）**：`pkill -x MacStroke; python3 tools/xctstub/xct.py regress`，
证据 `/tmp/regress-78-dblclick.log`

合计 **1230 用例 / 红 2 / 跳过 1**（11 套）：套件与用例数与上一趟完全一致（本轮只改两档气泡文案
与对应判据）。红的 2 条又是 RemoteControl E2E 的固定端口竞态（`testWarpMovesTheCursorToAnAbsolutePoint` /
`testScrollPostsAWheelEventWithTheGivenDelta`，Code=61 与空回读），两条各自 `--only` 单跑均绿
（2s / 3s），红名单随趟漂移、与往轮同一性质；跳过仍是 `testMirrorFramesFollowTheSwitch`。

| 套件 | 用例 | 红 | 跳过 |
|---|---|---|---|
| GestureEngine | 27 | 0 | 0 |
| EventCapture | 73 | 0 | 0 |
| RuleEngine | 138 | 0 | 0 |
| Storage | 91 | 0 | 0 |
| AppleScriptRunner | 36 | 0 | 0 |
| RightClickMenu | 7 | 0 | 0 |
| WindowManager | 250 | 0 | 0 |
| Screenshot | 283 | 0 | 0 |
| SelectionPopup | 181 | 0 | 0 |
| ProximityLock | 79 | 0 | 0 |
| RemoteControl | 60 | 0 | 1 |

## 八、装机验收清单

> 交 mtjo 实测。每条给「怎么按」和「看什么算过」。判据一律取外部观测（音量百分比、`defaults read`、
> 前台 App 的名字、日志行），不看软件自己声明的状态。

1. **截图不抢前台**：在 Safari 里按 ⌘⇧A → 拖选 → 回车（或 Esc）。过 = 遮罩收掉后前台还是 Safari，
   Dock 上 MacStroke 那枚没有跳起来。存盘那一路同样：选区回车 → 存盘面板「取消」，过 = 前台仍是 Safari。
2. **截图的权限那一路也还**：把 MacStroke 从「屏幕录制」名单里摘掉再按 ⌘⇧A，弹窗点「稍后」。
   过 = 弹窗关掉后前台仍是 Safari（这一场压根没铺遮罩，不该留痕迹）。
3. **规则页配瞬时手势**：规则页选一条规则 → 双击手势格 → 面板底下「瞬时手势（不用画）」点「上滚」。
   过 = 那一格换成向上箭头 + 一行「上滚」，旧轨迹点没了（把 `~/Library/Application Support/…rules.json`
   里那条读出来核对 `instant_gesture` 在、`data` 是空数组）。
4. **旧设置迁移**（升级用户）：升级前在 3.2.3 的「右键增强」页把滚轮打开、上滚选「上一个标签页」、
   下滚选「音量 −1 档」。装 3.2.4 后打开规则页。过 = 顶上多出「上滚」「下滚」两条启用规则
   （filter 是 `*`，动作分别是 ⌘⇧[ 与「音量 −1 档」），「右键增强」页不再有滚轮段；
   退出再启动一次，规则数不变（不会重复迁）；`defaults read` 里 `wheelGestureEnabled` 已是 0。
5. **按应用过滤**：给滚轮规则填 filter（只勾 Safari）。过 = Safari 里上滚执行、别的 App 里上滚
   照旧翻页不吞。
6. **没规则就归还滚轮**：把规则页那两条滚轮规则删掉（或停用）。过 = 按住起手键滚动不再执行任何
   动作、页面照常滚，回到 3.2.3 的原版行为；重新加回一条，下一次按下起始键就生效。
7. **黑名单一起失效**：过滤页把 Safari 拉黑。过 = 它的滚轮规则与轨迹规则同时不动作。
8. **音量档**：规则动作下拉里出现「音量 +1 档 / 音量 −1 档」。过 = 触发一次，系统音量条动一格（±5%），
   与 3.2.3 滚轮音量档的幅度一致；连着触发到顶/到底钳住不出错。
9. **屏幕键盘（双击的默认入口）**：截图页那个 ⌘⇧A 框里双击。过 = 弹出一块 Mac 键盘
   （六行主键区 + 右下角 ← ↑/↓ →）；点 ⌃、再点 ⇧、再点 2 → 气泡收起、框里显示 ⌃⇧2；
   `defaults read` 那一条的 keyCode 是 19、flags 里 ⌃ 与 ⇧ 两位都在。Esc 再双击一次：
   Esc 只收气泡、旧值一个字没变，也没有多一次保存。
10. **修饰键模式的键盘**：常规页「修饰键暂停手势」那个框（`modifiersOnly`）里双击。
    过 = 弹出的是一排五个修饰键；点「完成」不选任何键时应是灰的、点不动；
    选 ⌃ 与 ⌘ 再点「完成」→ 框里显示 ⌃⌘、`defaults read` 里键码为 0。
11. **手写兜底**：键盘面板左下角点「改成手写…」。过 = 气泡收起、原地变成可输入的文本框；
    填 `⌃↑` 回车 → 框里显示 ⌃↑，tooltip 给 `keyCode=126, flags=…`
    （⌃↑ 用单击录制录不到，这是这一条的存在理由）。
12. **手写三种拒法**：填 `⌃`（只有修饰键）、`⌘AB`（两个键）、`⌘zz`（认不出）。
    过 = 三种都不写库、原文标红留在框里、tooltip 各给一句人话；Esc 退出后旧值一个字没变。
13. **小键盘不被换**：先在录制态按小键盘的 5（框里显示「5」）→ 双击打开键盘 → 点「改成手写…」
    → 不改字直接回车。过 = tooltip 里的 keyCode 还是 84（小键盘 5），不是 19（主键盘 5）。
14. **清除仍是那把叉**：录好一个值后双击打开键盘（或手写框里把字删空）再收起。
    过 = 值没变、叉还在；点叉才真的清。
15. **旧数据不动**：装 3.2.4 前把 `rules.json` 备份一份，装完导出一次。
    过 = 导出结果与备份逐字节相同（除了迁移新增的那几条滚轮规则）—— 这条兜住 R2 那类坏法。
16. **中文界面**：切到中文再走第 3、4、8、9、10、19、21、23 步。过 = 「瞬时手势（不用画）」栏名、
    「上滚 / 下滚 / 中键 / 后退 / 前进」读法、「音量 +1 档」「单击录制 · 双击打开键盘」、
    键盘面板那几句（「先点修饰键，再点主键」「快捷键键盘」「改成手写…」「完成」）、
    录制提示那几句（「录制中…」「请按下快捷键（双击打开键盘，Esc 取消）」
    「请按住修饰键（双击打开键盘，Esc 取消）」）、
    起手键冲突那两处提醒都是中文，没有露出 key 原文（桩件只验了 en 表，
    这一条是 S1/S3 那类坏的唯一出口）。
17. **保存提示不顶出黑框**（本轮追加，见 §十）：把「常规 → 提示字号」调到 40、字体 Monaco，
    然后 ⌘⇧A 截一张存盘。过 = 「已保存 截图 …png」这行字**整行都在黑框里**，框子最宽不超过半屏、
    长消息自己折成两行且黑框跟着变高；再把字号回到默认 15 截一张，短提示仍是那枚 320×80 的窄气泡。
18. **从别的 App 双击快捷键格**（本轮追加，见 §十）：偏好窗口开着、但前台是别的 App（点一下桌面即可）。
    过 = 双击那一下**不会**把框里的快捷键改掉：先记下框里现值（或 `defaults read` 那一条规则），
    双击一次、再看 —— 值不变、也没有多一次「已保存」的持久化痕迹；焦点回到偏好窗口后再双击，
    才真的弹出键盘（再点左下「改成手写…」才进文本框）。
19. **中键/侧键直接触发**：给一条规则选「中键」（或后退/前进），动作设成好辨认的一项（如音量 +1 档）。
    过 = 不画轨迹、按一下就直接执行；`rules.json` 里那条 `instant_gesture=middleClick / backClick / forwardClick`。
20. **没配规则就归还按键**：把上一步那条规则停用（或删掉）。过 = 中键点链接仍在新标签打开、
    侧键仍照常后退/前进，不会被吞；重新启用后下一次按键就生效。
21. **起手键优先与冲突提醒**：常规页把「手势起始按键」录成中键；再给一条规则选中键。
    过 = 选完当场弹一条通知，说明中键同时是起手键、起手键优先；常规页起手键下面常驻一行橙色提示。
    按住中键拖动仍画手势（画布出现），那条规则没有执行；把起手键换回右键后，橙色提示消失，
    中键按一下才执行规则。
22. **选择手势窗口点红叉**（本轮追加，见 §10.3）：规则页双击手势格打开面板，直接点红叉（或 ⌘W）。
    过 = 面板收起、偏好窗口还在、程序不退出；再打开一次、点一格预设，选中的手势照常写回。
    重复五次不应出现任何崩溃（旧版两次都 100% 崩在 `_NSWindowTransformAnimation`）。
23. **录制提示气泡**（录制提示改版，见 §4.1）：单击任一快捷键格进入录制（不是双击）。
    过 = 框里只有「录制中…」三个字的宽，框上方气泡给整句「请按下快捷键（双击打开键盘，Esc 取消）」，
    不再漫出去盖住旁边的列 —— 气泡里**要能看到「双击打开键盘」**，这是屏幕键盘入口的唯一提示；
    点一下旁边别的列，气泡不消、录制还开着；按 Esc 或再点一下那格，气泡跟着收、
    旧值没变。按住 ⌃ 时框里显示 ⌃…。常规页「修饰键暂停手势」那一格进入录制时，气泡给的是
    「请按住修饰键（双击打开键盘，Esc 取消）」。

## 九、这一轮刻意没做的事

1. **音量键 / 媒体键作为「触发条件」**（#78 第 3 条的后半句）。本轮把音量做成了**动作**。
   触发条件那条要动的是「起手键之外的键也算手势」，与 issue #53 的起手键配置、以及 #78 第 4 条
   （每条手势单独起手键）是同一团纠缠，单独加一档会变成第四处入口。等第 4 条的方案定了一起做。
2. **每条手势单独起手键**（#78 第 4 条）：待方案。
3. **鼠标反向滚动 / 平滑滚动**（#78 第 5 条）：待方案 —— 那是「翻转滚轮符号」的系统级改造，
   与手势识别不在一层，且与 MacStroke 已有的滚轮节流（0.09 秒 + 够一格才算一次）会互相影响。
4. **Shift + 滚轮 / 水平滚轮**：这一档牵扯「带修饰键的滚轮」与触控板横轴，本轮仍没做；
   中键与侧键（后退/前进）已按 mtjo 的要求补进 `InstantGesture`（§3.6），编号 5 以上的额外键
   刻意不接管，留给鼠标厂商驱动。
5. **抬手那一刻的归属现读**（`CanvasManager.swift:371`）仍按 3.2.2 的口径现读，没跟着换成接缝 ——
   本轮判据只需要「按下时刻」那一份，多开一处洞超出任务范围。

## 十、mtjo 实测撞出来的两处（本轮追加）

这两条不在 #78 那五项里，是装机实测时撞出来的，也一起进了 3.2.4。

### 10.1 保存提示的气泡，字顶出黑框

**坏法（用户截图，实测）**：把「常规 → 提示字号」调到 40、字体换成 Monaco，⌘⇧A 截一张存盘，
「已保存 截图 2026-11-02 at 15.08.47.png」这行字的上半截冒在黑框上面。

**读码**：旧实现在 `show()` 里现算三个量，各用各的尺：

- 折行预算 = `maxWidth - labelMargin*2 - imageMarginLeft - iconWidth` = 693；
- 框宽却按「整串不折行的单行宽 + chrome」= 1006 定（冲出 826 的上限）；
- 框高只兜 `minHeight` = 80。

同一串在 Monaco 40 下实测：行高 53、单行宽 872.1，按 693 折成 2 行（文字块高 106）。
`label.y = (80 − 106) / 2 = −13` —— 上半行 13 点整个在黑框外，正是截图里的样子。

**修法**：`ToastManager.metrics(message:font:iconVisible:)` 收成一把尺，`makeContainer(...)` 按它装框；
`show()` 与离屏取证都走这一手。

- `labelLeft = 图标可见 ? 15 + 58 + 12 : 30`，`chrome = labelLeft + 30`；
- `labelBudget = 826 − chrome − labelCellPadding`，**数行数与 label 真正拿到的宽度是同一个数**；
- 单行宽 ≤ `labelBudget`：一行，按内容收缩（下限 320）；图标隐藏也照旧预留图标列（原版怪癖）；
- 否则框宽取 826，用同一个 `labelBudget` 折行；
- 框高 = `max(80, 行数 × 行高 + 12 × 2)`，label 与 icon 各自垂直居中。

同一串修后实测：826 宽 / 2 行 / 130 高 / `label.y = 12`；离屏 PNG `.build/evidence/toast-fixed-40.png`。

**同源的第二处（自测才发现）**：把字号放回默认 15 再截一张，长文件名在**单行**气泡里被裁尾巴。
`NSTextField(labelWithString:)` 的 label cell 左右各留约 8.4pt 内边距：旧单行分支按
`ceil(字宽)` 定格子，cell 在这个刚好等于字宽的格子里自己折成两行，第二行又被「1 × 行高」的格子高度裁掉，
用户看到的就是文件名后半截没了。四串实测折行阈值减字号宽 = 8.35～8.68，取 `labelCellPadding = 9`
兜住取整；单行框宽 = `字宽 + 9 + chrome`。修后实测 397 宽 / 1 行 / `label.width = 282`（全串 273+9），
PNG `.build/evidence/toast-fixed-15.png`。

**判据**（`Tests/WindowManagerTests/ToastLayoutTests.swift`，9 条）：

- 纯函数 7 条：长串不冲破 826 且 label 四边在框内、折行行数与 `labelFrame.width − labelCellPadding` 重算的一致、
  短消息仍是 320×80、label 让开图标列、隐藏图标仍预留图标列、框高按行数线性长且上下留白对称、
  默认字号单行格子让出 cell 内边距；
- 离屏像素 2 条：透明画布上先证「渲染真吃到字」（白字像素下限），再把白字 bbox 与黑框 rect 比 ——
  长串（Monaco 40）落框内 ±2、横向跨度 ≥ `labelFrame.width*0.6`；默认字号那条既要求出框像素为 0，
  又要求白字横向跨度 ≥ 全串宽的九成（只不超出框还不够，被裁短了同样红）。

**反向变异**（更新锚点后重跑）：T1–T9 全 KILLED —— 框高写死 / 两把尺 / 框宽冲上限 / 文字不让图标列 /
隐藏图标不预留 / 短消息不收缩 / 文字不居中 / 图标不居中 / 单行不付 cell 内边距，
证据 `.build/mutation/20261102-171352`。

### 10.2 从别的 App 双击快捷键格，现有快捷键被默默重写

**坏法（探针实测旧代码 `commits=1`）**：偏好窗口开着但前台是别的 App，直接双击截图页的快捷键格。
`ShortcutRecorderView.acceptsFirstMouse` 返回 true，那一下**不会先把窗口变成 key**；
`startManualEntry()` 里 `selectText` 当场结束编辑（当时以为只在非 key 窗口，3.2.4 实测
key 窗口一样，见本节末尾），`controlTextDidEndEditing` 立刻送到委托里 —— 送上来的是预填的旧值，却被当成用户提交，
等于「双击一下就把当前快捷键重新写了一次」。

**修法**：`manualEditingBegan` 闸门。`controlTextDidBeginEditing` 真的起来才置 true；
结束编辑时若没起来过，走 `cancelManualEntry()` —— 旧值原样留着、一次回调都不发，用户点第二下就能真编辑。

**判据**：`testADoubleClickIntoAWindowThatCannotHostEditingCommitsNothing`
（`Tests/WindowManagerTests/ShortcutManualEntryTests.swift`）——把视图挂进一个成不了 key 的窗口，
走到真入口 `startManualEntry()`，断言 commits/clears 都是 0、keyCode/flags 没变、不残留手填态。
反向变异 RC6（把闸门改成恒真）KILLED。

**为什么只剩这一种咬法**：桩件是裸二进制进程，`NSApp.isActive` 恒 false，真窗口成不了 key。
不过桩件里可以挂一扇 `isKeyWindow` 恒报 true 的窗口子类，把 key 窗口那条路整段演出来 ——
3.2.4 装机后补的用例就是这么跑的（见下），RC3 不必再留给 §8 手动覆盖。

**3.2.4 装机后追加：双击手填完全没反应（2026-11-04 用户实测）**

上一版把闸门挂在了 `controlTextDidBeginEditing` 上，但 `startManualEntry()` 在
`makeFirstResponder(field)` 之后紧跟了一句 `field.selectText(nil)` —— 它会把刚挂上的
编辑会话**当场结束**。真机探针（`key=1 ok=1 responder=NSTextView`）的次序是：

```
startManualEntry ... responder=NSTextView
currentEditor=Optional(<NSTextView …>)
controlTextDidEndEditing began=0     ← 2 ms 后到，且 didBeginEditing 一次都没来
afterSelectText responder=NSWindow
```

闸门据此判「编辑没起来」→ `cancelManualEntry()`，框子一闪即逝，用户看见的就是「双击没反应」。

**修法**：

1. 全选不再走 `selectText`，改由字段编辑器自己做：
   `editor.selectedRange = NSRange(location: 0, length: stringValue.count)`；
2. 闸门改以「编辑器真的挂上」为准：`manualEditingBegan = focused && editor != nil`，
   挂不上就直接收框（非 key 窗口那一道闸仍留在入口，§10.2 的旧语义不变）；
3. 新增 `tearDownManualField()`：**先摘委托、再拆视图**。拆掉正持字段编辑器的视图会再发
   一次 `controlTextDidEndEditing`；不摘委托的话，提交成功的那次会被预填旧值盖回去、
   被拒的那次会被清掉红字（本趟用例一次抓到 2 次回调）。

**判据**：`testAManualEntryInAKeyWindowStaysAliveUntilCommit`
（`Tests/WindowManagerTests/ShortcutManualEntryTests.swift`）—— 视图挂在 `isKeyWindow`
恒 true 的 `KeyReportingWindow` 里，断言进入后 `isEditingManually`、编辑器在位、预填串全选、
0 次回调；写入 `⌃↑` 后结束编辑（走真委托），模型落值、只回调一次、不残留文本框。
反向变异 RC8（把全选改回 `selectText(nil)`）KILLED：报的正是「进了手填却当场退出去 +
预填值提交了一次」。整份 `ShortcutManualEntryTests` 由裸视图改为挂在 key 窗口下重跑，26 条全绿。

**真机取证**（临时 `MACSTROKE_SRPROBE` 探针，2026-11-04，装完删掉）：

```
activation key=true active=true
after2     man=true  editor=true  text=⌘⇧A
afterReturn man=false value=126/262144      ← ⌃↑，Return 提交
reentry    man=true  editor=true
afterEsc   man=false value=126/262144      ← Esc 取消，值原样
```

（注意：程序内 `NSApp.activate` 在 macOS 14+ 的合作式激活下无效；探针是把偏好窗提到
`.floating` 后用 HID 点击标题栏拿到的前台。另：CGEvent 的屏幕原点在左上，NSWindow
的屏幕坐标原点在左下，`convertPoint(toScreen:)` 的 y 要翻转。）

### 10.3 选择手势窗口关窗：先崩、再卡死模态（2026-11-03 两场实测事故）

**第一场（用户实测两次，整个程序退出）**：规则页双击手势格打开选择面板 → 点红叉 → 整个程序退出。
崩溃报告 `~/Library/Logs/DiagnosticReports/MacStroke-2026-11-03-091454.ips` 与
`…-111404.ips`（都是 3.2.4，09:14 / 11:14）签名一致：`EXC_BAD_ACCESS`，故障线程落在
`com.apple.root.user-interactive-qos`，栈顶是

```
objc_msgSend
__62-[_NSWindowTransformAnimation _stopAnimation:withDisplayLink:]_block_invoke
-[_NSWindowTransformAnimation _stopAnimation:withDisplayLink:]
-[NSScreenDisplayLink _fire]
```

**读码**：`PresetGesturePickerPanel` 是全仓库唯一 `.titled, .closable` 的模态窗口。红叉走
`NSWindow.performClose` → AppKit 的关窗动画；`windowWillClose` 里 `NSApp.stopModal`，
`run()` 随即返回，`pick()` 的局部 `panel`（窗口唯一的强引用）释放 —— 窗口在动画还挂着
display link 的时候被 ARC 释放，下一拍就是野指针。3.2.3 及更早的面板代码就带着这个隐患
（本轮只加了底部那一栏，没动窗口生命周期），这次连续被撞到。

**第一版修法（只拦 `performClose`）**：`PickerWindow.performClose(_:)` 改为只回调
`onCloseRequested`（→ 取消 → `stopModal`），同时把 `windowWillClose` 摘掉。这版让崩溃消失。

**第二场（同日下午，用户报「关闭后所有的操作都失效了，焦点好像被吃掉了」）**：第一版装机后
再点红叉，面板收起，但整个 App 的点击与键盘全无反应。lldb 贴上还活着的进程读到：
`[NSApp modalWindow]` 仍是那个 `PickerWindow`，`keyWindow` 为 nil —— 模态会话没结束、窗口却
被收走了。`sel_getName` 读出红叉按钮的 action 是私有的 **`_close:`**：它直接关窗，**不**经过
`performClose(_:)`。所以第一版拦错了入口：窗口照关、`stopModal` 没人调。

**最终修法（三条入口全接住）**：

| 入口 | 实测走向 | 接法 |
| --- | --- | --- |
| 红叉 | `_close:`（私有，绕过 `performClose`） | 直接改按钮 target/action → `cancelClicked` |
| ⌘W | 菜单发 `performClose(_:)` | `PickerWindow.performClose` → `onCloseRequested` |
| 其他代码直接 `close()` | `close()` | `windowWillClose` 兜底 → `stopModal` |

另设 `animationBehavior = .none`（即使有漏网路径也不留关窗动画可残留）与
`isReleasedWhenClosed = false`（ARC 下程序化窗口的惯例）。窗口仍由 `run()` 里的
`orderOut(nil)` 收掉，随后随面板正常释放。

**判据**（`PresetGesturePickerPanelTests.testCloseOnlyEndsTheModalSessionAndKeepsTheWindow`）：
先 `performClose(nil)`、再用**真实按钮** `closeButton.performClick(nil)`，两轮都断言 `choice`
为 nil、窗口仍 `isVisible`；另断言 `isReleasedWhenClosed == false`、`animationBehavior == .none`。
反向变异两条，均 KILLED：

- override 改成 `super.performClose(sender)` → 红在 ⌘W 那一轮（窗口被收起）；
- 摘掉红叉按钮的 target/action 接管 → 红在「红叉把窗口关掉了：模态会话会永远挂着」。
  只测 `performClose` 会把第二场事故整个放过去，所以判据必须走真实按钮。

装机步骤见 §8 第 22 步。

### 10.4 规则表滚轮格图标顶到格子上沿、只剩一半（2026-11-03 用户截图）

**坏法（用户截图）**：规则表滚轮档那一格，图标缩在格子的上沿、被行边框切掉一半，
读法行也不居中。同一轮的轨迹格（`GestureThumbView`）看着正常。

**读码**：`viewFor` 返回的容器先以**零尺寸**创建，子视图加进去之后 AppKit 才把它改成
84×84。滚轮格给图标和读法行挂了 `[.width, .height]` 比例自适应，容器这一次改尺寸
把两者**放大成 168×168**：图标（以 168 的 bounds 居中）正好跨在容器上沿，可见的只有
下半截；读法行宽 168、居中点在格子右缘外。轨迹格同样被放大，但它的画法是锚定左下角
+12 偏移（对齐原版那一格的画风），放大后落在可见象限内的部分和原来一模一样，
所以肉眼看不出来 —— 这也是单格离屏取证全绿、真机却翻车的原因：孤立渲染的白盒直接
是 84×84，**没经历**容器那次改尺寸。探针实测（真 NSTableView 起 rowView）：
容器 (16, 0, 84, 84)、格子被放大成 (0, 0, 168, 168)。

**修法**：滚轮格的格子与读法行都改固定帧、不带 autoresizing（与表里文本框/组合框
同一套钉法）。胶囊取位本来就是纯函数居中，格子回到 84×84 后自然归位。

**判据**（`WheelRuleGestureGlyphTests.testTableHostedThumbKeepsItsCellGeometry`）：
走**生产路径**（`RulesTable.Coordinator` 的 viewFor → 真 NSTableView 起 rowView）再量
帧 —— 重现造一个 84×84 理想容器的那种写法没经历改尺寸，是假绿。断言格子帧仍是
(0, 0, 84, 84)、读法行帧与 `cellLabelRect` 一致，并导 `table-hosted-cell.png` 供人工核对。
反向变异：把 `[.width, .height]` 加回去 → 用例红（帧变成 168×168），改回绿。
