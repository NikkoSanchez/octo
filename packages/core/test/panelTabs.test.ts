import { describe, expect, it } from "vitest";
import {
  browserTab, ChangesTab, closeTab, createPanelTabs, decodePanelTabs, decodeProject, encodePanelTabs, fileTab, FilesTab, isBrowsingFiles,
  newID, openBrowser, openFile, panelFiles, pinFile, recentBrowser, recordAddress, selectAdjacentTab, selectTab, showChanges,
  showFiles, showsReview,
} from "../src";

const roundTrip = <T>(value: T): T => JSON.parse(JSON.stringify(value));

describe("PanelTabs", () => {
  it("replaces the preview tab until pinned", () => {
    const tabs = createPanelTabs();
    openFile(tabs, "a.swift", false);
    openFile(tabs, "b.swift", false);
    expect(tabs.tabs).toEqual([ChangesTab, fileTab("b.swift")]);
    expect(tabs.preview).toBe("b.swift");
    pinFile(tabs, "b.swift");
    openFile(tabs, "c.swift", false);
    expect(tabs.tabs).toEqual([ChangesTab, fileTab("b.swift"), fileTab("c.swift")]);
    openFile(tabs, "c.swift", true);
    expect(tabs.preview).toBeNull();
    openFile(tabs, "d.swift", true);
    openFile(tabs, "b.swift", false);
    expect(panelFiles(tabs)).toEqual(["b.swift", "c.swift", "d.swift"]);
    expect(tabs.selected).toEqual(fileTab("b.swift"));
    expect(tabs.preview).toBeNull();
  });

  it("selects a neighbor on close until nothing is open", () => {
    const tabs = createPanelTabs();
    const browser = newID();
    openFile(tabs, "a", true); openBrowser(tabs, browser); openFile(tabs, "b", true);
    selectTab(tabs, browserTab(browser));
    expect(closeTab(tabs, browserTab(browser))).toBe(true);
    expect(tabs.selected).toEqual(fileTab("b"));
    expect(closeTab(tabs, fileTab("b"))).toBe(true);
    expect(tabs.selected).toEqual(fileTab("a"));
    selectTab(tabs, ChangesTab);
    expect(closeTab(tabs, fileTab("a"))).toBe(true);
    expect(tabs.selected).toEqual(ChangesTab);
    expect(closeTab(tabs, fileTab("missing"))).toBe(false);
    expect(closeTab(tabs, ChangesTab)).toBe(true);
    expect(tabs.tabs).toEqual([]);
    expect(tabs.selected).toBeNull();
    expect(showsReview(tabs)).toBe(false);
    selectAdjacentTab(tabs, 1);
    expect(tabs.selected).toBeNull();
    showChanges(tabs);
    expect(tabs.tabs).toEqual([ChangesTab]);
    expect(tabs.selected).toEqual(ChangesTab);
  });

  it("replaces the Files tab with the first opened file", () => {
    const tabs = createPanelTabs();
    closeTab(tabs, ChangesTab);
    tabs.showsFileTree = false;
    showFiles(tabs);
    expect(tabs.tabs).toEqual([FilesTab]);
    expect(tabs.selected).toEqual(FilesTab);
    expect(isBrowsingFiles(tabs)).toBe(true);
    expect(tabs.showsFileTree).toBe(true);
    showFiles(tabs);
    expect(tabs.tabs).toEqual([FilesTab]);
    openFile(tabs, "a", false);
    expect(tabs.tabs).toEqual([fileTab("a")]);
    expect(tabs.preview).toBe("a");
    openFile(tabs, "b", true); selectTab(tabs, fileTab("a"));
    const browser = newID();
    openBrowser(tabs, browser);
    expect(isBrowsingFiles(tabs)).toBe(false);
    showFiles(tabs);
    expect(tabs.selected).toEqual(fileTab("a"));
    expect(recentBrowser(tabs)).toBe(browser);
    closeTab(tabs, fileTab("a")); selectTab(tabs, browserTab(browser)); showFiles(tabs);
    expect(tabs.selected).toEqual(fileTab("b"));
  });

  it("wraps adjacent selection", () => {
    const tabs = createPanelTabs();
    const browser = newID();
    openFile(tabs, "a", true); openBrowser(tabs, browser);
    selectAdjacentTab(tabs, 1);
    expect(tabs.selected).toEqual(ChangesTab);
    selectAdjacentTab(tabs, -1);
    expect(tabs.selected).toEqual(browserTab(browser));
  });

  it("persists addresses and drops private tabs", () => {
    const tabs = createPanelTabs();
    const browser = newID(), privateBrowser = newID();
    openFile(tabs, "Sources/a.swift", false);
    openBrowser(tabs, browser);
    recordAddress(tabs, "http://localhost:3000/", browser);
    openBrowser(tabs, privateBrowser, { isPrivate: true });
    recordAddress(tabs, "https://private.example/", privateBrowser);
    expect(tabs.browserAddresses[privateBrowser]).toBeUndefined();
    const encoded = roundTrip(encodePanelTabs(tabs));
    expect(encoded.browserAddresses).toEqual([browser, "http://localhost:3000/"]);
    const decoded = decodePanelTabs(encoded);
    expect(decoded.tabs).toEqual([ChangesTab, fileTab("Sources/a.swift"), browserTab(browser)]);
    expect(decoded.selected).toEqual(ChangesTab);
    expect(decoded.preview).toBe("Sources/a.swift");
    expect(decoded.browserAddresses).toEqual({ [browser]: "http://localhost:3000/" });
    expect(decoded.privateBrowsers).toEqual([]);
  });

  it("repairs malformed tabs when decoding", () => {
    const browser = newID();
    const json = JSON.parse(`{"tabs":[{"file":{"_0":"a"}},{"future":{}},{"file":{"_0":"a"}},{"browser":{"_0":"${browser}"}}],
      "selected":{"file":{"_0":"gone"}},"preview":"gone","showsFileTree":false}`);
    const tabs = decodePanelTabs(json);
    expect(tabs.tabs).toEqual([fileTab("a"), browserTab(browser)]);
    expect(tabs.selected).toEqual(fileTab("a"));
    expect(tabs.preview).toBeNull();
    expect(tabs.showsFileTree).toBe(false);
    const empty = createPanelTabs();
    closeTab(empty, ChangesTab);
    const decoded = decodePanelTabs(roundTrip(encodePanelTabs(empty)));
    expect(decoded.tabs).toEqual([]);
    expect(decoded.selected).toBeNull();
  });

  it("decodes projects without panel tabs", () => {
    const project = decodeProject({ id: newID(), name: "Legacy", rootPath: "/tmp/legacy", threads: [] });
    expect(project.panelTabs).toEqual(createPanelTabs());
  });
});
