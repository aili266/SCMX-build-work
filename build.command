#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
DEST="${1:-$PWD/dist/SCMX-build-work.app}"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" Engine.swift DeviceCatalog.swift FirmwareArtifact.swift DebugSession.swift RegisterCatalog.swift Programming.swift ProgrammingView.swift SerialTerminal.swift App.swift Tests.swift ProgrammingTests.swift main.swift -o "$DEST/Contents/MacOS/STM32Studio" -framework SwiftUI -framework AppKit
ICON_TMP="$(mktemp -d)"
xcrun swiftc make-icon.swift -o "$ICON_TMP/make-icon" -framework AppKit
"$ICON_TMP/make-icon" "$ICON_TMP/icon.png"
for size in 16 32 128 256 512 1024; do sips -z "$size" "$size" "$ICON_TMP/icon.png" --out "$ICON_TMP/icon_${size}x${size}.png" >/dev/null; done
mkdir -p "$ICON_TMP/STM32Burn.iconset"
cp "$ICON_TMP/icon_16x16.png" "$ICON_TMP/STM32Burn.iconset/icon_16x16.png"
cp "$ICON_TMP/icon_32x32.png" "$ICON_TMP/STM32Burn.iconset/icon_16x16@2x.png"
cp "$ICON_TMP/icon_128x128.png" "$ICON_TMP/STM32Burn.iconset/icon_128x128.png"
cp "$ICON_TMP/icon_256x256.png" "$ICON_TMP/STM32Burn.iconset/icon_128x128@2x.png"
cp "$ICON_TMP/icon_256x256.png" "$ICON_TMP/STM32Burn.iconset/icon_256x256.png"
cp "$ICON_TMP/icon_512x512.png" "$ICON_TMP/STM32Burn.iconset/icon_256x256@2x.png"
cp "$ICON_TMP/icon_512x512.png" "$ICON_TMP/STM32Burn.iconset/icon_512x512.png"
cp "$ICON_TMP/icon_1024x1024.png" "$ICON_TMP/STM32Burn.iconset/icon_512x512@2x.png"
iconutil -c icns "$ICON_TMP/STM32Burn.iconset" -o "$DEST/Contents/Resources/STM32Burn.icns"
rm -rf "$ICON_TMP"
cat > "$DEST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>STM32Studio</string>
<key>CFBundleIdentifier</key><string>local.stm32.workbench.preview</string>
<key>CFBundleName</key><string>SCMX-build-work</string>
<key>CFBundleDisplayName</key><string>SCMX-build-work</string>
<key>CFBundleIconFile</key><string>STM32Burn</string>
<key>CFBundleIconName</key><string>STM32Burn</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>本地免费工具 · 2026</string>
</dict></plist>
PLIST
codesign --force --sign - "$DEST"
echo "已打包：$DEST"
