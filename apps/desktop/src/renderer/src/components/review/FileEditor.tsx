import { useEffect, useMemo, useRef, useState } from "react";
import { File, Virtualizer } from "@pierre/diffs/react";
import { EditStateManager, type Editor } from "@pierre/diffs/edit";
import type { SelectedLineRange } from "@pierre/diffs";
import { makeSnapshot } from "@octo/core";
import { useUI } from "../../state/ui";
import { setCodeSelection, useReview } from "../../state/review";
import { editFile, fileKey, isDirty, reloadFile, saveFile, useFiles } from "../../state/files";
import { captureFile } from "../../lib/reviewCapture";
import { attachToDraft } from "../../lib/workspace";
import { call, run } from "../../bridge";
import { BorderedButton, Spinner } from "../controls";
import { labelGutter, usePierreTheme } from "./Pierre";
import styles from "./review.module.css";

/** A checkout file in Pierre's editor. Its document and undo history outlive tab switches. */
export function FileEditor({ root, path, projectID, visible }: { root: string; path: string; projectID: string; visible: boolean }) {
  const session = useFiles((s) => s.sessions[fileKey(root, path)]);
  const theme = usePierreTheme();
  const wrap = useReview((s) => s.wrapLines);
  const reveal = useUI((s) => s.reviewLocation);
  const focus = useUI((s) => s.reviewFocus);
  const editor = useRef<Editor<"file", undefined, undefined> | undefined>(undefined);
  const [baseRevision, setBaseRevision] = useState("working");
  const showing = useRef(visible);
  showing.current = visible;

  useEffect(() => {
    let active = true;
    void call("review", "fileSnapshot", path, projectID, root).then((snapshot) => { if (active) setBaseRevision(snapshot.baseRevision); }).catch(() => {});
    return () => { active = false; };
  }, [projectID, root, path, session?.revision]);
  useEffect(() => {
    if (visible && reveal?.root === root && reveal.path === path) editor.current?.focus({ lineNumber: reveal.line });
  }, [visible, reveal, root, path]);
  useEffect(() => { if (showing.current && focus) editor.current?.focus(); }, [focus]);

  const editKey = `${fileKey(root, path)}:${session?.revision ?? 0}`;
  const initial = session?.initial;
  const file = useMemo(() => initial === undefined ? undefined : { name: path, contents: initial, cacheKey: editKey }, [initial, editKey, path]);
  const context = useMemo(() => makeSnapshot({ projectID, workingDirectory: root, path, scope: "file", baseRevision, lines: [] }), [projectID, root, path, baseRevision]);

  if (!session || !file) return <div className={styles.centered}><Spinner label="Loading file" /></div>;
  const capture = (range: SelectedLineRange) => captureFile(editor.current?.getText() ?? session.text, context, range);
  const reload = async () => {
    if (isDirty(session)) {
      const choice = await call("app", "confirm", { message: "Reload file from disk?", detail: `Your unsaved edits to ${path} will be discarded.`, buttons: ["Keep Editing", "Reload"], destructive: 1 });
      if (choice !== 1) return;
    }
    await reloadFile(root, path);
    EditStateManager.clear("file", editKey);
  };
  const status = session.saving ? "Saving…" : session.error ? "Not saved" : isDirty(session) ? "Unsaved" : "Saved";

  return (
    <div className={styles.fileEditor} data-testid="file-editor">
      <div className={styles.editorHeader}>
        <span className={styles.editorPath} title={path}>{path}</span>
        <span className={styles.spacer} />
        <span className={styles.editorStatus}>{status}</span>
        <BorderedButton small disabled={!isDirty(session) || session.saving || !!session.error} help="Save file (⌘S)" onClick={() => void saveFile(root, path)}>Save</BorderedButton>
      </div>
      {session.error && (
        <div className={styles.editorError} role="alert">
          <span>{session.error}</span>
          <BorderedButton small disabled={session.saving} onClick={() => void reload().catch((error) => useUI.getState().showError(String(error)))}>Reload</BorderedButton>
        </div>
      )}
      <hr className={styles.hairline} />
      <div className={styles.editorBody}>
        <Virtualizer className={styles.editorScroller}>
          <File key={session.revision} file={file} edit editStateKey={editKey}
            editorOptions={{
              ownsVerticalViewport: true,
              onAttach: (instance) => {
                editor.current = instance;
                const location = useUI.getState().reviewLocation;
                if (showing.current && location?.root === root && location.path === path) instance.focus({ lineNumber: location.line });
              },
            }}
            onEditChange={(event) => {
              editFile(root, path, event.file.contents);
              // Editing keeps a preview tab open.
              run("store", "updatePanelTabsAction", projectID, { type: "pin", path });
            }}
            onEditComplete={() => "accept"}
            options={{
              theme, disableFileHeader: true, enableLineSelection: true, enableGutterUtility: true, overflow: wrap ? "wrap" : "scroll",
              onLineSelected: (range) => setCodeSelection(root, range ? capture(range) : undefined, "files"),
              onGutterUtilityClick: (range) => { const attachment = capture(range); if (attachment) attachToDraft(attachment); },
              onLineEnter: ({ event }) => labelGutter(event),
            }} />
        </Virtualizer>
      </div>
    </div>
  );
}
