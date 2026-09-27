# Architecture

## Composition and dependencies

```text
OctoApp (SwiftUI, AppStore, ReviewModel)
  ├── OctoAgents ── OctoCore
  ├── OctoGit ───── OctoCore
  ├── OctoReview ── OctoCore
  └── OctoTerminal ─ OctoCore + GhosttyTerminal
```

AppStore composes services and owns the persisted project/thread graph. Views communicate through intent methods; adapters emit provider-neutral AgentEvents. Git operations live on GitService's actor. ReviewModel rejects asynchronous results from a superseded project or file selection.

## Agent sessions

Each active chat has its own harness instance. HarnessID and HarnessRegistry describe locally available providers; AgentHarness exposes send, interrupt, shutdown, and events. Local thread IDs remain stable independently of remote session IDs. Switching projects does not reroute running events: callbacks capture the owning thread ID.

CodexExecutable in OctoAgents resolves a custom absolute executable path first, otherwise a supported desktop-app bundle path, then PATH. A missing explicit override is an error rather than an implicit switch. AppStore persists the override in app preferences, passes the resolved binary to both model discovery and harness creation, closes idle Codex connections when it changes, and rejects changes during active Codex turns. A configuration identity invalidates model caches and ignores discovery responses from a superseded installation. Settings reports the path and `--version` output.

Codex runs a long-lived `codex app-server` over newline JSON. The client initializes, starts/resumes a thread in its checkout, then starts turns. It requests `workspace-write` and `on-request` approval policy. Command and file-change approvals are presented as individual decisions. Unsupported permission expansion and MCP elicitation are declined; unknown server requests return an explicit protocol error. The installed CLI's own policies remain authoritative.

Claude Code starts `claude -p` per turn with stream-json and session resume. Print mode has no Octo interactive approval bridge. Denied tools are surfaced; no permissive flags are substituted. Codex discovers its model catalog through paginated `model/list` requests on a separate read-only app-server connection, without starting a thread or turn. OctoAgents decodes model IDs and supported reasoning efforts; the composer consumes these descriptors. Optional provider-neutral AgentSettings persist per thread, with older archives defaulting to no overrides. Explicit model and effort choices are passed on every Codex turn, including resumed sessions; model changes preserve compatible efforts or choose the advertised default. Unavailable catalog choices are reported without consuming the draft. Claude still inherits CLI model/reasoning configuration and rejects unsupported overrides. See ADDING_A_HARNESS.md.

JSONLineProcess owns bounded framing and stderr capture. OctoCore ManagedSubprocess launches each CLI in its own POSIX process group with nonblocking pipes, bounded outbound queues, and backpressure to MainActor protocol handling. Stop signals the group, escalates from TERM to KILL after 300 ms, drains briefly and reaps the child. Finite commands additionally have a 30-second deadline and an 8 MB combined output limit. Deliberately detached descendants are outside this lifecycle boundary; it is not a sandbox. Complete, fragmented and EOF protocol frames share the 8 MB inbound limit. Unrelated inherited file descriptors are closed at spawn. RPCConnection matches request IDs and propagates disconnects/timeouts. This transport is internal to OctoAgents; protocol fixtures test it without a paid model request.

## Review and captured context

GitService reads NUL-delimited porcelain status and unified diffs for the selected scope. It never stages, resets or commits files. ReviewSnapshot includes checkout, file, HEAD revision, scope and a content-derived identity. Working diffs compare the index to disk; staged diffs compare HEAD to the index. The snapshot hash captures rendered lines, not a Git object or a promise that the file remains current.

NativeDiffView wraps one AppKit NSTextView using TextKit 2. Native selection, scrolling, clipboard and contextual actions are retained. ReviewDocument maps UTF-16 ranges to the underlying source text, excluding headers and gutters. CodeAttachment carries captured text plus old/new ranges. Attaching it populates a draft; sending is explicit. Refreshing replaces the live selection but previously attached captures remain immutable and tell the agent to verify current files.

The first viewer is unified with lightweight highlighting. It is a separate module so split diff and richer syntax parsing can be added without replacing app state or harnesses. The native SwiftUI OutlineGroup file tree is built from Git-tracked and non-ignored untracked paths; full-file previews share the AppKit text surface and use a distinct file scope. Both full-file and untracked previews walk checkout-relative directory descriptors with no-follow opens, reject symlink path components and non-regular files, and bound reads to 2 MB.

The native text view tracks source-line hover and shows a gutter + button with a subtle line highlight. TextKit resolves the line geometry; ReviewDocument resolves its UTF-16 source range with a binary search over display segments. The action captures the hovered line, or the current selection when it intersects that line's source text. Headers and empty space below the document have no action; blank source lines are attachable. Snapshot replacement and scrolling clear the hover target so an old range cannot remain actionable.

## Screenshot attachments

The composer uses a plain NSTextView whose paste handler recognizes PNG/TIFF clipboard images. OctoApp converts them to bounded PNG snapshots and holds them per thread as draft ImageAttachments; paste never sends a turn. Draft removal and thread deletion release the captures. Sent messages persist PNG bytes in the local JSON archive, with backward-compatible decoding for older image-free messages. This increases archive size; separate asset storage remains future work. Up to four images per message are accepted, each up to 5 MB PNG/32 megapixels (clipboard representation capped at 30 MB).

AgentHarness accepts provider-neutral image attachments alongside text. Codex maps them to `image` inputs with PNG data URLs; no temporary filesystem path is required. Claude rejects images explicitly before launching a process. Catalog inputModalities is respected when available (older catalogs default to image-capable, per the app-server contract). Image-only turns are supported. Ordinary text paste, native undo, multiline input and explicit ⌘Return sending remain available.

## Workspace layout

Project and thread pin preferences and project disclosure state are stored in the workspace archive; missing preference fields in older archives default to false. Stable ordering puts pinned items first without changing their project ownership. AppStore coordinates removal with harness lifecycle and refuses to remove active work.

The composer has one agent menu with Provider, Model, and Reasoning submenus. The chat column, including conversation and composer, has an 840 pt maximum width centered in the available space.

The navigation sidebar has a Projects header with an add-project button; each project retains its new-thread action. The navigation sidebar has bounded width. Chat/review and file/preview columns use a SwiftUI geometry-based divider that clamps widths during every resize; nesting native split views retained oversized children. The right review panel can be hidden with its header button or ⌥⌘R; the chat expands while the review view stays mounted, preserving selection and split width. Visibility lasts for the app session. Files and Changes keep their list containers mounted and remember their selections separately. Browser switching reads only the requested snapshot, retaining the existing native preview until the replacement arrives; selection actions are disabled during that handoff.

## Keyboard and appearance

WorkspaceView builds a context-sensitive command catalog shared by the command palette, Workspace menu, and a window-scoped NSEvent monitor. The monitor runs before Ghostty handles key equivalents, recognizes only exact modifier combinations, and yields to Settings, attached sheets, and modal windows. Send/stop/attachment actions are excluded from terminal key routing. The command palette supports chat-content search and flat file search; native NSSearchField delegates handle its arrow/Return/Escape navigation and thread-find focus. The find field stays mounted; workspace transitions immediately transfer or clear native first-responder focus so subsequent keystrokes cannot reach a hidden terminal. Composer and preview requests also use explicit counters without remounting the terminal. Sidebar dialogs and terminal-close confirmation are shared by mouse and keyboard actions.

AppTheme in OctoCore stores a portable identifier and Catppuccin color values. AppStore persists the choice in UserDefaults. OctoApp applies SwiftUI appearance and native composer colors; OctoReview recolors attributed text without replacing a snapshot or discarding selection. OctoTerminal uses the pinned wrapper's setTheme API to update live Ghostty configurations in place. System removes the color overlay; user configuration remains the base where supported. No Neovim configuration files are edited. See KEYBOARD.md for the shortcut contract and references.

## Terminal ownership

TerminalWorkspace owns all tabs for the life of the app; TerminalTab owns the Ghostty state. TerminalSurfaces keeps inactive tabs mounted and disables their rendering/focus. Closing a tab is an explicit action because it ends its process.

New shells use the selected project's root. Open in LazyVim targets the thread's checkout, reusing one Neovim tab for that project/checkout via a local server socket inside a uniquely allocated, owner-only directory. The directory has a short path for Unix socket limits and is released with editor exit/tab lifetime. Remote-open uses argument arrays and a JSON-encoded Lua argument. A new editor starts `nvim --listen` with the selected file and line. No keystroke injection into an unknown foreground shell is used. Existing `~/.config/ghostty/config` and Neovim configuration are reused where supported by the wrapper.

## Persistence and future growth

WorkspaceStore writes schema-versioned JSON atomically using private 0600 temporary files. The standard storage directory is 0700, and old archives are tightened on load. Archives and standard storage are excluded from macOS backups. Storage inside a Git checkout, symlinked archive files, multiply-linked files and unsafe custom parent directories are rejected. Conversations are local to each Mac and are never part of source setup or Git synchronization. Unsupported or corrupt data blocks writes for that app launch rather than overwriting the file. Save requests are debounced. Terminal processes and drafts are session-local.

This format is intentionally small and understandable. Before large histories or multiple app writers, introduce a storage protocol, transactional database, migrations, paging and a single-writer strategy. Before external plugins, replace the closed HarnessID registry with stable identifiers and a capability schema. Worktree creation, branch switching, file watching and session recovery belong in explicit services rather than view callbacks.
