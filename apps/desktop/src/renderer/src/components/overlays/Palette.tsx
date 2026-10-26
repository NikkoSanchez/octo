import { useEffect, useMemo, useRef, useState } from "react";
import { Command, Folder, Search } from "lucide-react";
import { searchableThreads, ThreadSearch } from "@octo/core";
import { formatAccelerator } from "../../../../shared/menu";
import { appState, checkoutRoot, isProjectChat, selectedProject } from "../../state/app";
import { useUI, type PaletteMode } from "../../state/ui";
import { reviewFor } from "../../state/review";
import { commands } from "../../lib/commands";
import { navigateThread, showPanel } from "../../lib/workspace";
import { isMac, run } from "../../bridge";
import { cx } from "../controls";
import { Sheet } from "./Sheet";
import styles from "./overlays.module.css";

interface Entry { id: string; title: string; detail: string; shortcut?: string; enabled: boolean; action: () => void }

const PLACEHOLDERS: Record<PaletteMode, string> = {
  chats: "Search all chats…", projects: "Switch project by name or path…", commands: "Type a command…", files: "Find a project file…",
};

/** The entries for a mode, read when the palette opens. */
function entries(mode: PaletteMode): Entry[] {
  const state = appState(), current = selectedProject(state);
  switch (mode) {
    case "projects":
      return state.archive.projects.filter((p) => !p.isChatCollection).map((p) => ({
        id: p.id, title: p.name, detail: p.rootPath, shortcut: p.id === current?.id ? "Current" : "", enabled: true,
        action: () => { run("store", "selectProject", p.id); useUI.getState().focusComposer(); },
      }));
    case "commands":
      return commands().map((c) => ({ id: c.id, title: c.title, detail: c.group, shortcut: formatAccelerator(c.accelerator, isMac), enabled: c.enabled, action: c.action }));
    case "chats":
      return searchableThreads(state.archive).map(({ project, thread }) => ({
        id: thread.id, title: thread.title, detail: project.isChatCollection ? "Chats" : project.name, enabled: true, action: () => navigateThread(thread.id, project.id),
      }));
    case "files": {
      if (!current || !isProjectChat(state)) return [];
      return (reviewFor(checkoutRoot(state))?.paths ?? []).map((path) => ({
        id: path, title: path, detail: current.name, enabled: true, action: () => showPanel({ type: "openFile", path, pinned: true }, true),
      }));
    }
  }
}

/** ⌘K, ⇧⌘K, ⇧⌘P and ⌘P: one palette whose entries depend on the mode. */
export function Palette({ mode }: { mode: PaletteMode }) {
  const all = useMemo(() => entries(mode), [mode]);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(0);
  const list = useRef<HTMLDivElement>(null);
  const close = () => useUI.setState({ palette: null });

  const matches = useMemo(() => {
    const words = query.split(/\s+/).filter(Boolean);
    if (!words.length) return all;
    if (mode === "chats") {
      // Ranked as the sidebar's chat search ranks them.
      const byID = new Map(all.map((e) => [e.id, e]));
      return ThreadSearch.results(query, searchableThreads(appState().archive)).flatMap((r) => byID.get(r.threadID) ?? []);
    }
    return all.filter((e) => words.every((word) => `${e.title} ${e.detail}`.toLowerCase().includes(word.toLowerCase())));
  }, [all, query, mode]);

  useEffect(() => { setSelected(0); list.current?.scrollTo({ top: 0 }); }, [matches]);
  useEffect(() => { list.current?.querySelector(`[data-index="${selected}"]`)?.scrollIntoView({ block: "nearest" }); }, [selected]);

  const activate = (index: number) => {
    const entry = matches[index];
    if (!entry?.enabled) return;
    close();
    // Let the sheet hand focus back before navigating.
    requestAnimationFrame(entry.action);
  };
  const move = (delta: number) => { if (matches.length) setSelected((i) => (i + delta + matches.length) % matches.length); };
  const Icon = mode === "commands" ? Command : mode === "projects" ? Folder : Search;

  return (
    <Sheet label={mode === "commands" ? "Command palette" : mode === "projects" ? "Switch project" : mode === "files" ? "Find file" : "Search chats"}
      width={640} closeOnBackdrop close={close} className={styles.paletteSheet}>
      <div className={styles.paletteSearch}>
        <Icon size={16} className={styles.paletteIcon} />
        <input autoFocus data-plain aria-label="Search" placeholder={PLACEHOLDERS[mode]} value={query} onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
            else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
            else if (e.key === "Enter") { e.preventDefault(); activate(selected); }
          }} />
        <button type="button" className={styles.escape} onClick={close}>Esc</button>
      </div>
      <hr className={styles.rule} />
      <div ref={list} className={styles.paletteList} role="listbox" aria-label="Results">
        {matches.map((entry, index) => (
          <button key={entry.id} type="button" role="option" data-index={index} aria-selected={index === selected} disabled={!entry.enabled}
            className={cx(styles.paletteRow, index === selected && styles.paletteSelected)} onMouseMove={() => setSelected(index)} onClick={() => activate(index)}>
            <span className={styles.paletteText}><strong>{entry.title}</strong><small>{entry.detail}</small></span>
            {entry.shortcut && <kbd>{entry.shortcut}</kbd>}
          </button>
        ))}
        {!matches.length && <p className={styles.paletteEmpty}>{mode === "projects" && !all.length ? "No projects yet. Add one with ⇧⌘O." : "No results"}</p>}
      </div>
      <hr className={styles.rule} />
      <footer className={styles.paletteFooter}><span>↑ ↓ to navigate · Return to open · Esc to close</span><span>{matches.length} results</span></footer>
    </Sheet>
  );
}
