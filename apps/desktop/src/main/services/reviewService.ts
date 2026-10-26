import { watch, type FSWatcher } from "node:fs";
import type { CommitMessageModel } from "@octo/agents";
import type { DiffScope, ReviewSnapshot, StagedChanges } from "@octo/core";
import { CheckoutFileService, ProcessFailure, type CheckoutFile } from "@octo/core/node";
import { GitService, PullRequests, type ChangedFile, type GitStash } from "@octo/git";
import type { OpenedFile, ReviewEvent, ReviewRefresh } from "../../shared/review";

/**
 * Git reads, serialized Git actions per checkout, the Git-directory watcher and checkout file I/O.
 * Actions on one checkout run one at a time in the order requested. Nothing is pushed or published
 * except by an explicit request.
 */
export class ReviewService {
  private readonly git = new GitService();
  private readonly files = new CheckoutFileService();
  private readonly queues = new Map<string, Promise<unknown>>();
  private readonly watchers = new Map<string, { directory: string; watcher: FSWatcher; timer?: NodeJS.Timeout }>();
  private readonly running = new Map<string, number>();
  private readonly opened = new Map<string, CheckoutFile>();
  private fileDrafts = new Map<string, { root: string; path: string; text: string }>();
  private fileSaves = new Map<string, Promise<OpenedFile>>();
  private draftRequest: string | undefined;
  private draftAbort: AbortController | undefined;

  constructor(private readonly emit: (event: ReviewEvent) => void,
              private readonly generate: (model: CommitMessageModel, changes: StagedChanges) => Promise<string>) {}

  /** Runs after any earlier action on the same checkout finishes. */
  private enqueue<T>(root: string, body: () => Promise<T>): Promise<T> {
    const previous = this.queues.get(root) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(async () => {
      this.running.set(root, (this.running.get(root) ?? 0) + 1);
      try { return await body(); } finally { this.running.set(root, (this.running.get(root) ?? 1) - 1); }
    });
    this.queues.set(root, next.catch(() => undefined));
    return next;
  }

  async refresh(root: string): Promise<ReviewRefresh> {
    const [files, branch] = await Promise.all([this.git.changes(root), this.git.branch(root)]);
    const paths = await this.git.filePaths(root);
    const [diffStat, stagedStat, workingStat] = await Promise.all([
      this.git.diffStat(root).catch(() => undefined), this.git.diffStat(root, "staged").catch(() => undefined), this.git.diffStat(root, "working").catch(() => undefined),
    ]);
    return { files, branch, paths, diffStat, stagedStat, workingStat };
  }

  snapshot(file: ChangedFile, projectID: string, root: string, scope: DiffScope): Promise<ReviewSnapshot> { return this.git.snapshot(file, projectID, root, scope); }
  snapshots(entries: { file: ChangedFile; scope: DiffScope }[], projectID: string, root: string): Promise<ReviewSnapshot[]> { return this.git.snapshots(entries, projectID, root); }
  fileSnapshot(path: string, projectID: string, root: string): Promise<ReviewSnapshot> { return this.git.fileSnapshot(path, projectID, root); }
  filePaths(root: string): Promise<string[]> { return this.git.filePaths(root); }
  branches(root: string): Promise<string[]> { return this.git.localBranches(root).catch(() => []); }
  upstreamStatus(root: string) { return this.git.upstreamStatus(root); }
  stashes(root: string): Promise<GitStash[]> { return this.git.stashes(root).catch(() => []); }
  remoteBranches(remote: string, root: string) { return this.git.remoteBranches(remote, root); }
  commitSubjects(base: string, root: string) { return this.git.commitSubjects(base, root); }
  stagedChanges(root: string) { return this.git.stagedChanges(root); }

  stage(paths: string[], root: string) { return this.enqueue(root, () => this.git.stage(paths, root)); }
  unstage(files: ChangedFile[], root: string) { return this.enqueue(root, () => this.git.unstage(files, root)); }
  discard(files: ChangedFile[], root: string) { return this.enqueue(root, () => this.git.discardUnstaged(files, root)); }
  applyHunk(snapshot: ReviewSnapshot, hunk: number, root: string) { return this.enqueue(root, () => this.git.applyHunk(snapshot, hunk, root)); }
  commit(message: string, root: string) { return this.enqueue(root, () => this.git.commit(message, root)); }
  async push(root: string): Promise<{ error?: string; timedOut?: boolean }> {
    return this.enqueue(root, async () => {
      try { await this.git.push(root); return {}; }
      catch (error) { return { error: (error as Error).message, timedOut: error instanceof ProcessFailure && error.kind === "timedOut" }; }
    });
  }
  pull(root: string) { return this.enqueue(root, () => this.git.pull(root)); }
  fetch(root: string) { return this.enqueue(root, () => this.git.fetch(root)); }
  switchBranch(name: string, root: string) { return this.enqueue(root, () => this.git.switchBranch(name, root)); }
  stash(message: string, includeUntracked: boolean, root: string) { return this.enqueue(root, () => this.git.stash(message, includeUntracked, root)); }
  applyStash(stash: GitStash, pop: boolean, root: string) { return this.enqueue(root, () => this.git.applyStash(stash, pop, root)); }
  dropStash(stash: GitStash, root: string) { return this.enqueue(root, () => this.git.dropStash(stash, root)); }

  pullRequestsAvailable(): boolean { return PullRequests.isAvailable; }
  openPullRequest(branch: string, root: string) { return PullRequests.open(branch, root); }
  createPullRequest(title: string, body: string, base: string, head: string, draft: boolean, root: string) {
    return PullRequests.create(title, body, base, head, draft, root);
  }

  /**
   * Writes a message for what is staged now, trying each candidate in order until one answers. Runs
   * beside queued actions: it only reads. A newer request or cancellation supersedes this one.
   */
  async generateCommitMessage(root: string, candidates: CommitMessageModel[], request: string): Promise<{ message?: string; error?: string; cancelled?: boolean }> {
    this.cancelCommitMessage();
    this.draftRequest = request;
    const abort = new AbortController();
    this.draftAbort = abort;
    try {
      const changes = await this.git.stagedChanges(root);
      if (!changes.stat) throw new ProcessFailure("exited", "Nothing is staged.");
      const failures: string[] = [];
      for (const model of candidates) {
        if (abort.signal.aborted || this.draftRequest !== request) return { cancelled: true };
        try {
          const message = await this.generate(model, changes);
          if (abort.signal.aborted || this.draftRequest !== request) return { cancelled: true };
          return { message };
        } catch (error) {
          failures.push(candidates.length > 1 ? `${model.model}: ${(error as Error).message}` : (error as Error).message);
        }
      }
      return { error: failures.join("\n") || "No model is available to write a commit message." };
    } catch (error) {
      return abort.signal.aborted ? { cancelled: true } : { error: (error as Error).message };
    } finally {
      if (this.draftRequest === request) { this.draftRequest = undefined; this.draftAbort = undefined; }
    }
  }

  cancelCommitMessage(request?: string): void {
    if (request !== undefined && request !== this.draftRequest) return;
    this.draftAbort?.abort();
    this.draftAbort = undefined;
    this.draftRequest = undefined;
  }

  /**
   * Watches the checkout's Git directory, whose HEAD and index change when a branch switches, a commit
   * lands or files are staged from a terminal or agent. Refreshes only read (`--no-optional-locks`),
   * so they cannot retrigger it. Edits to working files alone do not.
   */
  async watch(root: string): Promise<void> {
    let directory: string;
    try { directory = await this.git.gitDirectory(root); } catch { return; }
    const existing = this.watchers.get(root);
    if (existing?.directory === directory) return;
    existing?.watcher.close();
    try {
      const watcher = watch(directory, { persistent: false }, () => {
        const entry = this.watchers.get(root);
        if (!entry) return;
        if (entry.timer) clearTimeout(entry.timer);
        entry.timer = setTimeout(() => {
          // An action refreshes when it finishes.
          if ((this.running.get(root) ?? 0) === 0) this.emit({ type: "gitChanged", root });
        }, 400);
      });
      this.watchers.set(root, { directory, watcher });
    } catch { /* not watchable */ }
  }

  // MARK: Checkout files

  private key(root: string, path: string): string { return `${root}\0${path}`; }

  async openFile(root: string, path: string): Promise<OpenedFile> {
    const file = await this.files.inspect(path, root, true);
    this.opened.set(this.key(root, path), file);
    return { text: file.text ?? "", baseline: file.text ?? "" };
  }

  /** Retains the latest text in main so quit can flush edits before renderer teardown. */
  setFileDraft(root: string, path: string, text: string): void {
    const key = this.key(root, path);
    const file = this.opened.get(key);
    if (!file) throw new Error("Open the file again before editing.");
    if (file.text === text && !this.fileSaves.has(key)) this.fileDrafts.delete(key); else this.fileDrafts.set(key, { root, path, text });
  }

  /** Saves against the captured identity, serialized per file, preserving any newer draft. */
  async saveFile(root: string, path: string, text: string): Promise<OpenedFile> {
    const key = this.key(root, path);
    const previous = this.fileSaves.get(key);
    const write = (previous ?? Promise.resolve()).catch(() => undefined).then(async () => {
      const file = this.opened.get(key);
      if (!file) throw new Error("Open the file again before saving.");
      const saved = await this.files.save(file, text);
      this.opened.set(key, saved);
      if (this.fileDrafts.get(key)?.text === text) this.fileDrafts.delete(key);
      return { text: saved.text ?? text, baseline: saved.text ?? text };
    });
    this.fileSaves.set(key, write);
    try { return await write; } finally { if (this.fileSaves.get(key) === write) this.fileSaves.delete(key); }
  }

  async flushDrafts(): Promise<string[]> {
    for (;;) {
      await Promise.allSettled([...this.fileSaves.values()]);
      const drafts = [...this.fileDrafts.values()];
      if (!drafts.length) return [];
      const failures: string[] = [];
      for (const draft of drafts) {
        try { await this.saveFile(draft.root, draft.path, draft.text); }
        catch (error) { failures.push(`${draft.path}: ${String(error)}`); }
      }
      if (failures.length) return failures;
      // A newer edit may have arrived while a prior version was being written.
    }
  }

  async fileChanged(root: string, path: string): Promise<boolean> {
    const before = this.opened.get(this.key(root, path));
    if (!before) return true;
    const after = await this.files.inspect(path, root, true);
    if (this.opened.get(this.key(root, path)) !== before) return false;
    return before.text !== after.text || Object.keys(before.identity).some((key) => before.identity[key as keyof typeof before.identity] !== after.identity[key as keyof typeof after.identity]);
  }

  async reloadFile(root: string, path: string): Promise<OpenedFile> {
    await this.fileSaves.get(this.key(root, path))?.catch(() => undefined);
    const file = await this.openFile(root, path);
    this.fileDrafts.delete(this.key(root, path));
    return file;
  }

  closeFile(root: string, path: string): void { this.opened.delete(this.key(root, path)); }

  createFile(root: string, path: string): Promise<void> { return this.files.create(path, root); }

  /** Captures the file's identity for a deletion confirmation. */
  async inspectFile(root: string, path: string): Promise<boolean> {
    const file = await this.files.inspect(path, root, false);
    this.opened.set(this.key(root, path) + "\0delete", file);
    return true;
  }

  async deleteFile(root: string, path: string): Promise<void> {
    const file = this.opened.get(this.key(root, path) + "\0delete");
    if (!file) throw new Error("Review the file again before deleting it.");
    await this.files.delete(file);
    this.opened.delete(this.key(root, path) + "\0delete");
    this.opened.delete(this.key(root, path));
    this.fileDrafts.delete(this.key(root, path));
  }

  dispose(): void {
    for (const entry of this.watchers.values()) { entry.watcher.close(); if (entry.timer) clearTimeout(entry.timer); }
    this.watchers.clear();
  }
}
