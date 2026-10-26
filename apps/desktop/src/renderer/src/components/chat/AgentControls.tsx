import { ChevronDown, Hand, ShieldAlert } from "lucide-react";
import { harnessTitle, type AgentPermissionMode, type HarnessID } from "@octo/core";
import { reasoningTitle } from "@octo/agents/model";
import { useApp } from "../../state/app";
import { useUI } from "../../state/ui";
import { popup, type MenuSpec } from "../../lib/menu";
import { call, run } from "../../bridge";
import { cx } from "../controls";
import { ProviderIcon, providerMenuIcon } from "../ProviderIcon";
import styles from "./chat.module.css";

/**
 * The provider, model and reasoning menu, then permissions for the next turn. Providers are listed
 * first; each holds its models, and the current one also its reasoning. Both lock while a turn runs.
 */
export function AgentControls({ threadID }: { threadID: string }) {
  const data = useApp((s) => {
    const thread = s.archive.projects.flatMap((p) => p.threads).find((t) => t.id === threadID);
    return {
      harness: thread?.harness ?? "codex", directory: thread?.workingDirectory ?? "", settings: thread?.agentSettings,
      hasHistory: !!thread && (thread.messages.length > 0 || thread.remoteSessionID !== undefined),
      running: s.running.includes(threadID), descriptors: s.descriptors, catalogs: s.modelCatalogs, loading: s.loadingModels, errors: s.modelErrors,
      dark: s.systemDark,
    };
  });
  const key = (id: HarnessID) => `${id}:${data.directory}`;
  const descriptor = data.descriptors.find((d) => d.id === data.harness);
  const selected = data.catalogs[key(data.harness)]?.find((m) => m.model === data.settings?.model);
  const effort = data.settings?.reasoningEffort;
  const summary = [harnessTitle(data.harness), selected?.displayName ?? data.settings?.model, effort && (effort === "xhigh" ? "Extra high" : effort.charAt(0).toUpperCase() + effort.slice(1))]
    .filter(Boolean).join(" · ");

  const agentMenu = (anchor: Element) => {
    const dark = document.documentElement.dataset.dark === "true";
    const items: MenuSpec[] = data.descriptors.map((provider) => {
      const current = provider.id === data.harness, installed = !!provider.executable;
      const models = (data.catalogs[key(provider.id)] ?? []).filter((m) => !m.hidden);
      const loading = data.loading.includes(key(provider.id));
      const entries: MenuSpec[] = [];
      if (!current && data.hasHistory) entries.push({ type: "header", label: `Starts a new ${harnessTitle(provider.id)} thread` });
      if (!provider.supportsModels) {
        entries.push({ label: current ? `Using ${harnessTitle(provider.id)} defaults` : `Use ${harnessTitle(provider.id)}`, enabled: !current && installed,
          action: () => run("store", "selectAgent", provider.id, undefined) });
      } else {
        if (current && !data.settings?.model) entries.push({ type: "header", label: "Using session default" });
        if (!models.length) entries.push({ type: "header", label: loading ? "Loading models…" : installed ? data.errors[key(provider.id)] ?? "No models reported" : "Not installed" });
        for (const model of models) {
          entries.push({ label: model.displayName, checked: current && data.settings?.model === model.model, toolTip: model.description, enabled: installed,
            action: () => run("store", "selectAgent", provider.id, model.model) });
        }
        if (current) {
          const efforts = selected?.supportedReasoningEfforts ?? [];
          entries.push({ type: "separator" }, { type: "submenu", label: "Reasoning", enabled: efforts.length > 0, items: efforts.length
            ? efforts.map((option) => ({ label: reasoningTitle(option.reasoningEffort), checked: effort === option.reasoningEffort, toolTip: option.description,
                action: () => run("store", "selectReasoning", option.reasoningEffort) }))
            : [{ type: "header", label: "Choose a model first" }] });
        }
        if (installed) {
          entries.push({ type: "separator" }, { label: loading ? "Loading models…" : "Refresh models", enabled: !loading,
            action: () => run("store", "loadModels", data.directory, provider.id, true) });
        }
      }
      return { type: "submenu", label: harnessTitle(provider.id) + (installed ? "" : " · not installed"), icon: providerMenuIcon(provider.id, dark), items: entries };
    });
    void popup(items, anchor);
  };

  const permission = data.settings?.permissionMode ?? descriptor?.defaultPermissionMode;
  const options = descriptor?.permissionOptions ?? [];
  const permissionTitle = options.find((o) => o.mode === permission)?.title ?? "CLI permissions";
  const choosePermission = async (mode: AgentPermissionMode) => {
    if (mode === "fullAccess") {
      const choice = await call("app", "confirm", {
        message: "Enable full access?",
        detail: "This thread's next turns can access files outside the project and the network without approval prompts. This choice is also remembered for new threads until you change permissions. The CLI's managed policies still apply.",
        buttons: ["Cancel", "Enable full access"], destructive: 1,
      });
      if (choice !== 1) return;
    }
    run("store", "selectPermissions", mode, threadID);
  };
  const permissionsMenu = (anchor: Element) => void popup(options.length
    ? [{ type: "header", label: "Permissions for the next turn" }, ...options.map((o): MenuSpec => ({
        label: o.title, checked: o.mode === permission, toolTip: o.detail,
        action: () => void choosePermission(o.mode).catch((error) => useUI.getState().showError(String(error))),
      }))]
    : [{ type: "header", label: "Uses CLI defaults. Permission controls are unavailable in this adapter." }], anchor);

  const fullAccess = permission === "fullAccess";
  return (
    <div className={styles.agentControls}>
      <button type="button" className={styles.menuButton} aria-label="Agent settings" title="Provider, model, and reasoning" disabled={data.running} onClick={(e) => agentMenu(e.currentTarget)}>
        <ProviderIcon harness={data.harness} size={14} />
        <span className={styles.agentSummary}>{summary}</span>
        <ChevronDown size={9} strokeWidth={3} className={styles.menuChevron} />
      </button>
      <button type="button" className={cx(styles.menuButton, styles.permissions, fullAccess && styles.fullAccess)} aria-label={`Permissions: ${permissionTitle}`}
        title={permissionTitle} disabled={data.running} onClick={(e) => permissionsMenu(e.currentTarget)}>
        {fullAccess ? <ShieldAlert size={13} /> : <Hand size={13} />}
        <span className={styles.permissionTitle}>{permissionTitle}</span>
        <ChevronDown size={9} strokeWidth={3} className={styles.menuChevron} />
      </button>
    </div>
  );
}
