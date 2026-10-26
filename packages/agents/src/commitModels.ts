import { HARNESS_IDS, type HarnessID } from "@octo/core";
import { TITLE_CONFIGURATIONS } from "./titleConfigurations";
import type { AgentModel } from "./types";

/**
 * The model that drafts commit messages, chosen in the Changes tab. Reasoning effort is the adapter's
 * choice, so only the provider and model are stored.
 */
export interface CommitMessageModel {
  harness: HarnessID;
  model: string;
}

export function commitModelStorageValue(model: CommitMessageModel): string {
  return `${model.harness}:${model.model}`;
}

export function parseCommitModel(value: string): CommitMessageModel | undefined {
  const index = value.indexOf(":");
  if (index === -1) return undefined;
  const harness = value.slice(0, index), model = value.slice(index + 1);
  if (!(HARNESS_IDS as readonly string[]).includes(harness) || !model) return undefined;
  return { harness: harness as HarnessID, model };
}

/** Numeric parts of a model name, so `gpt-6.1-luna` sorts after `gpt-6-luna` and `gpt-5.6-luna`. */
export function modelVersion(model: string): number[] {
  const first = model.split(/[^0-9.]+/).find((part) => part !== "");
  return (first ?? "").split(".").filter(Boolean).map(Number).filter((n) => !Number.isNaN(n));
}

function versionLess(a: number[], b: number[]): boolean {
  for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] < b[i];
  return a.length < b.length;
}

/**
 * Automatic tries these in order: Claude's Haiku alias (the newest Haiku), then Codex's newest Luna. A
 * provider is skipped when its CLI is missing or its loaded catalog lacks the model.
 */
export function automaticCommitModels(installed: Set<HarnessID>, catalogs: Partial<Record<HarnessID, AgentModel[]>>): CommitMessageModel[] {
  const models: CommitMessageModel[] = [];
  if (installed.has("claude") && (catalogs.claude?.some((m) => m.model === "haiku") ?? true)) models.push({ harness: "claude", model: "haiku" });
  if (installed.has("codex")) {
    const catalog = catalogs.codex;
    if (catalog) {
      let luna: AgentModel | undefined;
      for (const model of catalog.filter((m) => m.model.endsWith("-luna"))) {
        if (!luna || versionLess(modelVersion(luna.model), modelVersion(model.model))) luna = model;
      }
      if (luna) models.push({ harness: "codex", model: luna.model });
    } else if (TITLE_CONFIGURATIONS.codex) {
      models.push({ harness: "codex", model: TITLE_CONFIGURATIONS.codex.model });
    }
  }
  return models;
}
