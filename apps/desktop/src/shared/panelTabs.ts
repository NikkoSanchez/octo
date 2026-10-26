import {
  closeTab, openBrowser, openFile, pinFile, recordAddress, selectAdjacentTab, selectTab, showChanges, showFiles, type PanelTab, type PanelTabs,
} from "@octo/core";

/** Panel tab edits as data, so the renderer can request them over IPC. */
export type PanelTabOperation =
  | { type: "select"; tab: PanelTab }
  | { type: "showChanges" }
  | { type: "showFiles" }
  | { type: "openFile"; path: string; pinned: boolean }
  | { type: "pin"; path: string }
  | { type: "openBrowser"; id: string; address?: string; isPrivate?: boolean }
  | { type: "recordAddress"; id: string; address: string }
  | { type: "close"; tab: PanelTab }
  | { type: "selectAdjacent"; offset: number }
  | { type: "setFileTree"; visible: boolean };

export function applyPanelTabOperation(tabs: PanelTabs, operation: PanelTabOperation): void {
  switch (operation.type) {
    case "select": selectTab(tabs, operation.tab); break;
    case "showChanges": showChanges(tabs); break;
    case "showFiles": showFiles(tabs); break;
    case "openFile": openFile(tabs, operation.path, operation.pinned); break;
    case "pin": pinFile(tabs, operation.path); break;
    case "openBrowser": openBrowser(tabs, operation.id, { address: operation.address, isPrivate: operation.isPrivate }); break;
    case "recordAddress": recordAddress(tabs, operation.address, operation.id); break;
    case "close": closeTab(tabs, operation.tab); break;
    case "selectAdjacent": selectAdjacentTab(tabs, operation.offset); break;
    case "setFileTree": tabs.showsFileTree = operation.visible; break;
  }
}
