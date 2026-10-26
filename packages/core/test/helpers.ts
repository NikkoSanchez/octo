import { mkdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

export function temporaryRoot(prefix = "octo-test-"): string {
  const root = join(tmpdir(), prefix + randomUUID());
  mkdirSync(root, { recursive: true });
  return root;
}

export function removeRoot(root: string): void {
  rmSync(root, { recursive: true, force: true });
}

export function mode(path: string): number {
  return statSync(path).mode & 0o777;
}

export async function rejects(operation: () => Promise<unknown>): Promise<void> {
  let failed = false;
  try { await operation(); } catch { failed = true; }
  if (!failed) throw new Error("Unexpected filesystem mutation");
}
