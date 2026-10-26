import { existsSync, mkdtempSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** Marks a data folder as this app's. */
export const OWNER_MARKER = ".octo";
/** The marker earlier builds wrote. Still accepted; `OWNER_MARKER` is added beside it. */
const EARLIER_MARKER = ".octo-electron";

/** The data folder exists without a marker, so it belongs to another app. */
export class UnownedDataFolderError extends Error {
  constructor(readonly folder: string) {
    super(`${folder} belongs to another app.`);
  }
}

/**
 * The data folder to use. A fresh Mac gets a marked folder, created atomically. An existing folder
 * without the marker is never written into; this throws `UnownedDataFolderError` instead.
 */
export function resolveDataDirectory(appData: string, folder: string): string {
  const target = join(appData, folder);
  if (existsSync(join(target, OWNER_MARKER))) return target;
  if (existsSync(join(target, EARLIER_MARKER))) {
    writeFileSync(join(target, OWNER_MARKER), "");
    return target;
  }
  if (existsSync(target)) throw new UnownedDataFolderError(target);
  const staging = mkdtempSync(join(appData, ".octo-data-"));
  writeFileSync(join(staging, OWNER_MARKER), "");
  renameSync(staging, target);
  return target;
}
