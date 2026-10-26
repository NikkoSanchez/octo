import { memo, useMemo, type ReactNode } from "react";
import { WrapText } from "lucide-react";
import { parsePatchFiles, registerCustomTheme, type SelectedLineRange } from "@pierre/diffs";
import { EditProvider, FileDiff, WorkerPoolContextProvider } from "@pierre/diffs/react";
import PierreWorker from "@pierre/diffs/worker/worker.js?worker";
import { Editor } from "@pierre/diffs/edit";
import type { AppTheme, CodeAttachment, ReviewSnapshot } from "@octo/core";
import { useApp } from "../../state/app";
import { toggleWrapLines, useReview } from "../../state/review";
import { resolveTheme } from "../../theme/theme";
import { captureDiff, hunkAnnotations, snapshotPatch, type HunkAnnotation } from "../../lib/reviewCapture";
import { ToolbarButton } from "../controls";
import styles from "./review.module.css";

const registered = new Set<string>();

/** The app theme's syntax palette as a Shiki theme, so diffs and the editor match the window. */
export function pierreTheme(theme: AppTheme, dark: boolean): string {
  const name = `octo-${theme}-${dark ? "dark" : "light"}`;
  if (registered.has(name)) return name;
  const { palette: p, syntax: s } = resolveTheme(theme, { dark });
  const color = (hex: string, italic = false) => ({ foreground: `#${hex}`, ...(italic ? { fontStyle: "italic" } : {}) });
  const italic = (role: string) => s.italic.includes(role as never);
  registerCustomTheme(name, async () => ({
    name, type: p.isDark ? "dark" : "light",
    colors: { "editor.background": `#${p.base}`, "editor.foreground": `#${p.text}`, "editor.selectionBackground": `#${p.surface}` },
    settings: [
      { scope: ["comment", "punctuation.definition.comment"], settings: color(s.comment, italic("comment")) },
      { scope: ["keyword", "storage", "storage.type", "storage.modifier", "keyword.control"], settings: color(s.keyword, italic("keyword")) },
      { scope: ["string", "string.quoted", "string.template"], settings: color(s.string, italic("string")) },
      { scope: ["constant.character.escape"], settings: color(s.escape) },
      { scope: ["constant.numeric", "constant.language"], settings: color(s.number) },
      { scope: ["entity.name.function", "support.function", "meta.function-call"], settings: color(s.function, italic("function")) },
      { scope: ["variable.other.property", "support.type.property-name", "meta.object-literal.key", "entity.name.tag"], settings: color(s.key) },
      { scope: ["support.type", "support.class", "entity.name.type", "variable.language"], settings: color(s.builtin) },
      { scope: ["keyword.operator"], settings: color(s.operatorColor) },
      { scope: ["punctuation"], settings: color(s.punctuation) },
    ],
  }));
  registered.add(name);
  return name;
}

export function usePierreTheme(): string {
  const theme = useApp((s) => s.theme), dark = useApp((s) => s.systemDark);
  return pierreTheme(theme, dark);
}

/** Toggles soft wrapping for every diff and Files editor. */
export function WrapLinesButton() {
  const wrap = useReview((s) => s.wrapLines);
  return (
    <ToolbarButton aria-label="Wrap lines" aria-pressed={wrap} active={wrap} help={wrap ? "Stop wrapping long lines" : "Wrap long lines"}
      onClick={toggleWrapLines}><WrapText size={15} /></ToolbarButton>
  );
}

const poolOptions = { workerFactory: () => new PierreWorker(), poolSize: 2 };

/** Shiki highlighting in a two-worker pool, and Pierre's edit provider for the Files editor. */
export function Editors({ children }: { children: ReactNode }) {
  const theme = usePierreTheme();
  const highlighterOptions = useMemo(() => ({ theme }), [theme]);
  return (
    <WorkerPoolContextProvider poolOptions={poolOptions} highlighterOptions={highlighterOptions}>
      <EditProvider createEditor={(type, options, key) => new Editor(type, { ...options, ownsVerticalViewport: true }, key)}>{children}</EditProvider>
    </WorkerPoolContextProvider>
  );
}

const labeledRoots = new WeakSet<ShadowRoot>();
/** Pierre creates the gutter's + lazily inside its shadow root; give every one an accessible name. */
export function labelGutter(event: PointerEvent): void {
  const target = event.target as Element | null;
  const root = event.composedPath().find((node) => node instanceof ShadowRoot) ?? target?.shadowRoot ?? target?.getRootNode();
  if (!(root instanceof ShadowRoot)) return;
  const label = () => {
    for (const button of root.querySelectorAll("[data-utility-button]")) {
      button.setAttribute("aria-label", "Attach selected code to draft");
      button.setAttribute("title", "Attach selected code to draft");
    }
  };
  label();
  if (!labeledRoots.has(root)) { labeledRoots.add(root); new MutationObserver(label).observe(root, { childList: true, subtree: true }); }
}

/**
 * One file's diff. Pierre draws a display-only patch; selections and the gutter's + map back to
 * the immutable snapshot's old and new source lines. `hunkTitle` puts Stage or Unstage Hunk above
 * each hunk for ordinary modifications.
 */
export const DiffFile = memo(function DiffFile({ snapshot, split, hunkTitle, onHunk, onSelection, onAttach }: {
  snapshot: ReviewSnapshot;
  split: boolean;
  hunkTitle?: string;
  onHunk?: (hunk: number) => void;
  onSelection: (capture: CodeAttachment | undefined) => void;
  onAttach: (capture: CodeAttachment) => void;
}) {
  const theme = usePierreTheme();
  const wrap = useReview((s) => s.wrapLines);
  const diff = useMemo(() => parsePatchFiles(snapshotPatch(snapshot), snapshot.id, true)[0]?.files[0], [snapshot]);
  const annotations = useMemo(() => hunkTitle && onHunk ? hunkAnnotations(snapshot) : [], [snapshot, hunkTitle, onHunk]);
  if (!diff) return null;
  return (
    <FileDiff<HunkAnnotation> fileDiff={diff} lineAnnotations={annotations}
      renderAnnotation={(annotation) => annotation.metadata && (
        <button type="button" className={styles.hunkAction} aria-label={`${hunkTitle} ${annotation.metadata.index + 1}`}
          onClick={() => onHunk?.(annotation.metadata!.hunk)}>{hunkTitle}</button>
      )}
      options={{
        theme, disableFileHeader: true, diffStyle: split ? "split" : "unified", overflow: wrap ? "wrap" : "scroll",
        enableLineSelection: true, enableGutterUtility: true,
        unsafeCSS: ":host { --diffs-font-size: 12px; }",
        onLineSelected: (range: SelectedLineRange | null) => onSelection(range ? captureDiff(snapshot, range) : undefined),
        onGutterUtilityClick: (range: SelectedLineRange) => { const capture = captureDiff(snapshot, range); if (capture) onAttach(capture); },
        onLineEnter: ({ event }: { event: PointerEvent }) => labelGutter(event),
      }} />
  );
}, (a, b) => a.snapshot.id === b.snapshot.id && a.snapshot.notice === b.snapshot.notice && a.split === b.split && a.hunkTitle === b.hunkTitle
  && !!a.onHunk === !!b.onHunk && a.onSelection === b.onSelection && a.onAttach === b.onAttach);
