# Architecture

Octo is a workspace for coding agents. It drives locally installed agent CLIs (Codex, Claude Code), shows their conversations beside Git review, and keeps a persistent terminal per project. This document explains how the code is put together. It describes current behavior only; history lives in commit messages.

## Packages

```text
apps/desktop
  ├── main (Electron main process) ── @octo/agents ── @octo/core
  │                                ── @octo/git ───── @octo/core
  │                                ── @octo/core/node
  ├── preload (typed bridge)
  └── renderer (React) ───────────── @octo/core
```

Dependencies point inward. The default `@octo/core` entry is pure TypeScript: no Node, Electron, React or provider code, so both processes share it (a test enforces this). `@octo/core/node` holds the Node-only parts: archive storage, checkout file access, the managed subprocess and the finite process runner.

## Processes and trust

The renderer runs sandboxed with context isolation and no Node integration. `src/preload/index.ts` exposes `window.octo` with two bridge operations: `call(service, action, …args)` for allowlisted methods in `src/shared/ipc.ts` (`Services`) and `on` for event channels (`Events`). Both are checked against runtime allowlists in `src/shared/channels.ts`, which a compile-time assertion keeps in step with the types. The main process answers only requests from the app window's own main frame.

The app window never navigates; links open in the default browser. The default session denies permission requests.

## Identity and data

`src/main/identity.ts` runs before `ready`. It sets the app name and pins `userData` to `~/Library/Application Support/Octo` (release) or `…/Octo Dev` (development and unpackaged runs), never deriving the folder from the display name. `dataFolder.ts` resolves it: a folder carrying the `.octo` marker is used as is, and one carrying the earlier `.octo-electron` marker gets `.octo` added beside it. An unmarked folder belongs to another app; Octo shows an error and quits without writing into it. A fresh Mac gets a marked folder created atomically. `OCTO_USER_DATA` overrides it for tests. A single-instance lock prevents two writers on one data folder.

## Data model and persistence

`WorkspaceArchive` holds `WorkspaceProject`s; one built-in project with `isChatCollection` is the Chats section. Projects hold `WorkspaceThread`s, which hold `ChatMessage`s. In memory, dates are epoch milliseconds and images are base64 PNG strings.

`archiveCodec.ts` reads and writes schema-v1 JSON exactly: dates as seconds since 2001-01-01, binary data as base64, enum payloads as `{"case":{"_0":…}}`, UUID-keyed dictionaries as flat key/value arrays, and absent fields omitted. Existing archives must keep loading, so new fields must be optional.

`WorkspaceStore` writes the whole archive atomically with owner-only permissions: a `0600` temporary created with `O_EXCL`, fsync, then rename. It refuses storage inside a Git checkout (resolving symlinks), refuses symlinked or hard-linked archives and group/world-writable custom parents, and preserves a corrupt or newer archive. `WorkspaceArchiveWriter` coalesces debounced saves so only the newest snapshot is written.

## Subprocesses

`ManagedSubprocess` launches argument arrays as the leader of a new process group (`detached`), with bounded input (36 MB queue, 15 s write stall), an optional output cap and deadline. Stop sends TERM to the group, then KILL after 300 ms; when the leader exits, the rest of its group is killed. `runProcess` runs a finite command to completion (30 s default deadline, 8 MB output cap) with PATH augmented by the common install locations, because apps launched from the Dock inherit launchd's minimal PATH.

## Checkout files

`CheckoutFileService` creates, saves and deletes files inside a checkout. Paths must be relative, without `.`, `..`, empty components or `.git`. Node has no `openat`, so every parent component is checked with `lstat` (no symlinks), the parent's real path must equal the checkout's real path plus those components, and files open with `O_NOFOLLOW`. Files must be regular with one hard link; the editor accepts UTF-8 text up to 2 MB. A save captures the file's identity (device, inode, size, modification and change times) and content when opened, rechecks both immediately before an atomic replacement, and keeps the original mode. A narrow race between the parent check and the open remains; descriptor-relative opens (`openat`) would close it.

## Review and code capture

`ReviewDocument` lays one or more files out as text and maps every display range back to exact source UTF-16 ranges and old/new line numbers, excluding gutters and headers. Ranges are UTF-16 offsets, the native unit of JavaScript strings. A selection becomes a `CodeAttachment` carrying path, checkout, snapshot identity (SHA-256 of the file's lines) and line ranges. `SourceDocument` does the same for a plain file in the editor.

## React shell and chat

The main-process `AppStore` owns conversation state, provider connections, catalogs, approvals, interactions, attachments and queues. Its `StateStore` publishes versioned Immer patches. React starts a snapshot-and-patch mirror (`state/app.ts`); a missing version requests a fresh snapshot while retaining later events. Disposing a subscription retires its in-flight requests. The renderer never edits the archive directly.

Views select only what they draw. `useApp` compares a selection shallowly and `useAppPresentation` compares a derived presentation structurally, so a streamed delta, which replaces its thread on every patch, re-renders only the transcript that shows it. `state/ui.ts` holds per-thread draft text, layout, sheets, search and focus requests; only the composer subscribes to draft keystrokes.

The renderer is split by surface: `components/workspace` (the window, the titlebar and its glass capsule), `components/sidebar` (the sidebar card and thread rows), `components/chat` (`ChatPane`, the transcript, Markdown, `Composer`, `AgentControls`, context usage, the find bar and `InteractionCard`), `components/review` (the review card, `GitHeader`, `CommitComposer`, the Git sheets, Files and `BrowserPane`), `components/project` (`ProjectActions` and its branch picker) and `components/overlays` (the command palette, Settings with the theme gallery, account usage and the usage dashboard, alerts and file actions). Panels are translucent themed cards with a two-tone rim, opaque under Reduce Transparency. Text fields and small glass controls are outlined in the theme's text colour, at whatever opacity gives every theme the same contrast against its panel colour. Scrollbars, including the terminal's, are drawn only while the user scrolls (wheel, touch, scroll keys or a held pointer) or hovers the thumb, and fade a second after the last scroll; programmatic scrolling, such as a transcript following streamed output, leaves them hidden (`lib/scrollbars.ts`).

The sidebar presentation (`lib/sidebar.ts`) excludes live response bodies while a thread works and caches completed previews per thread object. Lists keep the selected and working threads beyond the page limit, and only one place (pinned strip, project or Recent) draws the selection: where the thread was opened while it is listed there. ⌘K searches in the sidebar while it shows and opens the palette otherwise.

`ChatPane` renders the Core Markdown parser as React elements without interpreting raw HTML; find highlights occurrences inside formatted runs. Turns keep activity and reasoning in one collapsible work row per run, show a live "Working for…" status, and end with how long the turn took. `useTranscriptScroll` owns follow intent: only the user's own wheel, touch, key or scrollbar input changes it, and streamed layout never does. Unread completion is cleared only for the visible, focused chat while following.

`Composer` guards IME composition, applies Markdown list edits using UTF-16 textarea selections, inserts provider-advertised slash commands without sending, and passes explicit sends to the main store. A response clears only the submitted thread's unchanged text. Main retains ownership of images, code captures, annotations and queued message snapshots. Provider-neutral decision cards render descriptor-supported controls and validate forms before replying to their connection/turn-bound IDs.

One command registry (`lib/commands.ts`) supplies the palette, the menu bar, key routing and ⌘-hold hints. Capture-phase routing reserves app commands on key-down and on the matching key-up; while a sheet or popover has the keyboard, keys stay with it. A panel and the terminal can share a key; the visible surface's command wins, and main forwards keys from native browser pages by the same rule. Sheets are modal `<dialog>`s and popovers are stack-aware, so a popover opened from another (the branch picker) doesn't close its parent. Both count as overlays, which hides native browser views.

When review and terminal are closed, the project actions card floats in the chat's trailing margin only when a 260-point card plus spacing fits beside the 840-point chat column; otherwise it opens as a popover from the titlebar capsule. Git reads remain in main and refresh on selection, checkout events, focus and agent completion.

## Review and editor surfaces

The lazily loaded review card shows the selected project's panel tabs and keeps every open surface mounted: Changes, Files with one Pierre editor per open file tab, and one pane per browser tab. Hidden surfaces leave the accessibility tree with `inert`. Panel tabs and preview/pinned paths use the Core archive model.

Per checkout, `state/review.ts` holds the changed files, every staged and unstaged diff for the continuous view, the chosen row and the file the header follows, and drops superseded refreshes and selections. In `state/git.ts`, actions on a checkout run one at a time with an activity label, failures become banners (push failures keep Retry and say the commits are safe), and a commit leaves the next explicit step, Push or Create PR. Stashes and pull requests use sheets; discards always ask through the system alert.

Pierre renders virtualized stacked or side-by-side diffs with a two-worker Shiki pool and a theme derived from the Core syntax palette. `reviewCapture.ts` maps Pierre selections back to the original snapshot's old/new source ranges and places Stage or Unstage Hunk above each hunk as a line annotation; gutter controls attach without sending.

Pierre's experimental edit provider retains document and undo state independently of panel visibility. Each file editor scrolls inside its own Pierre `Virtualizer`, which keeps that file's scroll position. The wrap toggle (`wrapLines` in `state/review.ts`) sets Pierre's `overflow` to `wrap` for every diff and editor. `state/files.ts` keeps renderer buffers and debounces saves. Every edit also sends its latest draft to main; `ReviewService` serializes file writes against the captured identity and retains newer drafts while older saves finish. Outside changes preserve the draft and require explicit reload. Quit flushes pending drafts before shutting down services; failed saves allow the user to keep editing. Closing the macOS window hides it without destroying its renderer.

Commit-message generation is bound to a request ID, checkout and visible Changes surface. Hiding retires the request. A successful response replaces the message in one undoable edit; committing remains explicit.

## Terminals

Main owns `node-pty` processes, the per-project workspace, split layout, bounded replay and backpressure. Each output event carries its pane ID and cumulative UTF-16 cursor. The renderer subscribes before requesting a snapshot, queues intervening events, drops replay overlap, and resynchronizes on a gap. Monotonic workspace versions reject stale layout snapshots. Output feeds the bound Ghostty surface directly, outside React state; acknowledgments follow ingestion.

The lazily loaded terminal workspace is a rounded box under the titlebar: a tab strip (rename by double-click, split, zoom and more actions) over tiled split panes. It retains all tab/pane surfaces of every project. Hidden surfaces keep updating the VT state and pause drawing only. Split ratios, pane zoom, focus and tab selection belong to the main workspace. App shortcuts win on key-down and key-up, including when terminal input or a native browser page has focus. Ghostty's default split, pane and tab keys are app commands available while the terminal shows; bindings in the user's Ghostty config run inside the focused surface.

The T3 adapter, WASM artifacts, Nerd Font, native headers and upstream licenses are vendored at the revisions in `native/libghostty-vt/provenance.json`. Its Canvas renderer uses the pinned official Ghostty C ABI. The rebuild script is a manual maintenance operation; ordinary builds use the checked-in WASM. See [terminal configuration](TERMINAL.md).

Open in Neovim starts the installed `nvim` with a private listen socket and the user's configuration. Neovim can miss a resize that arrives while it starts, and would then keep drawing at the PTY's initial 80×24. So the launch script waits, at most 2 s, until main has applied the renderer's first measured size to the PTY. Later opens reuse that socket with safely encoded paths; exit returns to a login shell. CLI sign-in runs in a dedicated explicitly requested terminal, without reading credentials into application state.

## Browser panels

Main owns one sandboxed `WebContentsView` per browser tab. Renderer bounds and visibility updates position the native overlay; it hides behind app dialogs and when its panel is inactive. Normal pages use a persistent partition and private pages an in-memory partition. Pages receive no preload or Node integration. Permissions are denied except sanitized clipboard writes. Popups, external application URLs and default-browser actions use the main navigation policy.

Element/region pickers execute in an isolated world. Validated annotation data and screenshots are passed to main-owned draft attachments, labeled untrusted, and never automatically sent. Browser key events reserve app commands before the page can handle them.

## Usage and project actions

Account limits render provider-reported buckets and windows with explicit capability checks. The dashboard reads local CLI usage records in main and summarizes tokens by model and day in the renderer; it does not infer prices or missing limits. Project actions call the serialized Git service for branches/stashes and the authenticated `gh` CLI for pull requests.

## Packaging

`make app` and `make release` create separate locally ad-hoc-signed macOS bundles. Vite includes the renderer workers, WASM and font assets; `node-pty` stays unpacked outside ASAR. Packaging generates notices from the locked bundled dependencies plus vendored licenses. Distribution signing/notarization and publishing are not configured. Both channels keep their explicitly pinned data directories.

## Pitfalls

- Electron 44 no longer downloads its runtime on install; the root `postinstall` runs `electron/install.js`.
- Sandboxed preloads must be a single CommonJS file (`out/preload/index.cjs`).
