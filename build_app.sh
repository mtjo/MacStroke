#!/bin/bash
set -e

APP_NAME="MacStroke"
APP_DIR="./${APP_NAME}.app"

# 版本号要接上原版的发布线：release 分支 appcast 最新条目是 2.0.5，移植版直接跳到 3.0.0，
# 用大版本区分 Swift 这条代码线（不再用 2.1.x，避免和 ObjC 版的小版本序列混在一起）。
# 若低于 appcast（例如写死 1.0.0），Sparkle 会把另一条代码线的 2.0.5 当成「有新版本」，
# 用户点更新就会把本机移植构建覆盖回 ObjC 版。发新版只改这一行，主程序与扩展共用。
# CFBundleVersion 与 MARKETING 同值，沿用原版 project.pbxproj 的做法。
#
# **只跟着线上版本走，别在装机来回之间一路加**：线上（`gh release view --json tagName` 拿到的那串）
# 是 3.2.2（2026-10-26 发的，issue #22 那一轮），这一轮要发的就是 3.2.3（issue #76 黑名单不落盘）。
# 早先本机装过 3.2.1/3.2.2/3.2.3 那几号，是「每改一轮就加一个」加出来的，不是三个版本 ——
# 一轮里改坏了重打一次包也加一号，用户手上就成了「版本号涨了但功能没变」。
# 规矩：一轮功能 = 一号，装机调试期间反复覆盖同一个号，验收通过才由 release.yml 真发。
# 3.2.3 这一号是 issue #76 那一轮的；同装机调试期间再改再包，**还是这一号**。
APP_VERSION="3.2.3"

# 最低系统：Package.swift 的部署目标是 .macOS(.v13)，二进制 minos 就是 13.0。
# 必须同时写进 Info.plist 和 appcast 的 sparkle:minimumSystemVersion，否则低于 13 的
# 机器上要么内核直接拒绝启动（提示难懂），要么用户点更新后拿到一个打不开的 app。
MIN_MACOS_VERSION="13.0"

# 自动检查的节奏。不写就是 Sparkle 默认的 86400（1 天），而 Sparkle 会把运行中的
# 定时器夹到最小 1 小时，所以「发版后一直开着的机器」最长要等一天才查一次。
UPDATE_CHECK_INTERVAL=43200

# 已静默下载完的更新多久之后主动喊用户。MacStroke 是菜单栏 App（LSUIElement），
# 几乎不会被退出，而开了「自动下载」（SUAutomaticallyUpdate）时 Sparkle 的默认做法是
# 「等 App 退出时才装」，只有超过这个间隔还没退出才提醒 —— 默认是 604800（1 周），
# 实测就是「发了新版，另一台开着的机器一直没弹窗」的原因。必须大于上面的检查间隔。
IMPATIENT_UPDATE_CHECK_INTERVAL=86400

# 稳定的自签名代码签名身份（见 README-签名.md /钥匙串里 "MacStroke Self Signed"）。
# 用它签名可让 cdhash 在重装后保持不变，辅助功能(TCC)授权不被重置。
# 若身份不存在则自动回退为 ad-hoc 签名。
SIGN_IDENTITY="MacStroke Self Signed"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGN_IDENTITY}"; then
    echo "⚠️  未找到签名身份 '${SIGN_IDENTITY}'，回退为 ad-hoc 签名"
    SIGN_IDENTITY="-"
fi

# 开始时间要取在编译之前，才能在下面分辨「这趟没增量可编」和「这趟没编出新东西」。
BUILD_STARTED=$(date +%s)
echo "🔨 Building release（先试通用包 arm64 + x86_64）..."
# 跟 Xcode 的 ARCHS_STANDARD 一样出双架构包：Apple Silicon 原生运行，不需要 Rosetta。
# 通用包（arm64 + x86_64）要靠工具链里的 xcbuild —— 只有 Xcode 带，纯 CommandLineTools 没有。
# 本机 2026-10-22 升级 CLT 之后就是后者，报错是「xcbuild executable ... does not exist」。
# 这时候回退成 host 单架构：**本机装机照样能用**（Apple Silicon 原生跑，不需要 Rosetta），
# 正式发版不受影响 —— release.yml 的 runner 带 Xcode 走通用那一条，而且它在出包之后
# 自己再 lipo 校验一次 arm64+x86_64，真回退到 CI 上会直接红，不会悄悄发一个单架构正式版。
UNIVERSAL_LOG=$(mktemp)
if swift build --configuration release --arch arm64 --arch x86_64 >"${UNIVERSAL_LOG}" 2>&1; then
    :
else
    if grep -qi "xcbuild" "${UNIVERSAL_LOG}"; then
        echo "⚠️  工具链里没有 xcbuild，通用包做不了，回退为 $(uname -m) 单架构 release 构建"
        echo "    （正式发版请走 GitHub 流水线，那边带 Xcode 出 arm64+x86_64）"
        tail -2 "${UNIVERSAL_LOG}"
        SINGLE_ARCH_BUILD=1
        swift build --configuration release
    else
        cat "${UNIVERSAL_LOG}"
        rm -f "${UNIVERSAL_LOG}"
        exit 1
    fi
fi
rm -f "${UNIVERSAL_LOG}"

# 产物落在哪儿，取决于这次是通用包还是单架构：
#   通用包（有 xcbuild）→ .build/apple/Products/Release
#   单架构              → .build/<host>-apple-macosx/release
#   更新的 Swift build 系统 → .build/out/Products/Release（.build/release 是指向那里的符号链接）
# 2.2 之前这里是「按固定顺序取第一个存在的」，本机因此踩过一次：通用包那一档的产物是
# 上一次装 Xcode 时留下的（10 月 21 日），这次只做了单架构构建（10 月 23 日），脚本照样
# 先命中旧目录，于是把一个 3.2.2 的二进制装进写着 3.2.3 的 Info.plist 里 —— 而版本号正是
# 用户区分新旧的唯一依据（见上面的 APP_VERSION 注释）。所以改成**按新旧取**：谁的最新用谁，
# 再拿源文件的时间当场校验：只要还有比产物更新的 .swift，直接红，绝不打包。
BUILD_DIR=""
NEWEST=0
for candidate in .build/release .build/out/Products/Release \
                 .build/apple/Products/Release \
                 .build/$(uname -m)-apple-macosx/release; do
    [ -x "${candidate}/MacStrokeApp" ] || continue
    stamp=$(stat -f %m "${candidate}/MacStrokeApp")
    echo "   候选 ${candidate}/MacStrokeApp  构建于 $(date -r ${stamp} '+%Y-%m-%d %H:%M')"
    if [ "${stamp}" -gt "${NEWEST}" ]; then NEWEST=${stamp}; BUILD_DIR="${candidate}"; fi
done
if [ -z "${BUILD_DIR}" ]; then
    echo "❌ 找不到 release 产物（.build/release、.build/out/Products/Release、.build/apple/Products/Release 或 .build/*-apple-macosx/release）"
    exit 1
fi
if [ "${NEWEST}" -lt "${BUILD_STARTED}" ]; then
    # 没有增量可编（源文件自上次构建没动）时，产物时间必然早于这次构建开始，这本身不是错。
    # 真正的「拿旧包当新版」是另一回事：有比产物更新的源文件。所以拿源文件比，不拿开始时间比。
    stale=$(find Sources -name '*.swift' -newer "${BUILD_DIR}/MacStrokeApp" 2>/dev/null | head -5)
    if [ -n "${stale}" ]; then
        echo "❌ 选中的产物（${BUILD_DIR}，$(date -r ${NEWEST} '+%Y-%m-%d %H:%M')）比下面这些源文件还旧，"
        echo "   说明这趟编译没把改动编进去，装上去就是「新号旧货」："
        echo "${stale}" | sed 's/^/      /'
        exit 1
    fi
    echo "ℹ️  产物时间早于本次构建开始 —— 这趟是「没有增量可编」，源文件都比它旧，用的就是当前代码"
fi
# 最后一道：这一轮新加的代码要在二进制里能摸到，摸不到就是打包打错了目录。
if ! grep -aq "MacStrokeSelectionProbe" "${BUILD_DIR}/MacStrokeApp"; then
    echo "❌ ${BUILD_DIR}/MacStrokeApp 里没有 SelectionCopyReader 的哨兵串，说明这个二进制不含划词气泡「代按 ⌘C」那一手"
    exit 1
fi
# 3.2.0 那一轮加的是「搜索走哪一家」那张表：模板串是纯字面量，一定在二进制里。
# 拿它当哨兵而不是拿「搜索走」—— 那句是 NSLog 的格式串，改文案就会假红。
if ! grep -aq "sogou.com/web?query=" "${BUILD_DIR}/MacStrokeApp"; then
    echo "❌ ${BUILD_DIR}/MacStrokeApp 里没有搜索引擎那张表的模板串，说明这个二进制不含 3.2.0 的「搜索走哪一家」"
    exit 1
fi
# 同一号里的第二手：「打开之后自动补一次 ⌘V」。这颗偏好键名是纯字面量（落盘与注册表都要用），
# 一定在二进制里；拿键名当哨兵而不是拿那句日志 —— 「自动贴」是格式串，改文案就假红，
# 而 3.2.0 已经上线过一轮，只有这一串能把「带自动贴的 3.2.0」和「不带的那一版」分开。
if ! grep -aq "selectionPopupAutoPaste" "${BUILD_DIR}/MacStrokeApp"; then
    echo "❌ ${BUILD_DIR}/MacStrokeApp 里没有 selectionPopupAutoPaste 这颗键，说明这个二进制不含「自动补 ⌘V」那一手"
    exit 1
fi
# 3.2.1 这一轮新增的是「按住起手键 + 滚轮」（issue #75）。拿这颗偏好键名当哨兵：
# 它是 Storage 的 rawValue（落盘、注册表、main.swift 读默认值都要用），纯字面量必然在二进制里，
# 而不像「Wheel gesture up fired」那种 NSLog 格式串 —— 改文案就会假红。
if ! grep -aq "wheelGestureUpAction" "${BUILD_DIR}/MacStrokeApp"; then
    echo "❌ ${BUILD_DIR}/MacStrokeApp 里没有 wheelGestureUpAction 这颗键，说明这个二进制不含 3.2.1 的滚轮触发"
    exit 1
fi
# 3.2.1 这一轮的另一手是关于页那行「已跳过的版本」（读三格 + 就地回执）。这串是
# SparkleSkippedVersions 里的键名字面量，只有新版那份代码会带它 —— 旧版只在 main.swift
# 的数组里写过同样的串，但那处已删；拿它当哨兵比拿「恢复提醒」那句文案可靠（改文案就假红）。
if ! grep -aq "SUSkippedMajorSubreleaseVersion" "${BUILD_DIR}/MacStrokeApp"; then
    echo "❌ ${BUILD_DIR}/MacStrokeApp 里没有 SUSkippedMajorSubreleaseVersion 这颗键，说明这个二进制不含「已跳过的版本」那一行的修复"
    exit 1
fi
# 3.2.2 这一轮加的是 issue #22「手势打到光标下的窗口」。同样拿键名当哨兵：
# `strokeTargetsCursorWindow` 是 StorageKey 的 rawValue，落盘、注册表、main.swift 读默认值三处都要用，
# 纯字面量必然在二进制里；而「已归给光标下的窗口」那种是 NSLog 格式串，改文案就假红。
if ! grep -aq "strokeTargetsCursorWindow" "${BUILD_DIR}/MacStrokeApp"; then
    echo "❌ ${BUILD_DIR}/MacStrokeApp 里没有 strokeTargetsCursorWindow 这颗键，说明这个二进制不含「手势打到光标下的窗口」（issue #22）"
    exit 1
fi
# 3.2.3 这一轮修的是 issue #76（黑名单每重启一次被清一次）。哨兵取 [BlockFilterMigration] 这个日志标签。
# 和前几条「拿键名当哨兵」不同，这轮没有新键可钉（改的是**少注册**一颗旧键 + 迁移的判据），
# 而这串标签是对外契约：装机脚本 filter_restart_test.sh 数日志、交接文档、issue 回复都引它，
# 不是随手写的文案 —— 真要改它得连那三处一起改。
if ! grep -aq "BlockFilterMigration" "${BUILD_DIR}/MacStrokeApp"; then
    echo "❌ ${BUILD_DIR}/MacStrokeApp 里没有 BlockFilterMigration 这个日志标签，说明这个二进制不含「旧键幻影迁移」的修复（issue #76）"
    exit 1
fi
# .build/release 可能是个符号链接；后面的 find 默认不跟进符号链接（-P），
# 不折成真实路径就会在找 Sparkle.framework 时空手而归。
BUILD_DIR=$(cd "${BUILD_DIR}" && pwd -P)
echo "📂 产物目录: ${BUILD_DIR}（最新，构建于 $(date -r ${NEWEST} '+%Y-%m-%d %H:%M')）"

echo "📦 Creating .app bundle at ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Frameworks"
mkdir -p "${APP_DIR}/Contents/PlugIns"

# 1. Executable
cp "${BUILD_DIR}/MacStrokeApp" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# 2. Icons & Resources (main app)
cp Sources/MacStrokeApp/Resources/menu_icon_16x16.png "${APP_DIR}/Contents/Resources/"
cp Sources/MacStrokeApp/Resources/menu_icon_disabled_16x16.png "${APP_DIR}/Contents/Resources/"
# 偏好窗口侧边栏图标（沿用原版素材）
cp Sources/MacStrokeApp/Resources/RightClick.png "${APP_DIR}/Contents/Resources/"
# 远程控制页的小程序码（微信后台烤的固定图，本机生成不出来）
cp Sources/MacStrokeApp/Resources/MiniProgramCode.png "${APP_DIR}/Contents/Resources/"

# Copy main app localization (DO NOT copy FinderSync's - it has its own bundle)
cp -R Sources/MacStrokeApp/Resources/en.lproj "${APP_DIR}/Contents/Resources/"
cp -R Sources/MacStrokeApp/Resources/zh-Hans.lproj "${APP_DIR}/Contents/Resources/"

# AppleScript definition + Sparkle public key
cp Sources/MacStrokeApp/Resources/AppleScript.sdef "${APP_DIR}/Contents/Resources/"
cp Sources/MacStrokeApp/Resources/dsa_pub.pem "${APP_DIR}/Contents/Resources/"

# App Icon：由原版 AppIcon.appiconset/logo.png（鼠标+三角结 logo）生成，
# 已入库，避免依赖外部工程路径。
cp Sources/MacStrokeApp/Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"

# 3. Sparkle framework - copy ENTIRE framework with correct structure
SPARKLE_SRC=$(find "${BUILD_DIR}" -name "Sparkle.framework" -type d | head -1)
if [ -n "${SPARKLE_SRC}" ]; then
    cp -R "${SPARKLE_SRC}" "${APP_DIR}/Contents/Frameworks/"
    echo "✅ Sparkle framework embedded"
fi

# 4. FinderSync Extension -> loadable .appex bundle
EXT_EXE="${BUILD_DIR}/FinderSyncExtension"
APPEX_DIR="${APP_DIR}/Contents/PlugIns/FinderSyncExtension.appex"
APPEX_ENT="$(mktemp /tmp/MacStrokeFinderSync.XXXXXX.entitlements)"
cat > "${APPEX_ENT}" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
</dict>
</plist>
ENT
if [ -x "${EXT_EXE}" ]; then
    rm -rf "${APPEX_DIR}"
    mkdir -p "${APPEX_DIR}/Contents/MacOS" "${APPEX_DIR}/Contents/Resources"
    cp "${EXT_EXE}" "${APPEX_DIR}/Contents/MacOS/FinderSyncExtension"
    cp -R Sources/FinderSyncExtension/Resources/en.lproj "${APPEX_DIR}/Contents/Resources/"
    cp -R Sources/FinderSyncExtension/Resources/zh-Hans.lproj "${APPEX_DIR}/Contents/Resources/"
    cat > "${APPEX_DIR}/Contents/Info.plist" <<APPEX
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleDisplayName</key>
	<string>FinderSyncExtension</string>
	<key>CFBundleExecutable</key>
	<string>FinderSyncExtension</string>
	<key>CFBundleIdentifier</key>
	<string>net.mtjo.MacStroke.FinderSyncExtension</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>FinderSyncExtension</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>${APP_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${APP_VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_MACOS_VERSION}</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionAttributes</key>
		<dict/>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.FinderSync</string>
		<key>NSExtensionPrincipalClass</key>
		<string>FinderSync</string>
	</dict>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
APPEX
    echo "✅ FinderSync .appex assembled"
else
    echo "⚠️ FinderSyncExtension executable not found at ${EXT_EXE}"
fi

# 5. Fix @rpath in executable to find Sparkle at Contents/Frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null

# 6. Also fix Sparkle's own rpath if needed
find "${APP_DIR}/Contents/Frameworks" -name "Sparkle" -type f -exec install_name_tool -id "@rpath/Sparkle.framework/Versions/B/Sparkle" {} \; 2>/dev/null

# 7. Info.plist
# SUPublicEDKey：Sparkle 2 硬性要求 EdDSA 公钥，缺失时 startUpdater 抛出致命错误
# 并弹出模态框，主线程停在 runModal 里（连 DistributedNotificationCenter 都收不到，
# Finder 右键菜单随之失效）。私钥在 .sparkle/ed25519-private.pem（未入库）。
# SUPublicDSAKeyFile 是沿用原版的遗留配置：Sparkle 2 已删除 DSA 支持，本包不会用到它。
# SUEnableAutomaticChecks 要为 true：原版偏好窗的「自动检查更新」复选框直接绑
# SUUpdater.automaticallyChecksForUpdates、Info.plist 里也没覆盖这个键（即默认为真），
# 写 false 就等于用户不手动点「检查更新」永远收不到新版。
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>net.mtjo.MacStroke</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS_VERSION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License - Copyright © 2024</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>OSAScriptingDefinition</key>
    <string>AppleScript.sdef</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>MacStroke listens for your watch or band's Bluetooth advertisements to lock the screen when you walk away. It never connects to any device.</string>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/mtjo/MacStroke/release/AppCast.xml</string>
    <key>SUPublicDSAKeyFile</key>
    <string>dsa_pub.pem</string>
    <key>SUPublicEDKey</key>
    <string>z7QoxopiJmon580ha8Kl8tI6m+Jq+xSZ9Oz/CCVqUAU=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>${UPDATE_CHECK_INTERVAL}</integer>
    <key>SUScheduledImpatientCheckInterval</key>
    <integer>${IMPATIENT_UPDATE_CHECK_INTERVAL}</integer>
</dict>
</plist>
PLIST

# 8. Codesign. Children are signed first — the parent seal then
# covers the appex signature that carries the sandbox entitlements.
codesign --force --sign "${SIGN_IDENTITY}" "${APP_DIR}/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${APPEX_ENT}" "${APPEX_DIR}" 2>/dev/null || true
codesign --force --sign "${SIGN_IDENTITY}" "${APP_DIR}" 2>/dev/null || true
rm -f "${APPEX_ENT}"

# 9. Verify framework linkage
echo "🔍 Verifying framework linkage..."
otool -L "${APP_DIR}/Contents/MacOS/${APP_NAME}" | grep -E "Sparkle|rpath"

# 10. 双架构校验：少任一架构就说明上面的 --arch 编译没生效，
#     那样的包在 Apple Silicon 上要装 Rosetta，直接失败比静默出包好。
#     唯一允许单架构的情形是上面真的因为工具链没有 xcbuild 而回退（SINGLE_ARCH_BUILD=1），
#     那时候仍然逐个二进制核对「至少要有本机这一档」，别拿一个只有 x86_64 的包去装 Apple Silicon。
echo "🔍 Verifying architectures..."
HOST_ARCH=$(uname -m)
for exe in "${APP_DIR}/Contents/MacOS/${APP_NAME}" \
           "${APPEX_DIR}/Contents/MacOS/FinderSyncExtension" \
           "${APP_DIR}/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"; do
    archs=$(lipo -archs "${exe}")
    if [ "${SINGLE_ARCH_BUILD:-0}" = "1" ]; then
        if ! echo "${archs}" | grep -q "${HOST_ARCH}"; then
            echo "❌ 回退的单架构构建里 ${exe} 不含本机架构 ${HOST_ARCH}：${archs}"
            exit 1
        fi
        # 回退那一条只保证「有本机这一档」；产物实际是几个架构照实说，别硬套「单架构」这个词。
        arch_count=$(echo "${archs}" | wc -w | tr -d ' ')
        if [ "${arch_count}" = "1" ]; then
            echo "   ${archs}  <- ${exe}（单架构回退：本机 ${HOST_ARCH}；通用包那条路要工具链里的 xcbuild）"
        else
            echo "   ${archs}  <- ${exe}（本机这一档 ${HOST_ARCH} 已在）"
        fi
        continue
    fi
    if ! (echo "${archs}" | grep -q x86_64 && echo "${archs}" | grep -q arm64); then
        echo "❌ ${exe} 不是 universal 包：${archs}"
        exit 1
    fi
    echo "   ${archs}  <- ${exe}"
done

echo "✅ Done! App at: ${APP_DIR}"
echo "📏 Size: $(du -sh "${APP_DIR}" | cut -f1)"
