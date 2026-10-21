# Octo-owned Ghostty integration

Octo now uses `OctoTerminal → OctoGhostty → GhosttyKit`, with the last module compiled locally from official Ghostty source. `Lakr233/libghostty-spm` and `MSDisplayLink` are removed from the active package graph. No renamed fork, community binary download, or runtime fallback is used.

The full embedding interface at this pin is an **internal API** tailored to Ghostty's own app. It is not a stable public embedding SDK. `libghostty-vt` alone does not supply the Metal renderer, PTY and native runtime Octo needs. The host owns the C boundary so future upstream changes remain confined to `OctoGhostty`.

## Build and verify

Use Xcode 26 or newer, the macOS 26 SDK and Apple's Metal compiler. This migration was built with Xcode 26.3 (17C529), SDK 26.2 (25C58), Zig 0.15.2 on arm64. The application deployment floor remains macOS 14; that minimum runtime and Intel have not been tested here.

```sh
# One-time Apple component, if doctor reports it missing:
xcodebuild -downloadComponent MetalToolchain
./Scripts/setup.sh --check
./Scripts/build-ghostty.sh
./Scripts/verify-ghostty.sh
swift test
./Scripts/build-app.sh
codesign --verify --deep --strict "build/Octo Dev.app"
python3 -m unittest discover -s Tests/GhosttyBuild
python3 Scripts/ghostty/smoke.py
# For engine/lifecycle checks while using the desktop (skips keyboard focus):
python3 Scripts/ghostty/smoke.py --background
```

`make build`, `make test`, `make app` and setup bootstrap Ghostty before SwiftPM resolves the local binary target. Direct Xcode/SwiftPM builds require that bootstrap first. On an existing checkout, stale community `GhosttyKit.swiftmodule` outputs can shadow the new C module. Clean the previous Swift/Xcode build outputs before the first migration build, then rerun bootstrap. Preserve `.build/ghostty` if moving old caches aside; `swift package clean` may require bootstrapping again. Do not edit dependency source or reuse old headers. When moving from the initial Zig 0.16 build, preserve its generated `.build/ghostty/source/zig-pkg` directory outside the source checkout (for example `.build/ghostty/previous-dev-zig-pkg`); 1.3.1 uses the Zig 0.15 global package cache and does not ignore that older directory. The clean-source check intentionally refuses to discard it automatically.

`Vendor/Ghostty.lock.json` pins stable **Ghostty 1.3.1**, official tag `v1.3.1` at `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`. On October 4, 2026, the user requested this change from the initial 1.3.2-dev integration at `3c47ca159368eb4a860ffe5333abdf4a85b2767b`. The [1.3.2 milestone](https://github.com/ghostty-org/ghostty/milestone/14) remains open past its May 31 target; no revised release date was found. The [1.3.1 release](https://ghostty.org/docs/install/release-notes/1-3-1) uses Zig 0.15.2. **No community or Octo engine patches are applied**. The build checks the official repository URL, exact checkout, clean tracked/untracked source, header/module-map hashes, official Zig archive hash, XCFramework architecture and all staged output hashes. Ghostty's own `build.zig.zon` pins transitive source downloads. Xcode/SDK versions are recorded in the manifest and invalidate the local output cache when changed.

Generated files are ignored:

- `.build/ghostty/source`: official source checkout, with no patches.
- `.build/ghostty/GhosttyKit.xcframework`: native static framework and matching header/module map.
- `.build/ghostty/build-manifest.json`: tools, inputs and output inventory.
- `Sources/OctoGhostty/Resources/Runtime`: matching terminfo, shell integration, themes and notices, copied into the app's `OctoKit_OctoGhostty.bundle`.
- `.build/ghostty/native-smoke.json`: latest standalone native validation result.

The archive contains Ghostty's embedded font/shader/engine data. The separately staged assets come from the same build. Missing resources produce a visible host error instead of a blank, silently substituted terminal. Both SwiftPM lockfiles are retained with empty package pins; SwiftPM can remove an empty lockfile during resolution. Ghostty's source/toolchain lock is now the authoritative dependency pin.

The recipe supports the host architecture only. Ghostty 1.3.1’s upstream universal target also emits iOS slices, so Octo rejects that target instead of claiming an unverified macOS universal build. Intel hardware remains untested. Neither byte-identical reproducibility nor a fresh build on a second machine has been established. CI now bootstraps the same source recipe and installs Apple's Metal component; the hosted workflow has not been run from this local task.

## Host responsibilities

`GhosttyRuntime` initializes Ghostty once with Octo-owned arguments and bundled assets. Ghostty retains ownership of PTYs, terminal state, rendering and its display link. Thread-safe wakeups coalesce onto the main actor and keep ticking while tabs are hidden. Octo does not need MSDisplayLink.

`GhosttySession` owns its native view and surface independently of SwiftUI visibility. Detach/reattach, theme changes and resize retain that surface. Hiding disables input, focus and rendering while output/lifecycle callbacks continue. Explicit tab close and app shutdown release the surface; queued callbacks carry an invalidatable context rather than a freed C handle. Pending clipboard requests are denied before disposal. Neovim launch/socket routing remains in `OctoTerminal` and uses the user's installed editor/configuration.

`GhosttyNativeView` supplies native keyboard/modifier/key-up translation, NSTextInputClient composition, mouse selection/reporting/scrolling, backing scale, display identity and cursor mapping. Ordinary copy/paste, file-path/URL paste and selection paste use bounded text data. File paths are shell-quoted. Image/binary MIME clipboard transfer and Kitty clipboard requests are unsupported by this host at 1.3.1. The stable API supplies NUL-terminated text, so the bridge bounds string scans, rejects invalid UTF-8 and copies borrowed data before prompting. URL actions accept http, https and mailto; other schemes produce a notice. Ghostty actions requiring host UI that Octo does not implement return unsupported and display a notice; native geometry/tab titles remain owned by Octo. Split actions (`new_split`, `goto_split`, `resize_split`, `equalize_splits`, `toggle_split_zoom`) are implemented by the host. `new_split` reads `ghostty_surface_inherited_config(…, SPLIT)` during the callback; Ghostty allocates its working-directory copy with no free function, and its own macOS app leaks it the same way.

Protected clipboard reads/writes and unsafe paste now require a native **Allow Once** decision with Cancel as the default. This deliberately replaces the former wrapper's automatic confirmation of user paste. No remembered grants are issued. Hidden tabs, concurrent prompts and teardown deny pending access. Normal operations already allowed by the user's Ghostty policy continue through that policy. Unlike the development API, 1.3.1 has no dedicated denial function: cancellation completes a read with empty text, consuming the request without sharing clipboard contents or pasting input. An OSC 52 reader receives an empty response. Cancelled writes leave the clipboard unchanged.

Configuration reloads from `~/.config/ghostty/config` plus its includes, then applies the chosen Octo color overlay. System removes the overlay by rebuilding from the base, preserving process and scrollback. Config diagnostics are visible. This retains Octo's existing single base-config path, not every config-location rule of the standalone Ghostty app. The user's Neovim theme is unchanged.

## Retired patch inventory

Reviewed the former package at `b7f888e3baf8585ea9d590ab1a45b49475e00d1c`, not its moving main branch. All 17 numbered Ghostty patches are accounted for below. None is applied. A successful arm64 build/smoke is evidence for that configuration only, not proof that each patched problem is absent on every platform.

| Patch | Octo disposition |
| --- | --- |
| 0001 Darwin library install | Unneeded: official XCFramework build exports archive/header/module map. |
| 0002 host-managed I/O | Unused: Octo keeps Ghostty's normal exec/PTY ownership. |
| 0003 prebuilt frame data | Unneeded: build the official generator/data from source. |
| 0004 iOS fixes | Outside this macOS host. |
| 0005 iOS Metal rendering | Outside this macOS host. |
| 0006 disable custom shaders | Not adopted; use upstream build options and dependencies. |
| 0007 disable inspector | Not adopted; no Octo inspector UI is exposed. |
| 0008 macOS texture storage | **Unresolved on Intel/AMD GPUs**; arm64 native smoke passed without it. |
| 0009 libc++ availability | **Minimum-OS validation outstanding**; unchanged build links locally. |
| 0010 scroll remainder | **Trackpad smoothness comparison outstanding**; no inherited parser/scroll patch. |
| 0011 response suppression for replay | Unused: no host-managed reconstructed-scrollback replay. |
| 0012 visionOS | Outside this macOS host. |
| 0013 host toolchain | Xcode 26.3 builds unchanged 1.3.1 source with Zig 0.15.2; the newer emit-lib-vt option is absent and not passed. Xcode 27 unverified. |
| 0014 synchronized-output resize | **Continuous TUI resize comparison outstanding**; lifecycle/grid-resize smoke passes. |
| 0015 prompt redraw frame hold | **Frame pacing comparison outstanding**; no claim of identical redraw timing. |
| 0016 Mac Catalyst | Outside this macOS host. |
| 0017 Zig packages / Apple mobile targets | Outside this macOS host. No package/toolchain patching. |

The former Zig mobile-target patches are also excluded. Future changes require a concrete reproducer, focused validation, reviewed source diff and a recorded patch/removal condition in the build contract. No automatic upstream upgrades are configured.

## Verification and remaining coverage

The initial community-backed baseline passed 160 Swift tests. The owned-module suite passes 169 tests, including native input mapping, control/Unicode handling, color-injection rejection, bounded stable-API clipboard strings and invalid UTF-8 rejection, exactly-once clipboard resolution, cancellation on close and invalidated late callbacks. Build-verification tests reject changed/missing/extra outputs and stale lock/recipe/revision/target records.

The standalone native host compiles only Octo's wrapper plus the official-source static library. It checks shell/render startup, native Settings/Quit menu precedence, Unicode and Return, hidden output/accessibility and ignored input, focus restoration, grid resize, theme apply/reset, view detach/reattach, stable process identity, child-exit notification, idempotent teardown and explicit close of a live child. The 1.3.1 regression run verifies the linked engine reports `1.3.1` and exercises real engine clipboard requests through cancellation, a subsequent request, one-time approval and closing a surface with a pending request. Shell identity is read from fixture output because 1.3.1 has no foreground-PID accessor. It uses a disposable `/bin/sh`/`sleep`, never an agent model. The first 1.3.1 foreground run passed 19 checks. Later repeats were interrupted by desktop focus/typing, so the final run used `--background`: 18 checks passed, with five native keyboard/focus/menu checks explicitly skipped in the result. Background mode does not activate its test window and supplies fixture text directly to the engine; it is not a replacement for foreground input coverage.

Before the change to 1.3.1, an isolated full app additionally verified shell PID/environment continuity across panel, Chats and editor navigation; clipboard denial and one-time approval; and the installed Neovim configuration opening/reusing a quoted Unicode filename and returning to a usable shell after `:qa`. The visual terminal and editor were inspected. A final full-app pass confirmed clean terminal startup and Cmd-Q reaching Octo’s normal quit confirmation. Native clipboard sheets and routine key-state notifications exposed and helped fix menu/accessibility integration issues during this check.

Full IME candidate interaction, international layouts/dead keys, VoiceOver editing/navigation, trackpad momentum, multi-display/sleep-wake behavior, long-session memory/CPU profiling, Intel and macOS 14 remain manual/hardware validation. The bridge exposes visible/selected text to accessibility, but does not implement the standalone app's full screen-buffer accessibility model. Do not equate the automated checks with that broader parity matrix.

No release/publish workflow, notarization, app-sandbox change, or provider-permission change is included. Review [notices](../Vendor/Ghostty-NOTICES.md) and the [interactive work plan](ghostty-integration-plan.html) for source provenance and remaining gates. Rollback is an explicit source rollback to the prior integration and restores its third-party dependency; there is no silent runtime fallback.
