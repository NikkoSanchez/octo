import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { constants, promises as fs, existsSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { parseArchive, serializeArchive } from "../archiveCodec";
import { makeArchive, type WorkspaceArchive } from "../workspace";

export type StoreErrorKind = "unsupportedVersion" | "repositoryLocation" | "unsafeFile" | "unsafeDirectory";

export class StoreError extends Error {
  readonly kind: StoreErrorKind;
  constructor(kind: StoreErrorKind, version?: number) {
    super(StoreError.describe(kind));
    this.kind = kind;
    this.name = "StoreError";
    if (version !== undefined) this.version = version;
  }
  version?: number;
  static describe(kind: StoreErrorKind): string {
    switch (kind) {
      case "unsupportedVersion": return "This workspace was saved by a newer Octo version. The file has been preserved.";
      case "repositoryLocation": return "Conversation storage must be outside Git repositories. Remove OCTO_WORKSPACE_PATH to use private local storage.";
      case "unsafeDirectory": return "Workspace storage requires a directory owned by your macOS account that other users cannot modify.";
      case "unsafeFile": return "Workspace storage must be a regular, unlinked file owned by your macOS account.";
    }
  }
}

const uid = () => process.getuid?.() ?? -1;
const excluded = new Set<string>();

/**
 * Excludes the private data folder from Time Machine once per launch. The exclusion covers files
 * replaced inside it, so atomic saves stay excluded.
 */
function excludeFromBackup(path: string): void {
  if (process.platform !== "darwin" || excluded.has(path)) return;
  excluded.add(path);
  execFile("/usr/bin/tmutil", ["addexclusion", path], () => { /* best effort */ });
}

/**
 * The archive is one schema-versioned JSON file. Saves are atomic and owner-only; storage inside a
 * Git checkout is refused, and a corrupt or newer archive is preserved untouched.
 */
export class WorkspaceStore {
  readonly filePath: string;
  /** The app's own data folder, which is created and tightened; custom parents are only checked. */
  private readonly isStandard: boolean;

  constructor(filePath: string, options: { isStandard?: boolean } = {}) {
    this.filePath = resolve(filePath);
    this.isStandard = options.isStandard ?? false;
  }

  private async prepareDirectory(): Promise<void> {
    const parent = dirname(this.filePath);
    // An explicit development override must not put conversations inside any checkout.
    let ancestor = resolveExisting(parent);
    for (;;) {
      if (existsSync(join(ancestor, ".git"))) throw new StoreError("repositoryLocation");
      const next = dirname(ancestor);
      if (next === ancestor) break;
      ancestor = next;
    }
    const exists = existsSync(parent);
    if (!exists) await fs.mkdir(parent, { recursive: true, mode: 0o700 });
    const handle = await fs.open(parent, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW).catch(() => {
      throw new StoreError("unsafeDirectory");
    });
    try {
      const info = await handle.stat();
      if (info.uid !== uid()) throw new StoreError("unsafeDirectory");
      if (!exists || this.isStandard) {
        await handle.chmod(0o700);
        excludeFromBackup(parent);
      } else if ((info.mode & 0o022) !== 0) {
        throw new StoreError("unsafeDirectory");
      }
    } finally {
      await handle.close();
    }
  }

  private async openArchive(): Promise<fs.FileHandle | undefined> {
    let handle: fs.FileHandle;
    try {
      handle = await fs.open(this.filePath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "ENOENT") return undefined;
      if (code === "ELOOP") throw new StoreError("unsafeFile");
      throw error;
    }
    try {
      const info = await handle.stat();
      if (!info.isFile() || info.uid !== uid() || info.nlink !== 1) throw new StoreError("unsafeFile");
      await handle.chmod(0o600);
      return handle;
    } catch (error) {
      await handle.close();
      throw error instanceof StoreError ? error : new StoreError("unsafeFile");
    }
  }

  async load(): Promise<WorkspaceArchive> {
    await this.prepareDirectory();
    const handle = await this.openArchive();
    if (!handle) return makeArchive();
    let text: string;
    try { text = await handle.readFile("utf8"); } finally { await handle.close(); }
    const archive = parseArchive(text);
    if (archive.schemaVersion !== 1) throw new StoreError("unsupportedVersion", archive.schemaVersion);
    return archive;
  }

  /**
   * Persistent per-chat CLI scratch space, separate from repositories and the archive itself. Each
   * component is opened without following symlinks and must be owner-only.
   */
  async prepareChatDirectory(id: string): Promise<string> {
    await this.prepareDirectory();
    let directory = dirname(this.filePath);
    for (const component of ["ChatWorkspaces", id]) {
      directory = join(directory, component);
      try { await fs.mkdir(directory, { mode: 0o700 }); } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      }
      const handle = await fs.open(directory, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW).catch(() => {
        throw new StoreError("unsafeDirectory");
      });
      try {
        const info = await handle.stat();
        if (info.uid !== uid() || (info.mode & 0o077) !== 0) throw new StoreError("unsafeDirectory");
      } finally {
        await handle.close();
      }
    }
    return directory;
  }

  async save(archive: WorkspaceArchive): Promise<void> {
    await this.prepareDirectory();
    const existing = await this.openArchive();
    await existing?.close();
    const data = serializeArchive(archive);
    // O_EXCL with mode 0600 creates the file owner-only before the first sensitive byte is written.
    const temporary = join(dirname(this.filePath), `.octo-workspace-${randomBytes(6).toString("base64url")}`);
    const handle = await fs.open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    let renamed = false;
    try {
      await handle.chmod(0o600);
      await handle.writeFile(data, "utf8");
      await handle.sync();
      await fs.rename(temporary, this.filePath);
      renamed = true;
    } finally {
      await handle.close();
      if (!renamed) await fs.unlink(temporary).catch(() => {});
    }
  }
}

/** The deepest existing ancestor of `path`, with symlinks resolved, followed by the missing tail. */
function resolveExisting(path: string): string {
  let existing = path;
  const tail: string[] = [];
  while (!existsSync(existing)) {
    const parent = dirname(existing);
    if (parent === existing) break;
    tail.unshift(existing.slice(parent.length + 1));
    existing = parent;
  }
  return join(realpathSync(existing), ...tail);
}

/**
 * Debounced saves run one at a time. Only the newest pending snapshot is written; archive values
 * are immutable snapshots, so later edits never race the encoder.
 */
export class WorkspaceArchiveWriter {
  private readonly storage: WorkspaceStore;
  private pending: WorkspaceArchive | undefined;
  private pendingFailure: ((error: Error) => void) | undefined;
  private running: Promise<void> = Promise.resolve();
  private scheduled = false;

  constructor(storage: WorkspaceStore) {
    this.storage = storage;
  }

  /** Returns immediately; `failed` is called if this or a coalesced later write fails. */
  write(archive: WorkspaceArchive, failed: (error: Error) => void): void {
    this.pending = archive;
    this.pendingFailure = failed;
    if (this.scheduled) return;
    this.scheduled = true;
    this.running = this.running.then(async () => {
      this.scheduled = false;
      const next = this.pending, onFailure = this.pendingFailure;
      this.pending = undefined; this.pendingFailure = undefined;
      if (!next) return;
      try { await this.storage.save(next); } catch (error) { onFailure?.(error as Error); }
    });
  }

  /** Writes after any running save and supersedes a snapshot not yet started. */
  async writeNow(archive: WorkspaceArchive): Promise<void> {
    this.pending = undefined; this.pendingFailure = undefined;
    const result = this.running.then(() => this.storage.save(archive));
    this.running = result.catch(() => {});
    await result;
  }

  /** Resolves once queued writes have finished. */
  async flush(): Promise<void> {
    await this.running;
  }
}
