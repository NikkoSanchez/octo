# Keyboard and appearance

Octo uses Command for application actions and leaves Control, Option-only keys, Escape, and Space/Vim leader sequences to the focused terminal or editor. The organization takes inspiration from [Omarchy's launcher and hotkeys](https://learn.omacom.io/books/2/pages/53) and [LazyVim's discoverable key groups](https://www.lazyvim.org/keymaps), while keeping macOS text editing conventions.

The command palette (⇧⌘P) is the discovery layer: type an action, use ↑/↓, and press Return. It includes project switching, pinning, renaming, removal, provider/model/reasoning choices, draft attachment removal, review scope, and approval review. Destructive actions retain confirmation; approval review shows the request and requires an explicit Allow Once or Decline. Escape dismisses the palette and restores workspace focus.

| Action | Shortcut |
| --- | --- |
| Toggle left sidebar | ⌘B |
| Search chats across projects (titles and message text) | ⌘K |
| Find in current thread | ⌘F |
| Next / previous matching message | ⌘G / ⇧⌘G |
| New thread in current project | ⌘N |
| Add project | ⇧⌘O |
| Find project file | ⌘P |
| Command palette | ⇧⌘P |
| Previous / next thread in current project | ⌥⌘[ / ⌥⌘] |
| Focus thread composer | ⌘1 |
| Show Changes / Files | ⌘2 / ⌘3 |
| Focus code preview | ⌘4 |
| Toggle review panel | ⌥⌘R |
| Toggle project terminal | ⌘J |
| Send draft / stop current agent | ⌘Return / ⌘. |
| Attach code selection to draft | ⇧⌘A |
| Open selected file in installed LazyVim | ⇧⌘E |
| Refresh changes and files | ⇧⌘R |
| New terminal tab | ⌘T |
| Close terminal tab with confirmation | ⌘W, in terminal workspace |
| Previous / next terminal tab | ⇧⌘[ / ⇧⌘] |
| Settings | ⌘, |

Numbers are destinations; ⌘J is a round trip between chat and terminal. File search opens and focuses the native preview. Use native selection (e.g. Shift-arrow, ⌘A), then ⇧⌘A to attach code. Attaching never sends. Thread search highlights and navigates matching messages rather than individual word occurrences. Return advances; Escape closes the find bar when its field is focused.

App shortcuts take precedence over any Ghostty bindings for those same combinations. Send, stop, next/previous thread-search result, and code attachment shortcuts are inactive in the terminal. ⌘W remains normal window closing outside the terminal. Native copy/paste/undo, terminal Control-C/Control-D/Control-R, Option navigation, and Neovim leader keys remain untouched. Modals and Settings use their native key handling. Full traversal of native buttons uses macOS Keyboard navigation (Tab/Shift-Tab); the palette provides direct access to workspace actions without that preference.

## Themes

The bottom-left Settings button opens Appearance, Keyboard, and Agents tabs. Appearance persists immediately in app preferences. Available themes are macOS System, Catppuccin Latte, and Catppuccin Mocha. Colors follow the [Catppuccin style guide](https://github.com/catppuccin/catppuccin/blob/main/docs/style-guide.md), using [official palette 1.8.0](https://github.com/catppuccin/palette/blob/main/palette.json) (reviewed September 26, 2026):

- Base canvas, Mantle secondary panels, Surface0 controls, Text body, Subtext0 labels, and Overlay1 subtle text. Mauve remains the app accent; accent-button text uses Base. Native menus, search fields, and standard macOS control chrome retain platform styling within the selected light/dark appearance.
- Custom selections use Overlay2 at 25%; cursors use Rosewater. Warnings use Yellow, errors Red, success Green, attachment pills Blue. Thread-find matches use translucent Teal, with Red for the active message; these are whole-message highlights rather than occurrence backgrounds.
- Code-review gutters use Overlay1, hunk headers Peach, and added/deleted line backgrounds Green/Red at 20%. Hover uses Text at 10%. Lightweight source highlighting recognizes keywords (Mauve), strings (Green), escapes (Pink), comments and punctuation (Overlay2), numbers/constants (Peach), calls and JSON keys (Blue), and operators (Sky).
- Terminal ANSI 0–15 uses the official normal and distinct bright colors, including Pink magenta and the flavour-specific black/white pairs; extended slots 16/17 are Peach/Rosewater. Cursor text is Base in Latte and Crust in Mocha. Terminal selections precompose Overlay2 at 25% over Base because the wrapper takes opaque RGB values.

Source highlighting is lexical, not a full grammar: it supports common C-family languages, Swift, JavaScript/TypeScript, Python, and JSON. Raw strings, interpolation, regex literals, semantic types/parameters, and missing lexical context before a diff hunk are not fully resolved. Other file types remain plain text. Deleted and added lines maintain independent multiline state, reset at each hunk. Theme rendering does not change source ranges or attachments.

Catppuccin updates mounted terminal surfaces in place, including inactive tabs. Shells, editors and scrollback remain alive. System follows macOS light/dark appearance and removes Octo's terminal color override, using the existing Ghostty configuration where supported by the pinned wrapper. It does not install missing Ghostty theme resources. Neovim retains its installed configuration and colorscheme. Theme changes preserve code-preview selection.

Current limits: fixed shortcut defaults (no remapping UI), no full transcript indexing or occurrence-level search, no code-preview find UI, and no automatic Neovim theme synchronization. International keyboard layouts, IME, and VoiceOver need broader validation.
