#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(cat version.txt 2>/dev/null || echo 0.0.0)
swift build -c release
APP=build/CodexTPS.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CodexTPS "$APP/Contents/MacOS/CodexTPS"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.codex-tps</string>
  <key>CFBundleName</key><string>CodexTPS</string>
  <key>CFBundleExecutable</key><string>CodexTPS</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
