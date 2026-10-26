import { describe, expect, it } from "vitest";
import {
  chatTurns, groupSummary, makeMessage, messageGroups, newID, toolActivityText, turnBody, turnLiveStatus, turnResponses, turnUser,
  type ChatMessage, type ToolActivityState,
} from "../src";

function tool(name: string, state: ToolActivityState = "completed"): ChatMessage {
  const activity = { id: newID(), server: "Claude", tool: name, state, detail: "" };
  return makeMessage("activity", toolActivityText(activity), { toolActivity: activity });
}

describe("ChatTurn", () => {
  it("keeps work between the replies it happened between", () => {
    const messages = [makeMessage("user", "Fix CI"), makeMessage("assistant", "Checking the logs."),
      tool("Bash"), tool("Bash"), makeMessage("reasoning", "It needs the CLI"),
      makeMessage("assistant", "Found it."), tool("Edit"), makeMessage("assistant", "Fixed.")];
    const turn = chatTurns(messages)[0];
    const body = turnBody(turn);
    expect(body.map((g) => g.isDetails)).toEqual([false, true, false, true, false]);
    expect(body.filter((g) => !g.isDetails).flatMap((g) => g.messages).map((m) => m.text)).toEqual(["Checking the logs.", "Found it.", "Fixed."]);
    expect(body[1].messages.length).toBe(3);
    expect(turnResponses(turn).map((m) => m.text)).toEqual(["Checking the logs.", "Found it.", "Fixed."]);
    const imported = chatTurns([makeMessage("assistant", "Earlier"), tool("Read")])[0];
    expect(turnUser(imported)).toBeUndefined();
    expect(turnBody(imported).length).toBe(2);
  });

  it("summarizes tools in order and mentions thinking", () => {
    const summary = (messages: ChatMessage[]) => groupSummary(messageGroups(messages)[0].messages);
    expect(summary([tool("Bash"), tool("Bash"), tool("Bash")])).toBe("Ran 3 commands");
    expect(summary([makeMessage("reasoning", "Hm"), tool("Read"), tool("Bash"), tool("Read")])).toBe("Thought, read 2 files and ran 1 command");
    expect(summary([tool("Grep"), tool("Glob"), tool("Edit"), tool("mcp__linear__search")])).toBe("Searched 2 times, edited 1 file and used 1 tool");
    expect(summary([makeMessage("activity", "git status"), makeMessage("activity", "swift test")])).toBe("2 steps");
    expect(summary([makeMessage("activity", "")])).toBe("Activity");
    expect(summary([makeMessage("reasoning", "Hm")])).toBe("Thought");
  });

  it("names the current work in the live status", () => {
    const status = (tail: ChatMessage[]) => turnLiveStatus(chatTurns([makeMessage("user", "Go"), ...tail])[0]);
    expect(status([])).toBe("Thinking");
    expect(status([makeMessage("reasoning", "…")])).toBe("Thinking");
    expect(status([tool("Bash", "running")])).toBe("Running a command");
    expect(status([tool("Read", "running")])).toBe("Reading a file");
    expect(status([tool("mcp__browser__click", "running")])).toBe("Using mcp__browser__click");
    expect(status([tool("Bash")])).toBe("Thinking");
    expect(status([makeMessage("activity", "swift test --filter Chat\nmore")])).toBe("swift test --filter Chat");
    expect(status([makeMessage("assistant", "Streaming")])).toBeUndefined();
    expect(status([makeMessage("assistant", "A"), makeMessage("user", "Also this", { isSteering: true })])).toBe("Thinking");
  });
});
