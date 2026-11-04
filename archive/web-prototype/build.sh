#!/bin/bash
# Builds build/LED Wall Tool.app (universal, ad-hoc signed). Requires Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LED Wall Tool.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos12.0" -o "build/LEDWallTool-$arch" mac/main.swift -framework Cocoa -framework WebKit
done
lipo -create -output "$APP/Contents/MacOS/LEDWallTool" build/LEDWallTool-arm64 build/LEDWallTool-x86_64
rm build/LEDWallTool-arm64 build/LEDWallTool-x86_64

rsync -a --delete --exclude '.DS_Store' app/ "$APP/Contents/Resources/app/"
[ -f mac/AppIcon.icns ] && cp mac/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LED Wall Tool</string>
  <key>CFBundleDisplayName</key><string>LED Wall Tool</string>
  <key>CFBundleIdentifier</key><string>org.samanderson.ledwalltool</string>
  <key>CFBundleExecutable</key><string>LEDWallTool</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF

codesign --force --deep -s - "$APP" >/dev/null
du -sh "$APP"
echo "Built: $APP"
