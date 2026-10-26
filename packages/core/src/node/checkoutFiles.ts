import { randomUUID } from "node:crypto";
import { constants, promises as fs, type BigIntStats } from "node:fs";
import { join, resolve } from "node:path";

export type CheckoutFileErrorKind = "unsafePath" | "unsupportedFile" | "tooLarge" | "notText" | "alreadyExists" | "changed" | "readOnly";

export class CheckoutFileError extends Error {
  readonly kind: CheckoutFileErrorKind;
  constructor(kind: CheckoutFileErrorKind) {
    super(CheckoutFileError.describe(kind));
    this.kind = kind;
    this.name = "CheckoutFileError";
  }
  static describe(kind: CheckoutFileErrorKind): string {
    switch (kind) {
      case "unsafePath": return "Choose a relative file path inside this checkout, outside Git metadata. Symbolic links are not supported.";
      case "unsupportedFile": return "Only regular files with a single hard link are supported.";
      case "tooLarge": return "The native editor supports files up to 2 MB. Open this file in Neovim.";
      case "notText": return "The native editor supports UTF-8 text files. Open this file in another editor.";
      case "alreadyExists": return "A file or folder already exists at this path.";
      case "changed": return "This file changed on disk. Your edits are still here. Copy any changes you need, then reload the file before saving.";
      case "readOnly": return "This file is read-only.";
    }
  }
}

interface FileIdentity {
  device: bigint; inode: bigint; size: bigint; modified: bigint; changed: bigint;
}

function identityOf(info: BigIntStats): FileIdentity {
  return { device: info.dev, inode: info.ino, size: info.size, modified: info.mtimeNs, changed: info.ctimeNs };
}

function sameIdentity(a: FileIdentity, b: FileIdentity): boolean {
  return a.device === b.device && a.inode === b.inode && a.size === b.size && a.modified === b.modified && a.changed === b.changed;
}

/** Captures the checkout and disk identity when an editor or deletion dialog opens. */
export interface CheckoutFile {
  readonly root: string;
  readonly path: string;
  readonly text?: string;
  readonly data?: Buffer;
  readonly identity: FileIdentity;
}

export const EDITOR_BYTE_LIMIT = 2_000_000;
const decoder = new TextDecoder("utf-8", { fatal: true });

/**
 * Finite file create, save and delete inside a checkout. No shell commands or Git mutations.
 *
 * Node has no `openat`, so instead of descriptor-relative opens every parent component is checked
 * with `lstat` (no symlinks), the parent's real path must equal the checkout's real path plus those
 * components, and files open with `O_NOFOLLOW`. Identity checks immediately before replacement
 * catch outside writes; a narrow race between the parent check and the open remains.
 */
export class CheckoutFileService {
  async inspect(path: string, root: string, forEditing: boolean): Promise<CheckoutFile> {
    const target = await this.resolveTarget(path, root);
    const handle = await openFile(target);
    try {
      const info = await fileInfo(handle);
      const data = forEditing ? await readText(handle, info) : undefined;
      if (!sameIdentity(identityOf(await fileInfo(handle)), identityOf(info))) throw new CheckoutFileError("changed");
      return { root, path, text: data ? data.toString("utf8") : undefined, data, identity: identityOf(info) };
    } finally {
      await handle.close();
    }
  }

  async create(path: string, root: string): Promise<void> {
    const target = await this.resolveTarget(path, root);
    let handle: fs.FileHandle;
    try {
      handle = await fs.open(target, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o644);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new CheckoutFileError("alreadyExists");
      throw error;
    }
    await handle.close();
  }

  async save(file: CheckoutFile, text: string): Promise<CheckoutFile> {
    const data = Buffer.from(text, "utf8");
    if (data.length > EDITOR_BYTE_LIMIT) throw new CheckoutFileError("tooLarge");
    if (data.includes(0) || !file.data) throw new CheckoutFileError("notText");
    const target = await this.resolveTarget(file.path, file.root);
    const original = await this.validate(file, target);
    if ((original.mode & 0o222n) === 0n) throw new CheckoutFileError("readOnly");
    const temporary = join(target, "..", `.octo-save-${randomUUID().toUpperCase()}`);
    const handle = await fs.open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    let renamed = false;
    try {
      await handle.writeFile(data);
      await handle.chmod(Number(original.mode & 0o777n));
      await handle.sync();
      // Recheck immediately before replacement; an agent or terminal may have written during the save.
      await this.validate(file, await this.resolveTarget(file.path, file.root));
      await fs.rename(temporary, target);
      renamed = true;
      // Keep the baseline tied to the bytes we wrote, never to a later reader's contents.
      return { root: file.root, path: file.path, text, data, identity: identityOf(await handle.stat({ bigint: true })) };
    } finally {
      await handle.close();
      if (!renamed) await fs.unlink(temporary).catch(() => {});
    }
  }

  async delete(file: CheckoutFile): Promise<void> {
    const target = await this.resolveTarget(file.path, file.root);
    await this.validate(file, target);
    await fs.unlink(target);
  }

  private async validate(file: CheckoutFile, target: string): Promise<BigIntStats> {
    const handle = await openFile(target);
    try {
      const info = await fileInfo(handle);
      if (!sameIdentity(identityOf(info), file.identity)) throw new CheckoutFileError("changed");
      if (file.data) {
        const current = await readText(handle, info);
        if (!current.equals(file.data) || !sameIdentity(identityOf(await fileInfo(handle)), file.identity)) throw new CheckoutFileError("changed");
      }
      const entry = await fs.lstat(target, { bigint: true }).catch(() => { throw new CheckoutFileError("changed"); });
      if (!sameIdentity(identityOf(entry), file.identity)) throw new CheckoutFileError("changed");
      return info;
    } finally {
      await handle.close();
    }
  }

  /** Validates a checkout-relative path and returns its absolute location with no symlinked parents. */
  private async resolveTarget(path: string, root: string): Promise<string> {
    const parts = path.split("/");
    if (path.startsWith("/") || path.includes("\0") || parts.length === 0 ||
        !parts.every((part) => part !== "" && part !== "." && part !== ".." && part.toLowerCase() !== ".git")) {
      throw new CheckoutFileError("unsafePath");
    }
    let rootReal: string;
    try { rootReal = await fs.realpath(resolve(root)); } catch { throw new CheckoutFileError("unsafePath"); }
    let directory = rootReal;
    for (const part of parts.slice(0, -1)) {
      directory = join(directory, part);
      const info = await fs.lstat(directory).catch(() => undefined);
      if (!info || info.isSymbolicLink() || !info.isDirectory()) throw new CheckoutFileError("unsafePath");
    }
    const real = await fs.realpath(directory).catch(() => undefined);
    if (real !== directory) throw new CheckoutFileError("unsafePath");
    return join(directory, parts[parts.length - 1]);
  }
}

async function openFile(target: string): Promise<fs.FileHandle> {
  try {
    return await fs.open(target, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ELOOP") throw new CheckoutFileError("unsafePath");
    throw error;
  }
}

async function fileInfo(handle: fs.FileHandle): Promise<BigIntStats> {
  const info = await handle.stat({ bigint: true });
  if (!info.isFile() || info.nlink !== 1n) throw new CheckoutFileError("unsupportedFile");
  return info;
}

async function readText(handle: fs.FileHandle, info: BigIntStats): Promise<Buffer> {
  if (info.size > BigInt(EDITOR_BYTE_LIMIT)) throw new CheckoutFileError("tooLarge");
  const chunks: Buffer[] = [];
  let total = 0, position = 0;
  const buffer = Buffer.alloc(16_384);
  for (;;) {
    const { bytesRead } = await handle.read(buffer, 0, Math.min(buffer.length, EDITOR_BYTE_LIMIT + 1 - total), position);
    if (bytesRead === 0) break;
    chunks.push(Buffer.from(buffer.subarray(0, bytesRead)));
    total += bytesRead; position += bytesRead;
    if (total > EDITOR_BYTE_LIMIT) throw new CheckoutFileError("tooLarge");
  }
  const data = Buffer.concat(chunks);
  if (data.includes(0)) throw new CheckoutFileError("notText");
  try { decoder.decode(data); } catch { throw new CheckoutFileError("notText"); }
  return data;
}
