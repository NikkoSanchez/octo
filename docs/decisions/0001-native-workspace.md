# 0001 — Native workspace and provider boundaries

Accepted, 2026-09-26.

Use SwiftUI for the macOS application shell and AppKit/TextKit 2 for selectable code review. This replaces the initial idea of embedding Pierre diff in a webview. It gives native text selection and contextual actions while keeping review independent of agent transport. It also means Octo owns diff rendering, syntax highlighting, accessibility and performance work.

Use a project/thread sidebar and a separate persistent terminal workspace per project. Generic terminal tabs can host shells, herdr or the user's LazyVim. Do not impose separate terminal modes or a project-comparison workflow.

Embed Ghostty through a pinned community Swift package, with the wrapper isolated in OctoTerminal. Its native PTY backend is available now but is an upstream maintenance dependency. Never expose its types outside that module's UI boundary unnecessarily.

Use local CLI harness adapters. Start with Codex app-server and Claude Code stream-json, preserving each provider's actual capabilities. Octo coordinates sessions; it does not reimplement provider tool execution or silently bypass approvals.

Use SwiftPM modules and explicit dependency direction instead of a monolithic app target. Swift 5 language mode initially accommodates dependency interoperability; Swift 6 strict concurrency is future work.
