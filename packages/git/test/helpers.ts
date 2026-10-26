import { mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import { findExecutable, runProcess } from "@octo/core/node";

export function temporaryRoot(): string {
  const root = join(realpathSync(tmpdir()), "octo-git-" + randomUUID());
  mkdirSync(root, { recursive: true });
  return root;
}
export const removeRoot = (root: string) => rmSync(root, { recursive: true, force: true });

/** A repository with a fixture identity, no signing and no hooks from the user's configuration. */
export class Repository {
  constructor(readonly root: string) {}
  async run(args: string[], directory?: string): Promise<string> {
    const result = await runProcess(findExecutable("git")!, args, { directory: directory ?? this.root });
    if (result.status !== 0) throw new Error(`git ${args.join(" ")}: ${result.error.toString("utf8")}`);
    return result.output.toString("utf8");
  }
  write(path: string, text: string): void {
    const file = join(this.root, path);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, text);
  }
  read(path: string): string { return readFileSync(join(this.root, path), "utf8"); }
  async commitAll(message: string): Promise<void> { await this.run(["add", "--all"]); await this.run(["commit", "--quiet", "-m", message]); }

  static async make(roots: string[], bare = false): Promise<Repository> {
    const root = temporaryRoot(); roots.push(root);
    const repository = new Repository(root);
    await repository.run(bare ? ["init", "--quiet", "--bare", "-b", "main"] : ["init", "--quiet", "-b", "main"]);
    if (bare) return repository;
    for (const [key, value] of [["user.name", "Octo Test"], ["user.email", "octo@example.invalid"], ["commit.gpgsign", "false"], ["core.hooksPath", join(root, ".git/no-hooks")]]) {
      await repository.run(["config", key, value]);
    }
    return repository;
  }
}
