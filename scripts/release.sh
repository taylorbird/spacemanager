#!/bin/zsh
# Cut a release of the live app:  scripts/release.sh <version>   (e.g. 0.1.0)
#
#   1. Preflight: on main, clean tree, tag not taken, RELEASE_NOTES.md rewritten
#      for this version (its first line must be "## <version>"; notes are
#      shipped verbatim, so stale notes would ship again otherwise).
#   2. Write VERSION, archive the notes to release-notes/<version>.md, commit
#      "Release v<version>", tag v<version>.
#   3. scripts/package-dmg.sh: live build, DMG, notarize, staple.
#   4. Sparkle's generate_appcast signs the DMG with the EdDSA key stored in
#      the login keychain (account "spacemanager") and writes appcast.xml with
#      the notes embedded.
#   5. Push main + tag; create the GitHub release with the DMG and appcast.xml.
#      Installed copies poll .../releases/latest/download/appcast.xml.
#
# Takes several minutes (notarization). Run it from a terminal, not a tool
# with a short command timeout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="taylorbird/spacemanager"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
V="${1:?usage: scripts/release.sh <version>   (e.g. 0.1.0)}"

die() { echo "release: $*" >&2; exit 1; }

[[ "$V" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "version must look like 1.2.3, got \"$V\""
[[ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" == main ]] || die "releases are cut from main"
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || die "working tree has uncommitted changes"
git -C "$ROOT" rev-parse -q --verify "refs/tags/v$V" >/dev/null && die "tag v$V already exists"
[[ "$(head -1 "$ROOT/RELEASE_NOTES.md")" == "## $V" ]] ||
  die "rewrite RELEASE_NOTES.md for $V first (its first line must be \"## $V\")"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || swift package --package-path "$ROOT" resolve
xcrun notarytool history --keychain-profile notary >/dev/null 2>&1 ||
  die "notarytool profile \"notary\" missing, or Apple unreachable (see the README's one-time setup)"

# Pin gh to the personal account; the active gh account can drift between
# work and personal mid-run. (git push goes over the SSH remote, not gh.)
GH_TOKEN="$(gh auth token --user taylorbird)" || die "gh is not logged in as taylorbird"
export GH_TOKEN

echo "$V" > "$ROOT/VERSION"
mkdir -p "$ROOT/release-notes"
cp "$ROOT/RELEASE_NOTES.md" "$ROOT/release-notes/$V.md"
git -C "$ROOT" add VERSION RELEASE_NOTES.md "release-notes/$V.md"
git -C "$ROOT" commit -q -m "Release v$V"
git -C "$ROOT" tag "v$V"
echo "==> Committed and tagged v$V (local)"

PUSHED=0
on_error() {
  if (( PUSHED )); then
    echo "release: failed after pushing main and v$V. Do not reset; finish by hand:" >&2
    echo "  gh release create v$V \"$ROOT/dist/SpaceManager-$V.dmg\" \"$ROOT/dist/appcast.xml\" --repo $REPO --title \"Space Manager $V\" --notes-file \"$ROOT/RELEASE_NOTES.md\" --latest" >&2
  else
    echo "release: failed before pushing. To retry: git tag -d v$V && git reset --hard HEAD~1" >&2
  fi
}
trap on_error ERR

echo "==> Packaging and notarizing"
"$ROOT/scripts/package-dmg.sh"
DMG="$ROOT/dist/SpaceManager-$V.dmg"

echo "==> Generating appcast"
FEED="$ROOT/build.noindex/appcast"
rm -rf "$FEED"
mkdir -p "$FEED"
cp "$DMG" "$FEED/"
cp "$ROOT/RELEASE_NOTES.md" "$FEED/SpaceManager-$V.md"
"$SPARKLE_BIN/generate_appcast" --account spacemanager --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$V/" \
  --full-release-notes-url "https://github.com/$REPO/releases/tag/v$V" "$FEED"
cp "$FEED/appcast.xml" "$ROOT/dist/appcast.xml"

echo "==> Publishing"
git -C "$ROOT" push --atomic origin main "v$V"
PUSHED=1
gh release create "v$V" "$DMG" "$ROOT/dist/appcast.xml" --repo "$REPO" \
  --title "Space Manager $V" --notes-file "$ROOT/RELEASE_NOTES.md" --latest
trap - ERR
echo "==> Released v$V: https://github.com/$REPO/releases/tag/v$V"
