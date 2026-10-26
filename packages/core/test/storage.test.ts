import { chmodSync, existsSync, linkSync, mkdirSync, readdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { makeArchive, makeProject, makeThread, serializeArchive } from "../src";
import { PrivateTemporaryDirectory, StoreError, WorkspaceArchiveWriter, WorkspaceStore } from "../src/node";
import { mode, removeRoot, temporaryRoot } from "./helpers";

const roots: string[] = [];
const root = () => { const r = temporaryRoot(); roots.push(r); return r; };
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });

describe("WorkspaceStore", () => {
  it("round-trips and preserves an unsupported archive", async () => {
    const store = new WorkspaceStore(join(root(), "store", "workspace.json"));
    const project = makeProject({ name: "octo", rootPath: "/tmp/octo", threads: [makeThread({ workingDirectory: "/tmp/octo" })] });
    const archive = makeArchive({ projects: [project], selectedProjectID: project.id });
    await store.save(archive);
    expect((await store.load()).projects).toEqual([project]);
    await store.save({ ...archive, schemaVersion: 999 });
    const before = readFileSync(store.filePath);
    await expect(store.load()).rejects.toMatchObject({ kind: "unsupportedVersion" });
    expect(readFileSync(store.filePath)).toEqual(before);
  });

  it("sets owner-only permissions and replaces atomically", async () => {
    const top = root();
    const originalParentMode = mode(top);
    const parent = join(top, "private");
    const store = new WorkspaceStore(join(parent, "workspace.json"));
    await store.save(makeArchive());
    expect(mode(parent)).toBe(0o700);
    expect(mode(store.filePath)).toBe(0o600);
    chmodSync(store.filePath, 0o644);
    await store.load();
    expect(mode(store.filePath)).toBe(0o600);
    await store.save(makeArchive({ projects: [makeProject({ name: "fixture", rootPath: "/tmp/fixture" })] }));
    expect((await store.load()).projects.length).toBe(1);
    expect(mode(store.filePath)).toBe(0o600);
    expect(readdirSync(parent)).toEqual(["workspace.json"]);
    expect(mode(top)).toBe(originalParentMode);
  });

  it("rejects repositories and links without changing targets", async () => {
    const top = root();
    mkdirSync(join(top, ".git"));
    const store = new WorkspaceStore(join(top, "renamed.json"));
    await expect(store.save(makeArchive())).rejects.toBeInstanceOf(StoreError);
    await expect(store.load()).rejects.toBeInstanceOf(StoreError);
    removeRoot(join(top, ".git"));
    const outside = join(top, "target");
    writeFileSync(outside, "unchanged");
    chmodSync(outside, 0o644);
    symlinkSync(outside, store.filePath);
    await expect(store.load()).rejects.toThrow();
    await expect(store.save(makeArchive())).rejects.toThrow();
    expect(readFileSync(outside, "utf8")).toBe("unchanged");
    expect(mode(outside)).toBe(0o644);
  });

  it("rejects unsafe custom parents and hard-linked archives", async () => {
    const top = root();
    const store = new WorkspaceStore(join(top, "state.json"));
    chmodSync(top, 0o777);
    await expect(store.save(makeArchive())).rejects.toThrow();
    expect(mode(top)).toBe(0o777);
    chmodSync(top, 0o700);
    const target = join(top, "target.json");
    writeFileSync(target, serializeArchive(makeArchive()));
    chmodSync(target, 0o644);
    linkSync(target, store.filePath);
    await expect(store.load()).rejects.toThrow();
    expect(mode(target)).toBe(0o644);
  });

  it("creates private chat directories", async () => {
    const store = new WorkspaceStore(join(root(), "data", "workspace.json"));
    const directory = await store.prepareChatDirectory("1F6E6C0A-6A5D-4E44-9D39-8B2F5A0C1E11");
    expect(directory.endsWith("ChatWorkspaces/1F6E6C0A-6A5D-4E44-9D39-8B2F5A0C1E11")).toBe(true);
    expect(mode(directory)).toBe(0o700);
  });
});

describe("PrivateTemporaryDirectory", () => {
  it("is short, owner-only and removed on dispose", () => {
    const directory = new PrivateTemporaryDirectory();
    expect(mode(directory.path)).toBe(0o700);
    expect(Buffer.byteLength(join(directory.path, "nvim.sock"))).toBeLessThan(104);
    writeFileSync(join(directory.path, "fixture"), "");
    directory.dispose();
    expect(existsSync(directory.path)).toBe(false);
  });
});

describe("WorkspaceArchiveWriter", () => {
  const archive = (name: string) => makeArchive({ projects: [makeProject({ name, rootPath: `/tmp/${name}` })] });

  it("coalesces background writes to the newest snapshot", async () => {
    const store = new WorkspaceStore(join(root(), "workspace.json"));
    const writer = new WorkspaceArchiveWriter(store);
    for (let index = 0; index < 50; index++) writer.write(archive(`p${index}`), (error) => { throw error; });
    await writer.writeNow(archive("final"));
    expect((await store.load()).projects.map((p) => p.name)).toEqual(["final"]);
  });

  it("supersedes a snapshot not yet started with writeNow", async () => {
    const store = new WorkspaceStore(join(root(), "workspace.json"));
    const writer = new WorkspaceArchiveWriter(store);
    writer.write(archive("stale"), (error) => { throw error; });
    await writer.writeNow(archive("current"));
    writer.write(archive("current"), (error) => { throw error; });
    await writer.flush();
    expect((await store.load()).projects.map((p) => p.name)).toEqual(["current"]);
  });

  it("reports background write failures", async () => {
    const top = root();
    // A directory at the archive path makes the final rename fail.
    const path = join(top, "workspace.json");
    mkdirSync(path, { recursive: true });
    const writer = new WorkspaceArchiveWriter(new WorkspaceStore(path));
    const failed = await new Promise<boolean>((resolve) => {
      writer.write(archive("x"), () => resolve(true));
      setTimeout(() => resolve(false), 5000);
    });
    expect(failed).toBe(true);
  });
});
