#!/bin/zsh
# Package the live build as a release DMG: build-app.sh --release → DMG with
# a designed window (dmgbuild) → sign → notarize → staple → Gatekeeper check.
# Output: dist/SpaceManager-<version>.dmg
#
# Notarization needs a keychain profile named "notary", created once with:
#   xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id UFCDGSKCXB
# Without it the script fails after signing, unless --no-notarize was passed.
#
# Refuses to run on a dirty tree (the build would be stamped -dirty);
# pass --allow-dirty to override. --no-notarize stops after signing (for
# checking the DMG window without a round-trip to Apple).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build.noindex/Space Manager.app"
IDENTITY="Developer ID Application: Taylor Bird (UFCDGSKCXB)"
PROFILE="notary"
DMGBUILD_VERSION="1.6.7"
VENV="$ROOT/build.noindex/dmgbuild-venv"

ALLOW_DIRTY=0
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if (( ! ALLOW_DIRTY )) && [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "Working tree has uncommitted changes; commit first or pass --allow-dirty." >&2
  exit 1
fi

"$ROOT/scripts/build-app.sh" --release

VERSION="$(<"$ROOT/VERSION")"
DMG="$ROOT/dist/SpaceManager-$VERSION.dmg"
mkdir -p "$ROOT/dist"
rm -f "$DMG"

# dmgbuild writes the Finder window layout directly (no Finder scripting,
# no Automation permission). Installed once into a venv under build.noindex/.
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "dmgbuild==$DMGBUILD_VERSION"
fi

# HiDPI background: one TIFF holding the 1x and 2x renders.
BACKGROUND="$ROOT/build.noindex/dmg-background.tiff"
tiffutil -cathidpicheck "$ROOT/assets/dmg/background.png" "$ROOT/assets/dmg/background@2x.png" \
  -out "$BACKGROUND"

"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" \
  -D app="$APP" -D background="$BACKGROUND" "Space Manager" "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "Built and signed: $DMG"
(( NOTARIZE )) || exit 0

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notarytool profile \"$PROFILE\"; the DMG is signed but NOT notarized. Create it with:" >&2
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id UFCDGSKCXB" >&2
  echo "or pass --no-notarize to build an un-notarized DMG on purpose." >&2
  exit 1
fi

# The ticket covers the DMG and the app inside it.
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Notarized and stapled: $DMG"
