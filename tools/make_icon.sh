#!/bin/bash
# Regenerate the app icon from tools/render_icon.swift.
#
#   ./tools/make_icon.sh
#
# Writes Sources/MacStrokeApp/Resources/AppIcon.icns (Dock / Finder / Launchpad)
# and /tmp/MacStrokeLogo.png (the square logo the README and About page show).
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER=/tmp/MacStrokeIcon_1024.png
LOGO=/tmp/MacStrokeLogo.png
ICONSET=/tmp/AppIcon.iconset
ICNS=Sources/MacStrokeApp/Resources/AppIcon.icns

swift tools/render_icon.swift "$MASTER" 1024
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# iconutil needs every size named after its points @ scale pairing.
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
            "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  px=${spec%% *}
  name=${spec##* }
  sips -z "$px" "$px" "$MASTER" --out "$ICONSET/icon_$name.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"

sips -z 512 512 "$MASTER" --out "$LOGO" >/dev/null

echo "$ICNS"
echo "$LOGO"
