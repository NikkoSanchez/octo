import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { pullHint, pushProblem } from "../../../shared/review";
import { ReviewService } from "../reviewService";

function repository(): string {
  const root = mkdtempSync(join(tmpdir(), "octo-review-"));
  const git = (...args: string[]) => execFileSync("git", args, { cwd: root });
  git("init", "-q", "-b", "main");
  git("config", "user.email", "test@example.com");
  git("config", "user.name", "Test");
  git("config", "commit.gpgsign", "false");
  writeFileSync(join(root, "a.txt"), "one\n");
  git("add", "a.txt");
  git("commit", "-qm", "initial");
  return root;
}

describe("review service", () => {
  it("runs a checkout's actions in the order requested", async () => {
    const root = repository();
    const service = new ReviewService(() => {}, async () => "unused");
    writeFileSync(join(root, "a.txt"), "two\n");
    writeFileSync(join(root, "b.txt"), "new\n");
    const order: string[] = [];
    await Promise.all([
      service.stage(["a.txt", "b.txt"], root).then(() => order.push("stage")),
      service.commit("Second", root).then(() => order.push("commit")),
    ]);
    expect(order).toEqual(["stage", "commit"]);
    expect((await service.refresh(root)).files).toEqual([]);
    service.dispose();
  });

  it("supersedes an older commit message request", async () => {
    const root = repository();
    writeFileSync(join(root, "a.txt"), "two\n");
    const releases: ((value: string) => void)[] = [];
    const service = new ReviewService(() => {}, () => new Promise<string>((resolve) => { releases.push(resolve); }));
    await service.stage(["a.txt"], root);
    const model = { harness: "codex" as const, model: "m" };
    // Each request reaches the model only after reading the staged changes; wait for that, not a fixed time.
    const first = service.generateCommitMessage(root, [model], "first");
    await vi.waitFor(() => expect(releases).toHaveLength(1), { timeout: 4000 });
    const second = service.generateCommitMessage(root, [model], "second");
    releases[0]!("Old");
    expect(await first).toEqual({ cancelled: true });
    await vi.waitFor(() => expect(releases).toHaveLength(2), { timeout: 4000 });
    releases[1]!("New");
    expect(await second).toEqual({ message: "New" });
  });

  it("refuses to save a file that wasn't opened through it", async () => {
    const root = repository();
    const service = new ReviewService(() => {}, async () => "");
    await expect(service.saveFile(root, "a.txt", "x")).rejects.toThrow("Open the file again");
    const opened = await service.openFile(root, "a.txt");
    expect(opened.text).toBe("one\n");
    expect((await service.saveFile(root, "a.txt", "changed\n")).baseline).toBe("changed\n");
  });
  it("detects outside changes without replacing the opened identity", async () => {
    const root = repository(); const service = new ReviewService(() => {}, async () => "");
    await service.openFile(root, "a.txt"); expect(await service.fileChanged(root, "a.txt")).toBe(false);
    writeFileSync(join(root, "a.txt"), "outside edit\n"); expect(await service.fileChanged(root, "a.txt")).toBe(true);
    await expect(service.saveFile(root, "a.txt", "draft")).rejects.toThrow("changed on disk");
    await service.reloadFile(root, "a.txt"); expect((await service.saveFile(root, "a.txt", "after reload")).text).toBe("after reload");
  });

  it("flushes the latest retained editor draft before shutdown", async () => {
    const root = repository(), service = new ReviewService(() => {}, async () => "");
    await service.openFile(root, "a.txt");
    service.setFileDraft(root, "a.txt", "latest draft\n");
    expect(await service.flushDrafts()).toEqual([]);
    expect((await service.openFile(root, "a.txt")).text).toBe("latest draft\n");
    service.setFileDraft(root, "a.txt", "conflicting draft"); writeFileSync(join(root, "a.txt"), "outside");
    expect((await service.flushDrafts())[0]).toContain("changed on disk");
    await service.reloadFile(root, "a.txt"); expect(await service.flushDrafts()).toEqual([]);
  });

  it("keeps flushing when a newer edit arrives during an older write", async () => {
    const root = repository(), service = new ReviewService(() => {}, async () => "");
    await service.openFile(root, "a.txt"); service.setFileDraft(root, "a.txt", "first");
    const write = service.saveFile(root, "a.txt", "first");
    // Undo back to the opened text while an older version is still being saved.
    service.setFileDraft(root, "a.txt", "one\n");
    expect(await service.flushDrafts()).toEqual([]); await write;
    expect((await service.openFile(root, "a.txt")).text).toBe("one\n");
  });

});

describe("Git action hints", () => {
  it("names what usually fixes a rejected push and keeps the commits' count", () => {
    const problem = pushProblem("! [rejected] main -> main (fetch first)", "origin/main", 2);
    expect(problem.title).toBe("Couldn't push to origin/main. Your 2 commits are saved locally.");
    expect(problem.hint).toContain("Pull or rebase");
    expect(pushProblem("fatal: could not read Username", "origin", 1).hint).toContain("credentials");
    expect(pullHint("fatal: Not possible to fast-forward, aborting.")).toContain("both have new commits");
  });
});
