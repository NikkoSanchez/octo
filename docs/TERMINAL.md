# Terminal configuration

Octo uses the official libghostty-vt emulation core through T3 Code's browser adapter and a Canvas 2D renderer. It does not launch the Ghostty application or use its Metal renderer. Fonts, selection and rendering can differ from the Ghostty app.

## User settings

At startup, main reads `config` and `config.ghostty` from `$XDG_CONFIG_HOME/ghostty` (or `~/.config/ghostty`), then `~/Library/Application Support/com.mitchellh.ghostty`. Later values win. `config-file` follows relative or absolute includes, optional `?` includes, and a bounded include depth. Restart Octo after changing these files.

Supported settings:

| Setting | Behavior |
| --- | --- |
| `font-family`, `font-size` | Applies to Canvas text and measurement; the symbols-only Nerd Font is bundled as fallback. |
| `theme` | Matches names in Octo's theme catalog, including `light:name,dark:name`; an unmatched name uses the app theme. Custom Ghostty theme files and color overrides are not loaded. |
| `unfocused-split-opacity`, `unfocused-split-fill`, `split-divider-color` | Applies to inactive panes and split dividers. |
| `keybind` | Basic single-chord modifiers and supported workspace/clipboard actions; `clear` resets the imported list. |

Supported key actions include new/close tab, next/previous or numbered tab, new/focus/resize/equalize split, toggle split zoom, copy, paste and select all. App commands take precedence. Global, chained and prefixed Ghostty bindings and other Ghostty settings are ignored. The adapter handles terminal keyboard/mouse encoding, IME, scrollback, selection, links and bracketed paste; it is not the full native Ghostty application.

## Ownership and retention

One terminal workspace belongs to each project, with generic tabs and split panes. Hiding a workspace, tab or pane leaves its process and VT state mounted. Only drawing pauses. Resizing propagates measured columns and rows to the PTY. Closing a busy terminal asks before stopping its processes. Quit shuts down all terminals; live PTYs and scrollback are not restored after relaunch.

Open in Neovim uses the installed Neovim and its normal configuration (LazyVim or otherwise), with a private socket for reuse. It starts once the pane has its measured size. No editor distribution is bundled. Claude sign-in uses its actual CLI in a dedicated terminal and requires the user's interaction.

## Upstream maintenance

T3 Code adapter revision: `c79ef8c454e1268ff79da5a9dcb74572e86f7861`.

libghostty-vt revision: `9f62873bf195e4d8a762d768a1405a5f2f7b1697`.

`native/libghostty-vt/provenance.json` records the copied assets and hashes. Local integration changes are import/support helpers and the transport around the adapter. Core emulation, runtime, Canvas renderer and WASM retain their upstream implementation. Licenses ship in `THIRD_PARTY_NOTICES.md`.

`scripts/build-libghostty-wasm.sh` is the explicit manual rebuild recipe. Building or testing Octo does not rebuild or change the pin. An intentional update must review the upstream changes, record provenance, regenerate notices and verify the ABI, keyboard encoding and native shell/editor workflows.
