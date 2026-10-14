#!/bin/zsh
# Switch back from the dev build to the installed live app: quit
# "Space Manager Dev", then open "Space Manager" from /Applications.
set -euo pipefail

osascript -e 'quit app id "com.taylorbird.spacemanager.dev"' 2>/dev/null || true
for _ in {1..50}; do
  pgrep -f "Space Manager Dev.app/Contents/MacOS/SpaceManager" >/dev/null || break
  sleep 0.1
done
open -b com.taylorbird.spacemanager
echo "Live Space Manager running."
