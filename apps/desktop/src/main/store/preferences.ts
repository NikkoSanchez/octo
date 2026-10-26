import { readFileSync } from "node:fs";
import { promises as fs } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

/** App preferences. Saved atomically, owner-only. */
export interface Preferences {
  theme?: string;
  codexExecutablePath?: string;
  commitMessageModel?: string;
  openTarget?: string;
  sidebarWidth?: number;
  diffLayout?: string;
  usageRange?: string;
}

export class PreferencesFile {
  private readonly path: string;
  private values: Preferences;
  private writing: Promise<void> = Promise.resolve();

  constructor(directory: string) {
    this.path = join(directory, "preferences.json");
    try {
      const parsed = JSON.parse(readFileSync(this.path, "utf8"));
      this.values = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch {
      this.values = {};
    }
  }

  get<K extends keyof Preferences>(key: K): Preferences[K] {
    return this.values[key];
  }

  set<K extends keyof Preferences>(key: K, value: Preferences[K]): void {
    if (value === undefined) delete this.values[key]; else this.values[key] = value;
    const data = JSON.stringify(this.values, null, 2);
    this.writing = this.writing.then(async () => {
      const temporary = `${this.path}.${randomBytes(4).toString("hex")}`;
      try {
        await fs.writeFile(temporary, data, { mode: 0o600 });
        await fs.rename(temporary, this.path);
      } catch {
        await fs.unlink(temporary).catch(() => {});
      }
    });
  }

  flush(): Promise<void> {
    return this.writing;
  }
}
