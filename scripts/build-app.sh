#!/bin/zsh
# Build SpaceManager.app: swift build → assemble bundle → Developer ID sign.
# TCC (Accessibility) grants key off the bundle ID + stable signature, so the
# Developer ID signature keeps the grant across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SpaceManager.app"
IDENTITY="Developer ID Application: Taylor Bird (UFCDGSKCXB)"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.taylorbird.spacemanager</string>
	<key>CFBundleName</key>
	<string>SpaceManager</string>
	<key>CFBundleExecutable</key>
	<string>SpaceManager</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

cp "$ROOT/.build/release/SpaceManager" "$APP/Contents/MacOS/SpaceManager"

codesign --force --timestamp=none --sign "$IDENTITY" "$APP"

echo "Built and signed: $APP"
