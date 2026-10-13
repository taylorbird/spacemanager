#!/bin/zsh
# Build SpaceManager.app: swift build → assemble bundle → Developer ID sign →
# install to /Applications and relaunch (pass --no-launch to skip both).
# Every build is stamped with the git
# commit and build time so the menu shows exactly which build is running.
# TCC (Accessibility) grants key off the bundle ID + stable signature, so the
# Developer ID signature keeps the grant across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SpaceManager.app"
BUNDLE_ID="com.taylorbird.spacemanager"
IDENTITY="Developer ID Application: Taylor Bird (UFCDGSKCXB)"

LAUNCH=1
[[ "${1:-}" == "--no-launch" ]] && LAUNCH=0

# Build number = commit count (monotonic, numeric — what updaters compare).
# Commit gets a -dirty suffix when the tree has uncommitted changes.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
[[ -n "$(git -C "$ROOT" status --porcelain)" ]] && COMMIT="$COMMIT-dirty"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>SpaceManager</string>
	<key>CFBundleExecutable</key>
	<string>SpaceManager</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>SMGitCommit</key>
	<string>$COMMIT</string>
	<key>SMBuildDate</key>
	<string>$BUILD_DATE</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

cp "$ROOT/.build/release/SpaceManager" "$APP/Contents/MacOS/SpaceManager"

codesign --force --timestamp=none --sign "$IDENTITY" "$APP"

echo "Built and signed: $APP ($BUILD_NUMBER, $COMMIT, $BUILD_DATE)"

(( LAUNCH )) || exit 0

# Quit the running copy (wherever it runs from), wait for it to exit, then
# install into /Applications and launch from there. macOS 27's MenuBarAgent
# only handles status items correctly for apps run from /Applications;
# from anywhere else the item is invisible to Bartender.
RUNNING="SpaceManager.app/Contents/MacOS/SpaceManager"
osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
for _ in {1..50}; do
  pgrep -f "$RUNNING" >/dev/null || break
  sleep 0.1
done
if pgrep -f "$RUNNING" >/dev/null; then
  echo "Old SpaceManager did not quit within 5s; not installing." >&2
  exit 1
fi

INSTALLED="/Applications/SpaceManager.app"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
open "$INSTALLED"
echo "Installed and launched: $INSTALLED"
