#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  ''|--check) ;;
  *) echo 'Usage: Scripts/setup.sh [--check]' >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Octo requires macOS 14 or newer.' >&2; exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 14 )); then
  echo 'Update this Mac to macOS 14 or newer.' >&2; exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo 'Install full Xcode, launch it once, and select it in Xcode > Settings > Locations > Command Line Tools.' >&2
  exit 1
fi
xcode_major="$(xcodebuild -version | sed -nE 's/^Xcode ([0-9]+).*/\1/p')"
if [[ -z "$xcode_major" ]] || (( xcode_major < 26 )); then
  echo 'The pinned Ghostty source build requires Xcode 26 or newer with the macOS 26 SDK.' >&2; exit 1
fi
if ! xcrun --sdk macosx metal --version >/dev/null 2>&1; then
  echo 'Install the Apple Metal compiler: xcodebuild -downloadComponent MetalToolchain' >&2; exit 1
fi
swift_major="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)"
if [[ -z "$swift_major" ]] || (( swift_major < 6 )); then
  echo 'Select an Xcode installation with Swift 6 or newer.' >&2; exit 1
fi
command -v git >/dev/null
command -v python3 >/dev/null
printf 'Prerequisites ready: macOS %s, Swift %s.\n' "$(sw_vers -productVersion)" "$swift_major"
codex_found=false
for app_root in /Applications "$HOME/Applications"; do
  for candidate in "$app_root/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" "$app_root/Codex.app/Contents/Resources/codex"; do
    if [[ -x "$candidate" ]]; then codex_found=true; fi
  done
done
if command -v codex >/dev/null 2>&1; then codex_found=true; fi
if ! $codex_found; then echo 'Optional: install and sign in to Codex before starting an agent chat. See README.md.'; fi
if ! command -v nvim >/dev/null 2>&1; then echo 'Optional: install Neovim for Open in LazyVim. Octo does not install or replace your editor configuration.'; fi
if [[ "${1:-}" == --check ]]; then exit 0; fi
hooks="$(git config --local --get core.hooksPath || true)"
if [[ -z "$hooks" || "$hooks" == .githooks ]]; then
  git config --local core.hooksPath .githooks
else
  printf 'Keeping existing Git hooks at %s. Run python3 Scripts/check-private-data.py before committing.\n' "$hooks"
fi
# Commit identity is per checkout. Never copy credentials or modify global Git settings.
if [[ -z "$(git config --local --get user.email || true)" ]]; then
  identity=""
  if command -v gh >/dev/null 2>&1; then
    identity="$(gh api user --jq '"\(.id) \(.login)"' 2>/dev/null || true)"
  fi
  if [[ "$identity" =~ ^([0-9]+)[[:space:]]([A-Za-z0-9-]+)$ ]]; then
    account_id="${BASH_REMATCH[1]}"
    account_login="${BASH_REMATCH[2]}"
    git config --local user.email "$account_id+$account_login@users.noreply.github.com"
    if [[ -z "$(git config --local --get user.name || true)" ]]; then git config --local user.name "$account_login"; fi
    echo 'Configured this checkout to use your GitHub noreply commit identity.'
  else
    echo "Before committing, set this checkout's Git user.email to your GitHub noreply address. Global identity was not changed."
  fi
fi
python3 Scripts/check-private-data.py --worktree
./Scripts/build-app.sh
printf '\nReady. Launch with: open build/Octo.app\n'
printf 'This Mac starts with its own local workspace. Add your project and authenticate your provider locally.\n'
