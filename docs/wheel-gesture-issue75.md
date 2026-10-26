# issue #75「右键 + 滚轮」这一版做了什么、验到什么程度、以及那份 fork

写于 2026-10-26。起因有两条：一是 3.2.1 那轮的收尾账（任务 #252）里「补完变异/回归」只留了
`/tmp` 下的产物、没落到仓库里；二是 issue #75 关闭后 DemoJameson 留言「我自己写了一版，还修了
一些问题」，维护者回了一句「应该是我理解错了」，这句话得有个交代。

> 口径提醒：本文每条结论都标了它是**实测**、**读码**还是**推断**。装机实测的判据一律取外部
> 观测（位图差值、`defaults read`、系统日志），不取自被测对象自己声明的状态。

## 一、这一版的口径（已上线 3.2.1）

需求原文只有一句：「希望分别添加右键+滚轮上滚和滚轮下滚的触发手势，可以用于快速的切换前后
标签页，或者调整音量等等。」落法：

- 另开**第二条** `.scrollWheel` 事件 tap，与手势捕获那条分开；建出来就是禁用状态，只在起手键
  按着的那一段里 `tapEnable(true)`，手势一结束（含被取消）当场收膛。默认总开关关 = 原版行为。
- 一格算一次动作，且那一格被吞掉（下面的页面不跟着滚）；配成「无」的方向一个事件都不拦。
- 节流：累计够一格、且离上次触发满 0.09 秒才算一次。先记账再过两道闸（不是挡了就丢账）。
- 两方向各配一档：无 / 上一个标签页 / 下一个标签页 / 音量 +1 档 / 音量 −1 档 / 自定义快捷键。
  上滚默认「上一个标签页」、下滚默认「下一个标签页」（`⌘⇧[` / `⌘⇧]`）。
- 音量直接读写默认输出设备的 CoreAudio 标量，一格 ±5%、两头钳住、优先 Main 汇总档 —— 投
  「音量+」多媒体键那条路本机实测命令行进程投不动。
- 触发过滚轮后松手，既不弹右键菜单，也不拿顺手画的半条弧线去匹配规则：一次手势只留一个结果。
- 「绘制手势」录制面板里滚轮掺进来一律不触发，只收轨迹。
- 按住「让位修饰键」（issue #59 那组）时整条滚轮交回前台应用。
- 配置页放在原「右键菜单」页，改名「右键增强」；那份应用列表原样还在，滚轮那组排在它下面。
  一个能力只给一组控件，没有铺「每个软件一行」。

代码接缝（本轮复述一遍，方便下次不用翻提交）：读数与节流是 `EventCapture/WheelGesture.swift`
里的纯逻辑（`WheelGestureParser` / `WheelGestureGate`），状态机在 `CanvasManager`，档位查表与
执行在 `RuleEngine/WheelGestureAction.swift`（`WheelGesturePlan` / `WheelGestureExecutor`），
App 层只做「读偏好 + 递进去」（`main.swift:192-212`）。

## 二、反向变异：39 条，原跑与本轮重跑

### 2.1 先更正 2026-10-25 那一趟的账

那张「39 条里漏 3 条」的结论有两个记账问题，本轮把账摊开重记一遍（证据是
`/tmp/xctstub/mut_wheel_progress_20261025-*.log` 与 `/tmp/xctstub/mut_wheel_logs/<ts>/`，
这两个目录里的东西本轮已经把它们的关键行抄进本文，不再只靠 `/tmp`）：

- **那一趟其实是三次调用，不是一趟。** `02:21:07` 起跑前锚点自检就发现 P5 的锚点在
  `PreferencesView.swift` 里出现 0 次，整趟没跑任何用例；`02:21:34` 跑了 W1–W13 共 13 条；
  `05:10:45` 跑了 W14–W26、P1–P4、P6–P11、S1、S2 共 25 条。**P5 在 10-25 从来没有结果**
  ——它不在任何一次调用里（不是漏判，是压根没跑）。
- **结论行的分母取的是表长，不是实跑数。** `05:10:45` 那条「39 条里预期该抓到的 39 条中漏 3 条」
  里，那趟实际只跑了 25 条，分母是从 `mut_wheel_cases.py` 的条数硬取的。读起来像「跑了 39 条」，
  其实是「跑了 25 条，另外 14 条的结果是上一次调用留下的」。
  已改：`/tmp/xctstub/mut_wheel.py` 现在自己记 `ran`，结论行写成「本趟跑了 N 条（表共 M 条），
  其中预期该抓到的 K 条里漏 …」，分母只算真跑过的那些。

账目更正之后，10-25 原跑**确实成立**的部分是：W1–W26 与 P1–P11、S1、S2 共 38 条有结果
（P5 无），其中 3 条漏 —— P2、P9、P11。漏的三条各自是什么性质的坏，见 2.3。

### 2.2 本轮（2026-10-26）重跑

一趟跑完，不拆次：`python3 /tmp/xctstub/mut_wheel.py`，起跑 `12:15:24`、完成 `13:21:55`，
进度日志 `/tmp/xctstub/mut_wheel_progress_20261026-121524.log`，逐条原始输出在
`/tmp/xctstub/mut_wheel_logs/20261026-121524/`（39 份）。这一趟用的是**当时那张 39 条的表**
（P12/P13 是跑中途才补进表的，Python 进程已经把表读进内存，所以这趟里没有它们；新用例也还没插入，
所以下面 P2/P9/P11 三条仍是漏 —— 这正是预期，补完后的单跑见 2.4）。

- **39 条全跑到了**，P5 这轮有了自己的结果：**抓到**（3 条红，287s）。10-25 那条「漏 3」的账
  现在能对上：跑过 38 条、漏 3 条，P5 压根没跑。
- 漏的还是同三条：P2（102s）、P9（151s）、P11（84s）。**没有新增的漏**，也没有「上一轮抓到、
  这轮反而放掉」的回退。
- 编译红 0 条、锚点跳过 0 条；跑完 `还原核对：全部文件 SHA 回到起跑前`（起跑前那 8 个文件的
  SHA 记在同一份进度日志的第 2 行）。
- 每条都带着一次重新编译跑：走逻辑的两套（`run_wheel.sh`）逐条 `swift build --target EventCapture`
  和 `--target RuleEngine`，各一次，再重链那两个测试可执行文件；走偏好页/落盘的那些
  （`run_rows_fast.sh`）逐条 `swift build --target Preferences` 一次——SwiftPM 顺着依赖图把
  Storage / EventCapture / RuleEngine 一起建掉，所以对本页用例覆盖面一样，它省的只是 9 次
  SwiftPM 起跑开销（脚本头注实测每次 15…25 秒），不是省掉重编。两条路都在每条重链测试
  binary，`run_rows_fast.sh` 还每次把两份 `.strings` 重拷进 `StubResources.bundle`。
  所以每条跑的都是当时的仓库源码，不是上一轮的 `.o`（本轮唯一允许的慢：单条 84–287 秒）。

逐条对照（左列是 10-25 的三趟合并结果，`**没跑过**` 就是 2.1 说的那笔账）：

| 编号 | 坏法 | 10-25 | 本轮 | 本轮耗时 |
| --- | --- | --- | --- | --- |
| W1 | 方向符号整个反过来（上滚当 down） | 抓到 | 抓到 | 26s |
| W2 | 定点行那一档废掉（只认整数行） | 抓到 | 抓到 | 38s |
| W3 | 点增量不折成格（除以 1） | 抓到 | 抓到 | 54s |
| W4 | 注入事件的 timestamp 不退让（照收 0） | 抓到 | 抓到 | 64s |
| W5 | 一格没动也当读数（nil 分支废掉） | 抓到 | 抓到 | 61s |
| W6 | 够一格的门槛废掉（>=0） | 抓到 | 抓到 | 46s |
| W7 | 最小间隔废掉（>=0） | 抓到 | 抓到 | 62s |
| W8 | 换方向不清账（旧余量与新方向相抵） | 抓到 | 抓到 | 42s |
| W9 | 被间隔挡住的那几发连账一起丢 | 抓到 | 抓到 | 52s |
| W10 | reset() 只清账不清节流 | 抓到 | 抓到 | 29s |
| W11 | 上膛条件漏掉「绘制手势录制态」 | 抓到 | 抓到 | 47s |
| W12 | 两处 wheelGate.reset() 一起删（窗口不复位） | 抓到 | 抓到 | 101s |
| W13 | 触发过滚轮仍拿轨迹去匹配 + 回放点击 | 抓到 | 抓到 | 104s |
| W14 | didScroll 第一道闸整个废掉（不看窗口开没开） | 抓到 | 抓到 | 88s |
| W15 | 修饰键让位那条规矩在滚轮上失效 | 抓到 | 抓到 | 108s |
| W16 | 动作没做成也当触发（不问 App 层结果） | 抓到 | 抓到 | 110s |
| W17 | 窗口结束不发收膛 | 抓到 | 抓到 | 106s |
| W18 | 上一个/下一个标签页的键码互换 | 抓到 | 抓到 | 106s |
| W19 | 音量两档方向互换 | 抓到 | 抓到 | 87s |
| W20 | 「无」也投一发键 | 抓到 | 抓到 | 90s |
| W21 | 自定义档没录键也当有键 | 抓到 | 抓到 | 101s |
| W22 | 认不出的偏好值当成「上一个标签页」 | 抓到 | 抓到 | 94s |
| W23 | 音量没动也报「做成了」 | 抓到 | 抓到 | 87s |
| W24 | 音量不钳在 0…1 | 抓到 | 抓到 | 86s |
| W25 | 已经在头顶/脚下就不算做成 | 抓到 | 抓到 | 99s |
| W26 | 先逐声道再问 Main | 抓到 | 抓到 | 102s |
| P1 | 上滚那档下拉摘掉 .disabled | 抓到 | 抓到 | 152s |
| P2 | 上滚那格录的其实是下滚的键（binding 串线） | 漏 | 漏 | 102s |
| P3 | 上滚那格配的其实是下滚的动作（binding 串线） | 抓到 | 抓到 | 146s |
| P4 | 「两个方向都没配」那句黄字常驻 | 抓到 | 抓到 | 233s |
| P5 | 黄字条件用 `\|\|`（只配一个方向也报警） | **没跑过** | 抓到 | 287s |
| P6 | 录入框的可用条件漏掉总开关 | 抓到 | 抓到 | 221s |
| P7 | updateNSView 不再把 isEnabled 递进 NSView | 抓到 | 抓到 | 156s |
| P8 | 灰掉的框还画着那一叉 | 抓到 | 抓到 | 165s |
| P9 | 灰掉的框点击照样进录制态 | 漏 | 漏 | 151s |
| P10 | 灰掉的框文字不褪（还是浓墨） | 抓到 | 抓到 | 88s |
| P11 | 页名回改成「模拟右键」（两个右键页撞名） | 漏 | 漏 | 84s |
| S1 | 滚轮功能默认开 | 抓到 | 抓到 | 96s |
| S2 | 上滚默认档从 1 改成 2（查表整体跑位） | 抓到 | 抓到 | 98s |

读法：W 段（逻辑与状态机 26 条）两趟都是**全抓到**，这一版的识别/节流/执行链没有判据洞；
问题集中在 P 段（偏好页 11 条）的三条，且三条的性质各不相同 —— 见 2.3。

### 2.3 漏掉的三条怎么处置

先说结论：三条里有两条**不是用例弱**，一条是坏法本身无效，一条是环境把判据遮住；只有 P2
是真正的判据洞，本轮补了用例。

**P9「灰掉的框点击照样进录制态」= 等价变异，坏法压根没生效。**
`ShortcutRecorderView` 挡着「不可用还能动」的是三层，不是一个开关：`acceptsFirstResponder`
（`:259`）、`startRecording` 里的 `controlEnabled`（`:363`）、`click(at:)` 里的 `controlEnabled`。
上一轮只删了 `click` 那一层，另两层还挡着，页面行为一点没变 —— 用例全绿是**对的**，
错的是那条变异。本轮把它改成两处一起拆（`click` 与 `startRecording` 的守卫同时去掉），
这才叫真坏法；`ShortcutRecorderClearButtonTests.testDisablingAfterMountReachesTheNSView`
那条状态判据（P7 就是被它抓住的）在改后的坏法上该红。表里那条的注释与 `note` 都同步改了。
**实测**：改完后单跑抓到（2 条红，51s），红的是 `testADisabledRecorderIgnoresClicksAndRefusesFirstResponder`
那两条（`:80` 点击、`:85` 程序侧拉进录制态），见 2.4。

**P11「页名回改成『模拟右键』」全绿 = 桩件只吃英文表，不是判据弱。**
这一条的机制本轮查清了（读码）：`/tmp/xctstub` 桩件进程里 `UserDefaults` 的
`AppleLanguages = ("zh-Hans-CN")`（`defaults read -g AppleLanguages` 实测现值），
`L()`（`Sources/Storage/Localization.swift:109-137`）先按整串找 `zh-hans-cn`、再退到 base `zh`，
两跳都命不中，最后兜底 **en**。也就是说离线那一整套用例从头到尾只验过英文表：打在
`zh-Hans.lproj` 上的变异进不了任何判据，中文表里少一条键、页名跟另一页撞了，离线一律看不出来。
处置没有走「改 `AppleLanguages`」那条路 —— 那是整个进程的本地化，会把同进程里后面跑的其它
用例一起掰档，桩件还会写进用户的偏好域。改成两手：

- 变异表补两条同型坏法：P12 打在**英文**表上（`"RightClickMenu" = "Right-click extras"` 改成
  和 `RightClick` 同一串），用来证明现有那条改名用例真的咬得住；P13 把中文表里的键名
  `"Wheel Gesture down row"` 拼成 `"Wheel Gesture down rowX"`（那一行在中文界面会露出 key 原文），
  现有用例对它仍然无效，专门用来验新增的双表用例。
- 新增 `Tests/WindowManagerTests/WheelGestureStringTablesTests.swift`：不碰 `UserDefaults`，
  直接把 `en.lproj` 与 `zh-Hans.lproj` 两份 `.strings` 当**数据**读出来（`appResourceBundle()` +
  `bundle.url(forResource:withExtension:localization:)`，读不出来就红、不许 skip），逐表验三件事：
  这一页与「模拟右键」页在**两张表里都不同名**并钉住 issue #75 定的那两个名字；段里 16 条
  文案 key 两张表都有、不等于 key 原文、非空；六档动作在同一张下拉里显示成六种串。
  再加一条「中文表 16 条的值必须和英文表那一份不同」，咬的是「把 en 表整段抄进 zh 表」
  这种坏 —— 键在、值也在、非空、也不等于 key 原文，前面四条判据一条都不会红。
  这 16 条 key 的清单现在归 `WheelGestureStringTablesTests.wheelCopyKeys` 一份，页面那组用例
  改成引用同一份，免得两处清单各漂各的。

**P2「上滚那格录的其实是下滚的键」= 真洞，本轮补判据。**
现有 W4 那条（`testRecorderLightsUpOnlyForItsOwnDirection`）两个方向填的是**同一个** keycode，
`$viewModel.wheelGestureUpShortcut` 与 `DownShortcut` 两个 binding 一旦写串，页面画出来的字还是
一模一样 —— 判据看不见任何差别，这是判据设计上的漏洞，不是环境问题。补法沿用 W3 给动作下拉
钉的那套路子：四个互不相同的键，只改一个方向录入，要求「上滚那一行必须动、下滚那一行必须
不动」两条带子同时成立，前后还各放一条带子自检（先证明这一带里确实有字在动）。用例
`testEachDirectionRecorderFollowsItsOwnShortcut()` 插在
`Tests/WindowManagerTests/WheelGesturePreferencesTests.swift` 的 W4 那一组之后。

补一条踩过的坑（**实测**，第一次跑就撞上）：这一对带子只有页高的 2.5%（`0.45…0.475`，1000 高的页
就是 25 行），而 `changedPixels` 为了省时间按步长 2 采样 —— 只把一个字母换掉（⌘V→⌘X，录入框还是
居中排字）采不到 20 个点，**自检那一条会假红**，看着像「录入框没接绑定」其实是带子太窄。
改法是两格的基准串都用光杆 ⌘ + 字母，改动版一律加满四个修饰键（`flags=1966080`，画出来是
⌘⌥⌃⇧V）：整串字形全挪位，采得到、也仍然只动自己那一行。阈值 20 没改，改的是坏法的可见度。

### 2.4 补完之后：单跑这五条

2.3 那三处补完（P2 的新用例插入 / P9 改成两处一起拆 / P12、P13 两条新坏法 + 双表用例），
单跑这五条：`python3 /tmp/xctstub/mut_wheel.py P2 P9 P11 P12 P13`，起跑 `13:27:37`、
完成 `13:33:44`，日志 `/tmp/xctstub/mut_wheel_progress_20261026-132737.log`，
逐条原始输出在 `/tmp/xctstub/mut_wheel_logs/20261026-132737/`。

**结论行原文**：`本趟跑了 5 条（表共 41 条），其中预期该抓到的 5 条里漏 0 条、编译红 0 条、锚点跳过 0 条`。
`还原核对：全部文件 SHA 回到起跑前`。注意分母这一行现在是「跑了 5 条」而不是「表共 41 条」，
就是 2.1 说的记账修复。

| 编号 | 结果 | 抓住它的判据（实测红在哪一行） |
| --- | --- | --- |
| P2 binding 写串 | 抓到（2 条红，54s） | `WheelGesturePreferencesTests.testEachDirectionRecorderFollowsItsOwnShortcut` `:313`（上滚那行没动静，自检先红）与 `:323`（只改下滚，上滚行也跟着改） |
| P9 三道闸一起拆 | 抓到（2 条红，51s） | `ShortcutRecorderClearButtonTests.testADisabledRecorderIgnoresClicksAndRefusesFirstResponder` `:80`（灰着的框点一下就开始录键）与 `:85`（程序侧也不该把不可用的框拉进录制态） |
| P11 中文表页名撞名 | 抓到（2 条红，64s） | `WheelGestureStringTablesTests.testBothStringTablesKeepTheTwoRightClickPagesDistinct` `:64`（zh-Hans 表里那页的名字不是 #75 定的那一个）与 `:66`（zh-Hans 表里两页同名） |
| P12 同一坏法打在英文表 | 抓到（3 条红，111s） | 老的 `WheelGesturePreferencesTests…testTheRenamedPageStaysDistinctFromTheOtherRightClickPage:384` **和**新的双表用例 `:64` 一起红 —— 这条就是用来证明「P11 上一轮全绿是打错靶，不是判据弱」 |
| P13 中文表键名拼错 | 抓到（3 条红，85s） | `WheelGestureStringTablesTests` 三条：`:71`（key 没进 zh-Hans 表）、`:74`（在表里是空串）、`:97`（中文表逐条比那一份里查不到这个键）；走 `L()` 的老用例照旧全绿 |

两点要说白：

- 这一趟只跑了 5 条，**不等于**整张 41 条表现在全抓到。另外 36 条的结果来自 2.2 那趟
  （起跑 12:15:24，比本轮补用例早一个多小时，用的还是当时那张 39 条的表：P12/P13 是跑中途才补进去的，
  Python 进程已经把表读进内存，所以那趟里没有它们）。这 36 条本轮没重跑，
  要拿「41 条全绿」这个口径得再单跑一趟全表（单条 51–287 秒，整趟约一小时）。
- 单跑里 P13 的三条红**全部来自新增那份双表用例**，`L()` 那条老判据一条都没红 ——
  这正是 2.3 里预期要看到的样子：桩件读英文表，所以打在中文表上的坏只有逐张表查键的用例咬得住。

<!-- 2.4 到此；新用例本身跑绿见第三节第 4 套 -->

## 三、全量回归

桩件那套「全量」= `/tmp/xctstub/regress_wheel75.sh`，13 套一次跑完（基线是发版 3.2.2/3.2.3 用的
`regress_stroke.sh` 那 12 套，本轮把远程控制 E2E 加进来当第 13 套，因为 `:236` 那行属性键本轮改了）。
起跑先 `pkill -x MacStroke`：常驻的 MacStroke 在跑时，它自己那条 HID 层监听会吃掉注入进来的键，
远程控制键盘那几条必红，那是**环境红**不是代码红。

| # | 这套跑什么 | 实跑的桩件脚本 |
| --- | --- | --- |
| 1 | SelectionPopup 模块（181 条） | `run.sh` |
| 2 | 划词气泡偏好页（18 条） | `run_prefs.sh` |
| 3 | 滚轮触发：逻辑（读数/节流/状态机/动作查表） | `run_wheel.sh` |
| 4 | 滚轮触发：偏好页行 + 落盘 + 清除按钮 + **双表文案**（2.3 那两条新用例在这一套里，FILES 四份） | `run_rows_fast.sh` |
| 5 | 截图注解（含斜体） | `run_shot.sh` |
| 6 | 中文斜体单测 | `run_italic.sh` |
| 7 | 关于页「已跳过的版本」这一行 | `run_skipped.sh` |
| 8 | issue #22 逻辑：CursorTargetTests（29 条） | `run_stroke_target.sh` |
| 9 | issue #22 偏好页：落盘 7 + 像素 5 | `run_stroke_prefs.sh` |
| 10 | Storage：stroke target 那两把键（3 条） | `FILES=StorageTests.swift run_stroke_prefs.sh` |
| 11 | CanvasManager：抬手点那一处坐标翻转（23 条） | `run_canvas.sh` |
| 12 | issue #76：黑名单幻影迁移（7 条） | `FILES=BlackWhiteFilterTests.swift run_stroke_prefs.sh` |
| 13 | 远程控制 E2E（含本轮改的 JPEG 属性键那条） | `FILES=RemoteControlServerE2ETests.swift run_rows.sh` |

计数只认每套自己打的「用例数：N 跳过：S 失败断言：F」那一行，不把「跳过」算进绿的分子；
桩件自带那 6 条自证 FAIL（`check.swift`）一律滤掉，它们本来就是「这一条必须红」。
红的一律逐条归到「环境红（权限/常驻 App/安全输入）」或「代码红」两类，写明是哪一个 case、
哪一行断言。环境判定同时读 `kCGSSessionSecureInputPID`，别只看屏幕锁没锁。

**本轮 13 套实跑（2026-10-26 13:34 起跑、13:49:41 完成，日志 `/tmp/xctstub/regress_issue75_20261026-133433.log`）**：
`swift build` rc=0，13 套全跑完，**合计 667 条、跳过 1 条、失败断言 0 条**。

| 套 | 用例数 | 跳过 | 失败断言 |
| --- | --- | --- | --- |
| 1 SelectionPopup | 181 | 0 | 0 |
| 2 划词气泡偏好页 | 18 | 0 | 0 |
| 3 滚轮逻辑（两份二进制：`EventCaptureTests/WheelGestureTests` 29 + `RuleEngineTests/WheelGestureActionTests` 19） | 29 + 19 | 0 | 0 |
| 4 滚轮偏好页像素 + 落盘 + 清除按钮 + **双表文案**（本轮新增的三条用例都在这一套里） | 36 | 0 | 0 |
| 5 截图注解（含斜体） | 274 | 0 | 0 |
| 6 中文斜体单测 | 7 | 0 | 0 |
| 7 关于页「已跳过的版本」 | 17 | 0 | 0 |
| 8 issue #22 逻辑 CursorTargetTests | 29 | 0 | 0 |
| 9 issue #22 偏好页（落盘 7 + 像素 5） | 12 | 0 | 0 |
| 10 Storage 那两把键 | 3 | 0 | 0 |
| 11 CanvasManager 坐标翻转 | 23 | 0 | 0 |
| 12 issue #76 黑名单幻影迁移 | 7 | 0 | 0 |
| 13 远程控制 E2E | 12 | **1** | 0 |

唯一这一条红/跳的归因，逐条写清：

- **跳过 1 条 = `RemoteControlServerE2ETests.testMirrorFramesFollowTheSwitch`，环境跳，不是代码红。**
  桩件进程没有「屏幕录制」授权（TCC 归的是终端），服务端只会回 `noScreenPermission`，
  用例自己在 `:189-191` 走 `XCTSkip`。**代价要说白**：本轮改的 `:236` 那行 JPEG 属性键就住在这条用例里，
  所以它这轮**没有被真跑到**（4.2③ 的支撑是探针实测，不是这条用例转绿）。
  要让它跑起来，得给跑桩件的那个终端补屏幕录制授权，或者在装机环境里跑这一套。
- **没有环境红。** 起跑前 `pkill -x MacStroke`、跑完 `pgrep -x MacStroke` 仍为空，
  所以「常驻 App 那条 HID 监听吃掉注入键」这个已知的键盘用例干扰源这轮不存在；
  会话字典实测 `kCGSSessionOnConsoleKey=1`、`kCGSSessionSecureInputPID=nil`
  （探针 `/tmp/xctstub/session_probe.swift`），也就是屏没锁、没有安全输入占着键盘 ——
  `testTypeAndKeyReachTheEventStream` 那类键盘用例的绿是真的绿，不是被环境掩盖成的绿。
- 远程控制这一套是**单跑**：已记的口径是「连跑必偶发红 1–2 条」，本轮只在第 13 套跑了一次，
  没做连跑压测，所以「偶发」这一项本轮没验。
- 第 4 套的 36 条按文件拆开是：`WheelGesturePreferencesTests` 9 条（含本轮新加的
  `testEachDirectionRecorderFollowsItsOwnShortcut`）+ `WheelGestureRowsTests` 7 条（落盘）
  + `ShortcutRecorderClearButtonTests` 18 条 + `WheelGestureStringTablesTests` 2 条（**本轮新增的双表文案用例**）。
  四份文件都编进了这一套的二进制（`run_rows_fast.sh` 的 `FILES` 四份，`mut_wheel.py` 的
  `ROWS_FILES` 同步加了第五行注释说明为什么必须带它）。

## 四、与 DemoJameson fork 的对照

他 fork 的是本仓库（`mtjo/MacStroke`，Swift 移植版），分支 `feature/right-button-impulse-gestures`
的分叉点是我们的 `734e1afea`（3.1.9）。也就是说他基于 3.1.9 做了一版并行实现，
我们这边此后走到 3.2.0 / 3.2.1 / 3.2.2 / 3.2.3，两边各走各的。他一共 13 条提交，动产品代码的 6 条。

### 4.1 产品侧六条修复逐条判定

判定口径：**A** = 我们 main 上有同一缺陷（症状真实、代码对得上）；**B** = 我们没有那条路径，
他的修复对我们是空转；**C** = 他自己架构带出来的问题，我们没有对应代码。每条的「我们这侧」
都按 `git show HEAD:<path>` 实读核过行号（重跑变异期间不许读工作区源码）。

| commit | 他在修什么 | 判定 | 我们这侧的实证 |
| --- | --- | --- | --- |
| `7e0614c` | 录制手势时无视「关闭鼠标路径」 | **A** | `Sources/EventCapture/CanvasWindow.swift:82` 的 `draw` 一看 `disableMousePath` 就 `return`，没有任何录制态例外；`CanvasManager.swift:162` 的 `isRecordingGesture` 是个裸 var，压根没传给画布；录制面板确实画在这层遮罩上（`GestureRecordFlow.swift:19-45` → `CanvasManager.swift:592-606`）。症状：勾了「关闭鼠标路径」的人点「画新触发器」是**盲画**。 |
| `2b13b35` | 关掉最后一个窗口不再退出常驻 App | **B**（且第三层有害） | 我们是 `.accessory`（`main.swift:50`）+ `LSUIElement`（`build_app.sh:244`），全仓没有 `applicationShouldTerminateAfterLastWindowClosed`/`applicationShouldTerminate` 的实现，AppKit 在 delegate 不实现时不因末窗关闭而退出。他第三层那种 `applicationShouldTerminate` 一刀切会连带砍掉我们菜单 Quit（`main.swift:933`）、二次启动让位（`main.swift:71`）、Sparkle 装更新（`main.swift:817`）。 |
| `d1d6acc` | 规则页三个文本框 | **A**（宽度溢出 + 边打字边选 App）／**C**（25pt 居中自绘 cell） | 列宽 `RulesTable.swift:172-179` 是 98 / 138.85 / 221，就地文本框写死 `:299-306` 的 100 / 160 / 400 —— 备注框比它那一列宽出近一倍，800pt 偏好窗（`Preferences.swift:787`）下必然被列边界裁出一条。另外我们 `PreferencesView.swift:802`「选择运行中的 App」前没有 `commitActiveFieldEditor()`，而 `RulesTable.swift:199-206` 的 `reloadIfNeeded()` 又被 `isEditing` 挡死 → 边打字边选 App，格子留旧文本、后提交的输入能盖掉刚选好的 filter。 |
| `916ef11` | 瞬时手势直查规则（不每次建引擎） | **C** | 那是给他的 `ImpulseGesture` 每格滚轮做按 App 匹配才需要的省法（`RuleStore.swift:139-152`）。我们滚轮只读轴 1、动作是偏好里钉死的五档（`main.swift:200-212`），不读 bundleID、不建引擎，没有这条路。 |
| `c5db0bb` | mouse-down 时捕获前台应用（latch） | **C**（动因自造，但记一笔真实分歧） | 他要在 down/up 都用 `capturedBundleID`，而「第二格打到 MacStroke 自己」是他 `b162b9b` 引入的瞬时匹配带来的。我们 `CanvasManager.swift:290`（down 读一次，管黑白名单闸门）与 `:349`（up 再读，管匹配与回放）读两次 —— 这**是**原版语义（`MacStroke/AppDelegate.m:285` 与 `:380` 同样读两次），且我们的画布是 borderless + `orderFrontRegardless`、没覆写 `canBecomeKey`（`CanvasWindow.swift:116-135`），不会把前台换成我们自己。残余分歧：一次按压内部前台真换了（#22 的 0.6s 回焦正落在半途、或外部 App 抢焦点），会出现「闸门按 A 放行、回放按 B 落地」，这条原版同病。跟不跟是取舍，不是补漏。与 #70 无关：#70 是 Toast 抢焦（`Toast.swift:233`），latch 救不了。 |
| `a3605bf` | 历史粘贴板列表聚焦时 Esc 关窗 | **A**（有机证） | 运行时探针（本机 SDK）确认 `NSTableView` 自己实现了 `keyDown:` 与 `cancelOperation:`，父类链上 `NSControl`/`NSView`/`NSResponder` 都没有 `cancelOperation:` → 表格拿到焦点时 Esc 在表格这一环就被吃掉。我们用的正是裸 `NSTableView()`（`HistoryClipboardListWindowController.swift:174`），关窗全靠 `:629-632` 那个 `EscClosesView.cancelOperation` —— 那段注释写着「Esc pressed while the result list … travels the responder chain here」，**注释描述的这条路被表格吃掉了**。默认焦点是搜索框（`:211`），所以症状是「面板刚开 Esc 好用，点过任意一行后 Esc 再也不关窗」。 |

**值得从他那儿捡回来的三件**（都不碰口径，`7e0614c` 与 `d1d6acc` 的实现细节要换成我们自己的通道）：

1. `a3605bf` 的 `EscForwardingTableView`（15 行，`keyDown:` 里认出 Esc 就 `nextResponder?.tryToPerform(cancelOperation)`）。症状真实、我们那文件与他的基线逐字相同、补丁不依赖他任何架构。
2. `7e0614c` 的**结论**：录制态必须无视 `disableMousePath`。他走 `UserDefaults` 裸键 `macStrokeRecordingGesture`，绕过我们的 `StorageKey` 那套（`Storage.swift:237-240`）——实现改成给 `CanvasView` 一个显式属性或由 `CanvasManager` 直接推给 `canvasWindows`。默认值 `disableMousePath = false`，改了不动默认行为，不破 parity 铁律；但要记一句「原版 `CanvasView.m:35` 同样盲画」，这是主动偏离原版。
3. `d1d6acc` 的两处：**文本框宽度跟着列宽走**（治裁黑块）+ 选 App 前先 `commitActiveFieldEditor()`（治格子留旧文本）。他的 25pt 垂直居中自绘 cell 不采纳 —— 他先改框高才需要居中，我们没有这个前提，且自绘 cell 会绕开 `NSTextField` 原生选中/编辑细节，风险不对称。

参考知识两条（不算修）：`WheelAxisMapping` 记的 macOS 对 Shift+竖滚「换轴再翻符号」的实测语义、`InjectedEvent.tag` 防自捕获回环 —— 将来做水平滚轮或改注入路径时先读一眼。

**没跑过的就不写实测**：① 我们包里末窗关闭是否真会退出（本轮没启动 App）；② 盲画与 Esc 不关窗的装机复现（依据是「文件与 3.1.9 逐字相同」+ SDK 运行时探针，不是按鼠标）；③ 原版 OC 的对应行为只读了源码。这三件都归入下面的待办，不混进上面的判定。

### 4.2 方法学三条：他指出的坑，我们身上有没有

先摆一个把前提改掉的事实（实测）：**本机不是 Retina**。`NSScreen` 的 backing scale = 1.0
（1920×1080），800×500 pt 的视图 `bitmapImageRepForCachingDisplay` 出来就是 800×500 px，
历史产物 `/tmp/macstroke-screenshot-check/bar-mosaic.png` 也是 800×500。所以「Retina 上点/像素
错位」这一类在我们这台机器上是**潜伏**，不是现行 —— 判据不能按「同一台机器所以正在错」写。

① 点坐标直接当像素坐标用（判定：潜伏，值得修）。他的改法是新增 `Tests/ScreenshotTests/OffscreenSampling.swift`，
用 `pointScale = pixelsWide / size.width` 换算。我们对应处有三处把视图点坐标直接喂 `colorAt`：
`Tests/ScreenshotTests/ScreenshotRenderTests.swift:790`（那条函数的注释写着「像素坐标是左上原点，
和视图（flipped）一致，所以能直接用视图坐标取点」—— 1x 下成立，2x 下整句作废）、
`ScreenshotModeTests.swift:1043`、`ScreenshotMagnifierTests.swift:353`。另外三处 `throw XCTSkip`
会在他那种机器上把整批判据关掉：`ScreenshotAnnotationTests.swift:34`、
`ScreenshotToolPanelTests.swift:340`、`ScreenshotRenderTests.swift:525`。
生产代码自己是按 scale 出图的（`Sources/Screenshot/ScreenshotAnnotation.swift:775-779` 写明了），
所以 2x 上错位是必然。**例外**：`ScreenshotAnnotationEditTests.swift:980/1034/1080/1126/1273`
已经在用 `pixelsWide / bounds.width` 换算，这个文件比他的基线更稳。
只采纳「点→像素换算 + 不许静默 skip」；**不采纳**他那个 `renderOneToOne()` 全面替换 `cacheDisplay`
—— 那会让离屏出图与真机 2x 的出图不再同构，而 `ScreenshotAnnotationEditTests` 的像素级判据
正是靠系统出图。

② 透明像素与写死的绝对亮度（判定：现行，两处都该修）。
`Tests/WindowManagerTests/ShortcutRecorderAppearanceTests.swift:71` 与他改前逐字相同（点坐标取样），
`:94` 更糟：`colorAt(x: 6, y: rep.pixelsHigh / 2)` 一行里 x 是点、y 是像素。透明像素经
`.deviceRGB` 读成 (0,0,0)，于是 `:29`/`:46` 两条 `XCTAssertLessThan(color.redComponent, 0.5)` 是虚过。
打码格那档：`ScreenshotRenderTests.swift:427-428` 写死 `> 0.6` / `> 0.28`，面积下限 `:441-442`
是 `dim >= 150` / `solid >= 100`；实测导出图条子底色亮度 **0.25**，离 0.28 只剩 0.03，
外观一翻档就可能自己长出一片同档灰。**采纳**「阈值锚在条子自身底色」，**不采纳**他把
150/100 降到 75/60 —— 1x 下那是净削弱判据约一半（几何上限约 122 个点，原阈值本来就贴着上限）。
顺带：我们已有「数墨迹前先查 alpha」的惯例（`ProximityLockPreferencesTests.swift:238`、
`SkippedUpdateRowTests.swift:116`），这颗录入框用例是唯一的漏网者。

③ `kCGImagePropertyWidth`（判定：结论对、前提错）。他的 commit message 说「这个常量不存在」——
不成立：`$(xcrun --show-sdk-path)/System/Library/Frameworks/ImageIO.framework/Headers/CGImageProperties.h:836`
就声明着它（`IMAGEIO_AVAILABLE_STARTING(10.13, 11.0)`，值就是 `"Width"`），Swift 侧能编译。
但**结论照收**：按我们自己的编码路径（`Sources/RemoteControl/RemoteScreenCapture.swift:74-84`，
`CGImageDestination` + `public.jpeg` + 只塞 `kCGImageDestinationLossyCompressionQuality`）产出的 JPEG，
属性字典里只有 `PixelWidth/PixelHeight/Depth/ColorModel/ProfileName/{Exif}/{JFIF}`，**没有 `Width` 这个键**。
本轮用只读探针复算了一遍（`/tmp/xctstub/jpeg_props_probe.swift` → 输出存档 `/tmp/xctstub/jpeg_props_probe.log`）：
编码配方逐字照搬生产那段，输入用内存里造的 320×180 图（不抓屏，所以不需要屏幕录制授权），
打出来的顶层键就是上面那七个，`kCGImagePropertyWidth` 的字面值确认是 `"Width"` 而这份图里没有它。
所以 `Tests/RemoteControlTests/RemoteControlServerE2ETests.swift:236` 那条
`XCTAssertNotNil(properties[kCGImagePropertyWidth])` 一旦走到就必红。它前面是 `:189-191`
的「无屏幕录制授权就 `XCTSkip`」，本机这条一直是跳过状态，所以这颗雷从没引爆过。
改法就是一行：换成 `kCGImagePropertyPixelWidth`（本轮已改）。**这条改动没有跑绿记录**：
它住在 `testMirrorFramesFollowTheSwitch` 里，而那条用例在离线桩件里必跳（测试进程没有屏幕录制授权，
第三节第 13 套实跑就是 `跳过：1`），装机的屏幕录制授权归的是 App 不是终端。
支撑只有两样，都写明白：① 探针 `/tmp/xctstub/jpeg_props_probe.swift` 按我们自己的编码路径
（`CGImageDestination` + `public.jpeg`）产出一份 JPEG，属性字典里 `PixelWidth` 在、`Width` 不在；
② 读码确认改动前后走的是同一个字典。所以这是**推断级**的「改了就会绿」，不是实测。

### 4.3 两套方案的结构差异，和那句「理解错了」

同一句需求，两种落法。区别不在「能不能切标签页」——两边都能——在**这件事算不算一条手势**。

| 这一处 | 我们（3.2.1） | 他（impulse 分支） |
| --- | --- | --- |
| 滚轮的身份 | 独立的一组偏好（`wheelGestureUp/DownAction` 等 5 个键），不进规则 | 进 `Rule`：新增 `impulse` 字段，和画出来的轨迹并存于同一张 `rules.json` |
| 能配的动作 | 五档预设 + 一个自定义快捷键录入框 | 规则的全部动作类型（快捷键 / 脚本 / 打开 / 菜单…），还有备注气泡、单条启用、持续触发 |
| 按应用配 | 不支持（全局两档） | 支持：走规则自带的 `filter`，`match(impulse:bundleID:)` 每次现读 |
| 方向 | 上、下两档 | 上、下、左、右（tilt）四档，另把中键 / 侧键单击也算成手势 |
| 监听挂在哪 | **另开第二条 tap，只收 `.scrollWheel`，建出来就禁用**，只在按住起手键那段里上膛 | 把 `.scrollWheel` 加进主 tap 的事件掩码，常驻收事件 |
| 节流 | 够一格 **且** 离上次满 0.09 秒（两道闸，先记账再过闸） | 只累计够一格（`wheelAccumulatorY`），没有时间闸 |
| 附加能力 | 音量两档直接走 CoreAudio 标量 | 平滑滚动 `SmoothWheelAnimator`（586 行，README 里注明借自 Mac Mouse Fix） |

两条值得单独说的：

- **主 tap 加滚轮掩码这件事有代价。** issue #43 / #68 咬过的延迟热路径就在那条 HID 回调上，
  触控板一秒能进上百发。我们这版之所以另开一条常关的 tap，就是为了让「没开这个功能的人」
  识别耗时与延迟一个字都不变（Changelog 3.2.1「关掉是关到根上」那条）。他那边只要分支在，
  滚轮事件就一直进回调。这一点上是我们的口径更严，不是他做错——但他的方案确实要多付这一笔。
- **他没有时间闸**，靠纯累计。自由轮和触控板惯性下，「滚三格」就是连切三个标签页；我们的
  0.09 秒那道闸会把一次快速拨动压成有限次。两种都说得通，差别要写出来，别让人以为我们这条
  是凭空多的。

至于「理解错了」这句话，从需求文本看没有理解错：`分别添加右键+滚轮上滚和滚轮下滚的触发手势`
——两档独立、各配一档，我们这版正是照这个做的。真正**没做到他那一层**的是两件事：
一是**按应用**配（在浏览器里切标签页、在播放器里调音量这种组合我们给不了），二是**动作面**
只有五档而规则动作有整套。这两件事是当年「一个能力只给一组控件、默认等于原版行为」这条口径
换来的代价，不是 bug。若要往他的方向靠，代价是要把滚轮那一格并进规则表（新增一种「签名」类型，
连带规则页就地编辑、预设选择器、导出导入格式都要跟着改），那是一次改版而不是补洞。

顺带一条**别照抄**：他的 `ImpulseGesture` 把 `leftClick` / `rightClick` 也算成瞬时手势，
意思是按住起手键时再点一下左键能触发规则。这与我们 issue #12 那条「手势按住期间吞掉左键单击」
和原版的口径直接冲突——原版按住右键期间那颗左键是被吃掉的，不是被当成一次触发。真要吸收
他的思路，得先把这两个口径理平。

### 4.4 一条必须钉住的口径分歧：同一批 CG 字段，两边注释的符号相反

两边读的是**同一批字段**（`scrollWheelEventDeltaAxis1` / `FixedPtDeltaAxis1` / `PointDeltaAxis1`，
他那边 `EventCapture.swift:380-384`，我们这边 `WheelGesture.lineDelta`），但注释给出的物理约定相反：

- 我们（`Sources/EventCapture/WheelGesture.swift:55`）：「正数 = 朝屏幕方向推那一格（上滚）」，
  于是 `lines >= 0 ? .up : .down`。
- 他（`Sources/GestureEngine/CanvasManager.swift` 的 `consumeWheel` 与 `WheelAxisMapping` 开头那段实测）：
  「roll up, no Shift : deltaY = -1」「Positive physical delta = rolled toward the user (down)」，
  于是 `steps > 0 ? .wheelDown : .wheelUp`。

同一颗滚轮、同一次物理动作，两份文档不可能都对。需要注意的是**我们这条用例钉不住它**：
`testRealWheelEventSignMeansUp` 是拿 `CGEvent(scrollWheelEvent2Source:… wheel1: 3)` **构造**事件再读，
它验的是「我们的算式对自己喂进去的数一致」，不是「真实一次上滚在字段里是正还是负」。

我们这条约定的证据其实在**注入侧**，而且仓库里有三处独立互相咬合（本轮逐处读码核对）：

1. `Sources/Screenshot/ScreenshotScrollCapture.swift:279-281`：要「向下滚」得把 `wheel1` **取负**再投
   （`wheel1: -Self.wheelUnits(points:)`，points 为正 = 向下）—— 长截图真链路那趟（滚到页尾、拼接出图）
   吃的就是这条，方向错了整张长图就废了。
2. `Sources/RemoteControl/RemoteClickExecutor.swift:109-118`：协议里 dy 为正 = 「手指往下划、看到更靠前的
   内容」，这里**不翻号**直接 `wheel1: delta.y` —— 也就是正号 = 往回（上）看，和第 1 条同一侧。
   这条在真机触屏那趟验过。
3. 两处都是 `.cgSessionEventTap` 投出去、由前台 App 自己按 axis1 消费 —— 而真实滚轮走的是同一条
   「HID → WindowServer → App 读 axis1」的管子，所以**消费侧的符号读法对真事件和注入事件是同一套**。

三处合起来支持我们这一版的映射；他那边没有对应的实测记录，其 commit 里那句
「roll up, no Shift : deltaY = -1」在这台机器上没有留下可复算的产物。**剩下没证的一环**是物理那一下：
标准鼠标「向上推 = 看更早内容」按上面第 3 条就是正号，但触控板/妙指开了「自然滚动」时，翻转发生在
哪一层（驱动 / WindowServer / AppKit）我们没测过 —— 那一档决定「两指往上推」算上滚还是下滚。
判定按「分歧已登记、我们这版有三处注入侧背书、离线判据不足以定自然滚动那一档」写，不当成谁的 bug。

要补上最后一环只需一次手测：`/tmp/xctstub/wheel_sign_probe.swift`（已编好 `wheel_sign_probe`）
挂一条 `.listenOnly` 的 `.scrollWheel` tap，只读不吞，把三个字段和 Shift 同屏打出来。
它要「辅助功能」授权，而弹窗记在发起进程上，所以**必须在「终端」App 里跑**（本会话的 shell 里跑会卡在授权上）：

1. 打开「终端」，粘贴执行：`/tmp/xctstub/wheel_sign_probe 20`
2. 提示开始后的 20 秒里：先**向上推**滚轮 3 格，停一秒，再**向自己方向拉** 3 格；用触控板就
   先两指**上推** 3 下、再**下拉** 3 下（两种都试最好）。
3. 把输出整段回贴。判据只看一件事：哪一种物理动作对应 `DeltaAxis1 > 0`。
   若「向上推」给正 → 我们这一版对，他的注释错；若「向自己拉」给正 → `WheelGestureReading.init`
   那行 `lines >= 0 ? .up : .down` 要翻，而第 4.4 节第 1、2 条那两处注入侧证据也必须重跑一遍才敢翻。
   退出码 2 = tap 建不起来（授权没给到终端）。

**收尾（2026-10-26）**：这一关不再要用户跑，口径按现状定（见 6.1 第一条）。上面三步留档，
只有将来收到「方向反了」的实际反馈时才捡回来。

## 五、这一轮顺带查出来的、我们自己的两处口径缺口

### 5.1 滚轮那一下没过「手势归给光标下的窗口」

issue #22 那套归属判定（`CursorTarget.attribute` → `StrokeRouter.execute` + `SystemFocusControl`）
在全仓库只有**一个**调用点：`Sources/MacStrokeApp/main.swift:1093`，画轨迹那条路。滚轮这条路
（`main.swift:200-211`）是 `wheelGestureExecutor.fire(...)` 直接投键，`ActionExecutor` 内部
不碰焦点（全文件只有 `:114` 一处提到 focus，且是注释里说的 `typeSting()` 那条打字路径）。

后果是**可复现的口径不一致**：开了「手势打到光标下的窗口」的人，画一笔轨迹的动作会先落到
光标下那扇窗的主人，而按住右键滚一下切标签页仍然打在**当前前台**。两扇 Chrome 窗、光标停在
没聚焦的那一扇上时，画轨迹切的是光标下那扇，滚轮切的是有焦点那扇。读码结论，未装机实测
（要两扇同类窗口 + 焦点不在光标下那扇，装机验证得占一段时间）。

他那边不存在这个问题，因为 impulse 复用 `performRule`，而 `performRule` 是规则动作的同一扇门。

### 5.2 桩件跑取证时读的是英文文案表，中文表从来没被断言过

`Sources/Storage/Localization.swift:109-137` 的 `L()` 按 `UserDefaults.standard` 的
`AppleLanguages` 找表：先原样小写（`zh-hans-cn`），再取 base（`zh`），都不中才兜底 `en`。
桩件资源包里只有 `en.lproj` 和 `zh-Hans.lproj` 两档，而本机 `AppleLanguages = ("zh-Hans-CN")`
——两跳都命不中，于是**测试进程里 `L()` 一直返回英文值**。

这条直接解释了 10-25 那轮变异 P11 的「漏」：变异打的是 `zh-Hans.lproj/Localizable.strings`
（把 `"RightClickMenu"` 改回「模拟右键」），而那档表压根没人读，所以全绿不是判据弱，
是**打错了靶**。同一个原因下，`testTheRenamedPageStaysDistinctFromTheOtherRightClickPage`
里那 16 条「key 都进了文案表」的断言，实际验的一直是英文表。

处置的两手（补变异条 + 双表用例）写在 2.3，单跑咬住它的记录见 2.4，用例本身跑绿见第三节第 4 套。
补一句口径：这条洞不只影响 issue #75 那一页 —— 凡是走 `L()` 的离线判据，历史上验的都是英文表，
中文表里的漏键、撞名、值等于 key 原文，离线一律看不出来。本轮只把滚轮这一段的双表判据补上，
其余页面的中文表判据没铺（那是另一件事，别在这份文档里假装已经做了）。

## 六、这一轮刻意没做的事

写下来免得下次又当成新发现重查一遍。

- **没发版，也没回复任何 issue。** 本轮动的只有测试与文档（加 1 条页面用例、1 个新文案表用例文件、
  1 行 E2E 断言的属性键），产品代码一行没改，用户侧没有可感知的变化，不值得为它出一个版本。
  线上仍是 3.2.3。
- **41 条变异表没有整趟重跑。** 补的三条只在单跑里验（2.4），另外 36 条的结果来自补用例之前那趟
  （2.2）。整趟约一小时，本轮没花；下次动到滚轮这段实现时顺手跑一遍就行。
- **4.1 里判定「值得捡回来」的三条没动手。** 那是别人的 fork，判据只是读码 + 一条运行时探针，
  没装机复现过；要捡也得单独起一轮，按我们自己的取证套路重做用例，而不是直接抄他的 diff。
- **5.1 那条口径不一致没修。** 修法要动 `main.swift` 里滚轮那一路的投递（先过 `CursorTarget.attribute`
  再 fire），影响面是「开了 #22 的人滚轮切标签页打哪扇窗」——这是行为变更，不是修 bug，
  得先定口径（要不要和画轨迹一致、默认值跟谁）再动。
- **4.4 那条符号口径只剩终端手测这一关没过。** 探针 `/tmp/xctstub/wheel_sign_probe` 已经编好，
  要用户在终端里跑（TCC 授权归终端），三条步骤写在 4.4。
- **同一类拦路虎还有一处**：4.2③ 那行 JPEG 属性键的改动，要靠给终端补「屏幕录制」授权才能真跑到
  （它所在的 `testMirrorFramesFollowTheSwitch` 是第 13 套里唯一那条跳过）。本轮没动 TCC。

### 6.1 收尾（2026-10-26）：上面六条由 mtjo 验收通过，按现状关闭

别再当新发现重提一遍。逐条落到什么状态：

- **4.4 的符号口径不再等终端手测。** 判据维持现状（`WheelGesture.lineDelta` 正数 = 上滚，
  `lines >= 0 ? .up : .down`），依据是 4.4 里那三处注入侧背书加上装机使用没有方向反馈。
  探针步骤留在 4.4，将来真收到「上滚成了下滚」这类反馈再跑那一次手测。
- **4.2③ 的 `:236` 接受「推断级」。** 不为它去补屏幕录制授权；改动本身保留 —— 换成
  `kCGImagePropertyPixelWidth` 在任何机器上都不会比原来更坏（原来的键压根不在这条编码路径的产出里）。
- **41 条变异表整趟不重跑。** 下次动到滚轮这段实现时顺手跑，2.1 那笔 `ran` 记账已经能保证
  分母不撒谎。
- **4.1 判定「值得捡回来」的三条不捡。** 判定与实证留在 4.1，真要捡按那里末尾的口径单独起一轮，
  不抄他的 diff。
- **5.1 维持现状，并从「缺口」改记为「口径」**：滚轮那一格不打给光标下的窗口，只打当前前台。
  以后读码读到这里的，别当缺陷重报；要改成与画轨迹一致属于改版，得先定默认值与开关归属。
- **确认不发版、不回 issue**，线上停在 3.2.3。
