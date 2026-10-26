import { useEffect, useState } from "react";
import { RotateCw } from "lucide-react";
import { harnessTitle, type HarnessID, type WorkspaceThread } from "@octo/core";
import { remainingPercent, windowTitle, type AgentUsageWindow } from "@octo/agents/model";
import type { AppState } from "../../../../shared/state";
import { selectedThread, useApp } from "../../state/app";
import { useUI } from "../../state/ui";
import { run } from "../../bridge";
import { CapsulePicker, HoverButton, Spinner } from "../controls";
import { ProviderIcon } from "../ProviderIcon";
import styles from "./overlays.module.css";

/** The thread whose checkout read-only limit queries run in: the selected one, else the newest using the provider. */
export function usageThread(state: AppState, provider: HarnessID): WorkspaceThread | undefined {
  const selected = selectedThread(state);
  if (selected?.harness === provider) return selected;
  let newest: WorkspaceThread | undefined;
  for (const project of state.archive.projects) for (const thread of project.threads) {
    if (thread.harness === provider && (!newest || thread.createdAt > newest.createdAt)) newest = thread;
  }
  return newest;
}

/** Claude limits belong to the signed-in account; Codex limits are read in a checkout. */
export const usageKey = (thread: Pick<WorkspaceThread, "harness" | "workingDirectory">) =>
  thread.harness === "claude" ? thread.harness : `${thread.harness}:${thread.workingDirectory}`;

/** Account limits for one provider at a time. It follows the selected thread's provider but can show any. */
export function AccountUsage({ dismiss }: { dismiss: () => void }) {
  const initial = useApp((s) => selectedThread(s)?.harness ?? s.archive.lastHarness ?? "codex");
  const [provider, setProvider] = useState<HarnessID>(initial);
  const data = useApp((s) => {
    const thread = usageThread(s, provider), key = thread && usageKey(thread);
    return {
      descriptors: s.descriptors, hasThread: !!thread, key,
      usage: key ? s.usageSnapshots[key] : undefined, error: key ? s.usageErrors[key] : undefined, loading: !!key && s.loadingUsage.includes(key),
    };
  });
  const descriptor = data.descriptors.find((d) => d.id === provider);
  const supported = !!descriptor?.supportsUsageLimits, refreshable = !!descriptor?.supportsUsageRefresh;
  useEffect(() => { if (supported && refreshable && data.hasThread) run("store", "loadUsage", provider); }, [provider, data.key, supported, refreshable, data.hasThread]);

  return (
    <div className={styles.accountUsage}>
      <CapsulePicker label="Provider" value={provider} options={data.descriptors.map((d) => ({ value: d.id, title: harnessTitle(d.id) }))} onChange={setProvider} />
      <h3><ProviderIcon harness={provider} size={16} />{harnessTitle(provider)} account usage</h3>
      <small>Shared across your account, including other chats and apps.</small>
      {!supported ? <p>Account limits and reset times are not exposed by this adapter.</p>
        : data.usage ? <>
            <div className={styles.buckets}>
              {data.usage.buckets.map((bucket) => (
                <div key={bucket.id} className={styles.bucket}>
                  <strong>{bucket.title}</strong>
                  {!bucket.windows.length && <small>No usage windows reported.</small>}
                  {bucket.windows.map((window) => <UsageWindowRow key={window.id} window={window} />)}
                </div>
              ))}
            </div>
            <small>{refreshable ? "Last updated" : "Last reported"} {new Date(data.usage.fetchedAt).toLocaleTimeString()}</small>
          </>
        : !data.hasThread ? <p>Start a {harnessTitle(provider)} chat to see your session and weekly limits.</p>
        : !refreshable ? <>
            <p>{harnessTitle(provider)} reports limits alongside responses. Send a message in any {harnessTitle(provider)} chat to see your session and weekly limits.</p>
            <small>API-key, Bedrock and Vertex sign-ins do not report subscription limits.</small>
          </>
        : null}
      {supported && data.error && <small>{data.error}</small>}
      <div className={styles.usageFooter}>
        {supported && refreshable && data.hasThread && <>
          <HoverButton aria-label="Refresh usage" help="Refresh usage" disabled={data.loading} onClick={() => run("store", "loadUsage", provider)}><RotateCw size={13} /></HoverButton>
          {data.loading && <Spinner />}
        </>}
        <span className={styles.spacer} />
        <HoverButton help="Token usage across Codex and Claude sessions" onClick={() => { dismiss(); useUI.setState({ usageDashboard: true }); }}>Usage Dashboard</HoverButton>
      </div>
    </div>
  );
}

/** A last-known limit window. A passed reset means the reported percentage describes an earlier window. */
export function UsageWindowRow({ window }: { window: AgentUsageWindow }) {
  const expired = window.resetsAt !== undefined && window.resetsAt <= Date.now();
  const remaining = remainingPercent(window);
  return (
    <div className={styles.window}>
      <div className={styles.windowTitle}>
        <span>{windowTitle(window)}</span>
        {expired ? <span>Reset</span> : window.isLimited ? <span className={styles.limited}>Limit reached</span>
          : remaining !== undefined ? <span>{Math.round(remaining)}% remaining</span> : <span>Usage unavailable</span>}
      </div>
      {!expired && remaining !== undefined && <progress max={100} value={remaining} className={window.isLimited ? styles.limitedBar : undefined} aria-label={`${windowTitle(window)} remaining`} />}
      <small>{expired ? "A new window has started. Usage updates after the next report."
        : window.resetsAt ? `Resets ${new Date(window.resetsAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}` : "Reset time unavailable"}</small>
    </div>
  );
}
