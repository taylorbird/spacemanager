#!/bin/zsh
# Build the app bundle, in one of two identities:
#
#   scripts/build-app.sh            DEV:  "Space Manager Dev.app", bundle ID
#                                   com.taylorbird.spacemanager.dev, no update
#                                   feed. Quits the live app (only one runs at a
#                                   time), installs to /Applications, launches.
#                                   scripts/use-live.sh switches back.
#   scripts/build-app.sh --release  LIVE: "Space Manager.app", bundle ID
#                                   com.taylorbird.spacemanager, Sparkle feed.
#                                   Builds only; scripts/package-dmg.sh ships it.
#   --no-launch                     DEV build without installing or launching.
#
# The two bundle IDs keep settings (UserDefaults) and TCC grants separate.
# Every build is stamped with the git commit and build time, shown in the menu.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="Developer ID Application: Taylor Bird (UFCDGSKCXB)"
LIVE_ID="com.taylorbird.spacemanager"
VERSION="$(<"$ROOT/VERSION")"
FEED_URL="https://github.com/taylorbird/spacemanager/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="/YSJw6mSvjuXSJUj9ZOghosYMRbkwyAZyJLF8jzZDdQ="

RELEASE=0
LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1; LAUNCH=0 ;;
    --no-launch) LAUNCH=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if (( RELEASE )); then
  NAME="Space Manager"; BUNDLE_ID="$LIVE_ID"
else
  NAME="Space Manager Dev"; BUNDLE_ID="$LIVE_ID.dev"
fi
APP="$ROOT/build.noindex/$NAME.app"

# Build number = commit count (monotonic, numeric — what Sparkle compares).
# Commit gets a -dirty suffix when the tree has uncommitted changes.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
[[ -n "$(git -C "$ROOT" status --porcelain)" ]] && COMMIT="$COMMIT-dirty"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Icon: actool compiles the Icon Composer package into Assets.car (Liquid
# Glass, macOS 26+) plus a masked AppIcon.icns for older macOS. Layers come
# from scripts/render-icon.swift.
xcrun actool "$ROOT/assets/icon/AppIcon.icon" \
  --compile "$APP/Contents/Resources" \
  --app-icon AppIcon --include-all-app-icons \
  --enable-on-demand-resources NO --development-region en \
  --target-device mac --platform macosx --minimum-deployment-target 14.0 \
  --output-partial-info-plist "$ROOT/build.noindex/actool-partial.plist" \
  --output-format human-readable-text >/dev/null

# Update keys only in the live build: a dev build must never update itself
# into the live release.
UPDATE_KEYS=""
if (( RELEASE )); then
  UPDATE_KEYS="	<key>SUFeedURL</key>
	<string>$FEED_URL</string>
	<key>SUPublicEDKey</key>
	<string>$SPARKLE_PUBLIC_KEY</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$NAME</string>
	<key>CFBundleExecutable</key>
	<string>SpaceManager</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
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
$UPDATE_KEYS
</dict>
</plist>
PLIST

cp "$ROOT/.build/release/SpaceManager" "$APP/Contents/MacOS/SpaceManager"
ditto "$ROOT/.build/release/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Sign inside-out with hardened runtime + secure timestamp (notarization needs
# both). Sparkle's helpers must carry our signature too; the Downloader keeps
# its own entitlements (Sparkle's documented recipe for Developer ID apps).
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"

echo "Built and signed: $APP ($VERSION, build $BUILD_NUMBER, $COMMIT, $BUILD_DATE)"

(( LAUNCH )) || exit 0

# Only one copy runs at a time: both hook the same space switches, HUD and
# hotkey. Quit live and any older dev copy, then install into /Applications —
# macOS 27's MenuBarAgent only handles status items correctly for apps run
# from there (from elsewhere the item is invisible to Bartender).
RUNNING="Manager.*\.app/Contents/MacOS/SpaceManager"
for id in "$LIVE_ID" "$LIVE_ID.dev"; do
  osascript -e "quit app id \"$id\"" 2>/dev/null || true
done
for _ in {1..50}; do
  pgrep -f "$RUNNING" >/dev/null || break
  sleep 0.1
done
if pgrep -f "$RUNNING" >/dev/null; then
  echo "A running Space Manager did not quit within 5s; not installing." >&2
  exit 1
fi

INSTALLED="/Applications/$NAME.app"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
open "$INSTALLED"
echo "Installed and launched: $INSTALLED (scripts/use-live.sh switches back to live)"
