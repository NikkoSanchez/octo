import { useEffect, useState } from "react";
import { appState, useApp } from "../../state/app";
import { useUI, type FileAction, type SidebarEdit } from "../../state/ui";
import { useTerminal } from "../../state/terminal";
import { forgetFile } from "../../state/files";
import { refreshCheckout } from "../../state/git";
import { showPanel } from "../../lib/workspace";
import { call, run } from "../../bridge";
import { BorderedButton, PrimaryButton, Spinner } from "../controls";
import { Palette } from "./Palette";
import { Settings } from "./Settings";
import { Sheet } from "./Sheet";
import { UsageDashboard } from "./UsageDashboard";
import styles from "./overlays.module.css";

/** Everything that covers the workspace: palette, settings, usage, edits and alerts. */
export function Overlays() {
  const palette = useUI((s) => s.palette), settings = useUI((s) => s.settings), usage = useUI((s) => s.usageDashboard);
  const edit = useUI((s) => s.sidebarEdit), fileAction = useUI((s) => s.fileAction), renaming = useUI((s) => s.renamingTerminal);
  const uiError = useUI((s) => s.error), storeError = useApp((s) => s.error);
  const error = uiError ?? storeError;
  return <>
    {palette && <Palette key={palette} mode={palette} />}
    {settings && <Settings tab={settings} />}
    {usage && <UsageDashboard />}
    {edit && <SidebarEditor key={`${edit.kind}:${edit.threadID ?? edit.projectID}`} edit={edit} />}
    {fileAction && <FileActionSheet action={fileAction} />}
    {renaming && <RenameTerminal id={renaming} />}
    {error && <Alert message={error} dismiss={() => { useUI.setState({ error: null }); if (storeError) run("store", "dismissError"); }} />}
  </>;
}

function Alert({ message, dismiss }: { message: string; dismiss: () => void }) {
  return (
    <Sheet label="Octo" width={380} close={dismiss} className={styles.alert}>
      <div className={styles.alertBody}>
        <strong>Octo</strong>
        <p>{message}</p>
        <PrimaryButton autoFocus onClick={dismiss}>OK</PrimaryButton>
      </div>
    </Sheet>
  );
}

/** A small alert with one text field. */
function NameSheet({ title, message, initial, allowEmpty = false, save, close }: {
  title: string; message?: string; initial: string; allowEmpty?: boolean; save: (name: string) => void; close: () => void;
}) {
  const [name, setName] = useState(initial);
  return (
    <Sheet label={title} width={320} close={close} className={styles.alert}>
      <form className={styles.alertBody} onSubmit={(e) => { e.preventDefault(); if (allowEmpty || name.trim()) { save(name.trim()); close(); } }}>
        <strong>{title}</strong>
        {message && <p>{message}</p>}
        <input autoFocus aria-label="Name" placeholder="Name" value={name} onChange={(e) => setName(e.target.value)} onFocus={(e) => e.currentTarget.select()} />
        <div className={styles.alertButtons}>
          <BorderedButton onClick={close}>Cancel</BorderedButton>
          <PrimaryButton type="submit" disabled={!allowEmpty && !name.trim()}>Save</PrimaryButton>
        </div>
      </form>
    </Sheet>
  );
}

/** Renames show a name field; removals ask through the system's own alert. */
function SidebarEditor({ edit }: { edit: SidebarEdit }) {
  const close = () => useUI.setState({ sidebarEdit: null });
  const project = appState().archive.projects.find((p) => p.id === edit.projectID);
  const thread = edit.threadID ? project?.threads.find((t) => t.id === edit.threadID) : undefined;
  useEffect(() => {
    if (edit.kind !== "remove") return;
    let active = true;
    void call("app", "confirm", edit.threadID ? {
      message: "Delete thread?", buttons: ["Cancel", "Delete Thread"], destructive: 1,
      detail: "This permanently deletes the saved conversation and its draft from Octo. Files on disk and CLI history are kept.",
    } : {
      message: "Remove project from Octo?", buttons: ["Cancel", "Remove Project"], destructive: 1,
      detail: "This removes the project and its saved conversations from Octo. Files on disk are kept. Stop agents and close this project's terminal tabs first.",
    }).then((choice) => {
      if (!active) return;
      useUI.setState({ sidebarEdit: null });
      if (choice !== 1) return;
      if (edit.threadID) run("store", "deleteThread", edit.threadID, edit.projectID); else run("store", "removeProject", edit.projectID);
    });
    return () => { active = false; };
  }, [edit]);
  if (edit.kind === "remove") return null;
  return (
    <NameSheet title={edit.threadID ? "Rename thread" : "Rename project"} initial={thread?.title ?? project?.name ?? ""} close={close}
      save={(name) => { if (edit.threadID) run("store", "renameThread", edit.threadID, name); else run("store", "renameProject", edit.projectID, name); }} />
  );
}

function RenameTerminal({ id }: { id: string }) {
  const tab = useTerminal((s) => s.workspace.tabs.find((t) => t.id === id));
  const close = () => useUI.setState({ renamingTerminal: null });
  if (!tab) return null;
  return <NameSheet title="Rename terminal tab" message="Leave the name empty to use the automatic one." initial={tab.customName ?? tab.label} allowEmpty
    close={close} save={(name) => run("terminal", "rename", id, name)} />;
}

/** New File and Delete File, each confirmed against the checkout it was requested for. */
function FileActionSheet({ action }: { action: FileAction }) {
  const [path, setPath] = useState(action.path);
  const [busy, setBusy] = useState(false), [error, setError] = useState<string>(), [exists, setExists] = useState(action.kind === "create");
  const close = () => { if (!busy) useUI.setState({ fileAction: null }); };
  useEffect(() => {
    if (action.kind !== "delete") return;
    let active = true;
    void call("review", "inspectFile", action.root, action.path).then(() => { if (active) setExists(true); })
      .catch((failure) => { if (active) setError(String(failure instanceof Error ? failure.message : failure)); });
    return () => { active = false; };
  }, [action]);
  const canPerform = !busy && (action.kind === "create" ? !!path && !path.endsWith("/") : exists);
  const perform = async () => {
    if (!canPerform) return;
    setBusy(true); setError(undefined);
    try {
      if (action.kind === "create") {
        await call("review", "createFile", action.root, path);
        showPanel({ type: "openFile", path, pinned: true }, true);
      } else {
        await call("review", "deleteFile", action.root, path);
        await forgetFile(action.root, path);
        run("store", "updatePanelTabsAction", action.projectID, { type: "close", tab: { kind: "file", path } });
      }
      await refreshCheckout(action.projectID, action.root);
      useUI.setState({ fileAction: null });
    } catch (failure) { setError(String(failure instanceof Error ? failure.message : failure)); }
    finally { setBusy(false); }
  };
  return (
    <Sheet label={action.kind === "create" ? "New File" : "Delete File?"} width={460} close={close}>
      <form className={styles.fileAction} onSubmit={(e) => { e.preventDefault(); void perform(); }}>
        <h2>{action.kind === "create" ? "New File" : "Delete File?"}</h2>
        <small className={styles.root}>{action.root}</small>
        {action.kind === "create" ? <>
          <input autoFocus aria-label="New file path" placeholder="Relative file path" value={path} onChange={(e) => setPath(e.target.value)} />
          <small className={styles.secondary}>Use an existing folder, for example src/newFile.ts.</small>
        </> : <>
          <code>{path}</code>
          <p>This permanently deletes the file from disk and discards its unsaved edits in Octo.</p>
        </>}
        {error && <p className={styles.error}>{error}</p>}
        <div className={styles.alertButtons}>
          {busy && <Spinner />}
          <span className={styles.spacer} />
          <BorderedButton disabled={busy} onClick={close}>Cancel</BorderedButton>
          {action.kind === "delete"
            ? <BorderedButton type="submit" className={styles.destructive} disabled={!canPerform}>Delete File</BorderedButton>
            : <PrimaryButton type="submit" disabled={!canPerform}>Create</PrimaryButton>}
        </div>
      </form>
    </Sheet>
  );
}
