import type { ComponentPropsWithRef, CSSProperties, ReactNode } from "react";
import type { HarnessID } from "@octo/core";
import { ChevronDown } from "lucide-react";
import { useUI } from "../state/ui";
import { ProviderIcon } from "./ProviderIcon";
import { HELD_HINTS } from "../lib/shortcuts";
import styles from "./controls.module.css";

/** React 19 passes `ref` as a prop, so spreading the props forwards it to the button. */
type ButtonProps = ComponentPropsWithRef<"button"> & { help?: string };
const cx = (...names: (string | false | undefined | null)[]) => names.filter(Boolean).join(" ");

/** A button that stays plain until hovered, then shows a soft rounded wash. */
export function HoverButton({ padded = true, selected = false, chevron = false, className, help, children, ...props }: ButtonProps & { padded?: boolean; selected?: boolean; chevron?: boolean }) {
  return (
    <button type="button" title={help} {...props} className={cx(styles.hover, !padded && styles.flush, selected && styles.selected, className)}>
      {children}
      {chevron && <ChevronDown size={9} strokeWidth={3} className={styles.chevron} />}
    </button>
  );
}

/** A control in a card's top corner, concentric with its curve. */
export function CornerButton({ className, help, children, ...props }: ButtonProps) {
  return <button type="button" title={help} {...props} className={cx(styles.corner, className)}>{children}</button>;
}

/** A 32×28 capsule in a toolbar or control row; `active` draws the glyph in the accent. */
export function ToolbarButton({ active = false, className, help, children, ...props }: ButtonProps & { active?: boolean }) {
  return <button type="button" title={help} {...props} className={cx(styles.toolbar, active && styles.active, className)}>{children}</button>;
}

/** A labelled capsule on a field-coloured track, as for Open in. */
export function CapsuleButton({ className, help, children, ...props }: ButtonProps) {
  return <button type="button" title={help} {...props} className={cx(styles.capsule, className)}>{children}</button>;
}

/** A round or capsule control floating on glass, as in the sidebar footer. */
export function GlassButton({ className, help, children, style, ...props }: ButtonProps) {
  return <button type="button" title={help} {...props} style={style} className={cx(styles.glassButton, className)}>{children}</button>;
}

export function PrimaryButton({ pill = false, small = false, className, help, children, ...props }: ButtonProps & { pill?: boolean; small?: boolean }) {
  return <button type="button" title={help} {...props} className={cx(styles.primary, pill && styles.pill, small && styles.small, className)}>{children}</button>;
}

export function BorderedButton({ small = false, className, help, children, ...props }: ButtonProps & { small?: boolean }) {
  return <button type="button" title={help} {...props} className={cx(styles.bordered, small && styles.small, className)}>{children}</button>;
}

/** A segmented capsule: the selected segment is raised on the track. */
export function CapsulePicker<T extends string>({ label, value, options, onChange }: { label: string; value: T; options: { value: T; title: string }[]; onChange: (value: T) => void }) {
  return (
    <div role="radiogroup" aria-label={label} className={styles.picker}>
      {options.map((option) => (
        <button key={option.value} type="button" role="radio" aria-checked={option.value === value}
          className={cx(styles.segment, option.value === value && styles.on)} onClick={() => onChange(option.value)}>
          {option.title}
        </button>
      ))}
    </div>
  );
}

/** A floating card after the macOS 26 Messages sidebar, drawn flat with a translucent fill. */
export function GlassPanel({ className, style, children }: { className?: string; style?: CSSProperties; children: ReactNode }) {
  return <div className={cx(styles.panel, className)} style={style}>{children}</div>;
}

/** A provider mark on a monogram circle; a ring pulses while the thread works. */
export function ThreadAvatar({ harness, size = 36, running = false, outline }: { harness: HarnessID; size?: number; running?: boolean; outline?: string }) {
  return (
    <span className={styles.avatar} style={{ width: size, height: size }} aria-hidden="true">
      <ProviderIcon harness={harness} size={size * 0.5} />
      {running && <span className={styles.ring} style={outline ? ({ "--ring-color": outline } as CSSProperties) : undefined} />}
    </span>
  );
}

export function TypingIndicator() {
  return <span className={styles.dots} aria-hidden="true"><span /><span /><span /></span>;
}

/** A live dot whose soft ring expands and fades; Reduce Motion keeps it still. */
export function WorkingIndicator({ icon }: { icon?: ReactNode }) {
  if (icon) return <span className={styles.pulse} role="img" aria-label="Working">{icon}</span>;
  return <span className={styles.live} role="img" aria-label="Working" />;
}

export function ShimmerText({ children, size = 13 }: { children: ReactNode; size?: number }) {
  return <span className={styles.shimmer} style={{ fontSize: size }}>{children}</span>;
}

export function Spinner({ label }: { label?: string }) {
  return <span className={styles.spinner} role={label ? "progressbar" : undefined} aria-label={label} />;
}

export function EmptyState({ icon, title, description, children }: { icon?: ReactNode; title: string; description?: ReactNode; children?: ReactNode }) {
  return (
    <div className={styles.empty}>
      {icon && <div className={styles.emptyIcon}>{icon}</div>}
      <div className={styles.emptyTitle}>{title}</div>
      {description && <div className={styles.emptyDescription}>{description}</div>}
      {children && <div className={styles.emptyActions}>{children}</div>}
    </div>
  );
}

/**
 * A command's shortcut badged while ⌘ is held, for the few commands in `HELD_HINTS`. `leading` sits
 * beside the control, for a button whose neighbour's badge already takes the space above.
 */
export function ShortcutHint({ command, placement = "above", active = true }: { command: string; placement?: "above" | "leading"; active?: boolean }) {
  const shown = useUI((s) => s.shortcutHints);
  const text = HELD_HINTS[command];
  if (!shown || !active || !text) return null;
  return <span className={cx(styles.hint, placement === "leading" && styles.leading)} aria-hidden="true">{[...text].join(" ")}</span>;
}

export { cx };
