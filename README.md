# Octo

A native macOS workspace for coding agents: projects and nested chat threads on the left, conversation and code review together, and a persistent terminal workspace for each project.

**Status:** working development foundation, not a production release. See [current status](docs/STATUS.md) for implemented behavior, verification, and next steps.

## Run

On a new Mac, install **full Xcode 26 or newer with Swift 6 and the macOS 26 SDK** and launch it once. Select its Command Line Tools in Xcode Settings → Locations. Octo targets macOS 14 or newer; this source build was verified on macOS 26. Install the Metal compiler with `xcodebuild -downloadComponent MetalToolchain` if `make doctor` reports it missing.

Clone your private repository using your authenticated GitHub CLI, then run:

```sh
gh repo clone NikkoSanchez/octo
cd octo
make setup
open build/Octo.app
```

`make setup` checks prerequisites, installs this checkout's privacy Git hooks (without replacing existing custom hooks), uses your authenticated `gh` account to set a local noreply commit identity when one is not already configured, scans source files, and builds the native app. It downloads the pinned build dependencies; it does not install agent CLIs, copy credentials, import conversations, or alter Neovim configuration. `make doctor` checks prerequisites without building. `make test` runs the Swift tests. `make run` rebuilds and launches the app.

Install and authenticate the provider you want on this Mac, then add your local projects in Octo. For Codex, the desktop app's bundled CLI is discovered automatically, or select an installed CLI in Settings → Agents. Claude and Neovim are optional; the terminal works without Neovim. LazyVim uses your own existing Neovim configuration.

The app bundle is `build/Octo.app`. Packaging uses the Xcode app target so dependency resources are embedded correctly; the SwiftPM executable is also available for development. To import a repository at launch:

```sh
open build/Octo.app --args --project /absolute/path/to/repository
```

The first build downloads pinned official Ghostty source and a checksum-verified Zig compiler, then builds our local framework. Octo owns the Swift/AppKit host in `Sources/OctoGhostty`; it no longer depends on libghostty-spm or MSDisplayLink. `Vendor/Ghostty.lock.json` and the generated build manifest record its provenance. See [Ghostty setup, migration-cache notes and validation limits](docs/GHOSTTY.md). The bundle is signed ad hoc for local development; distribution signing and notarization are not configured.

Install and authenticate the agent CLIs separately (`codex`, optionally `claude`). Octo uses their local credentials and configuration. It never collects API keys. Codex automatically prefers the CLI bundled with the ChatGPT/Codex desktop app, then falls back to PATH (including common Homebrew and local CLI directories). Settings shows its exact executable path and version; Choose Executable selects a different installation, and Use Automatic restores discovery. The selection applies to both model discovery and agent turns. Stop active Codex turns before changing installations.

For Claude, **Settings → Agents → Open CLI sign-in…** opens a dedicated native terminal running the installed executable’s `claude auth login`. Complete Anthropic’s browser flow (or paste a code in that terminal if the CLI asks), then close it to refresh the reported sign-in status. Stop Claude turns before renewing login. An installed CLI can still be signed out; Octo checks `claude auth status --json` separately. `/login` in an Octo chat cannot perform interactive sign-in. Credentials remain managed by Claude Code; Octo does not extract or save them.

Type **/** at the beginning of an otherwise empty draft to browse the selected provider’s skills and commands. Continue typing to filter; ↑/↓ select, Return/Tab insert, and Escape dismisses. Clicking an entry also inserts it; sending remains explicit. Refresh rescans the current working directory. Claude supplies SDK-compatible commands through initialize; terminal-only commands are absent. Codex supplies enabled skills through `skills/list`, with exact skill name/path input on send. Claude and Codex have separate skill/configuration locations; Octo does not copy skills between them.

## Use

1. Start in **Chats** for questions, ideas, and conversations without a project. Its **+** creates or reopens an unsent chat; a fresh workspace opens there automatically. Add a Git repository with the **+** beside **Projects** or ⇧⌘O when you want code review and a project terminal.
2. Create a thread with ⌘N (reopens the current Chats or project draft when one exists); open the compact agent menu in the composer for Provider, Model, and Reasoning submenus. Choose a model and its supported reasoning effort for Codex or Claude; choices are saved per thread and apply to the next turn. Until a model is chosen, the session uses CLI defaults. Changing providers after a conversation starts creates a new thread.
3. Click **+** in the composer to choose image files, or paste a screenshot with ⌘V. Review or remove its thumbnail, then send explicitly with Return (Shift–Return adds a new line). Codex accepts image-only messages; up to four images per message (30 MB source, 5 MB PNG and 32 megapixels each). Sent screenshots are saved with the conversation. Claude also accepts screenshots and image-only messages.
4. Select a changed file (or browse the Files tree), then hover a source line in the native preview and click its **+** to attach it to the draft. Select multiple lines and click **+** within the selection, or use **Ask Agent**, to attach the selection. Write your question and send explicitly with Return (Shift–Return adds a new line).
5. **Open in LazyVim** opens the file using your installed `nvim` and its existing configuration. Quitting Neovim with `:qa` returns that tab to an interactive shell in the checkout. The project terminal retains its tabs as you switch between chats and projects. ⌘J toggles the terminal; ⌘1 focuses the thread composer.
6. New Codex chats get a title of at most six words / 60 characters from a separate Luna/low request after the first send; manual names are preserved. If automatic naming is unavailable, the first-message title remains. Hover a chat to see its full title, project and time since last activity. Truncated names also scroll (Reduce Motion keeps them still). **Recent** below Projects shows your eight most recently opened or active conversations from Chats and projects. **✓ New** marks a finished, unread response; project counts include these even when collapsed. View the chat at its latest output to clear the badge. Click the Chats, Projects, or Recent heading to fold the section. Section disclosure, recent order and unread status survive relaunch. Click a project's name or folder icon to collapse or expand it; the icon switches between closed and open folders. Hover a thread and click its trailing pin to pin or unpin it. Right-click projects or threads to pin, rename, add, or remove them. Threads appear newest-first in Chats and each project, with pinned threads first. Each list shows five threads; **Show more** reveals ten more at a time and **Show less** returns to five. The selected and working threads always stay listed. ⌥⌘[ / ⌥⌘] cycle through the listed threads only. Pins survive relaunch. Removal keeps repository files on disk.
7. The right review panel starts hidden. Toggle it with the sidebar icon beside Terminal or ⌥⌘B. Reopening retains its file selection and split width. Chat content stays centered with an 840 pt maximum width. Windows can shrink to 480 pt: Projects becomes an overlay opened with ⌘B, and review uses the full main area when space is tight. Close review or press ⌘1 to return to chat; terminal sessions stay alive through layout changes.
8. Open **Settings** at the bottom left or with ⌘, to choose macOS System, Catppuccin Latte, Catppuccin Mocha, or Dracula Classic and browse the keyboard reference. Hold ⌘ for 650 ms to reveal shortcut hints beside available actions; quick taps and shortcut presses keep them hidden. ⇧⌘K switches projects by name or path, ⌘K (or the search field at the top of the sidebar) searches all chats, ⌘F finds messages in the current thread, ⌘P finds files, and ⇧⌘P opens the command palette. See [all shortcuts and terminal boundaries](docs/KEYBOARD.md).
9. Use **Permissions** beside the model menu to choose Read only, Ask for approval, Approve for me (supported Codex installations), or explicitly enable Full access. Choices apply to the next turn and are remembered for new threads, along with provider, model, and reasoning. The **chart icon** in the chat header shows provider-reported account limits and reset times (Claude reports them after each response), and **Usage Dashboard** opens a window charting token usage from your local Codex and Claude Code session logs over 24 hours to 90 days. Click anywhere on the **Worked for** header to expand its summary to inspect provider summaries and tool progress; answers stay visible. Unsupported provider controls are identified in the UI.
10. Click the **context ring** beside Send for context used/remaining and token breakdowns for the latest model response and session. Codex reports these as it works; saved reports show their timestamp. Compaction displays a live status and remains managed by the CLI. The context window is not an exact countdown to automatic compaction. Claude metrics are currently unavailable.
11. Chats follow new output while you are near the bottom. Scroll up to read without being pulled down; return to the bottom or click **Scroll to end** to resume following. Opening another chat starts at its latest content. Each message shows its day/time, and each response its copy button, only while hovered; the footer space stays reserved so hovering does not move the text.
12. In **Changes**, choose **Stacked** or **Side by Side** from the layout menu. Side by Side aligns Before/After rows, scrolls vertically together, and lets you select or attach code from either version. The choice stays active while navigating files during this window session. Use Refresh Changes after terminal edits. Changes also refresh when the app becomes active and after an agent finishes.
13. The review panel is a tab strip. Changes, Files, files and browser pages are tabs you can close (×, ⌘W while the panel shows the tab, or the tab's context menu); with every tab closed the panel shows **Open a surface**, where B, F and C (⇧B for a private browser) open Browser, Files or Changes while it is focused. ⇧⌘[ / ⇧⌘] cycle tabs; **+** opens a Browser, a Private Browser, Files or Changes (⌘2). Tabs and browser addresses are saved per project (private tabs are not). **Browser** (⌘5 shows the last browser tab or opens one) loads your dev server or any page; links that open a new window become new tabs. Click the **annotate** button, then click an element or drag a region; its selector, text, HTML and a cropped screenshot are added to the draft for review. Nothing is sent until you send. The camera button attaches a screenshot of the visible page. The **⋯** menu has Hard Reload, Open Web Inspector, Open in Separate Window, a device toolbar (phone/tablet/laptop viewport sizes for responsive CSS), page Appearance, Zoom, and Clear Cookies/Clear Cache for the tab's profile.
14. In **Files** (⌘3; the tree button beside Refresh hides or shows the tree), a single click opens a file in a temporary *italic* tab that the next click replaces; double-click, **Open File**, or editing keeps the tab. Click a text file in **Files** and edit directly in the panel. Edits autosave after a short pause; **Save** or ⌘S saves immediately. Native undo, line numbers, syntax coloring, and code attachment remain available. File navigation preserves the buffer, cursor, scroll position and undo history. Use **New File** or a folder's **New File Here** to open a new file in that editor. Right-click a file for **Delete File**, which requires confirmation. External changes block saving and keep your draft; copy anything you need before choosing **Reload**.

While an agent is working or asking a question, Return (or ⌘Return) stacks follow-ups above the composer. Messages send in order after successful turns. Use **Steer now** on a queued Codex message to add it to the active turn, or **×** to remove it. Steering does not answer question or approval cards. Stop, interruption, failure or an unconfirmed steer pauses the queue; **Send queued** resumes it. Queues are local to the current app session and are not saved on quit.

Codex supports streaming, resume, stop, command/file approvals, and selectable permissions. The default remains workspace-write with on-request approval. Selecting Full access requires confirmation and is remembered for new threads; managed CLI policies remain authoritative. Claude uses its bidirectional CLI SDK stream with model/effort selection, screenshots, tool activity, operation approvals and single-choice questions. Its CLI owns authentication, settings, hooks, plugins and MCP servers. Run `claude auth login` before your first Claude send; select **Claude Agent** under Provider. Claude offers Manual and Auto, defaulting to Auto when no permission choice is saved. Explicit choices remain remembered for new chats. Auto uses Claude’s own classifier and requires CLI confirmation before input is sent; unavailable modes produce a visible error. Claude’s OS sandbox remains CLI-configured. Context metrics, read-only/full-access modes, active steering, generic MCP forms and automatic titles remain unavailable. Codex also displays CLI-owned MCP activity and supported native forms/app-access decisions, with explicit choices and cancellation. Tool questions require a supported experimental CLI API. Configure and authenticate integrations through the selected CLI, including in Octo’s terminal; see [supported schemas and runtime verification limits](docs/CLI_MCP.md).

## Layout

| Location | Responsibility |
| --- | --- |
| `Sources/OctoApp` | SwiftUI shell, navigation, chat, composition and app state |
| `Sources/OctoCore` | Portable domain models, captured review context, storage, process utilities |
| `Sources/OctoAgents` | Harness contract, registry, subprocess protocols, Codex/Claude adapters |
| `Sources/OctoGit` | Git status, staged/working snapshots, unified diff parser |
| `Sources/OctoReview` | AppKit/TextKit 2 selectable native diff surface |
| `Sources/OctoTerminal` | Project terminal tabs, lifecycle and Neovim routing |
| `Sources/OctoGhostty` | Octo-owned Swift/AppKit host for the source-built Ghostty C interface |
| `Tests` | Selection, persistence, Git integration, agent protocol fixtures |
| `Scripts` | Local app bundle packaging |
| `docs` | Architecture, decisions, provider guide, status and historical concept |

Start with [architecture](docs/ARCHITECTURE.md), then [status and next work](docs/STATUS.md). Agent contributors should read [AGENTS.md](AGENTS.md).

## Local data

Each Mac has its own workspace at `~/Library/Application Support/Octo/workspace.json`. A fresh clone starts with **no conversations or project paths from another Mac**. Octo has no conversation sync or archive-upload feature. Source code and dependency lockfiles belong in Git; conversation archives, CLI authentication, screenshots from chats, and machine-specific preferences do not.

Chats needs no folder selection or Git repository. Octo manages a separate persistent working directory for each chat under `ChatWorkspaces/<chat-id>` beside the workspace archive, so agents have somewhere to run and create files. Normal provider permissions still apply. Project review, file browsing, and terminal controls appear only in Projects. Deleting a chat removes its history but retains any files its agent created; moving chats into projects and managing these files in the UI are not implemented.

The default folder is owner-only (`0700`) and archives are created owner-only (`0600`) before any content is written, then replaced atomically. Existing archives are tightened when loaded. Standard storage and archives are excluded from macOS backups. The archive remains local plaintext: these permissions do not encrypt it, stop same-account tools from reading it, remove earlier backups, or control independently configured backup/sync software. Keep this folder outside cloud-synced locations. Agent CLIs maintain their own histories and privacy settings.

**Sending a message explicitly shares its text, selected code and attached screenshots with the selected agent CLI/provider.** Local storage does not make cloud model inference offline. Octo never silently attaches or sends the entire saved archive. Provider tools can access files according to their own approvals and sandbox settings.

For development, `OCTO_WORKSPACE_PATH` selects an isolated local archive. Storage inside a Git checkout is refused, including through symlinked directories. Use a dedicated directory outside repositories; existing custom parent directories must be owned by your account and not writable by other users. Do not run multiple app instances against the same archive.

The supplied Git hooks reject known secret formats and Octo archive JSON regardless of its filename. The pre-push check examines history, so deleting a private file in a later commit does not make it safe to push. Run `make privacy` before staging; CI repeats the staged-file check. These checks are safeguards, not a substitute for reviewing uploads. A corrupt or newer workspace file is preserved and disables saving for that launch. Drafts and terminal sessions remain local to the running app.

See [security findings and remediation](docs/SECURITY_AUDIT.md). Setup configures a GitHub noreply identity when `gh` is authenticated and no repository-local email exists. Existing local identities are preserved; review them before committing. If `gh` is unavailable, setup prints a reminder to configure a noreply email manually. Global Git identity is never changed.

## Dependencies and attribution

The native terminal compiles [official Ghostty](https://github.com/ghostty-org/ghostty/tree/332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28) **1.3.1** at `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`, using its internal full macOS embedding interface behind Octo’s own wrapper. This interface is not a stable public SDK. See [source/build provenance and notices](Vendor/Ghostty-NOTICES.md); redistribution review and hardware compatibility testing remain outstanding. The application source has no distribution license selected yet.
