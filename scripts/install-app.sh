#!/bin/bash
# Installs a release build as the Octo you use day to day, in ~/Applications by default.
# A running Octo is never quit: the new version waits beside it and replaces it once it has quit,
# so an agent or terminal inside Octo can run this safely.
set -euo pipefail
cd "$(dirname "$0")/.."
directory="${OCTO_INSTALL_DIR:-$HOME/Applications}"
app="$directory/Octo.app"
mkdir -p "$directory"
# Built straight into the staging bundle, so no copy anyone is running from is replaced.
node apps/desktop/scripts/package.mjs release "$directory/.Octo-update.app"
if pgrep -af "/Octo\.app/Contents/MacOS/Octo( |$)" >/dev/null; then
  # Its own session, so quitting the app (and the terminal this runs in) does not end it.
  python3 -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
    "$PWD/scripts/finish-install.sh" "$directory" </dev/null >/dev/null 2>&1 &
  echo "Octo is running. The new version replaces it when you quit it; open it again to use it."
else
  ./scripts/finish-install.sh "$directory"
  open "$app"
  echo "Installed $app"
fi
