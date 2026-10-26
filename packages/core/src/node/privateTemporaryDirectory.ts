import { mkdtempSync, rmSync } from "node:fs";

/**
 * A short, owner-only namespace for local IPC; UUID-only names in shared /tmp are insufficient.
 * Call `dispose()` when done; JavaScript has no deinit.
 */
export class PrivateTemporaryDirectory {
  readonly path: string;
  constructor() {
    // mkdtemp creates the directory with mode 0700.
    this.path = mkdtempSync("/tmp/octo-");
  }
  dispose(): void {
    rmSync(this.path, { recursive: true, force: true });
  }
}
