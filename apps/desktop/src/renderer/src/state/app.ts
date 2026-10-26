import { applyPatches, enablePatches, type Patch } from "immer";
import { useRef } from "react";
import { create } from "zustand";
import { useShallow } from "zustand/react/shallow";
import { findProject, type WorkspaceProject, type WorkspaceThread } from "@octo/core";
import type { AppState } from "../../../shared/state";
import { call, on } from "../bridge";
import { StateMirror } from "./stateMirror";
import { useUI } from "./ui";
import { deepEqual } from "../lib/equality";

enablePatches();
interface Mirror { ready: boolean; version: number; state: AppState }
export const useMirror = create<Mirror>(() => ({ ready: false, version: 0, state: undefined as unknown as AppState }));

/** Each subscription owns its snapshot request; StrictMode cleanup retires the old owner. */
export function startMirror(): () => void {
  const mirror = new StateMirror<AppState>(
    () => call("app", "snapshot"),
    (state, patches) => applyPatches(state, patches as Patch[]),
    (snapshot) => useMirror.setState({ ...snapshot, ready: true }),
    (error) => useUI.getState().showError(String(error)),
  );
  const off = on("state:patches", (batch) => mirror.receive(batch));
  void mirror.refresh();
  return () => { off(); mirror.dispose(); };
}

/**
 * Reads main's state. The result is compared shallowly, so select the fields a view draws:
 * patches replace only the objects they touch, and streamed text replaces its thread on every delta.
 */
export function useApp<T>(selector: (state: AppState) => T): T {
  return useMirror(useShallow((m: Mirror) => selector(m.state)));
}
/**
 * Reads a derived presentation, compared structurally: the view renders only when what it draws
 * changes, however many patches (streamed text included) replace the objects it was derived from.
 */
export function useAppPresentation<T>(selector: (state: AppState) => T): T {
  const last = useRef<{ value: T } | undefined>(undefined);
  return useMirror((m) => {
    const next = selector(m.state);
    if (last.current && deepEqual(last.current.value, next)) return last.current.value;
    last.current = { value: next };
    return next;
  });
}
export function appState(): AppState { return useMirror.getState().state; }

export function selectedProject(state: AppState): WorkspaceProject | undefined { return findProject(state.archive, state.archive.selectedProjectID); }
export function selectedThread(state: AppState): WorkspaceThread | undefined {
  return selectedProject(state)?.threads.find((t) => t.id === state.archive.selectedThreadID);
}
export function isProjectChat(state: AppState): boolean {
  const project = selectedProject(state);
  return project !== undefined && !project.isChatCollection;
}

/** The selected project's fields a view needs, compared shallowly. */
export function useProject<T>(select: (project: WorkspaceProject | undefined) => T): T {
  return useApp((s) => select(selectedProject(s)));
}
/** The selected thread's fields a view needs, compared shallowly. */
export function useThread<T>(select: (thread: WorkspaceThread | undefined) => T): T {
  return useApp((s) => select(selectedThread(s)));
}
export function useIsProjectChat(): boolean { return useApp(isProjectChat); }
/** The checkout the selected thread works in: its own working directory, else its project's root. */
export function checkoutRoot(state: AppState): string | undefined {
  return selectedThread(state)?.workingDirectory ?? selectedProject(state)?.rootPath;
}
