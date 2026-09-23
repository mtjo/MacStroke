#!/bin/bash
set -euo pipefail

# 生成 Sparkle 更新包与 appcast 条目。发版顺序：./build_app.sh → ./make_release.sh
# → 把 release_out/ 里的产物推到 release 分支与 GitHub release tag。
#
# 为什么必须「双签」同一条目：
#   * 老版 MacStroke（ObjC）用 Sparkle 1.24，Info.plist 里只有 SUPublicDSAKeyFile，
#     只认 sparkle:dsaSignature；
#   * 移植版用 Sparkle 2，Sparkle 2 已彻底删除 DSA 支持，只认 sparkle:edSignature。
# 只签一种就会有一条线的用户收不到更新，所以两个签名都要写进同一个 <enclosure>。

REPO="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${REPO}/MacStroke.app"
OUT_DIR="${REPO}/release_out"
SPARKLE_BIN="${REPO}/.build/artifacts/sparkle/Sparkle/bin"
BUILD_SH="${REPO}/build_app.sh"
DSA_PUB="${REPO}/Sources/MacStrokeApp/Resources/dsa_pub.pem"

# 两把私钥都不入库（.gitignore 里 .sparkle/；DSA 私钥在原处 ~/bin）。
ED_PRIV="${REPO}/.sparkle/ed25519-private.pem"
DSA_PRIV="${MACSTROKE_DSA_KEY:-${HOME}/bin/dsa_priv.pem}"

APP_VERSION="$(sed -n 's/^APP_VERSION="\([^"]*\)".*/\1/p' "${BUILD_SH}")"
MIN_MACOS="$(sed -n 's/^MIN_MACOS_VERSION="\([^"]*\)".*/\1/p' "${BUILD_SH}")"
EXPECTED_ED_PUB="$(awk '/<key>SUPublicEDKey<\/key>/{getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit}' "${BUILD_SH}")"

# zip 的下载地址：沿用原版 2.0.5 起的做法，放 GitHub release tag 资源。
DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/mtjo/MacStroke/releases/download/${APP_VERSION}/MacStroke.zip}"
NOTES_URL="${NOTES_URL:-https://raw.githubusercontent.com/mtjo/MacStroke/release/Changelog/${APP_VERSION}.html}"

fail() { echo "❌ $*" >&2; exit 1; }

# 过程中会落地的密钥派生物与摘要文件都放这里，退出即销毁。
umask 077
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "🔎 检查 ${APP_DIR} (v${APP_VERSION})..."
[ -d "${APP_DIR}" ] || fail "找不到 ${APP_DIR}，先跑 ./build_app.sh"
[ -f "${ED_PRIV}" ] || fail "找不到 EdDSA 私钥 ${ED_PRIV}"
[ -f "${DSA_PRIV}" ] || fail "找不到 DSA 私钥（${DSA_PRIV}）。没有它就签不出旧版能验的 sparkle:dsaSignature，\
旧 app 将收不到本次更新。可用 MACSTROKE_DSA_KEY 指定路径。"

# 这三项是「装了就打不开 / 更新提示不断复现」的直接成因，必须在签名前挡住。
ARCHS="$(lipo -archs "${APP_DIR}/Contents/MacOS/${APP_NAME:-MacStroke}")"
echo "${ARCHS}" | grep -q arm64 && echo "${ARCHS}" | grep -q x86_64 \
    || fail "主程序不是 arm64+x86_64 通用包：${ARCHS}"
PLIST="${APP_DIR}/Contents/Info.plist"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"
[ "${ACTUAL_VERSION}" = "${APP_VERSION}" ] \
    || fail "CFBundleVersion=${ACTUAL_VERSION} 与 build_app.sh 的 APP_VERSION=${APP_VERSION} 不一致"
ACTUAL_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${PLIST}")" \
    || fail "Info.plist 缺 LSMinimumSystemVersion"
[ "${ACTUAL_MIN}" = "${MIN_MACOS}" ] \
    || fail "LSMinimumSystemVersion=${ACTUAL_MIN} 与 build_app.sh 的 ${MIN_MACOS} 不一致"

# 私钥一旦和 app 里的公钥对不上，签出来的条目会被静默拒绝，所以先自检。
ED_PUB="$(openssl pkey -in "${ED_PRIV}" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)"
[ "${ED_PUB}" = "${EXPECTED_ED_PUB}" ] \
    || fail "EdDSA 私钥推出的公钥(${ED_PUB})与 Info.plist 的 SUPublicEDKey(${EXPECTED_ED_PUB})不匹配"
openssl dsa -in "${DSA_PRIV}" -pubout 2>/dev/null > "${TMP_DIR}/dsa_pub.pem"
diff -q "${TMP_DIR}/dsa_pub.pem" "${DSA_PUB}" >/dev/null || fail "DSA 私钥与 ${DSA_PUB} 不配对"

# Sparkle 2 的 sign_update 只接受 32 字节 seed（新格式）或 96 字节旧格式，
# 而 .sparkle 里存的是 PKCS#8 PEM，取其末尾 32 字节再单行 base64。
openssl pkey -in "${ED_PRIV}" -outform DER 2>/dev/null \
    | tail -c 32 | base64 | tr -d '\n' > "${TMP_DIR}/seed.b64"

mkdir -p "${OUT_DIR}"
ZIP="${OUT_DIR}/MacStroke-${APP_VERSION}.zip"
rm -f "${ZIP}"
echo "📦 打包 zip..."
# ditto 而非 zip：保留符号链接与扩展属性，Sparkle 解包后签名才不会被破坏。
ditto -c -k --keepParent "${APP_DIR}" "${ZIP}"
LENGTH="$(stat -f %z "${ZIP}")"

echo "✍️  签名 (EdDSA + DSA)..."
ED_OUT="$("${SPARKLE_BIN}/sign_update" --ed-key-file "${TMP_DIR}/seed.b64" "${ZIP}")"
ED_SIG="$(printf '%s' "${ED_OUT}" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
ED_LEN="$(printf '%s' "${ED_OUT}" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "${ED_SIG}" ] || fail "EdDSA 签名失败：${ED_OUT}"
[ "${ED_LEN}" = "${LENGTH}" ] || fail "EdDSA 报告 length=${ED_LEN} 与 zip 实际 ${LENGTH} 不符"

DSA_SIG="$(printf '%s' "$("${SPARKLE_BIN}/old_dsa_scripts/sign_update" "${ZIP}" "${DSA_PRIV}")" | tr -d '\n')"
[ -n "${DSA_SIG}" ] || fail "DSA 签名失败"

echo "🔍 验证签名..."
"${SPARKLE_BIN}/sign_update" --verify --ed-key-file "${TMP_DIR}/seed.b64" "${ZIP}" "${ED_SIG}" \
    || fail "EdDSA 签名自检失败"
# DSA 自检必须复刻老 sign_update 的构造：它先对文件取一次 sha1，再把那 20 字节
# 摘要当输入做 `dgst -sha1 -sign`（即签的是 sha1(sha1(zip))）。用官方 2.0.5 条目里
# 现成的 dsaSignature 反推验证过，只有这种配方对老版 Sparkle 才验得过。
printf '%s' "${DSA_SIG}" | /usr/bin/openssl base64 -d -A > "${TMP_DIR}/dsa_sig.bin"
/usr/bin/openssl dgst -sha1 -binary < "${ZIP}" > "${TMP_DIR}/zip_sha1.bin"
/usr/bin/openssl dgst -sha1 -verify "${DSA_PUB}" \
    -signature "${TMP_DIR}/dsa_sig.bin" "${TMP_DIR}/zip_sha1.bin" >/dev/null \
    || fail "DSA 签名用 ${DSA_PUB} 验不过（旧版就是用它验签）"

ITEM="${OUT_DIR}/AppCast-${APP_VERSION}-item.xml"
PUB_DATE="$(date '+%Y-%m-%d %H:%M:%S %z')"
# 结构与 release 分支既有 17 条保持一致（每版一个 <channel> 块），
# 这样老 Sparkle 1.24 与新 Sparkle 2 都能按原样解析。
cat > "${ITEM}" <<ITEM_EOF
  <channel>
    <title>MacStroke Changelog</title>
    <link>https://raw.githubusercontent.com/mtjo/MacStroke/release/AppCast.xml</link>
    <description>Most recent changes with links to updates.</description>
    <language>en</language>
    <item>
      <title>Version${APP_VERSION}</title>
      <sparkle:releaseNotesLink>
        ${NOTES_URL}
      </sparkle:releaseNotesLink>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure url="${DOWNLOAD_URL}" sparkle:version="${APP_VERSION}" sparkle:shortVersionString="${APP_VERSION}" length="${LENGTH}" type="application/octet-stream" sparkle:dsaSignature="${DSA_SIG}" sparkle:edSignature="${ED_SIG}" />
      <sparkle:minimumSystemVersion>${MIN_MACOS}</sparkle:minimumSystemVersion>
    </item>
  </channel>
ITEM_EOF

echo "✅ 产物："
echo "   ${ZIP}  (${LENGTH} bytes, ${ARCHS})"
echo "   ${ITEM}"
echo
echo "下一步（都是改动公开仓库的动作，需人工确认后再做）："
echo "  1. 把 ${ITEM} 的内容追加到 release 分支 AppCast.xml，并同步 Changelog/${APP_VERSION}.html"
echo "  2. 上传 ${ZIP} 为 GitHub release tag ${APP_VERSION} 的资源 MacStroke.zip"
echo "  3. 校验：./verify_appcast.sh 或让一台旧版机器点「检查更新」"
