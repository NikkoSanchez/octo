import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { OWNER_MARKER, resolveDataDirectory, UnownedDataFolderError } from "../dataFolder";

const roots: string[] = [];
const root = () => { const r = mkdtempSync(join(tmpdir(), "octo-data-")); roots.push(r); return r; };
afterEach(() => { while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true }); });

describe("resolveDataDirectory", () => {
  it("creates a marked folder on a fresh Mac and reuses it", () => {
    const appData = root();
    expect(resolveDataDirectory(appData, "Octo")).toBe(join(appData, "Octo"));
    expect(readdirSync(join(appData, "Octo"))).toEqual([OWNER_MARKER]);
    expect(readdirSync(appData)).toEqual(["Octo"]);
    writeFileSync(join(appData, "Octo", "workspace.json"), "{}");
    expect(resolveDataDirectory(appData, "Octo")).toBe(join(appData, "Octo"));
    expect(readdirSync(join(appData, "Octo")).sort()).toEqual([OWNER_MARKER, "workspace.json"]);
  });

  it("keeps a folder carrying the earlier marker and adds the current one beside it", () => {
    const appData = root();
    mkdirSync(join(appData, "Octo"));
    writeFileSync(join(appData, "Octo", ".octo-electron"), "");
    writeFileSync(join(appData, "Octo", "workspace.json"), "{}");
    expect(resolveDataDirectory(appData, "Octo")).toBe(join(appData, "Octo"));
    expect(readdirSync(join(appData, "Octo")).sort()).toEqual([OWNER_MARKER, ".octo-electron", "workspace.json"]);
  });

  it("refuses another app's unmarked folder and leaves it untouched", () => {
    const appData = root();
    mkdirSync(join(appData, "Octo"));
    writeFileSync(join(appData, "Octo", "workspace.json"), "other");
    expect(() => resolveDataDirectory(appData, "Octo")).toThrow(UnownedDataFolderError);
    expect(readdirSync(join(appData, "Octo"))).toEqual(["workspace.json"]);
    expect(existsSync(join(appData, "Octo", OWNER_MARKER))).toBe(false);
  });
});
