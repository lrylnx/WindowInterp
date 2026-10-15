#!/bin/zsh
# 构建「窗口插帧助手」。引擎资源来自本机已有的 LSFG 视频播放器 / MetalFrame。
set -eu
cd "$(dirname "$0")"

APP="$PWD/窗口插帧助手.app"
NAME="窗口插帧助手"

# 引擎资源来源：可用 LSFGM_LSFG_SOURCES 覆盖（冒号分隔多个候选目录）
DESKTOP="${DESKTOP:-$HOME/Desktop}"
ENGINE_SOURCES=(
    "$DESKTOP/LSFG 视频播放器.app/Contents/Resources/Native"
    "/Applications/窗口插帧助手.app/Contents/Resources/Native"
    "$DESKTOP/MetalFrame.app/Contents/Resources/Native"
)

if [ -n "${LSFGM_LSFG_SOURCES:-}" ]; then
    ENGINE_SOURCES=("${(@s/:/)LSFGM_LSFG_SOURCES}" "${ENGINE_SOURCES[@]}")
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Native" "$APP/Contents/Resources/Tools"

cp Info.plist "$APP/Contents/Info.plist"

# 引擎资源：liblsfg_metal / liblsfg_extended / libMoltenVK / lsfg-vk.dll
COPIED=0
for SRC in "${ENGINE_SOURCES[@]}"; do
    [ -d "$SRC" ] || continue
    for F in liblsfg_metal.dylib liblsfg_extended.dylib libMoltenVK.dylib lsfg-vk.dll; do
        if [ -f "$SRC/$F" ]; then cp -f "$SRC/$F" "$APP/Contents/Resources/Native/"; fi
    done
    if [ -f "$SRC/liblsfg_metal.dylib" ] && [ -f "$SRC/lsfg-vk.dll" ]; then COPIED=1; break; fi
done
if [ "$COPIED" -ne 1 ] && [ -s "$APP/Contents/Resources/Native/liblsfg_metal.dylib" ] && [ -s "$APP/Contents/Resources/Native/lsfg-vk.dll" ]; then
    COPIED=1
    echo "→ 复用 App 内已有的 LSFG 引擎资源"
fi
if [ "$COPIED" -ne 1 ]; then
    echo "❌ 找不到 LSFG 引擎资源（liblsfg_metal.dylib / lsfg-vk.dll）。" >&2
    echo "   需要桌面上存在「LSFG 视频播放器.app」，或 MetalFrame.app。" >&2
    exit 1
fi
if [ ! -f "$APP/Contents/Resources/Native/liblsfg_extended.dylib" ]; then
    echo "   （没有 liblsfg_extended.dylib：5× 以上倍率不可用）"
fi

# 图标（沿用播放器那份，缺就跳过）
if [ -f "$DESKTOP/LSFG 视频播放器.app/Contents/Resources/AppIcon.icns" ]; then
    cp -f "$DESKTOP/LSFG 视频播放器.app/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/"
elif [ -f "/Applications/窗口插帧助手.app/Contents/Resources/AppIcon.icns" ]; then
    cp -f "/Applications/窗口插帧助手.app/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/"
elif [ -f AppIcon.icns ]; then
    cp -f AppIcon.icns "$APP/Contents/Resources/"
fi
[ -f README.md ] && cp -f README.md "$APP/Contents/Resources/使用说明.md"

# 签名身份：用固定证书（不是 ad-hoc），否则每次重构建 cdhash 都变，
# 系统认为换了 App，屏幕录制授权每次都要重给。证书由 make-identity.sh 一次性生成。
IDENTITY="WindowInterp Local Signing"
KEYCHAIN="$HOME/Library/Keychains/windowinterp.keychain-db"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    [ -f "$KEYCHAIN" ] && security unlock-keychain -p "windowinterp-local" "$KEYCHAIN" 2>/dev/null || true
    SIGN_ARGS=(--force --sign "$IDENTITY")
    echo "→ 使用签名身份：$IDENTITY"
else
    SIGN_ARGS=(--force --sign -)
    echo "⚠️  没找到自签证书，先用 ad-hoc 签名（屏幕录制授权会在每次重构建后失效）"
    echo "    想固定授权请先跑一次：zsh make-identity.sh"
fi

# 引擎 dylib 必须能单独签名，否则注入时被库校验拦下
for F in liblsfg_metal.dylib liblsfg_extended.dylib libMoltenVK.dylib; do
    [ -f "$APP/Contents/Resources/Native/$F" ] && codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/Native/$F" 2>/dev/null || true
done

# 编译：必须摘掉 WorkBuddy 注入层，否则产物会带上无效的打包/沙箱钩子
#
# ⚠️ 必须显式指定 `-target …-macos15.0`。不写的话 swiftc 默认按**本机系统版本**做
#    deployment target，在 macOS 27 上编出来的二进制 `minos` 就是 27.0 ⇒ **只能在
#    macOS 27+ 启动**（低版本双击直接报「需要 macOS 27」），而 Info.plist 里写的
#    却是 LSMinimumSystemVersion 15.0 —— 两边不一致，是个静默的坑。
#    实测降到 15.0 是**零编译错误**（代码用到的 API 15.0 全都已有），所以这里就钉
#    死 15.0，与 Info.plist 对齐，macOS 15 及以上都能跑。
#    再往下（14.0/13.0）要先在 ScreenCaptureKit 那几个属性外面补 #available 守卫，
#    没那个必要。
#    架构固定 arm64：LSFG 引擎 dylib 只有 arm64，这App本来就只面向 Apple Silicon。
env -u NODE_OPTIONS -u CODEBUDDY_BROKERED_FS_HOOK_ENABLED -u CODEBUDDY_SAFE_DELETE_SANDBOX \
    xcrun swiftc -O -target arm64-apple-macos15.0 main.swift EngineSession.swift \
    -o "$APP/Contents/MacOS/WindowInterp" \
    -Xlinker -rpath -Xlinker @executable_path/../Resources/Native
# 注意：不加 --options runtime —— Hardened Runtime 会拦下 DYLD_INSERT_LIBRARIES，
# LSFG 引擎就注入不进去了。
codesign "${SIGN_ARGS[@]}" --identifier local.windowinterp --deep "$APP"
codesign --verify --verbose=1 "$APP"
echo "→ designated requirement："
codesign -d --requirements - "$APP" 2>&1 | grep designated || true
echo "✅ 构建完成：$APP"


# 桌面上那份是日常双击用的副本（和播放器一样的习惯）
if [ -d "$DESKTOP/窗口插帧助手.app" ]; then
    ditto "$APP" "$DESKTOP/窗口插帧助手.app"
    echo "→ 已同步到 $DESKTOP/窗口插帧助手.app"
fi
