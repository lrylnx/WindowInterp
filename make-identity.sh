#!/bin/zsh
# 一次性创建「本机自签代码签名证书」，放进独立钥匙串。
#
# 为什么需要它：ad-hoc 签名（codesign --sign -）的 designated requirement 基于
# cdhash —— 每次重新编译 cdhash 都变，系统就认为换了一个 App，
# 屏幕录制授权随之失效（用户体感就是"每次都要重新授权"）。
# 换成固定证书后 DR 变成「identifier + 证书指纹」，重构建也不变，授权能长期保留。
#
# 用法：zsh make-identity.sh [--force]
set -eu
cd "$(dirname "$0")"

IDENTITY="WindowInterp Local Signing"
KEYCHAIN="$HOME/Library/Keychains/windowinterp.keychain-db"
KCPASS="windowinterp-local"
WORK="$PWD/signing"

# 注意：自签证书不会被判定为 "valid"（没有可信链），所以查身份时不能加 -v
if [ "${1:-}" != "--force" ] && security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ 已存在签名身份：$IDENTITY"
    security find-identity -p codesigning | grep "$IDENTITY"
    exit 0
fi

mkdir -p "$WORK"
chmod 700 "$WORK"

echo "→ 生成自签证书（codeSigning 用途，10 年有效）"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
    -subj "/CN=$IDENTITY/O=Local Development/C=CN" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -name "$IDENTITY" -passout "pass:$KCPASS" 2>/dev/null

echo "→ 写入独立钥匙串 $KEYCHAIN"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"
# -A：不限制调用方；-T 额外显式允许 codesign / security
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$KCPASS" -A \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcrun
# 现代 macOS 必须设置 partition list，否则 codesign 取私钥时会弹钥匙串授权框
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KEYCHAIN" >/dev/null

# 把新钥匙串加进用户搜索列表（保留原有条目，不覆盖）
typeset -a EXISTING
EXISTING=(${(f)"$(security list-keychains -d user | sed 's/^[[:space:]]*\"//; s/\"$//' | grep -v '^$' | grep -v 'windowinterp.keychain')"})
security list-keychains -d user -s "$KEYCHAIN" "${EXISTING[@]}"

echo "→ 校验"
security find-identity -p codesigning | grep "$IDENTITY" || {
    echo "❌ 身份没有生效，请检查钥匙串" >&2; exit 1; }
echo "✅ 完成。以后 zsh build.sh 会自动用这个身份签名。"
echo "   授权一次「窗口插帧助手」的屏幕录制权限后，重新构建也不会再问。"
