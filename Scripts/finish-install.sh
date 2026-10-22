#!/bin/bash
# Moves a staged Octo update into place once no Octo is running.
set -euo pipefail
directory="$1"
app="$directory/Octo.app"
update="$directory/.Octo-update.app"
old="$directory/.Octo-old.app"
while pgrep -af "/Octo\.app/Contents/MacOS/Octo( |$)" >/dev/null; do sleep 1; done
# Another install already applied (or replaced) the update.
[[ -d "$update" ]] || exit 0
rm -rf "$old"
if [[ -d "$app" ]]; then mv "$app" "$old"; fi
mv "$update" "$app"
rm -rf "$old"
