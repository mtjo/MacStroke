#!/bin/bash
set -e

APP_NAME="MacStroke"
BUILD_DIR=".build/x86_64-apple-macosx/release"
APP_DIR="./${APP_NAME}.app"

echo "🔨 Building release..."
swift build --configuration release

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

# Copy main app localization (DO NOT copy FinderSync's - it has its own bundle)
cp -R Sources/MacStrokeApp/Resources/en.lproj "${APP_DIR}/Contents/Resources/"
cp -R Sources/MacStrokeApp/Resources/zh-Hans.lproj "${APP_DIR}/Contents/Resources/"

# App Icon (from original project)
cp /Users/mtjo/work/MacStroke/MacStroke/Images.xcassets/AppIcon.appiconset/Danrabbit-Elementary-Devices-mouse.icns \
   "${APP_DIR}/Contents/Resources/AppIcon.icns"

# 3. Sparkle framework
cp /Users/mtjo/work/MacStroke/MacStroke/Images.xcassets/AppIcon.appiconset/Danrabbit-Elementary-Devices-mouse.icns \
   "${APP_DIR}/Contents/Resources/AppIcon.icns"

# 3. Sparkle framework - copy ENTIRE framework with correct structure
SPARKLE_SRC=$(find "${BUILD_DIR}" -name "Sparkle.framework" -type d | head -1)
if [ -n "${SPARKLE_SRC}" ]; then
    cp -R "${SPARKLE_SRC}" "${APP_DIR}/Contents/Frameworks/"
    echo "✅ Sparkle framework embedded"
fi

# 4. FinderSync Extension
EXTENSION_DIR=$(find "${BUILD_DIR}" -name "MacStroke_FinderSyncExtension.bundle" -type d | head -1)
if [ -n "${EXTENSION_DIR}" ]; then
    cp -R "${EXTENSION_DIR}" "${APP_DIR}/Contents/PlugIns/"
    echo "✅ FinderSync extension embedded"
fi

# 5. Fix @rpath in executable to find Sparkle at Contents/Frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null

# 6. Also fix Sparkle's own rpath if needed
find "${APP_DIR}/Contents/Frameworks" -name "Sparkle" -type f -exec install_name_tool -id "@rpath/Sparkle.framework/Versions/B/Sparkle" {} \; 2>/dev/null

# 7. Info.plist
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
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <key>SUFeedURL</key>
    <string>https://example.com/updates/feed.xml</string>
</dict>
</plist>
PLIST

# 8. Codesign (ad-hoc)
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true

# 9. Verify framework linkage
echo "🔍 Verifying framework linkage..."
otool -L "${APP_DIR}/Contents/MacOS/${APP_NAME}" | grep -E "Sparkle|rpath"

echo "✅ Done! App at: ${APP_DIR}"
echo "📏 Size: $(du -sh "${APP_DIR}" | cut -f1)"
