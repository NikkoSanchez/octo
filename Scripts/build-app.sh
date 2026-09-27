#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-debug}" in
  debug) configuration=Debug ;;
  release) configuration=Release ;;
  *) echo 'Usage: Scripts/build-app.sh [debug|release]' >&2; exit 1 ;;
esac
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
if [[ -d build/Octo.app ]]; then
  rm -rf build/Octo.previous.app
  mv build/Octo.app build/Octo.previous.app
fi
mv "$staging/Octo.app" build/Octo.app
echo "$PWD/build/Octo.app"
