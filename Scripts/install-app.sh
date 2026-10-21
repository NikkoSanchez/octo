#!/bin/bash
# Installs a Release build as the Octo you use day to day, in ~/Applications by default.
# A running Octo is never quit: the new version waits beside it and replaces it once every Octo
# (any copy; they share one chat history) has quit, so an agent or terminal inside Octo can run this safely.
set -euo pipefail
cd "$(dirname "$0")/.."
directory="${OCTO_INSTALL_DIR:-$HOME/Applications}"
app="$directory/Octo.app"
mkdir -p "$directory"
# Built straight into the staging bundle, so no copy anyone is running from is replaced.
./Scripts/build-app.sh release "$directory/.Octo-update.app"
if pgrep -f "/Octo\.app/Contents/MacOS/Octo( |$)" >/dev/null; then
  # Its own session, so quitting Octo (and the terminal this runs in) does not end it.
  python3 -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
    "$PWD/Scripts/finish-install.sh" "$directory" </dev/null >/dev/null 2>&1 &
  echo "Octo is running. The new version replaces it when you quit Octo; open Octo again to use it."
else
  ./Scripts/finish-install.sh "$directory"
  open "$app"
  echo "Installed $app"
fi
