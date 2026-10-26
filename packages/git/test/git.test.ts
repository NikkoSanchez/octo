import { chmodSync, existsSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { newID } from "@octo/core";
import { CheckoutFileService, findExecutable, runProcess, shellQuote } from "@octo/core/node";
import { GitService, hasStaged, hasWorking, isUntracked, UnifiedDiffParser } from "../src";
import { removeRoot, Repository, temporaryRoot } from "./helpers";

const roots: string[] = [];
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });
const git = findExecutable("git")!;

describe("GitService", () => {
  it("keeps rename destinations and spaces in status", () => {
    const files = GitService.parseStatus("R  new name.swift\0old name.swift\0?? café.txt\0 M existing.swift\0");
    expect(files.length).toBe(3);
    expect(files.some((f) => f.path === "new name.swift" && hasStaged(f))).toBe(true);
    expect(files.some((f) => f.path === "old name.swift")).toBe(false);
    expect(files.some((f) => f.path === "café.txt" && isUntracked(f))).toBe(true);
  });

  it("numbers hunk lines and keeps the missing final newline", () => {
    const lines = UnifiedDiffParser.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -4,2 +4,2 @@\n same\n-old\n+new\n\\ No newline at end of file\n");
    expect(lines.find((l) => l.kind === "deletion")?.oldLine).toBe(5);
    expect(lines.find((l) => l.kind === "addition")?.newLine).toBe(5);
    expect(lines.find((l) => l.kind === "context")?.newLine).toBe(4);
  });

  it("separates the index and working tree in a real repository", async () => {
    const repo = await Repository.make(roots);
    const name = "file with spaces.swift";
    repo.write(name, "base\n");
    await repo.commitAll("fixture");
    repo.write(name, "staged\n");
    await repo.run(["add", "--", name]);
    repo.write(name, "working\n");
    const service = new GitService(), projectID = newID();
    const [change] = await service.changes(repo.root);
    expect(hasStaged(change) && hasWorking(change)).toBe(true);
    const staged = await service.snapshot(change, projectID, repo.root, "staged");
    const working = await service.snapshot(change, projectID, repo.root, "working");
    expect(staged.lines.filter((l) => l.kind === "addition").map((l) => l.text)).toEqual(["staged"]);
    expect(working.lines.filter((l) => l.kind === "addition").map((l) => l.text)).toEqual(["working"]);
    expect(working.lines.filter((l) => l.kind === "deletion").map((l) => l.text)).toEqual(["staged"]);
    expect(await service.filePaths(repo.root)).toEqual([name]);
    const source = await service.fileSnapshot(name, projectID, repo.root);
    expect(source.scope).toBe("file");
    expect(source.lines.map((l) => l.text)).toEqual(["working"]);
    const outside = join(dirname(repo.root), randomUUID());
    writeFileSync(outside, "outside");
    try {
      symlinkSync(outside, join(repo.root, "external"));
      await expect(service.fileSnapshot("external", projectID, repo.root)).rejects.toThrow();
    } finally { rmSync(outside, { force: true }); }
  });

  it("rejects traversal, ancestor links and special files in both previews", async () => {
    const root = temporaryRoot(), outside = temporaryRoot(); roots.push(root, outside);
    writeFileSync(join(outside, "secret"), "private");
    symlinkSync(outside, join(root, "link"));
    const service = new GitService(), id = newID();
    for (const path of ["link/secret", "../outside", join(outside, "secret")]) {
      await expect(service.fileSnapshot(path, id, root)).rejects.toThrow();
      await expect(service.snapshot({ path, indexStatus: "?", worktreeStatus: "?" }, id, root, "working")).rejects.toThrow();
    }
    mkdirSync(join(root, "folder"));
    const snapshot = await service.snapshot({ path: "folder", indexStatus: "?", worktreeStatus: "?" }, id, root, "working");
    expect(snapshot.notice).toBeDefined(); expect(snapshot.lines).toEqual([]);
  });

  it("drops a deleted tracked file from Files but keeps it in Changes", async () => {
    const root = temporaryRoot(); roots.push(root);
    await runProcess(git, ["init", "--quiet"], { directory: root });
    writeFileSync(join(root, "tracked.txt"), "tracked\n");
    expect((await runProcess(git, ["add", "--", "tracked.txt"], { directory: root })).status).toBe(0);
    const service = new GitService(), files = new CheckoutFileService();
    await files.save(await files.inspect("tracked.txt", root, true), "manual\n");
    const [before] = await service.changes(root);
    const staged = await service.snapshot(before, newID(), root, "staged");
    expect(staged.lines.filter((l) => l.kind === "addition").map((l) => l.text)).toEqual(["tracked"]);
    await files.delete(await files.inspect("tracked.txt", root, false));
    expect(await service.filePaths(root)).toEqual([]);
    const changes = await service.changes(root);
    expect(changes[0].path).toBe("tracked.txt");
    expect(changes[0].worktreeStatus).toBe("D");
    await files.create("tracked.txt", root);
    expect(await service.filePaths(root)).toEqual(["tracked.txt"]);
  });

  it("sums text in numstat and skips binary counts", () => {
    const stat = GitService.parseNumstat("3\t1\tSources/a.swift\n-\t-\timage.png\n10\t0\tpath\twith tab.txt\n2\t2\tSources/{old => new}.swift\n");
    expect(stat.additions).toBe(15);
    expect(stat.deletions).toBe(3);
    expect(stat.files).toEqual({ "Sources/a.swift": { additions: 3, deletions: 1 }, "path\twith tab.txt": { additions: 10, deletions: 0 } });
    expect(GitService.parseNumstat("")).toEqual({ additions: 0, deletions: 0, files: {} });
  });

  it("lists local branches and refuses to switch to unknown names", async () => {
    const repo = await Repository.make(roots);
    repo.write("file.txt", "base\n");
    await repo.commitAll("fixture");
    await repo.run(["branch", "feature/one"]);
    const service = new GitService();
    expect(new Set(await service.localBranches(repo.root))).toEqual(new Set(["main", "feature/one"]));
    await service.switchBranch("feature/one", repo.root);
    expect(await service.branch(repo.root)).toBe("feature/one");
    for (const name of ["--orphan", "origin/main", "missing"]) await expect(service.switchBranch(name, repo.root)).rejects.toThrow();
    expect(await service.branch(repo.root)).toBe("feature/one");
    repo.write("file.txt", "changed\nmore\n");
    expect(await service.diffStat(repo.root)).toEqual({ additions: 2, deletions: 1, files: { "file.txt": { additions: 2, deletions: 1 } } });
  });

  it("does not run the repository's fsmonitor when listing files", async () => {
    const base = temporaryRoot(); roots.push(base);
    const root = join(base, "repo");
    mkdirSync(root);
    const repo = new Repository(root);
    await repo.run(["init", "-b", "main"]);
    repo.write("a.txt", "a\n");
    await repo.run(["add", "--", "a.txt"]);
    const marker = join(base, "fired"), hook = join(base, "hook.sh");
    writeFileSync(hook, `#!/bin/sh\ntouch ${shellQuote(marker)}\n`);
    chmodSync(hook, 0o700);
    await repo.run(["config", "core.fsmonitor", hook]);
    await repo.run(["ls-files", "--cached", "--others", "-z"]);
    expect(existsSync(marker)).toBe(true);
    rmSync(marker);
    expect(await new GitService().filePaths(root)).toEqual(["a.txt"]);
    expect(existsSync(marker)).toBe(false);
  });

  it("does not open an embedded bare repository", async () => {
    const root = temporaryRoot(); roots.push(root);
    const embedded = join(root, "embedded");
    for (const folder of ["objects", "refs"]) mkdirSync(join(embedded, folder), { recursive: true });
    await runProcess(git, ["init", "-b", "main"], { directory: root });
    writeFileSync(join(embedded, "HEAD"), "ref: refs/heads/main\n");
    writeFileSync(join(embedded, "config"), "[core]\n\tbare = true\n");
    expect((await runProcess(git, ["for-each-ref", "refs/heads"], { directory: embedded })).status).toBe(0);
    await expect(new GitService().localBranches(embedded)).rejects.toThrow();
  });
});
