#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-debug}" in
  # Debug is the development copy, "Octo Dev" with its own chats; Release is the app you use.
  debug) configuration=Debug; name="Octo Dev" ;;
  release) configuration=Release; name=Octo ;;
  *) echo 'Usage: Scripts/build-app.sh [debug|release] [output.app]' >&2; exit 1 ;;
esac
# The output defaults to build/<name>.app; install passes its staging location instead.
output="${2:-$PWD/build/$name.app}"
./Scripts/build-ghostty.sh
# Xcode places package resource bundles under Contents/Resources and generates
# the matching accessor; copying a swift-build executable alone does not.
xcodebuild -quiet -project Octo.xcodeproj -scheme Octo \
  -configuration "$configuration" -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build/xcode-packages \
  -destination "platform=macOS,arch=$(uname -m)" ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
mkdir -p build
# Do not overlay a previous bundle: stale resources can invalidate signing.
staging="$(mktemp -d "$PWD/build/.octo-bundle.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto ".build/xcode/Build/Products/$configuration/Octo.app" "$staging/Octo.app"
codesign --force --deep --sign - "$staging/Octo.app"
# Replace the old build rather than keeping it beside the new one: a renamed copy keeps the same
# bundle ID, and Dock items follow it there instead of opening the new build.
if [[ -d "$output" ]]; then mv "$output" "$staging/old.app"; fi
mv "$staging/Octo.app" "$output"
echo "$output"
