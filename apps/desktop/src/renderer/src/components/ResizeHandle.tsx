import type { CSSProperties, KeyboardEvent, PointerEvent } from "react";
import { cx } from "./controls";
import styles from "./resizeHandle.module.css";

/**
 * A 7 pt divider strip: drag reports the translation from where the
 * drag began; arrow keys step by 20. The line shows only while hovered or dragged unless `idleLine`.
 */
export function ResizeHandle({ label, vertical = false, idleLine = false, value, onDrag, onEnd, onStep, style, className }: {
  label: string;
  /** A horizontal divider dragged up and down; the translation is positive downwards. */
  vertical?: boolean;
  idleLine?: boolean;
  value?: number;
  onDrag: (translation: number) => void;
  onEnd?: () => void;
  onStep: (delta: number) => void;
  style?: CSSProperties;
  className?: string;
}) {
  const begin = (event: PointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    event.preventDefault();
    const node = event.currentTarget, origin = vertical ? event.clientY : event.clientX;
    node.setPointerCapture(event.pointerId);
    node.dataset.dragging = "true";
    onDrag(0);
    const move = (e: globalThis.PointerEvent) => onDrag((vertical ? e.clientY : e.clientX) - origin);
    const finish = () => {
      delete node.dataset.dragging;
      node.removeEventListener("pointermove", move);
      node.removeEventListener("pointerup", finish);
      node.removeEventListener("pointercancel", finish);
      onEnd?.();
    };
    node.addEventListener("pointermove", move);
    node.addEventListener("pointerup", finish);
    node.addEventListener("pointercancel", finish);
  };
  const key = (event: KeyboardEvent<HTMLDivElement>) => {
    const back = vertical ? "ArrowUp" : "ArrowLeft", forward = vertical ? "ArrowDown" : "ArrowRight";
    if (event.key !== back && event.key !== forward) return;
    event.preventDefault();
    onStep(event.key === back ? -20 : 20);
  };
  return (
    <div role="separator" tabIndex={0} aria-label={label} aria-orientation={vertical ? "horizontal" : "vertical"} aria-valuenow={value === undefined ? undefined : Math.round(value)}
      className={cx(styles.handle, vertical ? styles.vertical : styles.horizontal, idleLine && styles.idleLine, className)} style={style}
      onPointerDown={begin} onKeyDown={key} />
  );
}
