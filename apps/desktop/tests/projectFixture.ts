import { expect } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { launchApp } from "./fixtures";
export async function launchProject() {
  let root = "";
  const fixture = await launchApp({ SHELL: "/bin/sh" }, (directory) => {
    root = join(directory, "repository"); mkdirSync(root);
    const git = (...args: string[]) => execFileSync("git", args, { cwd: root });
    git("init", "-q", "-b", "main"); git("config", "user.name", "Fixture"); git("config", "user.email", "fixture@example.com"); git("config", "commit.gpgsign", "false");
    writeFileSync(join(root, "example.ts"), "const greeting = 'old';\n"); git("add", "example.ts"); git("commit", "-qm", "Initial fixture");
    writeFileSync(join(root, "example.ts"), "const greeting = 'hello 🐙';\n");
    writeFileSync(join(directory, "preferences.json"), JSON.stringify({ codexExecutablePath: join(import.meta.dirname, "fixtures/codex-ui.py"), theme: "mocha", commitMessageModel: "codex:fixture-model" }), { mode: 0o600 });
  });
  await fixture.page.getByRole("textbox", { name: "Message", exact: true }).waitFor();
  await fixture.page.evaluate((root) => window.octo.call("store", "addProject", root), root);
  await expect(fixture.page.getByTestId("workspace-titlebar")).toContainText("repository");
  return { ...fixture, root };
}
