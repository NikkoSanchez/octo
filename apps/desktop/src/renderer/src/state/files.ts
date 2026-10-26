import { create } from "zustand";
import { call, run } from "../bridge";

/**
 * An open checkout file in the Files editor. Text edits are debounced into atomic saves in main,
 * which also holds the latest draft so Quit can flush it. An outside change keeps the draft and
 * blocks saving until the user reloads.
 */
export interface FileSession {
  root: string;
  path: string;
  /** The text the editor was created with; a reload replaces it and bumps `revision`. */
  initial: string;
  text: string;
  /** The text on disk when opened or last saved. */
  baseline: string;
  revision: number;
  saving: boolean;
  error?: string;
}

export const fileKey = (root: string, path: string) => `${root}\0${path}`;
export const isDirty = (session: FileSession) => session.text !== session.baseline;

export const useFiles = create<{ sessions: Record<string, FileSession> }>(() => ({ sessions: {} }));

/** Saves wait for a pause in typing. */
const AUTOSAVE_DELAY = 450;
const timers = new Map<string, ReturnType<typeof setTimeout>>();
const saves = new Map<string, Promise<void>>();
const openings = new Map<string, Promise<void>>();

function update(key: string, change: Partial<FileSession>): void {
  useFiles.setState((s) => s.sessions[key] ? { sessions: { ...s.sessions, [key]: { ...s.sessions[key], ...change } } } : s);
}

const message = (error: unknown) => error instanceof Error ? error.message : String(error);

/** Opens a file once; later calls reuse the retained session and its edits. */
export async function openFile(root: string, path: string): Promise<void> {
  const key = fileKey(root, path);
  if (useFiles.getState().sessions[key]) return;
  const pending = openings.get(key);
  if (pending) return pending;
  const opening = call("review", "openFile", root, path).then((file) => {
    useFiles.setState((s) => ({ sessions: { ...s.sessions, [key]: { root, path, initial: file.text, text: file.text, baseline: file.baseline, revision: 0, saving: false } } }));
  });
  openings.set(key, opening);
  try { await opening; } finally { openings.delete(key); }
}

export function editFile(root: string, path: string, text: string): void {
  const key = fileKey(root, path);
  update(key, { text });
  run("review", "setFileDraft", root, path, text);
  clearTimeout(timers.get(key));
  timers.set(key, setTimeout(() => { timers.delete(key); void saveFile(root, path); }, AUTOSAVE_DELAY));
}

/** Saves now (⌘S). Typing stays enabled while writing; a newer draft is saved in a following write. */
export async function saveFile(root: string, path: string): Promise<void> {
  const key = fileKey(root, path);
  clearTimeout(timers.get(key));
  timers.delete(key);
  const pending = saves.get(key);
  if (pending) return pending;
  const saving = (async () => {
    for (;;) {
      const session = useFiles.getState().sessions[key];
      if (!session || session.error || !isDirty(session)) return;
      update(key, { saving: true });
      try {
        const saved = await call("review", "saveFile", root, path, session.text);
        update(key, { baseline: saved.baseline, saving: false });
      } catch (error) {
        update(key, { error: message(error), saving: false });
        return;
      }
    }
  })();
  saves.set(key, saving);
  try { await saving; } finally { saves.delete(key); }
}

/** Replaces the buffer with the file on disk, discarding unsaved edits. */
export async function reloadFile(root: string, path: string): Promise<void> {
  const key = fileKey(root, path);
  clearTimeout(timers.get(key));
  timers.delete(key);
  await saves.get(key);
  const file = await call("review", "reloadFile", root, path);
  const revision = (useFiles.getState().sessions[key]?.revision ?? 0) + 1;
  update(key, { initial: file.text, text: file.text, baseline: file.baseline, revision, error: undefined, saving: false });
}

/** A deleted file must not be reopened from a retained buffer if its path is recreated. */
export async function forgetFile(root: string, path: string): Promise<void> {
  const key = fileKey(root, path);
  clearTimeout(timers.get(key));
  timers.delete(key);
  await Promise.allSettled([saves.get(key), openings.get(key)]);
  useFiles.setState((s) => {
    const sessions = { ...s.sessions };
    delete sessions[key];
    return { sessions };
  });
}

/** Marks sessions whose file changed on disk; their drafts stay until an explicit reload. */
export async function checkFiles(): Promise<void> {
  await Promise.all(Object.entries(useFiles.getState().sessions).map(async ([key, session]) => {
    if (session.saving || session.error || saves.has(key)) return;
    try {
      if (await call("review", "fileChanged", session.root, session.path)) {
        update(key, { error: "This file changed on disk. Your edits are still here. Copy any changes you need, then reload before saving." });
      }
    } catch (error) { update(key, { error: message(error) }); }
  }));
}
