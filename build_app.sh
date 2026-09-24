#!/bin/bash
set -e

APP_NAME="MacStroke"
APP_DIR="./${APP_NAME}.app"

# 版本号要接上原版的发布线：release 分支 appcast 最新条目是 2.0.5，移植版直接跳到 3.0.0，
# 用大版本区分 Swift 这条代码线（不再用 2.1.x，避免和 ObjC 版的小版本序列混在一起）。
# 若低于 appcast（例如写死 1.0.0），Sparkle 会把另一条代码线的 2.0.5 当成「有新版本」，
# 用户点更新就会把本机移植构建覆盖回 ObjC 版。发新版只改这一行，主程序与扩展共用。
# CFBundleVersion 与 MARKETING 同值，沿用原版 project.pbxproj 的做法。
APP_VERSION="3.0.1"

# 最低系统：Package.swift 的部署目标是 .macOS(.v13)，二进制 minos 就是 13.0。
# 必须同时写进 Info.plist 和 appcast 的 sparkle:minimumSystemVersion，否则低于 13 的
# 机器上要么内核直接拒绝启动（提示难懂），要么用户点更新后拿到一个打不开的 app。
MIN_MACOS_VERSION="13.0"

# 稳定的自签名代码签名身份（见 README-签名.md /钥匙串里 "MacStroke Self Signed"）。
# 用它签名可让 cdhash 在重装后保持不变，辅助功能(TCC)授权不被重置。
# 若身份不存在则自动回退为 ad-hoc 签名。
SIGN_IDENTITY="MacStroke Self Signed"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGN_IDENTITY}"; then
    echo "⚠️  未找到签名身份 '${SIGN_IDENTITY}'，回退为 ad-hoc 签名"
    SIGN_IDENTITY="-"
fi

echo "🔨 Building release (universal: arm64 + x86_64)..."
# 跟 Xcode 的 ARCHS_STANDARD 一样出双架构包：Apple Silicon 原生运行，不需要 Rosetta。
swift build --configuration release --arch arm64 --arch x86_64

# 多架构产物落在 .build/apple/Products/Release；单架构（如手工改回 host 架构编译）
# 仍落在 .build/<triple>/release，这里都认。
BUILD_DIR=""
for candidate in .build/apple/Products/Release \
                 .build/$(uname -m)-apple-macosx/release; do
    if [ -x "${candidate}/MacStrokeApp" ]; then BUILD_DIR="${candidate}"; break; fi
done
if [ -z "${BUILD_DIR}" ]; then
    echo "❌ 找不到 release 产物（.build/apple/Products/Release 或 .build/*-apple-macosx/release）"
    exit 1
fi
echo "📂 产物目录: ${BUILD_DIR}"

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
cp Sources/FinderSyncExtension/Resources/toolbarIcon.png "${APP_DIR}/Contents/Resources/"
# 偏好窗口侧边栏图标（沿用原版素材）
cp Sources/MacStrokeApp/Resources/RightClick.png "${APP_DIR}/Contents/Resources/"

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
    cp Sources/FinderSyncExtension/Resources/toolbarIcon.png "${APPEX_DIR}/Contents/Resources/"
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
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/mtjo/MacStroke/release/AppCast.xml</string>
    <key>SUPublicDSAKeyFile</key>
    <string>dsa_pub.pem</string>
    <key>SUPublicEDKey</key>
    <string>z7QoxopiJmon580ha8Kl8tI6m+Jq+xSZ9Oz/CCVqUAU=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
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
echo "🔍 Verifying architectures..."
for exe in "${APP_DIR}/Contents/MacOS/${APP_NAME}" \
           "${APPEX_DIR}/Contents/MacOS/FinderSyncExtension" \
           "${APP_DIR}/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"; do
    archs=$(lipo -archs "${exe}")
    if ! (echo "${archs}" | grep -q x86_64 && echo "${archs}" | grep -q arm64); then
        echo "❌ ${exe} 不是 universal 包：${archs}"
        exit 1
    fi
    echo "   ${archs}  <- ${exe}"
done

echo "✅ Done! App at: ${APP_DIR}"
echo "📏 Size: $(du -sh "${APP_DIR}" | cut -f1)"
