/**
 * A tab in a project's review panel. Every tab closes; with none open the panel offers surfaces
 * to open. File paths are checkout-relative, so open files follow the selected thread's checkout.
 */
export type PanelTab =
  | { kind: "changes" }
  /** The file tree with no file open. The first file opened from it takes its place. */
  | { kind: "files" }
  | { kind: "file"; path: string }
  | { kind: "browser"; id: string };

export const ChangesTab: PanelTab = { kind: "changes" };
export const FilesTab: PanelTab = { kind: "files" };
export const fileTab = (path: string): PanelTab => ({ kind: "file", path });
export const browserTab = (id: string): PanelTab => ({ kind: "browser", id });

export function tabKey(tab: PanelTab): string {
  switch (tab.kind) {
    case "changes": case "files": return tab.kind;
    case "file": return `file:${tab.path}`;
    case "browser": return `browser:${tab.id}`;
  }
}

export function tabsEqual(a: PanelTab | null | undefined, b: PanelTab | null | undefined): boolean {
  if (!a || !b) return !a && !b;
  return tabKey(a) === tabKey(b);
}

const tabPath = (tab: PanelTab | null | undefined) => (tab?.kind === "file" ? tab.path : undefined);
const tabBrowser = (tab: PanelTab | null | undefined) => (tab?.kind === "browser" ? tab.id : undefined);

/** The open panel tabs of one project, in display order. Functions below edit it in place. */
export interface PanelTabs {
  tabs: PanelTab[];
  /** `null` exactly when no tab is open. */
  selected: PanelTab | null;
  /** The single-click file tab that the next single click replaces; editing or double-clicking keeps it. */
  preview: string | null;
  showsFileTree: boolean;
  /** Last committed address per browser tab, restored on relaunch. */
  browserAddresses: Record<string, string>;
  /** Private tabs use a non-persistent session and are never saved. */
  privateBrowsers: string[];
  lastFile: string | null;
  lastBrowser: string | null;
}

export function createPanelTabs(): PanelTabs {
  return { tabs: [ChangesTab], selected: ChangesTab, preview: null, showsFileTree: true, browserAddresses: {}, privateBrowsers: [], lastFile: null, lastBrowser: null };
}

const contains = (tabs: PanelTabs, tab: PanelTab) => tabs.tabs.some((t) => tabsEqual(t, tab));
const indexOf = (tabs: PanelTabs, tab: PanelTab) => tabs.tabs.findIndex((t) => tabsEqual(t, tab));

export const panelBrowsers = (tabs: PanelTabs) => tabs.tabs.flatMap((t) => (t.kind === "browser" ? [t.id] : []));
export const panelFiles = (tabs: PanelTabs) => tabs.tabs.flatMap((t) => (t.kind === "file" ? [t.path] : []));
export const selectedFile = (tabs: PanelTabs) => tabPath(tabs.selected);
export const selectedBrowser = (tabs: PanelTabs) => tabBrowser(tabs.selected);
/** The selected tab shows the file tree: a file tab or the Files tab. */
export const isBrowsingFiles = (tabs: PanelTabs) => tabs.selected?.kind === "files" || selectedFile(tabs) !== undefined;
/** The selected tab shows Changes or Files content rather than a browser or the surface picker. */
export const showsReview = (tabs: PanelTabs) => tabs.selected !== null && selectedBrowser(tabs) === undefined;
export const isPrivateBrowser = (tabs: PanelTabs, id: string) => tabs.privateBrowsers.includes(id);

/** The most recently viewed browser tab, if any is open. */
export function recentBrowser(tabs: PanelTabs): string | undefined {
  if (tabs.lastBrowser && contains(tabs, browserTab(tabs.lastBrowser))) return tabs.lastBrowser;
  const browsers = panelBrowsers(tabs);
  return browsers[browsers.length - 1];
}

export function selectTab(tabs: PanelTabs, tab: PanelTab): void {
  if (!contains(tabs, tab)) return;
  tabs.selected = tab;
  if (tab.kind === "file") tabs.lastFile = tab.path;
  if (tab.kind === "browser") tabs.lastBrowser = tab.id;
}

export function showChanges(tabs: PanelTabs): void {
  if (!contains(tabs, ChangesTab)) tabs.tabs.push(ChangesTab);
  selectTab(tabs, ChangesTab);
}

/** Shows the file tree beside the most recently viewed file, or opens the Files tab. */
export function showFiles(tabs: PanelTabs): void {
  tabs.showsFileTree = true;
  if (isBrowsingFiles(tabs)) return;
  const files = panelFiles(tabs);
  if (tabs.lastFile && contains(tabs, fileTab(tabs.lastFile))) selectTab(tabs, fileTab(tabs.lastFile));
  else if (files.length > 0) selectTab(tabs, fileTab(files[files.length - 1]));
  else {
    if (!contains(tabs, FilesTab)) tabs.tabs.push(FilesTab);
    selectTab(tabs, FilesTab);
  }
}

export function openFile(tabs: PanelTabs, path: string, pinned: boolean): void {
  const tab = fileTab(path);
  if (contains(tabs, tab)) {
    if (pinned && tabs.preview === path) tabs.preview = null;
  } else if (!pinned && tabs.preview !== null && indexOf(tabs, fileTab(tabs.preview)) !== -1) {
    const current = tabs.preview;
    tabs.tabs[indexOf(tabs, fileTab(current))] = tab;
    tabs.preview = path;
    if (tabs.lastFile === current) tabs.lastFile = null;
  } else if (indexOf(tabs, FilesTab) !== -1) {
    tabs.tabs[indexOf(tabs, FilesTab)] = tab;
    if (!pinned) tabs.preview = path;
  } else {
    tabs.tabs.push(tab);
    if (!pinned) tabs.preview = path;
  }
  selectTab(tabs, tab);
}

export function pinFile(tabs: PanelTabs, path: string): void {
  if (tabs.preview === path) tabs.preview = null;
}

export function openBrowser(tabs: PanelTabs, id: string, options: { address?: string; isPrivate?: boolean } = {}): void {
  if (contains(tabs, browserTab(id))) { selectTab(tabs, browserTab(id)); return; }
  tabs.tabs.push(browserTab(id));
  if (options.isPrivate) tabs.privateBrowsers.push(id);
  else if (options.address) tabs.browserAddresses[id] = options.address;
  selectTab(tabs, browserTab(id));
}

export function recordAddress(tabs: PanelTabs, address: string, id: string): void {
  if (!contains(tabs, browserTab(id)) || tabs.privateBrowsers.includes(id) || !address) return;
  tabs.browserAddresses[id] = address;
}

/** Closes a tab and selects its right neighbor, else its left, else nothing. */
export function closeTab(tabs: PanelTabs, tab: PanelTab): boolean {
  const index = indexOf(tabs, tab);
  if (index === -1) return false;
  tabs.tabs.splice(index, 1);
  if (tab.kind === "file") {
    if (tabs.preview === tab.path) tabs.preview = null;
    if (tabs.lastFile === tab.path) tabs.lastFile = null;
  }
  if (tab.kind === "browser") {
    delete tabs.browserAddresses[tab.id];
    tabs.privateBrowsers = tabs.privateBrowsers.filter((id) => id !== tab.id);
    if (tabs.lastBrowser === tab.id) tabs.lastBrowser = null;
  }
  if (tabsEqual(tabs.selected, tab)) {
    if (tabs.tabs.length === 0) tabs.selected = null;
    else selectTab(tabs, tabs.tabs[Math.min(index, tabs.tabs.length - 1)]);
  }
  return true;
}

export function selectAdjacentTab(tabs: PanelTabs, offset: number): void {
  if (tabs.tabs.length === 0) return;
  const current = tabs.selected ? indexOf(tabs, tabs.selected) : 0;
  const index = current === -1 ? 0 : current;
  const count = tabs.tabs.length;
  selectTab(tabs, tabs.tabs[(((index + offset) % count) + count) % count]);
}
