#!/bin/bash
# 构建 DisplayToggle.app（无需 Xcode 工程，只用命令行工具链）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DisplayToggle"
DISPLAY_NAME="屏衡"
VERSION="${DISPLAYTOGGLE_VERSION:-1.10.0}"
BUILD_NUMBER="${DISPLAYTOGGLE_BUILD:-1}"
# 反向域名标识，换了仓库可以自己改，或用环境变量覆盖：
#   DISPLAYTOGGLE_BUNDLE_ID=com.example.foo ./build.sh
BUNDLE_ID="${DISPLAYTOGGLE_BUNDLE_ID:-com.github.huangzx.displaytoggle}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
ICON_SOURCE="Assets/AppIcon.png"

if [ ! -f "$ICON_SOURCE" ]; then
    echo "缺少应用图标：$ICON_SOURCE" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R Assets/MacBook "$APP/Contents/Resources/MacBook"
cp -R THIRD_PARTY_LICENSES "$APP/Contents/Resources/Licenses"

ARCH_DIR="$BUILD_DIR/arch"
mkdir -p "$ARCH_DIR"
ARCHS=${DISPLAYTOGGLE_ARCHS:-"arm64 x86_64"}
BINARIES=()
for architecture in $ARCHS; do
    case "$architecture" in arm64|x86_64) ;; *) echo "不支持的架构: $architecture" >&2; exit 1 ;; esac
    binary="$ARCH_DIR/$APP_NAME-$architecture"
    swiftc -O -target "$architecture-apple-macos13.0" main.swift Version.swift DiagnosticReport.swift Updater.swift HiDPI.swift ModeCatalog.swift DisplayInfo.swift DisplayPolicy.swift DisplayConfigurationLock.swift DDCService.swift DDCProtocol.swift DDCPreview.swift PreviewLock.swift TrueTonePolicy.swift TrueToneService.swift LidAngle.swift AnglePolicy.swift KeyboardBacklightPolicy.swift KeyboardBacklight.swift SettingsModel.swift SettingsWindow.swift LidGeometry.swift LidIllustration.swift -o "$binary"
    BINARIES+=("$binary")
done
if [ "${#BINARIES[@]}" -eq 1 ]; then
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/$APP_NAME"
else
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
fi

ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        suffix=""
        if [ "$scale" -eq 2 ]; then suffix="@2x"; fi
        sips -z "$pixels" "$pixels" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}${suffix}.png" >/dev/null
    done
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"
echo "built: $APP"
