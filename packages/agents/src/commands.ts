import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { ProcessFailure, runProcess } from "@octo/core/node";
import type { JSONObject } from "./jsonLine";
import { AgentToolDetails } from "./toolDetails";
import type { AgentCommand } from "./types";
import { commandMentions, type ClaudeAuthStatus } from "./commandText";
export * from "./commandText";

const COMMAND_NAME = /^[A-Za-z0-9][A-Za-z0-9._:\-]*$/;
const isObject = (value: unknown): value is JSONObject => typeof value === "object" && value !== null && !Array.isArray(value);
const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

function canonical(path: string): string {
  const standardized = resolve(path);
  try { return realpathSync(standardized); } catch { return standardized; }
}

/** Codex `skills/list` for one checkout: enabled skills with absolute paths, as the composer offers them. */
export function decodeCodexCommands(response: JSONObject, directory: string): AgentCommand[] {
  const entries = Array.isArray(response.data) ? response.data : undefined;
  const entry = entries?.find((e) => isObject(e) && typeof e.cwd === "string" && canonical(e.cwd) === canonical(directory)) as JSONObject | undefined;
  if (!entry || !Array.isArray(entry.skills)) throw new ProcessFailure("exited", "Codex did not report a skill catalog for this checkout.");
  const seen = new Set<string>();
  const commands: AgentCommand[] = [];
  for (const skill of entry.skills.slice(0, 2000)) {
    if (!isObject(skill) || skill.enabled !== true || typeof skill.name !== "string" || skill.name.length > 200 ||
        !COMMAND_NAME.test(skill.name) || typeof skill.path !== "string" || !skill.path.startsWith("/") || skill.path.includes("\n") ||
        seen.has(skill.name)) continue;
    seen.add(skill.name);
    const iface = isObject(skill.interface) ? skill.interface : undefined;
    const description = [iface?.shortDescription, skill.shortDescription, skill.description].find((v) => typeof v === "string") as string | undefined;
    commands.push({ name: skill.name, description: AgentToolDetails.text(description ?? "", 1024), argumentHint: "", skillPath: skill.path });
  }
  return commands.sort((a, b) => collator.compare(a.name, b.name));
}


/**
 * Each explicit "/skill" the user typed becomes native provider skill input ("$skill" in the text,
 * as Codex writes mentions). Arguments and attached context stay intact; skill contents are never
 * copied. Unknown names stay as typed.
 */
export function codexCommandInput(prompt: string, commands: AgentCommand[]): JSONObject[] {
  let text = prompt;
  const skills: JSONObject[] = [];
  const seen = new Set<string>();
  for (const mention of commandMentions(prompt)) {
    const path = commands.find((c) => c.name === mention.name)?.skillPath;
    if (!path) continue;
    text = text.slice(0, mention.index) + "$" + text.slice(mention.index + 1);
    if (!seen.has(mention.name)) { seen.add(mention.name); skills.push({ type: "skill", name: mention.name, path }); }
  }
  if (skills.length === 0) return prompt ? [{ type: "text", text: prompt }] : [];
  return [{ type: "text", text }, ...skills];
}

/** Claude `initialize` command catalog. Interactive commands such as /login are unavailable in chat. */
export function decodeClaudeCommands(response: JSONObject): AgentCommand[] {
  if (!Array.isArray(response.commands)) {
    throw new ProcessFailure("exited", "This Claude CLI does not report a command catalog. You can still type a known /command explicitly.");
  }
  const seen = new Set<string>();
  const commands: AgentCommand[] = [];
  for (const value of response.commands.slice(0, 2000)) {
    if (!isObject(value) || typeof value.name !== "string" || value.name.length > 200 || !COMMAND_NAME.test(value.name) || seen.has(value.name)) continue;
    seen.add(value.name);
    commands.push({
      name: value.name,
      description: AgentToolDetails.text(typeof value.description === "string" ? value.description : "", 1024),
      argumentHint: AgentToolDetails.text(typeof value.argumentHint === "string" ? value.argumentHint : "", 200),
    });
  }
  return commands.sort((a, b) => collator.compare(a.name, b.name));
}

export const ClaudeCLI = {
  loginArguments: ["auth", "login"],

  async authStatus(executable: string): Promise<ClaudeAuthStatus> {
    const result = await runProcess(executable, ["auth", "status", "--json"], { directory: homedir(), outputLimit: 64_000 });
    // Signed-out status exits 1, with a valid JSON report.
    if (result.status !== 0 && result.status !== 1) throw new ProcessFailure("exited", "Claude authentication status is unavailable. Check the installed CLI.");
    return ClaudeCLI.decodeAuthStatus(result.output.toString("utf8"));
  },

  decodeAuthStatus(text: string): ClaudeAuthStatus {
    let report: unknown;
    try { report = JSON.parse(text); } catch { report = undefined; }
    if (!isObject(report) || typeof report.loggedIn !== "boolean" || typeof report.authMethod !== "string") {
      throw new ProcessFailure("exited", "Claude did not return a supported authentication status. Run claude auth status in your terminal.");
    }
    return { loggedIn: report.loggedIn, method: AgentToolDetails.text(report.authMethod, 80) };
  },
};
