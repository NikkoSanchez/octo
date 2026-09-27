# Working on Octo

Read README.md, docs/ARCHITECTURE.md, and docs/STATUS.md before changing behavior. Update STATUS.md when a capability or limitation changes.

## Product invariants

- SwiftUI application shell; AppKit/TextKit native code review. No webview diff dependency.
- Projects contain chat threads in the sidebar. Each project has one terminal workspace with generic tabs.
- Keep inactive terminal surfaces mounted. Hiding a tab must not destroy its shell or editor.
- LazyVim means the user's installed Neovim configuration, not a bundled editor distribution.
- Code selection is attached to the draft with path, checkout, snapshot and old/new line metadata. Never silently send it.
- Provider-specific protocols belong in OctoAgents, not SwiftUI views. Report unsupported capabilities honestly.
- Preserve provider approval and sandbox boundaries. Never add bypass-permission flags to make an integration test pass.

## Implementation

OctoApp owns composition. Dependencies point inward to OctoCore; Core must not import SwiftUI, AppKit, or any provider implementation. Keep process arguments as arrays. Do not interpolate user paths into shell commands except the terminal's explicitly shell-quoted launch boundary.

Use MainActor for UI and long-lived process event coordination, GitService's actor for Git, and background work for blocking finite subprocesses. The package currently uses Swift 5 language mode with a Swift 6 toolchain; strict concurrency migration is tracked work.

Add focused tests for behavior involving source ranges, framing, persistence, Git parsing, or process lifecycle. Do not call paid models in automated tests. `swift test` and `Scripts/build-app.sh` are the baseline checks. UI or terminal changes additionally require a native smoke test.

Keep Package.resolved. Do not silently update the Ghostty binary dependency. Record protocol versions and upstream references when changing adapters. No release/publish workflow is configured.
