#!/bin/zsh
# Package a release DMG: build-app.sh (no launch) → drag-install DMG with an
# Applications shortcut → sign → notarize → staple → Gatekeeper check.
# Output: dist/SpaceManager-<version>.dmg
#
# Notarization needs a keychain profile named "notary", created once with:
#   xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id UFCDGSKCXB
# Without it the DMG is built and signed but not notarized.
#
# Refuses to run on a dirty tree (the build would be stamped -dirty);
# pass --allow-dirty to override.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Space Manager.app"
IDENTITY="Developer ID Application: Taylor Bird (UFCDGSKCXB)"
PROFILE="notary"

if [[ "${1:-}" != "--allow-dirty" && -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "Working tree has uncommitted changes; commit first or pass --allow-dirty." >&2
  exit 1
fi

"$ROOT/scripts/build-app.sh" --no-launch

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/SpaceManager-$VERSION.dmg"
STAGE="$ROOT/build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE" "$ROOT/dist"
ditto "$APP" "$STAGE/Space Manager.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Space Manager" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "Built and signed: $DMG"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notarytool profile \"$PROFILE\"; skipping notarization. Create it with:" >&2
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id UFCDGSKCXB" >&2
  exit 0
fi

# The ticket covers the DMG and the app inside it.
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Notarized and stapled: $DMG"
