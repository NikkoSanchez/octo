# Keyboard and appearance

Octo uses Command for application actions and leaves Control, Option-only keys, Escape, and Space/Vim leader sequences to the focused terminal or editor. The organization takes inspiration from [Omarchy's launcher and hotkeys](https://learn.omacom.io/books/2/pages/53) and [LazyVim's discoverable key groups](https://www.lazyvim.org/keymaps), while keeping macOS text editing conventions.

Hold ⌘ for 650 ms to show small shortcut badges on the main controls only: the current project’s New Thread button (⌘N), chat search (⌘K), the sidebar toggle (⌘B), the terminal button (⌘J) and the review panel button (⌥⌘B). Badges above controls have a 6 pt gap; the terminal button’s sits to its left, clear of the review button’s. Other controls give their shortcut in their tooltip. Quick taps never show badges. Pressing a key while holding Command hides badges and suppresses them until Command is released and held again. Badges also disappear when Command is released, the workspace loses focus, or a sheet opens. They share the command catalog and respect terminal/disabled contexts.

The command palette (⇧⌘P) is the discovery layer: type an action, use ↑/↓, and press Return. It includes project switching, pinning, renaming, removal, provider/model/reasoning choices, draft attachment removal, review scope, and approval review. Destructive actions retain confirmation; approval review shows the request and requires an explicit Allow Once or Decline. Escape dismisses the palette and restores workspace focus.

| Action | Shortcut |
| --- | --- |
| Toggle left sidebar | ⌘B |
| Search chats across projects (titles and message text) | ⌘K |
| Switch project (search names and paths) | ⇧⌘K |
| Find in current thread (your messages, replies and errors; occurrences highlighted) | ⌘F |
| Next / previous matching message | ⌘G / ⇧⌘G |
| New thread / reopen unstarted draft in current project | ⌘N |
| Add project | ⇧⌘O |
| Find project file | ⌘P |
| Command palette | ⇧⌘P |
| Previous / next thread in current project | ⌥⌘[ / ⌥⌘] |
| Focus thread composer | ⌘1 |
| Show Changes / Files | ⌘2 / ⌘3 |
| Focus code preview | ⌘4 |
| Toggle review panel | ⌥⌘B |
| Toggle project terminal | ⌘J |
| Send draft (composer) / insert new line | Return / Shift–Return |
| Continue a Markdown list or quote (composer) | Shift–Return on a `-`, `*`, `+`, `1.`, `1)`, `- [ ]` or `>` line; on an empty item it ends the list or steps out a level |
| Nest / un-nest a list item (composer) | Tab / Shift–Tab on a list line (or every list line selected) |
| Move to the next / previous control (composer, outside a list) | Tab / Shift–Tab. Tab rings the composer's enabled controls in turn (+, agent, permissions, stop, send), then the review panel's file list and diff when shown, then returns. Space or Return presses the ringed control, ←/→ also move, Escape returns to the composer, and typing returns and types. Option–Tab types a tab |
| Send draft (outside terminal) / stop current agent | ⌘Return / ⌘. |
| Attach code selection to draft | ⇧⌘A |
| Open selected file in installed LazyVim | ⇧⌘E |
| Refresh changes and files | ⇧⌘R |
| Save current file immediately (Files also autosaves) | ⌘S |
| New terminal tab | ⌘T |
| Close terminal tab with confirmation | ⌘W, in terminal workspace |
| Previous / next terminal tab | ⇧⌘[ / ⇧⌘] |
| Settings | ⌘, |

Numbers are destinations; ⌘J is a round trip between chat and terminal. File search opens and focuses the native preview. Use native selection (e.g. Shift-arrow, ⌘A), then ⇧⌘A to attach code. Attaching never sends. Thread search highlights and navigates matching messages rather than individual word occurrences. Return advances; Escape closes the find bar when its field is focused.

App shortcuts take precedence over any Ghostty bindings for those same combinations. Save file, send, stop, next/previous thread-search result, and code attachment shortcuts are inactive in the terminal. ⌘W remains normal window closing outside the terminal. Native copy/paste/undo, terminal Control-C/Control-D/Control-R, Option navigation, and Neovim leader keys remain untouched. Modals and Settings use their native key handling. Full traversal of native buttons uses macOS Keyboard navigation (Tab/Shift-Tab); the palette provides direct access to workspace actions without that preference.

Use ⇧⌘K to switch projects from any workspace pane, including the terminal or a hidden sidebar. Type a project name or path, use ↑/↓, then Return; Escape cancels without changing projects. Results follow the sidebar's pinned-first order and label the current project. Opening a project expands its sidebar group, opens its first thread in sidebar order, and focuses the composer; selecting the current project keeps its current thread. Then use ⌥⌘[ / ⌥⌘] to cycle threads, ⌘J for its terminal, or ⌘N to start a thread in an empty project. Terminal sessions remain mounted.

## Themes

The bottom-left Settings button opens Appearance, Keyboard, and Agents tabs. Appearance persists immediately in app preferences. It has a Theme menu (grouped Light / Dark) and a gallery of preview cards in **Automatic** (macOS System), **Light** and **Dark** sections; each card shows the theme's panel with thread rows (the first selected exactly as the sidebar draws it: Surface0 with Text in Catppuccin, the accent elsewhere), its canvas with a syntax sample in the theme's colors and italics, and its status colors. The chosen card has an accent outline and checkmark. Every named theme declares whether it is light or dark, which sets the SwiftUI color scheme, so native controls follow it.

- **Light:** Catppuccin Latte, GitHub Light, Gruvbox Light, One Light, Rosé Pine Dawn, Solarized Light, Tokyo Night Day.
- **Dark:** Catppuccin Frappé, Macchiato and Mocha, Dracula Classic, GitHub Dark, Gruvbox Dark, Nord, One Dark, Rosé Pine, Solarized Dark, Tokyo Night.

All palettes live in `OctoCore/ThemeCatalog.swift` as semantic roles (Base/Mantle/Surface/Overlay/Text/Secondary, accent and status colors, cursor, selection, line highlight, ANSI) plus syntax roles (keyword, string, escape, comment, number, function, key, punctuation, operator, builtin, diff headers, italic roles). Views never branch on a specific theme.

**Catppuccin** (all four flavours) uses [palette 1.8.0](https://github.com/catppuccin/palette/blob/main/palette.json) (every hex and all 64 ANSI values re-verified October 21, 2026). Roles follow the [style guide](https://github.com/catppuccin/catppuccin/blob/main/docs/style-guide.md), and the official [VS Code port](https://github.com/catppuccin/vscode/blob/main/packages/catppuccin-vsc/src/theme/uiColors.ts) where the port is more specific or differs:

- Base canvas, Mantle secondary panels, Surface0 controls, Text body, Subtext0 labels, Overlay1 subtle text, Overlay0 inactive borders, Lavender active borders (and the pinned-thread ring). Mauve is the accent (the port's default `accent: "mauve"`), used for icons, focus rings and prominent buttons, as the port's `icon.foreground`, `focusBorder` and `button.background` are. Text on accent fills is Crust (port `button.foreground`; the style guide says Base).
- **Selected sidebar threads are Surface0 with Text** (port `list.activeSelectionBackground` / `list.activeSelectionForeground`). They were a solid Mauve fill with Base text before October 21, 2026, which neither source specifies. The review panel's changed-file list is still a native list whose selection macOS draws in the accent.
- Editor selections use Overlay2 at 30% in Latte and 25% in the dark flavours (port `editor.selectionBackground`); cursors Rosewater. Links and pills Blue, warnings Yellow, errors Red, success Green. Thread find: current match Red, other matches Sky, at 30% for occurrences and 20% for the message tint (port `editor.findMatchBackground` / `findMatchHighlightBackground`).
- Code review: gutters Overlay1, hunk headers Peach, `diff` lines Blue, `---`/`+++` Pink, added/deleted line backgrounds Green/Red at 15% (port `diffEditor.inserted/removedLineBackground`), hover Text at 7% (port `editor.lineHighlightBackground`). Syntax: keywords Mauve, strings Green, escapes Pink, italic Overlay2 comments, Overlay2 punctuation, Peach numbers/constants, italic Blue calls, Blue JSON keys, Teal operators (the port; the style guide says Sky), Red `self`/`this`/`super`.
- Terminal ANSI 0–15 uses the official normal and bright colors; extended slots 16/17 are Peach/Rosewater. Cursor text is Base in Latte and Crust in the dark flavours. Terminal selection is Surface2 (port `terminal.selectionBackground`; the Catppuccin Ghostty port uses a lighter precomposed overlay).
- Remaining differences: the port colors `super` Mauve (Octo's highlighter treats it as a builtin, Red), and long-form chat prose in dark flavours is Text at 82% opacity. Types (Yellow, italic), parameters (Maroon), enum variants (Teal) and macros (Rosewater) are not recognized by the lexical highlighter.

**Dracula Classic** follows the [official specification source](https://github.com/dracula/draculatheme.com/blob/main/content/spec.mdx) and [official Ghostty palette](https://github.com/dracula/ghostty/blob/main/dracula) (reviewed October 3, 2026). Its canvas is `#282A36`, panels `#21222C`, deeper surfaces `#191A21`, controls `#343746`, foreground/cursor `#F8F8F2`, and selection `#44475A` at full opacity. Purple accents and cyan links use the classic editor palette. Syntax: Pink keywords/operators, Yellow strings/escapes, Green calls, Cyan JSON keys, Orange numbers/booleans, Foreground punctuation, italic Comment comments and Purple builtins; diff headers use Comment and hover a 25% Comment overlay. Terminal colors match the Ghostty port; extended slots 16/17 are Orange/Foreground.

**Other themes** (reviewed October 20, 2026). UI roles map each theme's own background/surface/text ladder; syntax follows its editor port; terminal colors follow its official terminal port, with no extended slots:

| Theme | Palette and syntax source | Terminal source | Notes |
|---|---|---|---|
| GitHub Light/Dark | Primer primitives via [github-nvim-theme](https://github.com/projekt0n/github-nvim-theme) (Default variants) | Primer `ansi` tokens | Accent-blue selection at 15% / 30% |
| Gruvbox Light/Dark | [morhetz/gruvbox](https://github.com/morhetz/gruvbox/blob/master/colors/gruvbox.vim) (faded / bright accents) | Gruvbox 16-color palette | Orange accent; italic comments; punctuation and operators plain, as upstream leaves Delimiter unset |
| Nord | [nordtheme/vim](https://github.com/nordtheme/vim) | [nordtheme/alacritty](https://github.com/nordtheme/alacritty) | Frost (`#88C0D0`) accent; secondary labels use the port's dim foreground |
| One Light/Dark | Atom [one-dark-syntax / one-light-syntax](https://github.com/atom/atom/tree/master/packages) and UI levels | [onedark.vim](https://github.com/joshdick/onedark.vim) (Dark) | One Light has no official terminal port; its ANSI reuses the same hue roles. Values computed from the current Atom HSL sources (One Light orange `#B76B01`, not the older `#986801`) |
| Rosé Pine / Dawn | [rose-pine/palette](https://github.com/rose-pine/palette/blob/main/palette.json), [rose-pine/neovim](https://github.com/rose-pine/neovim) | [rose-pine/ghostty](https://github.com/rose-pine/ghostty) | Dawn text is the palette's current `#464261` (the Ghostty port still has `#575279`); Dawn uses Pine as accent because Iris under Base text is low-contrast; Leaf is not in the canonical palette, so success/additions use Foam as the Neovim port's Git colors do |
| Solarized Light/Dark | [altercation/solarized](https://github.com/altercation/solarized), [vim-colors-solarized](https://github.com/altercation/vim-colors-solarized) | Official README mapping | Bright black is Base03, as specified, so it matches the dark background (e.g. zsh autosuggestions default to it) |
| Tokyo Night / Day | [tokyonight.nvim extras](https://github.com/folke/tokyonight.nvim/tree/main/extras) | Its Ghostty extras | Teal border-highlight for active borders |

Translucent selections are precomposed over Base for the terminal unless a port supplies its own value; hovered source lines always use a translucent highlight because they are drawn over the text.

Source highlighting is lexical, not a full grammar: it supports common C-family languages, Swift, JavaScript/TypeScript, Python, and JSON. Raw strings, interpolation, regex literals, semantic types/parameters, and missing lexical context before a diff hunk are not fully resolved. Other file types remain plain text. Deleted and added lines maintain independent multiline state, reset at each hunk. Theme rendering does not change source ranges or attachments.

Named themes update mounted terminal surfaces in place, including inactive tabs. Shells, editors and scrollback remain alive. System follows macOS light/dark appearance and removes Octo's terminal color override, using the existing Ghostty configuration where supported by the Octo-owned host. Matching upstream theme resources are bundled. Neovim retains its installed configuration and colorscheme. Theme changes preserve code-preview selection.

Current limits: fixed shortcut defaults (no remapping UI), no full transcript indexing or occurrence-level search, no code-preview find UI, and no automatic Neovim theme synchronization. International keyboard layouts, IME, and VoiceOver need broader validation.

### Chats without a project

The **Chats** section is always available above Projects. Its + button or **File → New Chat Without a Project** starts or reopens a standalone draft from any project. ⌘N creates/reuses a draft in the current section. The command palette includes **Go to Chats**; ⌘K searches both standalone and project conversations. Project terminal, file and review shortcuts are disabled while Chats is selected.
