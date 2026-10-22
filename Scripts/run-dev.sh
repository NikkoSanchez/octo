#!/bin/bash
# Builds and opens Octo Dev, the development copy with its own chats. A running Octo Dev is
# quit first: `open` would otherwise bring the old process forward instead of launching the
# new build. The installed Octo is not touched.
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build-app.sh
if pgrep -af "/Octo Dev.app/Contents/MacOS/Octo" >/dev/null; then
  osascript -e 'tell application id "dev.octo.app.dev" to quit' >/dev/null || true
  for _ in $(seq 1 30); do pgrep -af "/Octo Dev.app/Contents/MacOS/Octo" >/dev/null || break; sleep 0.5; done
  if pgrep -af "/Octo Dev.app/Contents/MacOS/Octo" >/dev/null; then
    echo "Octo Dev is still running (it may be asking to confirm quitting). Quit it, then run this again." >&2
    exit 1
  fi
fi
open "build/Octo Dev.app"
