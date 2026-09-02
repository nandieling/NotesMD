#!/bin/zsh
# 构建并打包 NotesMD.app
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP="build/NotesMD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotesMD "$APP/Contents/MacOS/NotesMD"

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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotesMD 需要控制 Apple 备忘录，以写入渲染后的笔记。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "已生成：$APP"
