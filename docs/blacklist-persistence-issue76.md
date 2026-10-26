# 黑名单重启即丢（issue #76）—— 启动时那一次幻影迁移

线上 3.2.2 及此前**每一个 3.x** 都有这个问题：过滤页里加进黑名单的应用，重启 MacStroke 之后
名单变空。已修，3.2.3 发布。记录留在这里，是因为根因不在过滤页，而在 `UserDefaults` 的注册表，
回头再动注册表时容易把它请回来。

## 1. 症状与报告

- issue #76（beck023，2026-10-25）：「过滤中使用黑名单模式，添加的应用会在重启后消失，黑名单空了」，
  并补了一句关键观察 —— 和升级无关，**只要重启应用就消失，前几个版本一直这样**。
- 保存那条路本身是好的：偏好页 Apply → `BlackWhiteFilter.blackListText` setter → `filterBlackList`
  写盘，`defaults read` 当场能看到那两条。丢是在**下一次启动**丢的。

## 2. 机制：注册值对读取可见、对删除不可见

启动序列里 `main.swift:56` 的 `registerUserDefaultsDefaults()` 先跑，之后 `main.swift:249` 调
`BlackWhiteFilter.shared.compatibleProcedureWithPreviousVersion()` —— 这一步是 2.x 那坨旧名单
（单键 `blockFilter = "com.a|com.b"`）迁进现在这套名单的原版行为（原版 `AppDelegate.m:239-243`）。
移植版的判据是「旧键有没有值」：

```swift
if let s = defaults.string(forKey: "blockFilter") { ...迁移... }   // 旧写法
```

而 `blockFilter` 这一键被 `registerUserDefaultsDefaults()` 注册成了 `""`（`StorageKey.blockFilter`
进了那张默认值表）。三条 CF 语义叠在一起就成了死循环：

1. `register(defaults:)` 塞进注册域的值，**对 `string(forKey:)` 一样可见** → 判据每次启动都成立；
2. `removeObject(forKey:)` 只删得掉**真正写进磁盘**的那一份，删不掉注册表里的 → 旧键"删了"还在；
3. 于是每次启动都执行一遍迁移：`filterBlackList` 被那份**空名单**重写、模式被按成黑名单
   （2.x 只有黑名单，迁移把 `isInWhiteMode = NO` 一起带过来）。

原版从不注册 `blockFilter`（`MacStroke/Resources/DefaultPreferences.plist` 一共 31 键，`PlistBuddy` 数的，
里面连 `filterBlackList` / `filterWhiteList` / `filterIsInWhiteMode` 都没有），所以同一行判据在原版身上
是无害的 —— 移植时把键加进默认值表，才把这一步变成了每启动必炸。

**引入点**：`da2e3e8`「历史粘贴板修复」（2026-09-18）把 `blockFilter` 加进了注册表；含它的最早 tag
是 `3.0.0` → 3.0.0～3.2.2 每一版都这样，和报告里"前几个版本就这样"对得上。

本机实测（`/tmp/xctstub/filter_restart_test.sh --seed` + `--round`）：装机那份**线上 3.2.2** 吃一份
刚写好的两条名单 + 白名单模式，**第一次启动**就把它清成 `filterBlackList = ( )`、
`filterIsInWhiteMode = 0`。这就是用户看到的症状，不需要任何注入的假状态。

## 3. 修法：两颗钉子，不是一颗

- **钉子一（Storage）**：`blockFilter` 不再进注册表 —— 回到原版 plist 的形状。顺带把那张表从
  `registerUserDefaultsDefaults()` 里提成 `registeredUserDefaultsValues()`，因为「这一键到底注册没注册」
  在用例里靠读 UserDefaults 判不了（见 §4）。
- **钉子二（RuleEngine）**：`legacyBlockFilterValue(in:)` 只认**真写过而且非空**的那一份
  （`string != nil` 且 `!isEmpty`）。钉子一挡的是幻影值，钉子二挡的是"老机器真写过一份空名单"。
  两条都不成立就一个字不动，所以名单和模式都不会再被背着改。
- 迁移动的手顺带收进一份可注入的 `defaults:` 参数（默认 `.standard`），用例才能用私有 suite
  跑真语义而不碰用户自己的名单。
- 名单拆分口径抽成纯函数 `splitListText`：偏好页那两个文本框和 2.x 迁移现在共用同一只手
  （一行一个、空行/纯空白行丢掉、两头去空格、**不按逗号拆** —— 逗号是原版 LIKE 模式的普通字符）。
- 真动手时留一行 `[BlockFilterMigration] 旧键 blockFilter 里迁进黑名单 %d 条…`；没东西可迁一个字不写
  （和"功能没开"那档一样，别把有用的行埋掉）。

其余一律没动：没加设置项、没要新权限、没去掉任何键（`blockFilter` 只是不再有注册默认值，
`StorageDefaults.blockFilter` 作为读回退留着）、过滤页面上和之前一模一样。

## 4. 三条测出来的 CF 语义（写用例时被它们咬过）

1. **注册域在一个进程里是全局的，不是 per-suite**：A suite 调 `register(defaults: ["blockFilter": ""])`
   之后，B suite 和 `UserDefaults.standard` 的 `string(forKey:)` 一起吃到那个 `""`
   （`/tmp/xctstub/scratch_tests/RegLeakTests.swift`）。真机只有 `main.swift` 那一次注册，没有这个
   污染源 —— 所以用例里"这一键存在吗"这类判断必然被上一条用例污染，判据只能落在
   **那张表本身**（`registeredUserDefaultsValues()`）或**后果**（迁移跑没跑）上。
2. `object(forKey:)` 对注册的**空串**返回 nil；但同一键一旦被写过再 `removeObject`，它又改口返回那份
   注册值 —— 于是 `XCTAssertNil(object)` 同样是顺序相关的，不能用。
3. `~/Library/Preferences/<suite>.plist` 直接读文件**不是可信判据**：`set`×3 + `removeObject` +
   `synchronize` 之后，那份文件里还留着已删的 `blockFilter`、且缺刚写的两格（cfprefsd 的快照滞后）。
   判据取 `defaults read` 现值与系统日志，不取磁盘快照。

## 5. 原版对齐

| 事项 | 原版 | 移植版（本轮后） |
| --- | --- | --- |
| 迁移来源键 `blockFilter` | `DefaultPreferences.plist` 里没有 | 同样不注册 |
| 迁移判据 | `BlackWhiteFilter.m:111-121` 读旧键，非空才迁 | `legacyBlockFilterValue` 非空才迁，并显式拒绝幻影值 |
| 迁完 | 落黑名单、删旧键 | 同 |
| 日志 | 无 | 多一行 `[BlockFilterMigration]`（只在这次真动手时） |

## 6. 取证

**新用例**：`Tests/RuleEngineTests/BlackWhiteFilterTests.swift` 7 条（桩件跑法
`FILES=… ONLY=BlackWhiteFilterTests zsh /tmp/xctstub/run_stroke_prefs.sh`）—— 注册空值的旧键不清名单、
真写过的空旧值不清名单、真旧值迁成两条且模式落黑名单并删掉旧键（哨兵重跑证明删干净了）、
幂等、来源键不在注册表上、`splitListText` 口径、四个键名和 `StorageKey` 对齐。全绿。

**反向变异**：`/tmp/xctstub/mut_filter_cases.py` F01–F19（驱动 `/tmp/xctstub/mut_filter.py`）。
结论 **19 条里预期该抓到的 18 条全部抓到、编译红 0、锚点跳过 0**；F19（main.swift 不再调这一步）
表里就声明抓不到 —— MacStrokeApp 不链进桩件二进制，靠 §7 的装机那两趟日志钉。
进度与逐条日志：`/tmp/xctstub/mut_filter_progress_20261026-105212.log`（全表）、
`/tmp/xctstub/mut_filter_progress_20261026-110417.log`（F06 补判据后单跑：抓到，2 条红）、
`/tmp/xctstub/mut_filter_logs/{20261026-105212,20261026-110417}/`。
F06 一开始漏了，原因值得记：`split(separator: "\n")` 默认就跳空段，所以"空段不丢"那个变异体只能靠
**纯空白行**那一档咬住（`"a\n \t\nb"`），补了判据才红。

**全量回归**：`/tmp/xctstub/regress_stroke.sh` 12 步（第 12 步是本轮新加的那套），
**652 用例、0 失败、0 跳过**，日志 `/tmp/xctstub/regress_issue22_110517.log`（11:11:29 完成）。
基线由上一轮的「11 套 645」抬到 652。

**出包哨兵**：`build_app.sh` 第 7 道 —— 装出来的二进制里必须能 `grep -aq BlockFilterMigration`，
否则判定这个包不含本轮修复，直接 `exit 1`。

## 7. 装机真链路（判据一律不问被测对象）

脚本 `/tmp/xctstub/filter_restart_test.sh`（不带参数=只读；写操作要 `--seed` / `--legacy`，
`--restore` 回到起跑前的整域备份 `/tmp/xctstub/filter_real_domain_backup.plist`）。三趟都在**同一台机器、
同一份 seed** 上跑，只差装的那个包：

| 趟 | 装的是 | 结果 |
| --- | --- | --- |
| 反向对照 | 线上 3.2.2（通用包） | seed 的两条 + 白名单模式，**第一次启动**就变 `filterBlackList = ( )`、`filterIsInWhiteMode = 0`；迁移日志 0 行（那份二进制里没这个标签） |
| 正向 | 3.2.3（本机 x86_64 包） | 连起两次，两条名单和 `filterIsInWhiteMode = 1` **都在**；两趟迁移日志都 0 行 |
| 真 2.x 旧值 | 3.2.3（本机 x86_64 包） | 第一次启动 **1 行** `[BlockFilterMigration] … 迁进黑名单 2 条`（喂的是 `"com.legacy.a|com.legacy.b |"`：三段，第二段带尾空格、第三段是空的，按口径出来两条），`blockFilter` 消失、名单两条、模式落黑名单；第二次启动 **0 行**、名单不动 |
| 换线上包再跑一遍 | 线上 3.2.3（通用包，`diff -rq` 与解压出来的那份逐字节相同、`codesign --verify --deep --strict` 过） | 上面「正向」「真 2.x 旧值」两趟结论**逐条相同**：0 行/0 行保名单保模式；1 行/0 行迁两条删旧键 |

数日志时有两个坑，脚本里已经改好并写了注释：只按 `eventMessage` 过滤会数到 `log` 自己的审计行
（它把整条命令含谓词里那串 `BlockFilterMigration` 记进了统一日志，等于每数一次先给自己 +1），
以及 `--last 20m` 是滑动窗口会把第二趟的差值算成负数 —— 现在谓词加 `process == "MacStroke"`、
窗口用 `--start` 钉在本趟开始那一刻。第一版脚本没改之前报的「新增 1 行」就是这个自命中。

装机那一步本机记一条：把线上包放进 `/Applications` 时 `ditto` 被拦（`ditto: …/Contents:
Operation not permitted`，连 `--noextattr --norsrc` 都一样），`cp -R` 正常 —— 同一台机器同一个
目标目录，几分钟前从仓库产物 `ditto` 是通的。所以交接清单里别把 `ditto` 写成唯一路径，
两个都能装，装完都要 `diff -rq` + `codesign --verify` 兜一次。

## 8. 发版与回复

- 3.2.3（线上是 3.2.2，按规矩 +1）：`build_app.sh` 里 `APP_VERSION` 单源，说明 `Changelog/3.2.3.md`。
- 发版走一条 `release.yml` workflow_dispatch（`dry_run=false`），运行
  [40263762084](https://github.com/mtjo/MacStroke/actions/runs/40263762084) 全绿；核对一律用 `gh api`
  （raw 有 CDN 缓存）：tag `3.2.3` 指向 `16d74f1`；release 附件 `MacStroke.zip` 5,124,777 字节；
  release 分支 `AppCast.xml` 第 34 条 `Version3.2.3`，`length` 与附件同值、双签齐、
  `minimumSystemVersion` 13.0、说明页链接指到 release 分支那份 md。
- tap 同步当场手工 dispatch（`mtjo/homebrew-tap` 的 `macstroke-sync`，运行 40264096077），
  之后 `Casks/macstroke.rb` = `version "3.2.3"` / `sha256 3124871a…4b390`，与本机
  `gh release download` 下来的那串 `shasum -a 256` 逐字符相同 —— 三方对齐。
- **回复要点**：已经被清掉的找不回来（旧键在第一次误迁时就删了），请重新加一次；之后重启、升级、
  恢复默认都不会再丢。白名单模式以前会被同一步按成黑名单，一并修了。
  「恢复默认设置」这一条是查过的：`Preferences.resetToDefaults()` 只回写原版 plist 带的那些键，
  三个名单键（`filterBlackList` / `filterWhiteList` / `filterIsInWhiteMode`）和 `blockFilter` 都不在其中，
  所以点它不会清名单 —— 上一轮丢名单的锅本来也不在它。
