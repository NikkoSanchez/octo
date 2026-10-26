import { useEffect, useId, useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from "react";
import { createPortal } from "react-dom";
import { useUI } from "../state/ui";
import styles from "./popover.module.css";

/** Open popovers, oldest first. A click inside a later one (a popover opened from this one) isn't outside. */
const stack: HTMLElement[] = [];

/**
 * A popover anchored to a control: below the anchor when it fits,
 * otherwise above. Escape, a click outside or the window losing focus closes it. While open it
 * counts as an overlay, so native browser pages, which draw above the page, step aside.
 */
export function Popover({ anchor, close, label, width, children }: {
  anchor: RefObject<HTMLElement | null>;
  close: () => void;
  label: string;
  width?: number;
  children: ReactNode;
}) {
  const id = useId();
  const box = useRef<HTMLDivElement>(null);
  const closeRef = useRef(close);
  closeRef.current = close;
  const [position, setPosition] = useState<{ left: number; top: number; above: boolean }>();

  useLayoutEffect(() => {
    const place = () => {
      const target = anchor.current?.getBoundingClientRect(), node = box.current;
      if (!target || !node) return;
      const margin = 8, gap = 6;
      const { width: w, height: h } = node.getBoundingClientRect();
      const below = target.bottom + gap + h <= window.innerHeight - margin;
      const above = !below && target.top - gap - h >= margin;
      const left = Math.min(Math.max(margin, target.left + target.width / 2 - w / 2), window.innerWidth - w - margin);
      const top = below || !above ? Math.min(target.bottom + gap, window.innerHeight - h - margin) : target.top - gap - h;
      setPosition({ left, top: Math.max(margin, top), above });
    };
    place();
    const observer = new ResizeObserver(place);
    if (box.current) observer.observe(box.current);
    window.addEventListener("resize", place);
    return () => { observer.disconnect(); window.removeEventListener("resize", place); };
  }, [anchor]);

  useEffect(() => {
    useUI.getState().openOverlay(id);
    const restore = document.activeElement as HTMLElement | null;
    const node = box.current!;
    stack.push(node);
    const later = () => stack.slice(stack.indexOf(node) + 1);
    const pointer = (event: PointerEvent) => {
      const target = event.target as Node;
      if (node.contains(target) || anchor.current?.contains(target) || later().some((child) => child.contains(target))) return;
      closeRef.current();
    };
    // Escape closes the newest popover only.
    const key = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || stack.at(-1) !== node) return;
      event.preventDefault(); event.stopPropagation(); closeRef.current();
    };
    const blur = () => closeRef.current();
    document.addEventListener("pointerdown", pointer, true);
    document.addEventListener("keydown", key, true);
    window.addEventListener("blur", blur);
    return () => {
      stack.splice(stack.indexOf(node), 1);
      useUI.getState().closeOverlay(id);
      document.removeEventListener("pointerdown", pointer, true);
      document.removeEventListener("keydown", key, true);
      window.removeEventListener("blur", blur);
      if (restore?.isConnected && node.contains(document.activeElement)) restore.focus();
    };
  }, [id, anchor]);

  return createPortal(
    <div ref={box} role="dialog" aria-label={label} className={styles.popover}
      style={{ width, left: position?.left ?? -9999, top: position?.top ?? -9999, visibility: position ? "visible" : "hidden" }}>
      {children}
    </div>,
    document.body,
  );
}
