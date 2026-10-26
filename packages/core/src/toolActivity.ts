export type ToolActivityState = "running" | "completed" | "failed" | "interrupted";

export interface ToolActivity {
  id: string;
  server: string;
  tool: string;
  state: ToolActivityState;
  detail: string;
}

export function toolActivityText(activity: ToolActivity): string {
  const state = activity.state.charAt(0).toUpperCase() + activity.state.slice(1);
  return `${activity.server} / ${activity.tool} · ${state}` + (activity.detail ? `\n${activity.detail}` : "");
}
