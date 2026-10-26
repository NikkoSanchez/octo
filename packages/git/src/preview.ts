import { constants, promises as fs } from "node:fs";
import { join, resolve } from "node:path";
import { ProcessFailure } from "@octo/core/node";

const LIMIT = 2_000_000;
const decoder = new TextDecoder("utf-8", { fatal: true });

/**
 * Reads a checkout file for preview. Every parent component must be a real directory (no symlinks)
 * and the file opens with `O_NOFOLLOW`; Node has no descriptor-relative open, so parents are checked
 * with `lstat` and a matching real path instead.
 */
export async function readPreview(path: string, root: string): Promise<{ text?: string; notice?: string }> {
  const parts = path.split("/");
  if (path.startsWith("/") || parts.length === 0 || !parts.every((p) => p !== "" && p !== "." && p !== "..")) {
    throw new ProcessFailure("exited", "File path is outside this checkout.");
  }
  let directory = await fs.realpath(resolve(root));
  for (const part of parts.slice(0, -1)) {
    directory = join(directory, part);
    const info = await fs.lstat(directory).catch(() => undefined);
    if (!info || info.isSymbolicLink() || !info.isDirectory()) throw new ProcessFailure("exited", "Cannot preview a missing directory or symbolic-link path.");
  }
  if ((await fs.realpath(directory).catch(() => "")) !== directory) throw new ProcessFailure("exited", "Cannot preview a missing directory or symbolic-link path.");
  let handle: fs.FileHandle;
  try {
    handle = await fs.open(join(directory, parts[parts.length - 1]), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch {
    throw new ProcessFailure("exited", "Cannot preview a missing file or symbolic link.");
  }
  try {
    const info = await handle.stat();
    if (!info.isFile()) return { notice: "This entry is not a regular file." };
    if (info.size > LIMIT) return { notice: "This file exceeds the 2 MB preview limit. Open it in Neovim." };
    const buffer = Buffer.alloc(Math.min(LIMIT + 1, info.size + 1));
    let total = 0;
    for (;;) {
      const { bytesRead } = await handle.read(buffer, total, buffer.length - total, total);
      if (bytesRead === 0) break;
      total += bytesRead;
      if (total > LIMIT) return { notice: "This file exceeds the 2 MB preview limit. Open it in Neovim." };
      if (total === buffer.length) break;
    }
    const data = buffer.subarray(0, total);
    if (data.includes(0)) return { notice: "Binary or non-UTF-8 file." };
    try { return { text: decoder.decode(data) }; } catch { return { notice: "Binary or non-UTF-8 file." }; }
  } finally {
    await handle.close();
  }
}
