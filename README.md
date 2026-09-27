# Octo

A native macOS workspace for coding agents: projects and nested chat threads on the left, conversation and code review together, and a persistent terminal workspace for each project.

**Status:** working development foundation, not a production release. See [current status](docs/STATUS.md) for implemented behavior, verification, and next steps.

## Run

On a new Mac, install **full Xcode with Swift 6** and launch it once. Select its Command Line Tools in Xcode Settings → Locations. macOS 14 or newer is required.

Clone your private repository using your authenticated GitHub CLI, then run:

```sh
gh repo clone NikkoSanchez/octo
cd octo
make setup
open build/Octo.app
```

`make setup` checks prerequisites, installs this checkout's privacy Git hooks (without replacing existing custom hooks), scans source files, and builds the native app. It downloads the pinned build dependencies; it does not install agent CLIs, copy credentials, import conversations, or alter Neovim configuration. `make doctor` checks prerequisites without building. `make test` runs the Swift tests. `make run` rebuilds and launches the app.

Install and authenticate the provider you want on this Mac, then add your local projects in Octo. For Codex, the desktop app's bundled CLI is discovered automatically, or select an installed CLI in Settings → Agents. Claude and Neovim are optional; the terminal works without Neovim. LazyVim uses your own existing Neovim configuration.

The app bundle is `build/Octo.app`. Packaging uses the Xcode app target so dependency resources are embedded correctly; the SwiftPM executable is also available for development. To import a repository at launch:

```sh
open build/Octo.app --args --project /absolute/path/to/repository
```

The first build downloads a pinned community Ghostty wrapper and binary framework. `Package.resolved` locks transitive dependencies. The bundle is signed ad hoc for local development; distribution signing and notarization are not configured.

Install and authenticate the agent CLIs separately (`codex`, optionally `claude`). Octo uses their local credentials and configuration. It never collects API keys. Codex automatically prefers the CLI bundled with the ChatGPT/Codex desktop app, then falls back to PATH (including common Homebrew and local CLI directories). Settings shows its exact executable path and version; Choose Executable selects a different installation, and Use Automatic restores discovery. The selection applies to both model discovery and agent turns. Stop active Codex turns before changing installations.

## Use

1. Add a Git repository with the **+** beside **Projects** or ⇧⌘O.
2. Create a thread with ⌘N; open the compact agent menu in the composer for Provider, Model, and Reasoning submenus. For Codex, choose a model and its supported reasoning effort; choices are saved per thread and apply to the next turn. Until a model is chosen, the session uses CLI defaults. Changing providers after a conversation starts creates a new thread.
3. Paste a screenshot into the message editor with ⌘V. Review or remove its thumbnail, then send explicitly with ⌘Return. Codex accepts image-only messages; up to four screenshots per message (5 MB PNG and 32 megapixels each). Sent screenshots are saved with the conversation. Claude image input is not yet supported.
4. Select a changed file (or browse the Files tree), then hover a source line in the native preview and click its **+** to attach it to the draft. Select multiple lines and click **+** within the selection, or use **Ask Agent**, to attach the selection. Write your question and send explicitly with ⌘Return.
5. **Open in LazyVim** opens the file using your installed `nvim` and its existing configuration. The project terminal retains its tabs as you switch between chats and projects. ⌘J toggles the terminal; ⌘1 focuses the thread composer.
6. Click a project's name or folder icon to collapse or expand it; the icon switches between closed and open folders. Right-click projects or threads to pin, rename, add, or remove them. Pins appear first within their existing hierarchy and survive relaunch. Removal keeps repository files on disk.
7. Toggle the right review panel with the sidebar icon beside Terminal or ⌥⌘R. Reopening retains its file selection and split width. Chat content stays centered with an 840 pt maximum width.
8. Open **Settings** at the bottom left or with ⌘, to choose macOS System, Catppuccin Latte, or Catppuccin Mocha and browse the keyboard reference. ⌘K searches chats, ⌘F finds messages in the current thread, ⌘P finds files, and ⇧⌘P opens the command palette. See [all shortcuts and terminal boundaries](docs/KEYBOARD.md).
9. Use Refresh Changes after terminal edits. Changes also refresh when the app becomes active and after an agent finishes.

Codex supports streaming, resume, stop, command/file approvals, and a workspace-write sandbox requested from the CLI. Claude uses its print/stream protocol and reports its narrower approval capabilities in the UI. No provider runs with blanket permission bypasses.

## Layout

| Location | Responsibility |
| --- | --- |
| `Sources/OctoApp` | SwiftUI shell, navigation, chat, composition and app state |
| `Sources/OctoCore` | Portable domain models, captured review context, storage, process utilities |
| `Sources/OctoAgents` | Harness contract, registry, subprocess protocols, Codex/Claude adapters |
| `Sources/OctoGit` | Git status, staged/working snapshots, unified diff parser |
| `Sources/OctoReview` | AppKit/TextKit 2 selectable native diff surface |
| `Sources/OctoTerminal` | Embedded Ghostty surfaces, tab lifecycle, Neovim routing |
| `Tests` | Selection, persistence, Git integration, agent protocol fixtures |
| `Scripts` | Local app bundle packaging |
| `docs` | Architecture, decisions, provider guide, status and historical concept |

Start with [architecture](docs/ARCHITECTURE.md), then [status and next work](docs/STATUS.md). Agent contributors should read [AGENTS.md](AGENTS.md).

## Local data

Each Mac has its own workspace at `~/Library/Application Support/Octo/workspace.json`. A fresh clone starts with **no conversations or project paths from another Mac**. Octo has no conversation sync or archive-upload feature. Source code and dependency lockfiles belong in Git; conversation archives, CLI authentication, screenshots from chats, and machine-specific preferences do not.

The default folder is owner-only (`0700`) and archives are created owner-only (`0600`) before any content is written, then replaced atomically. Existing archives are tightened when loaded. Standard storage and archives are excluded from macOS backups. The archive remains local plaintext: these permissions do not encrypt it, stop same-account tools from reading it, remove earlier backups, or control independently configured backup/sync software. Keep this folder outside cloud-synced locations. Agent CLIs maintain their own histories and privacy settings.

**Sending a message explicitly shares its text, selected code and attached screenshots with the selected agent CLI/provider.** Local storage does not make cloud model inference offline. Octo never silently attaches or sends the entire saved archive. Provider tools can access files according to their own approvals and sandbox settings.

For development, `OCTO_WORKSPACE_PATH` selects an isolated local archive. Storage inside a Git checkout is refused, including through symlinked directories. Use a dedicated directory outside repositories; existing custom parent directories must be owned by your account and not writable by other users. Do not run multiple app instances against the same archive.

The supplied Git hooks reject known secret formats and Octo archive JSON regardless of its filename. The pre-push check examines history, so deleting a private file in a later commit does not make it safe to push. Run `make privacy` before staging; CI repeats the staged-file check. These checks are safeguards, not a substitute for reviewing uploads. A corrupt or newer workspace file is preserved and disables saving for that launch. Drafts and terminal sessions remain local to the running app.

See [security findings and remediation](docs/SECURITY_AUDIT.md). Before your first commit on another Mac, choose your GitHub noreply email in that repository's local Git configuration if you want to keep your personal email out of commit metadata.

## Dependencies and attribution

The native terminal uses [Lakr233/libghostty-spm](https://github.com/Lakr233/libghostty-spm), pinned to `b7f888e3baf8585ea9d590ab1a45b49475e00d1c`, wrapping [Ghostty](https://github.com/ghostty-org/ghostty). This is a community integration, not a stable official embedding SDK. Audit its licenses and binary supply chain before distribution. The application source has no distribution license selected yet.
