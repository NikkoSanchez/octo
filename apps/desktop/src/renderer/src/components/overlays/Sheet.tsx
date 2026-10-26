import { useEffect, useId, useRef, type ReactNode } from "react";
import { useUI } from "../../state/ui";
import { cx } from "../controls";
import styles from "./overlays.module.css";

/**
 * A modal sheet: it takes the keyboard, Escape closes it, and its content
 * carries its own title. While open it counts as an overlay, so native browser pages step aside.
 */
export function Sheet({ label, width, close, closeOnBackdrop = false, className, children }: {
  label: string;
  width?: number;
  close: () => void;
  closeOnBackdrop?: boolean;
  className?: string;
  children: ReactNode;
}) {
  const id = useId();
  const dialog = useRef<HTMLDialogElement>(null);
  const closeRef = useRef(close);
  closeRef.current = close;
  useEffect(() => {
    const node = dialog.current!;
    const restore = document.activeElement as HTMLElement | null;
    useUI.getState().openOverlay(id);
    // React has already focused an autoFocus field; showModal would move focus to the first button.
    const requested = node.contains(document.activeElement) ? document.activeElement as HTMLElement : undefined;
    node.showModal();
    // Without a requested field the sheet takes focus itself, so no button opens with a focus ring.
    (requested ?? node).focus();
    return () => {
      node.close();
      useUI.getState().closeOverlay(id);
      if (restore?.isConnected) restore.focus();
    };
  }, [id]);
  return (
    <dialog ref={dialog} tabIndex={-1} aria-label={label} className={cx(styles.sheet, className)} style={{ width }}
      onCancel={(e) => { e.preventDefault(); closeRef.current(); }}
      onMouseDown={(e) => {
        if (!closeOnBackdrop || e.target !== dialog.current) return;
        const r = dialog.current.getBoundingClientRect();
        if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) closeRef.current();
      }}>
      {children}
    </dialog>
  );
}
