#!/bin/zsh
# 构建并打包 NotesMD.app
set -e
cd "$(dirname "$0")/.."

export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swift build -c release --disable-sandbox

APP="build/NotesMD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotesMD "$APP/Contents/MacOS/NotesMD"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>NotesMD</string>
    <key>CFBundleDisplayName</key>
    <string>NotesMD</string>
    <key>CFBundleIdentifier</key>
    <string>com.nan.notesmd</string>
    <key>CFBundleExecutable</key>
    <string>NotesMD</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotesMD 需要控制 Apple 备忘录，以写入渲染后的笔记。</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Markdown 文档</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# 优先用 Apple Development 证书签名：TCC 权限按「bundle id + 团队」锚定，
# 重新构建/替换应用后权限不失效（ad-hoc 签名每次 cdhash 变化都会要求重新授权）。
# 证书不可用（过期/已从钥匙串删除）时 codesign 仍会签出「信任失败」的签名，
# TCC 校验不过就会反复弹权限窗，所以这里只接受能验证通过的证书。
IDENTITY=${NOTESMD_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Apple Distribution|Developer ID/{print $2; exit}')}
if [ -n "$IDENTITY" ]; then
    if codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null \
        && codesign --verify --strict "$APP" 2>/dev/null; then
        echo "签名：$IDENTITY（校验通过，权限可长期保持）"
    else
        IDENTITY=""
    fi
fi
if [ -z "$IDENTITY" ]; then
    codesign --force --sign - "$APP"
    echo "签名：ad-hoc（未找到可用证书）"
    echo "提示：ad-hoc 签名的 cdhash 每次构建都变，系统会把每次构建当成不同应用，"
    echo "      重新打包后需要重新授权：tccutil reset Accessibility com.nan.notesmd"
    echo "      然后在 系统设置→隐私与安全性→辅助功能 里重新勾选 NotesMD"
fi
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2
echo "已生成：$APP"
