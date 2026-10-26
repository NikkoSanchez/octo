import { useEffect, type ReactNode } from "react";
import { CircleCheck, Keyboard, Palette, SquareTerminal } from "lucide-react";
import { APP_THEMES, harnessTitle, syntaxColor, themeIsDark, themePalette, themeSyntax, themeTitle, type AppTheme, type SyntaxRole } from "@octo/core";
import { useApp } from "../../state/app";
import { useTerminal } from "../../state/terminal";
import { useUI, type SettingsTab } from "../../state/ui";
import { mappedGhosttyTheme } from "../../terminal/config";
import { run } from "../../bridge";
import { BorderedButton, cx } from "../controls";
import { Sheet } from "./Sheet";
import styles from "./overlays.module.css";

const TABS: { id: SettingsTab; title: string; icon: ReactNode }[] = [
  { id: "appearance", title: "Appearance", icon: <Palette size={18} /> },
  { id: "keyboard", title: "Keyboard", icon: <Keyboard size={18} /> },
  { id: "agents", title: "Agents", icon: <SquareTerminal size={18} /> },
];

/** Settings (⌘,): a toolbar of panes over the chosen pane. */
export function Settings({ tab }: { tab: SettingsTab }) {
  return (
    <Sheet label="Settings" width={680} close={() => useUI.setState({ settings: null })} closeOnBackdrop className={styles.settingsSheet}>
      <nav className={styles.settingsTabs} aria-label="Settings panes">
        {TABS.map((item) => (
          <button key={item.id} type="button" aria-current={tab === item.id ? "page" : undefined} className={cx(tab === item.id && styles.currentTab)}
            onClick={() => useUI.setState({ settings: item.id })}>{item.icon}<span>{item.title}</span></button>
        ))}
      </nav>
      <div className={styles.settingsBody}>
        {tab === "appearance" && <Appearance />}
        {tab === "keyboard" && <Shortcuts />}
        {tab === "agents" && <Agents />}
      </div>
    </Sheet>
  );
}

function Section({ title, footer, children }: { title?: string; footer?: ReactNode; children: ReactNode }) {
  return (
    <section className={styles.formSection}>
      {title && <h3>{title}</h3>}
      <div className={styles.formGroup}>{children}</div>
      {footer && <small className={styles.formFooter}>{footer}</small>}
    </section>
  );
}

/** A menu for quick keyboard choice, then preview cards grouped into Automatic, Light and Dark. */
function Appearance() {
  const theme = useApp((s) => s.theme), dark = useApp((s) => s.systemDark);
  const terminal = useTerminal((s) => s.config);
  const light = APP_THEMES.filter((t) => themeIsDark(t) === false), darkThemes = APP_THEMES.filter((t) => themeIsDark(t) === true);
  const select = (next: AppTheme) => run("store", "setTheme", next);
  const mapped = terminal?.theme ? mappedGhosttyTheme(terminal.theme, dark) : undefined;
  return <>
    <Section title="Color theme" footer="Applies immediately to Octo, code previews, and terminal colors. macOS System follows your Mac's light or dark appearance and uses your Ghostty configuration where supported. Neovim uses its own installed theme.">
      <label className={styles.formRow}>
        <span>Theme</span>
        <select value={theme} onChange={(e) => select(e.target.value as AppTheme)}>
          <option value="system">{themeTitle("system")}</option>
          <optgroup label="Light">{light.map((t) => <option key={t} value={t}>{themeTitle(t)}</option>)}</optgroup>
          <optgroup label="Dark">{darkThemes.map((t) => <option key={t} value={t}>{themeTitle(t)}</option>)}</optgroup>
        </select>
      </label>
      <div className={styles.systemCard}><ThemeCard theme="system" selected={theme === "system"} select={select} /></div>
    </Section>
    <Section title="Light"><div className={styles.themeGrid}>{light.map((t) => <ThemeCard key={t} theme={t} selected={theme === t} select={select} />)}</div></Section>
    <Section title="Dark"><div className={styles.themeGrid}>{darkThemes.map((t) => <ThemeCard key={t} theme={t} selected={theme === t} select={select} />)}</div></Section>
    <Section title="Terminal" footer="The terminal reads the font, size and theme from your Ghostty configuration. Other Ghostty settings do not apply.">
      <div className={styles.formRow}><span>Font</span><span className={styles.secondary}>{terminal?.fontFamily ?? "System monospace"} · {terminal?.fontSize ?? 12} pt</span></div>
      <div className={styles.formRow}><span>Theme</span><span className={styles.secondary}>
        {!terminal?.theme ? "Follows the app theme" : mapped ? `Ghostty theme: ${themeTitle(mapped)}` : `“${terminal.theme}” is not available; follows the app theme`}
      </span></div>
      {terminal?.diagnostics.map((line) => <small key={line} className={styles.secondary}>{line}</small>)}
    </Section>
  </>;
}

const PREVIEW: [string, SyntaxRole | "text"][][] = [
  [["let ", "keyword"], ["idea", "text"], [" = ", "operatorSymbol"], ["\"Octo\"", "string"]],
  [["run", "function"], ["(", "punctuation"], ["42", "number"], [")", "punctuation"]],
];

function ThemeCard({ theme, selected, select }: { theme: AppTheme; selected: boolean; select: (theme: AppTheme) => void }) {
  const palette = themePalette(theme), syntax = themeSyntax(theme);
  const c = (hex: string) => `#${hex}`;
  return (
    <button type="button" className={cx(styles.themeCard, selected && styles.themeSelected)} aria-pressed={selected} aria-label={themeTitle(theme)}
      aria-description={themeIsDark(theme) === undefined ? "Follows macOS" : themeIsDark(theme) ? "Dark" : "Light"} onClick={() => select(theme)}>
      {palette && syntax ? (
        <span className={styles.preview}>
          <span className={styles.previewSidebar} style={{ background: c(palette.mantle) }}>
            {[true, false, false].map((rowSelected, i) => (
              <span key={i} className={styles.previewRow} style={rowSelected ? { background: c(palette.listSelection), boxShadow: `inset 0 0 0 0.75px ${c(palette.activeBorder)}` } : undefined}>
                <i style={{ background: c(palette.overlay0) }} />
                <span>
                  <b style={{ width: 24, background: rowSelected ? c(palette.listSelectionText) : c(palette.text), opacity: rowSelected ? 1 : 0.75 }} />
                  <b style={{ width: 18, background: rowSelected ? c(palette.listSelectionText) : c(palette.secondary), opacity: 0.6 }} />
                </span>
              </span>
            ))}
          </span>
          <span className={styles.previewCode} style={{ background: c(palette.base) }}>
            {PREVIEW.map((line, i) => (
              <span key={i}>{line.map(([text, role], j) => (
                <span key={j} style={{ color: role === "text" ? c(palette.text) : c(syntaxColor(syntax, role)), fontStyle: role !== "text" && syntax.italic.includes(role) ? "italic" : undefined }}>{text}</span>
              ))}</span>
            ))}
            <span style={{ color: c(syntaxColor(syntax, "comment")), fontStyle: syntax.italic.includes("comment") ? "italic" : undefined }}>// {palette.isDark ? "dark" : "light"}</span>
            <span className={styles.previewDots}>{[palette.red, palette.yellow, palette.green, palette.blue, palette.accent].map((color, i) => <i key={i} style={{ background: c(color) }} />)}</span>
          </span>
        </span>
      ) : (
        // System: native light and dark halves with the Mac's accent, which also fills selected rows.
        <span className={styles.preview}>
          {[false, true].map((dark) => (
            <span key={String(dark)} className={styles.systemHalf} style={{ background: dark ? "#242424" : "#f7f7f7", color: dark ? "#fff" : "#000" }}>
              <span className={styles.systemSelection}><b /></span>
              <b style={{ width: 44, opacity: 0.25 }} /><b style={{ width: 36, opacity: 0.15 }} />
              <strong>Aa</strong>
            </span>
          ))}
        </span>
      )}
      <span className={styles.themeName}>{themeTitle(theme)}{selected && <CircleCheck size={14} className={styles.check} />}</span>
    </button>
  );
}

const SHORTCUT_GROUPS: [string, [string, string][]][] = [
  ["Navigate & create", [["Search chats", "⌘K"], ["Switch project", "⇧⌘K"], ["Find in current thread", "⌘F"], ["Next / previous matching message", "⌘G / ⇧⌘G"], ["New thread / add project", "⌘N / ⇧⌘O"], ["Find file / command palette", "⌘P / ⇧⌘P"], ["Previous / next thread", "⌥⌘[ / ⌥⌘]"]]],
  ["Workspace", [["Toggle left sidebar / review panel", "⌘B / ⌥⌘B"], ["Focus composer / show changes / show files", "⌘1 / ⌘2 / ⌘3"], ["Focus code preview", "⌘4"], ["Show browser", "⌘5"], ["Toggle terminal", "⌘J"], ["Settings", "⌘,"]]],
  ["Conversation & review", [["Send message / new line (composer)", "Return / ⇧Return"], ["Send message / stop agent", "⌘Return / ⌘."], ["Attach selected code to draft", "⇧⌘A"], ["Open selected file in Neovim", "⇧⌘E"], ["Refresh changes and files", "⇧⌘R"], ["Save file now (also autosaves)", "⌘S"]]],
  ["Terminal", [["New tab / close tab with confirmation", "⌘T / ⌘W"], ["Previous / next terminal tab", "⇧⌘[ / ⇧⌘]"], ["Split right / down", "⌘D / ⇧⌘D"], ["Previous / next pane, or by direction", "⌘[ / ⌘], ⌥⌘ arrows"], ["Equalize panes", "⌃⌘="], ["Zoom pane / close pane", "⇧⌘Return / ⌘W"]]],
];

function Shortcuts() {
  return (
    <div className={styles.shortcuts}>
      <h2>Keyboard first</h2>
      <p className={styles.secondary}>⌘⇧P opens every workspace command, including project and thread management, agent choices, and draft attachments. Type to filter; use ↑ / ↓ and Return to run. Escape closes the palette.</p>
      {SHORTCUT_GROUPS.map(([group, rows]) => (
        <section key={group}>
          <h3>{group}</h3>
          <table><tbody>{rows.map(([title, keys]) => <tr key={title}><td>{title}</td><td>{keys}</td></tr>)}</tbody></table>
        </section>
      ))}
      <small className={styles.secondary}>Octo reserves the listed Command shortcuts in workspace windows, including when a terminal is focused. Control, Option-only, Vim leader keys, and Escape stay with the terminal. Copy, paste, undo, and text navigation stay native. In the composer, Return sends and Shift–Return inserts a new line. ⌘Return and ⌘. act on chat only outside the terminal. Approval buttons require an explicit choice; use Tab / Shift-Tab to focus controls.</small>
    </div>
  );
}

function Agents() {
  const data = useApp((s) => ({
    descriptors: s.descriptors, custom: s.codexExecutablePath, version: s.codexVersion, auth: s.claudeAuth, authError: s.claudeAuthError, checking: s.checkingClaudeAuth,
    codexRunning: s.archive.projects.some((p) => p.threads.some((t) => t.harness === "codex" && s.running.includes(t.id))),
    claudeRunning: s.archive.projects.some((p) => p.threads.some((t) => t.harness === "claude" && s.running.includes(t.id))),
  }));
  useEffect(() => { run("store", "refreshCodexVersion"); run("store", "refreshClaudeAuth"); }, []);
  const codex = data.descriptors.find((d) => d.id === "codex"), claude = data.descriptors.find((d) => d.id === "claude");
  return <>
    <Section title="Agent harnesses">
      {data.descriptors.map((d) => (
        <div key={d.id} className={styles.harness}>
          <div className={styles.formRow}><strong>{harnessTitle(d.id)}</strong><span style={{ color: d.executable ? "var(--green)" : "var(--secondary)" }}>{d.executable ? "Detected" : "Not installed"}</span></div>
          <small className={styles.secondary}>{d.detail}</small>
        </div>
      ))}
    </Section>
    <Section title="Codex executable">
      <strong>{data.custom ? "Custom executable" : "Automatic · desktop app first, then PATH"}</strong>
      <code className={styles.path}>{data.custom ?? codex?.executable ?? "Not found"}</code>
      <small className={styles.secondary}>{data.version}</small>
      <div className={styles.buttons}>
        <BorderedButton disabled={data.codexRunning} onClick={() => run("store", "chooseCodexExecutable")}>Choose Executable…</BorderedButton>
        <BorderedButton disabled={data.codexRunning || !data.custom} onClick={() => run("store", "setCodexExecutable", undefined)}>Use Automatic</BorderedButton>
      </div>
      <small className={styles.secondary}>{data.codexRunning ? "Stop running Codex turns to change installations." : "The same installation supplies the model list and runs your turns. Changing it refreshes models; saved conversations remain."}</small>
    </Section>
    <Section title="Claude CLI sign-in">
      <code className={styles.path}>{claude?.executable ?? "Claude CLI not found"}</code>
      <span style={{ color: data.auth?.loggedIn ? "var(--green)" : "var(--secondary)" }}>
        {data.checking ? "Checking sign-in…" : data.auth ? (data.auth.loggedIn ? `Signed in${data.auth.method ? ` · ${data.auth.method}` : ""}` : "Signed out") : "Sign-in status unavailable"}
      </span>
      {data.authError && <small className={styles.secondary}>{data.authError}</small>}
      <div className={styles.buttons}>
        <BorderedButton disabled={!claude?.executable || data.claudeRunning} onClick={() => { useUI.setState({ settings: null }); run("terminal", "openCLISetup", "claudeLogin"); }}>Open CLI sign-in…</BorderedButton>
        <BorderedButton disabled={data.checking} onClick={() => run("store", "refreshClaudeAuth")}>Refresh status</BorderedButton>
        <BorderedButton onClick={() => run("app", "openExternal", "https://code.claude.com/docs/en/authentication")}>Authentication guide</BorderedButton>
      </div>
      <small className={styles.secondary}>{data.claudeRunning ? "Stop Claude turns before signing in again." : "Opens the installed Claude CLI’s browser sign-in flow. Choose your account there; the CLI stores and refreshes its credentials."}</small>
    </Section>
    <Section title="CLI-owned integrations">
      <small className={styles.secondary}>Configure and authenticate integrations with your selected CLI, including in Octo’s terminal. Octo inherits its launch environment; shell-only variables may differ. Use the executable shown above and the same project. No credentials or MCP settings are copied into Octo.</small>
      <small className={styles.secondary}>Missing tools, service connection failures, macOS permissions, app authorization, and unsupported forms are separate issues. Follow the owning CLI’s setup/login workflow; app approval does not repair a transport or OS permission failure.</small>
    </Section>
    <Section title="Local workspace">
      <small className={styles.secondary}>Uses your installed CLI authentication and Neovim configuration. Terminal tabs survive navigation, but do not survive app exit.</small>
    </Section>
  </>;
}
