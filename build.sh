#!/bin/bash
# Builds Plateau.app into ./build (pass --install to copy it to /Applications)
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=build/Plateau.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Plateau" "$APP/Contents/MacOS/Plateau"
cp "$BIN/Helper" "$APP/Contents/Resources/plateau-helper"
cp Support/install-helper.sh Support/uninstall-helper.sh "$APP/Contents/Resources/"

# App icon: render once (or when the generator changes) into .build/AppIcon.icns
ICNS=.build/AppIcon.icns
if [ ! -f "$ICNS" ] || [ Support/make-icon.swift -nt "$ICNS" ]; then
    ICONSET=.build/AppIcon.iconset
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    swift Support/make-icon.swift .build/icon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s .build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) .build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/Resources/"*.sh
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Plateau</string>
    <key>CFBundleIdentifier</key><string>com.basitanwer.plateau</string>
    <key>CFBundleExecutable</key><string>Plateau</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"

# ./build.sh --install  copies the app to /Applications and relaunches it
if [ "${1:-}" = "--install" ]; then
    pkill -x Plateau 2>/dev/null || true
    rm -rf /Applications/Plateau.app
    cp -R "$APP" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Plateau.app
    touch /Applications/Plateau.app
    open /Applications/Plateau.app
    echo "Installed /Applications/Plateau.app"
fi
