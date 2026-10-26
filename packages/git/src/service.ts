import { makeSnapshot, type DiffLine, type DiffScope, type ReviewSnapshot, type StagedChanges } from "@octo/core";
import { findExecutable, ProcessFailure, runProcess, type ProcessResult } from "@octo/core/node";
import { HunkPatch, UnifiedDiffParser } from "./diff";
import { readPreview } from "./preview";
import type { ChangedFile, CommitSummary, DiffStat, GitStash, UpstreamStatus } from "./model";
import { DEFERRED_NOTICE, hasStaged, hasWorking, isUntracked, publishes, pushRemote, stashReference } from "./model";
export * from "./model";

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
const LITERAL = "--literal-pathspecs";
/** Pushes and fetches wait on the network and on hooks; commits wait on hooks and signing. */
const NETWORK_TIMEOUT = 300;

/**
 * Git status, diffs and explicit actions. Every command runs with argument arrays, no optional locks,
 * unquoted paths and `safe.bareRepository=explicit`. Mutations never pass `--no-verify` or force.
 */
export class GitService {
  /** Shown for files past `snapshots`' line limit; selecting such a file loads its diff alone. */
  static readonly deferredNotice = DEFERRED_NOTICE;

  /**
   * A checkout can contain a folder laid out as a bare repository, whose config Git would otherwise
   * apply when run inside it; `explicit` opens bare repositories only when named.
   */
  static invocation(args: string[]): string[] {
    return ["--no-optional-locks", "-c", "core.quotepath=false", "-c", "safe.bareRepository=explicit", ...args];
  }
  /**
   * `core.fsmonitor` names a command run on each index refresh. Listing files does not need it, so a
   * repository's config cannot run one there; status keeps it for large repositories.
   */
  static readonly listingConfiguration = ["-c", "core.fsmonitor=false"];

  async git(args: string[], root: string, input?: string, timeout = 30): Promise<ProcessResult> {
    const executable = findExecutable("git");
    if (!executable) throw new ProcessFailure("missing", "git");
    return runProcess(executable, GitService.invocation(args), { directory: root, input, timeout });
  }

  async text(args: string[], root: string, input?: string, timeout = 30): Promise<string> {
    const result = await this.git(args, root, input, timeout);
    if (result.status !== 0) throw new ProcessFailure("exited", GitService.message(result));
    return result.output.toString("utf8").replace(/^[\r\n]+|[\r\n]+$/g, "");
  }

  /** Git reports some refusals, such as "nothing to commit", on standard output. */
  static message(result: ProcessResult): string {
    const error = result.error.toString("utf8").trim();
    if (error) return error;
    const output = result.output.toString("utf8").trim();
    return output || `Git exited with status ${result.status}.`;
  }

  repositoryRoot(path: string): Promise<string> { return this.text(["rev-parse", "--show-toplevel"], path); }

  async branch(root: string): Promise<string> {
    const name = await this.text(["branch", "--show-current"], root).catch(() => "");
    return name || "Detached HEAD";
  }

  /** Local branches, most recently committed first. */
  async localBranches(root: string): Promise<string[]> {
    return (await this.text(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"], root)).split("\n").filter(Boolean);
  }

  /** Switches only to an existing local branch; never guesses a remote-tracking branch. */
  async switchBranch(name: string, root: string): Promise<void> {
    if (!name || name.startsWith("-")) throw new ProcessFailure("exited", "Invalid branch name.");
    if (!(await this.localBranches(root)).includes(name)) throw new ProcessFailure("exited", `${name} is not a local branch.`);
    await this.text(["switch", "--no-guess", name], root);
  }

  /** Lines added and removed in tracked files relative to HEAD, or within one scope. */
  async diffStat(root: string, scope?: DiffScope): Promise<DiffStat> {
    const args = ["diff", "--no-ext-diff", "--no-textconv", "--numstat"];
    if (scope === undefined) args.push("HEAD"); else if (scope === "staged") args.push("--cached");
    return GitService.parseNumstat(await this.text(args, root));
  }

  /**
   * The staged diff for a commit message draft, with the patch cut at `limit` characters. External
   * diff drivers and text conversion stay off, as in every other diff read.
   */
  async stagedChanges(root: string, limit = 60_000, subjects = 10): Promise<StagedChanges> {
    const diff = ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color"];
    const stat = await this.text([...diff, "--stat=120"], root);
    let patch = "", truncated = false;
    try { [patch, truncated] = GitService.cut(await this.text([...diff, "--unified=3"], root), limit); }
    catch (error) { if (error instanceof ProcessFailure && error.kind === "oversized") truncated = true; else throw error; }
    const recent = (await this.hasHead(root)) ? await this.text(["log", "--format=%s", "--no-merges", `--max-count=${subjects}`], root).catch(() => "") : "";
    return { stat, patch, truncated, recentSubjects: recent.split("\n").filter(Boolean) };
  }

  static cut(patch: string, limit: number): [string, boolean] {
    const characters = Array.from(patch);
    if (characters.length <= limit) return [patch, false];
    const prefix = characters.slice(0, limit).join("");
    const newline = prefix.lastIndexOf("\n");
    return [newline === -1 ? prefix : prefix.slice(0, newline), true];
  }

  static parseNumstat(output: string): DiffStat {
    const stat: DiffStat = { additions: 0, deletions: 0, files: {} };
    for (const line of output.split("\n")) {
      if (!line) continue;
      const first = line.indexOf("\t"), second = first === -1 ? -1 : line.indexOf("\t", first + 1);
      if (second === -1) continue;
      const a = line.slice(0, first), d = line.slice(first + 1, second), path = line.slice(second + 1);
      // Binary files report "-" for both counts.
      const additions = /^\d+$/.test(a) ? Number(a) : undefined, deletions = /^\d+$/.test(d) ? Number(d) : undefined;
      stat.additions += additions ?? 0;
      stat.deletions += deletions ?? 0;
      // Without -z a rename reads "old => new" or "dir/{old => new}"; those paths are not usable.
      if (additions !== undefined && deletions !== undefined && !path.includes(" => ")) stat.files[path] = { additions, deletions };
    }
    return stat;
  }

  async changes(root: string): Promise<ChangedFile[]> {
    const result = await this.git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], root);
    if (result.status !== 0) throw new ProcessFailure("exited", result.error.toString("utf8"));
    return GitService.parseStatus(result.output);
  }

  static parseStatus(data: Buffer | string): ChangedFile[] {
    const records = (typeof data === "string" ? data : data.toString("utf8")).split("\0").filter(Boolean);
    const result: ChangedFile[] = [];
    let i = 0;
    while (i < records.length) {
      const chars = Array.from(records[i]); i++;
      if (chars.length < 4) continue;
      const file: ChangedFile = { path: chars.slice(3).join(""), indexStatus: chars[0], worktreeStatus: chars[1] };
      if ("RC".includes(chars[0]) || "RC".includes(chars[1])) {
        if (i < records.length) file.originalPath = records[i];
        i++;
      }
      result.push(file);
    }
    return result.sort((a, b) => collator.compare(a.path, b.path));
  }

  async filePaths(root: string): Promise<string[]> {
    const result = await this.git([...GitService.listingConfiguration, "ls-files", "--cached", "--others", "--exclude-standard", "-z"], root);
    if (result.status !== 0) throw new ProcessFailure("exited", result.error.toString("utf8"));
    // Cached paths include tracked files deleted from disk; those belong in Changes only.
    const deleted = await this.git([...GitService.listingConfiguration, "ls-files", "--deleted", "-z"], root);
    if (deleted.status !== 0) throw new ProcessFailure("exited", deleted.error.toString("utf8"));
    const missing = new Set(deleted.output.toString("utf8").split("\0").filter(Boolean));
    return [...new Set(result.output.toString("utf8").split("\0").filter(Boolean))].filter((p) => !missing.has(p)).sort();
  }

  private async base(root: string): Promise<string> {
    return this.text(["rev-parse", "HEAD"], root).catch(() => "unborn");
  }

  async fileSnapshot(path: string, projectID: string, root: string): Promise<ReviewSnapshot> {
    const preview = await readPreview(path, root);
    let lines: DiffLine[] = [];
    if (preview.text !== undefined) {
      const source = preview.text.split("\n");
      if (source[source.length - 1] === "") source.pop();
      lines = source.map((text, i) => ({ id: i, kind: "context", text, newLine: i + 1 }));
    }
    return makeSnapshot({ projectID, workingDirectory: root, path, scope: "file", baseRevision: await this.base(root), lines, ...(preview.notice ? { notice: preview.notice } : {}) });
  }

  snapshot(file: ChangedFile, projectID: string, root: string, scope: DiffScope): Promise<ReviewSnapshot> {
    return this.snapshotWithBase(file, projectID, root, scope, undefined);
  }

  /**
   * Every change for the all-files diff, in the given order (Staged, then Unstaged). A few diffs run at
   * a time. Once `lineLimit` lines are loaded, later files carry `deferredNotice` instead, and a file
   * that can't be read carries its error, so one bad file never hides the rest.
   */
  async snapshots(entries: { file: ChangedFile; scope: DiffScope }[], projectID: string, root: string, lineLimit = 20_000): Promise<ReviewSnapshot[]> {
    if (entries.length === 0) return [];
    const base = await this.base(root);
    const results: ReviewSnapshot[] = new Array(entries.length);
    let next = 0;
    const worker = async () => {
      while (next < entries.length) {
        const index = next++, entry = entries[index];
        try { results[index] = await this.snapshotWithBase(entry.file, projectID, root, entry.scope, base); }
        catch (error) {
          results[index] = makeSnapshot({ projectID, workingDirectory: root, path: entry.file.path, scope: entry.scope, baseRevision: base, lines: [], notice: (error as Error).message });
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(6, entries.length) }, worker));
    let total = 0;
    return results.map((snapshot) => {
      if (total > lineLimit) {
        return snapshot.lines.length === 0 ? snapshot
          : makeSnapshot({ projectID, workingDirectory: root, path: snapshot.path, scope: snapshot.scope, baseRevision: base, lines: [], notice: GitService.deferredNotice });
      }
      total += snapshot.lines.length;
      return snapshot;
    });
  }

  private async snapshotWithBase(file: ChangedFile, projectID: string, root: string, scope: DiffScope, knownBase: string | undefined): Promise<ReviewSnapshot> {
    const base = knownBase ?? await this.base(root);
    let lines: DiffLine[] = [], notice: string | undefined;
    if (isUntracked(file)) {
      const preview = await readPreview(file.path, root);
      notice = preview.notice;
      if (preview.text !== undefined) lines = preview.text.split("\n").map((text, i) => ({ id: i, kind: "addition", text, newLine: i + 1 }));
    } else {
      const args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=5"];
      if (scope === "staged") args.push("--cached");
      args.push("--", file.path);
      const result = await this.git(args, root);
      if (result.status !== 0) throw new ProcessFailure("exited", GitService.message(result));
      if (result.output.length > 2_000_000) notice = "Diff exceeds the 2 MB preview limit. Open the file in Neovim.";
      else {
        const patch = result.output.toString("utf8");
        lines = UnifiedDiffParser.parse(patch);
        if (lines.length === 0) notice = patch.includes("Binary files") ? "Binary file changed." : "No text changes in this scope (possibly a rename or mode change).";
      }
    }
    return makeSnapshot({ projectID, workingDirectory: root, path: file.path, scope, baseRevision: base, lines, ...(notice ? { notice } : {}) });
  }

  // MARK: Actions

  /** The checkout's Git directory, whose HEAD and index change when anything commits or stages. */
  gitDirectory(root: string): Promise<string> { return this.text(["rev-parse", "--absolute-git-dir"], root); }

  async hasHead(root: string): Promise<boolean> {
    return (await this.git(["rev-parse", "--verify", "--quiet", "HEAD"], root).catch(() => undefined))?.status === 0;
  }

  private checked(paths: string[]): string[] {
    if (!paths.every((p) => p && !p.startsWith("/"))) throw new ProcessFailure("exited", "File path is outside this checkout.");
    return paths;
  }

  /** Stages the whole file, including deletions and untracked files. */
  async stage(paths: string[], root: string): Promise<void> {
    if (paths.length === 0) return;
    await this.text([LITERAL, "add", "--all", "--", ...this.checked(paths)], root);
  }

  /** Returns the files' index entries to HEAD, keeping their working-tree contents. */
  async unstage(files: ChangedFile[], root: string): Promise<void> {
    const paths = this.checked(files.flatMap((f) => [f.path, ...(f.originalPath ? [f.originalPath] : [])]));
    if (paths.length === 0) return;
    if (await this.hasHead(root)) await this.text([LITERAL, "restore", "--staged", "--", ...paths], root);
    // Before the first commit there is no HEAD to restore from: unstaging removes the entry.
    else await this.text([LITERAL, "rm", "--cached", "--quiet", "-r", "--ignore-unmatch", "--", ...paths], root);
  }

  /**
   * Discards unstaged edits by restoring the working tree from the index, so staged changes stay.
   * Untracked files are deleted. The caller confirms first: Git cannot recover these edits.
   */
  async discardUnstaged(files: ChangedFile[], root: string): Promise<void> {
    const tracked = this.checked(files.filter((f) => !isUntracked(f) && hasWorking(f)).map((f) => f.path));
    const untracked = this.checked(files.filter(isUntracked).map((f) => f.path));
    if (tracked.length > 0) await this.text([LITERAL, "restore", "--worktree", "--", ...tracked], root);
    if (untracked.length > 0) await this.text([LITERAL, "clean", "--force", "--quiet", "--", ...untracked], root);
  }

  /** Stages one working-tree hunk, or unstages one staged hunk, changing only the index. */
  async applyHunk(snapshot: ReviewSnapshot, hunk: number, root: string): Promise<void> {
    const patch = snapshot.workingDirectory === root && snapshot.scope !== "file" ? HunkPatch.make(snapshot.path, snapshot.lines, hunk) : undefined;
    if (!patch) throw new ProcessFailure("exited", "This hunk can't be staged on its own. Stage the whole file instead.");
    const args = ["apply", "--cached", "--whitespace=nowarn"];
    if (snapshot.scope === "staged") args.push("--reverse");
    const result = await this.git([...args, "-"], root, patch);
    if (result.status !== 0) throw new ProcessFailure("exited", "This hunk no longer matches the index. Refresh Changes and try again.\n\n" + GitService.message(result));
  }

  /** Commits exactly what is staged. Repository hooks and signing settings apply as usual. */
  async commit(message: string, root: string): Promise<CommitSummary> {
    if (!message.trim()) throw new ProcessFailure("exited", "Write a commit message first.");
    // The message goes through standard input, so a leading "-" or "#" stays part of it.
    await this.text(["commit", "--cleanup=whitespace", "--file=-"], root, message, NETWORK_TIMEOUT);
    const fields = (await this.text(["log", "-1", "--format=%h%x1f%s"], root)).split("\u001f");
    return { hash: fields[0] ?? "", subject: fields.slice(1).join("\u001f") };
  }

  async upstreamStatus(root: string): Promise<UpstreamStatus> {
    const status: UpstreamStatus = { ahead: 0, behind: 0, upstreamGone: false, remotes: [], hasCommits: false };
    status.remotes = (await this.text(["remote"], root)).split("\n").filter(Boolean);
    status.hasCommits = await this.hasHead(root);
    const symbolic = await this.git(["symbolic-ref", "--quiet", "--short", "HEAD"], root);
    if (symbolic.status === 0) status.branch = symbolic.output.toString("utf8").trim();
    const branch = status.branch;
    if (!branch || !status.hasCommits) return status;
    const ref = "refs/heads/" + branch;
    const refs = await this.text(["for-each-ref", "--format=%(refname)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)", ref], root);
    for (const line of refs.split("\n")) {
      const fields = line.split("\u001f");
      if (fields.length !== 4 || fields[0] !== ref || !fields[1]) continue;
      status.upstream = fields[1];
      if (fields[2]) status.upstreamRemote = fields[2];
      const track = GitService.parseTrack(fields[3]);
      status.ahead = track.ahead; status.behind = track.behind; status.upstreamGone = track.gone;
    }
    if (publishes(status)) status.ahead = Number(await this.text(["rev-list", "--count", "HEAD", "--not", "--remotes"], root)) || 0;
    return status;
  }

  /** Parses `%(upstream:track,nobracket)`: "ahead 2, behind 1", "behind 3", "gone" or empty. */
  static parseTrack(track: string): { ahead: number; behind: number; gone: boolean } {
    let ahead = 0, behind = 0;
    for (const part of track.split(",")) {
      const words = part.trim().split(" ");
      if (words.length !== 2 || !/^\d+$/.test(words[1])) continue;
      if (words[0] === "ahead") ahead = Number(words[1]); else if (words[0] === "behind") behind = Number(words[1]);
    }
    return { ahead, behind, gone: track.trim() === "gone" };
  }

  /**
   * Pushes the current branch only. A tracked branch uses the user's push configuration; an untracked
   * one is published to `pushRemote` and starts tracking it. Never forces.
   */
  async push(root: string): Promise<void> {
    const status = await this.upstreamStatus(root);
    if (!status.branch) throw new ProcessFailure("exited", "Check out a branch before pushing.");
    if (!status.hasCommits) throw new ProcessFailure("exited", "Commit before pushing.");
    if (!publishes(status)) { await this.text(["push"], root, undefined, NETWORK_TIMEOUT); return; }
    const remote = pushRemote(status);
    if (!remote || remote.startsWith("-")) {
      throw new ProcessFailure("exited", status.remotes.length === 0 ? "This repository has no remote. Add one in the terminal, then push."
        : "Several remotes and no origin. Choose one with git push -u in the terminal.");
    }
    await this.text(["push", "--set-upstream", remote, `refs/heads/${status.branch}:refs/heads/${status.branch}`], root, undefined, NETWORK_TIMEOUT);
  }

  /**
   * Brings in the upstream's new commits only when that needs no merge or rebase. A diverged branch, or
   * local edits the update would overwrite, make Git refuse with nothing changed.
   */
  async pull(root: string): Promise<void> {
    const status = await this.upstreamStatus(root);
    if (!status.branch) throw new ProcessFailure("exited", "Check out a branch before pulling.");
    if (!status.upstream || status.upstreamGone) throw new ProcessFailure("exited", "This branch doesn't track a remote branch yet. Push it first.");
    await this.text(["pull", "--ff-only", "--no-rebase", "--quiet"], root, undefined, NETWORK_TIMEOUT);
  }

  async fetch(root: string): Promise<void> {
    await this.text(["fetch", "--quiet"], root, undefined, NETWORK_TIMEOUT);
  }

  /** Branches on `remote` for a pull request base, and the remote's default branch when known. */
  async remoteBranches(remote: string, root: string): Promise<{ branches: string[]; defaultBranch?: string }> {
    const prefix = `refs/remotes/${remote}/`;
    const branches = (await this.text(["for-each-ref", "--format=%(refname)", `refs/remotes/${remote}`], root)).split("\n")
      .filter((r) => r.startsWith(prefix)).map((r) => r.slice(prefix.length)).filter((b) => b !== "HEAD");
    const head = await this.git(["symbolic-ref", "--quiet", prefix + "HEAD"], root);
    const target = head.output.toString("utf8").trim();
    return { branches, ...(head.status === 0 && target.startsWith(prefix) ? { defaultBranch: target.slice(prefix.length) } : {}) };
  }

  /** Subjects of commits on HEAD that `base` lacks, newest first, to draft a pull request. */
  async commitSubjects(base: string, root: string, limit = 50): Promise<string[]> {
    return (await this.text(["log", "--format=%s", `--max-count=${limit}`, "--end-of-options", `${base}..HEAD`, "--"], root)).split("\n").filter(Boolean);
  }

  async stashes(root: string): Promise<GitStash[]> {
    return GitService.parseStashes(await this.text(["stash", "list", "--format=%H%x1f%gd%x1f%ct%x1f%s"], root));
  }

  static parseStashes(output: string): GitStash[] {
    const stashes: GitStash[] = [];
    for (const line of output.split("\n")) {
      const parts = line.split("\u001f");
      if (parts.length < 4) continue;
      const fields = [parts[0], parts[1], parts[2], parts.slice(3).join("\u001f")];
      const index = /^stash@\{(\d+)\}$/.exec(fields[1]);
      if (!index) continue;
      // `stash push -m` records "On <branch>: <name>"; an unnamed stash "WIP on <branch>: <hash> <subject>".
      // Branch names cannot contain ":", so the first ": " ends the prefix.
      let message = fields[3], branch: string | undefined;
      const separator = message.indexOf(": ");
      if (separator !== -1) {
        const prefix = message.slice(0, separator);
        for (const lead of ["WIP on ", "On "]) {
          if (!prefix.startsWith(lead)) continue;
          const name = prefix.slice(lead.length);
          branch = name === "(no branch)" ? undefined : name;
          message = message.slice(separator + 2);
          break;
        }
      }
      stashes.push({ index: Number(index[1]), commit: fields[0], message, ...(branch ? { branch } : {}), date: (Number(fields[2]) || 0) * 1000 });
    }
    return stashes;
  }

  /** Saves staged and unstaged edits under `message` and cleans the checkout; staging is recorded. */
  async stash(message: string, includeUntracked: boolean, root: string): Promise<void> {
    const args = ["stash", "push", ...(includeUntracked ? ["--include-untracked"] : []), `--message=${message}`];
    const output = await this.text(args, root, undefined, 120);
    if (output.includes("No local changes to save")) throw new ProcessFailure("exited", "There are no changes to stash.");
  }

  /** Restores the stash with its staging. Pop drops it only after a clean apply; Git keeps it on conflict. */
  async applyStash(stash: GitStash, pop: boolean, root: string): Promise<void> {
    await this.verify(stash, root);
    await this.text(["stash", pop ? "pop" : "apply", "--index", "--quiet", stashReference(stash)], root, undefined, 120);
  }

  async dropStash(stash: GitStash, root: string): Promise<void> {
    await this.verify(stash, root);
    await this.text(["stash", "drop", "--quiet", stashReference(stash)], root);
  }

  private async verify(stash: GitStash, root: string): Promise<void> {
    const current = await this.text(["rev-parse", "--verify", "--quiet", stashReference(stash)], root).catch(() => undefined);
    if (current !== stash.commit) throw new ProcessFailure("exited", "The stash list changed. Review the stashes again before continuing.");
  }
}
