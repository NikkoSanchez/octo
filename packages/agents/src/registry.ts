import type { HarnessID } from "@octo/core";
import { findExecutable, ProcessFailure } from "@octo/core/node";
import { ClaudeHarness } from "./claudeHarness";
import { CodexExecutable } from "./codexExecutable";
import { CodexHarness } from "./codexHarness";
import { CLAUDE_CAPABILITIES, CODEX_CAPABILITIES, type AgentCommand, type AgentHarness, type AgentModel, type AgentUsage, type HarnessDescriptor } from "./types";

/** The compiled-in provider registry. The UI reads descriptors and capabilities; it never switches on provider. */
export const HarnessRegistry = {
  descriptors(codexExecutable?: string): HarnessDescriptor[] {
    return [
      {
        id: "codex", executable: codexExecutable ?? CodexExecutable.resolve(), supportsApprovals: true,
        detail: "App-server · tool activity, bounded forms and app-access decisions; experimental questions require CLI 0.158+. Inventory and URL/device verification are unavailable.",
        permissionOptions: CodexHarness.permissionOptions, defaultPermissionMode: "ask", supportsModels: true, supportsImages: true,
        supportsUsageLimits: true, supportsUsageRefresh: true, supportsConversationUsage: true, supportsCompactionStatus: true,
        capabilities: CODEX_CAPABILITIES,
      },
      {
        id: "claude", executable: findExecutable("claude"), supportsApprovals: true,
        detail: "CLI SDK stream · models, effort, images, tool activity, approvals and single-choice questions. Sign in with claude auth login. Account limits and context usage update after responses; active steering is unavailable.",
        permissionOptions: ClaudeHarness.permissionOptions, defaultPermissionMode: "autoReview", supportsModels: true, supportsImages: true,
        supportsUsageLimits: true, supportsUsageRefresh: false, supportsConversationUsage: true, supportsCompactionStatus: true,
        capabilities: CLAUDE_CAPABILITIES,
      },
    ];
  },

  make(id: HarnessID, codexExecutable?: string): AgentHarness {
    return id === "codex" ? new CodexHarness(codexExecutable) : new ClaudeHarness();
  },

  models(id: HarnessID, directory: string, codexExecutable?: string): Promise<AgentModel[]> {
    return id === "codex" ? CodexHarness.models(directory, codexExecutable) : ClaudeHarness.models(directory);
  },

  commands(id: HarnessID, directory: string, codexExecutable?: string): Promise<AgentCommand[]> {
    return id === "codex" ? CodexHarness.commands(directory, codexExecutable) : ClaudeHarness.commands(directory);
  },

  usage(id: HarnessID, directory: string, codexExecutable?: string): Promise<AgentUsage> {
    if (id === "codex") return CodexHarness.usage(directory, codexExecutable);
    return Promise.reject(new ProcessFailure("exited", "Claude reports account limits only alongside responses; there is no read-only query."));
  },
};
