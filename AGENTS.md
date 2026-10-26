# Working on Octo

Read README.md and docs/ARCHITECTURE.md before changing behavior. When a capability or limitation changes, update the doc that describes it. Docs describe current behavior; change history, test counts and verification notes belong in commit messages.

## Product invariants

- Electron + React application shell. The renderer is sandboxed with context isolation and no Node access; the preload exposes a narrow typed API (`src/shared/ipc.ts`).
- Diffs and the file editor use `@pierre/diffs`, pinned to an exact version.
- Projects contain chat threads in the sidebar. Each project has one terminal workspace with generic tabs.
- Keep inactive terminal surfaces mounted. Hiding a tab must not destroy its shell or editor; hidden terminals keep receiving output and only stop drawing.
- Open in Neovim means the user's installed `nvim` and its own configuration (such as LazyVim), not a bundled editor distribution.
- Code selection is attached to the draft with path, checkout, snapshot and old/new line metadata. Never silently send it.
- Provider-specific protocols belong in `packages/agents`, never in UI components. Report unsupported capabilities honestly.
- Preserve provider approval and sandbox boundaries. Never add bypass-permission flags to make an integration test pass.
- Only the main process spawns processes.
- Every IPC event carries its owner (thread, checkout, connection plus turn) and is dropped when superseded.

## Implementation

`apps/desktop` owns composition: `src/main` (state owner, processes), `src/preload`, `src/renderer` (React UI), `src/shared` (IPC contract). Dependencies point inward to `packages/core`. The default `@octo/core` entry must not import Node, Electron, React or any provider implementation; Node-only storage and process code lives in `@octo/core/node`. `packages/agents` and `packages/git` run in the main process only.

Keep process arguments as arrays. Do not interpolate user paths into shell commands except the terminal's explicitly shell-quoted launch boundary.

The main process owns long-lived state (archive, harnesses, Git queue, ptys, browser views) and publishes it to the renderer as Immer patches. Renderer stores hold view state only. Git work for a checkout runs on that checkout's serialized queue.

Add focused tests for behavior involving source ranges, framing, persistence, Git parsing, or process lifecycle. Do not call paid models in automated tests. `pnpm test` and `pnpm build` are the baseline checks. UI or terminal changes additionally require `pnpm smoke` (Playwright driving the built Electron app against a throwaway data folder).

Keep `pnpm-lock.yaml`. Pin exact dependency versions. Do not silently bump the libghostty-vt pin or rebuild its WASM. Record protocol versions and upstream references when changing adapters. Update THIRD_PARTY_NOTICES.md whenever vendored code changes. No release/publish workflow is configured.

## Identity

Release: "Octo", `dev.octo.app`, data in `~/Library/Application Support/Octo`. Development: "Octo Dev", `dev.octo.app.dev`, data in `…/Octo Dev`. The data folder is resolved in `src/main/dataFolder.ts` and never follows the display name: a folder this app owns carries a `.octo` marker (earlier builds wrote `.octo-electron`, which is still accepted). Never write into an unmarked folder.
