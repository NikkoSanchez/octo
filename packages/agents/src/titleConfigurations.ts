import type { HarnessID } from "@octo/core";

/** Adapter-owned auxiliary model; undefined means keep the first-message title. */
export interface ThreadTitleConfiguration {
  model: string;
  reasoningEffort?: string;
}

export const TITLE_CONFIGURATIONS: Record<HarnessID, ThreadTitleConfiguration | undefined> = {
  codex: { model: "gpt-6-luna", reasoningEffort: "low" },
  // The CLI's Haiku alias, through the user's existing Claude Code sign-in.
  claude: { model: "haiku" },
};
