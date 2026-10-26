import type { PopupItem } from "../../../shared/menu";
import { call } from "../bridge";

/** Shows a native menu below `anchor`, or at the pointer, and runs the chosen item's action. */
export async function popup(items: MenuSpec[], anchor?: Element | null): Promise<void> {
  const actions = new Map<string, () => void>();
  let counter = 0;
  const convert = (list: MenuSpec[]): PopupItem[] => list.filter(Boolean).map((item) => {
    const spec = item as Exclude<MenuSpec, false | null | undefined>;
    if (spec.type === "separator" || spec.type === "header") return spec;
    if (spec.type === "submenu") return { ...spec, items: convert(spec.items) };
    const id = `m${counter++}`;
    if (spec.action) actions.set(id, spec.action);
    const { action: _action, ...rest } = spec;
    return { ...rest, type: "item", id };
  });
  const rect = anchor?.getBoundingClientRect();
  const chosen = await call("app", "popupMenu", convert(items), rect ? { x: rect.left, y: rect.bottom + 4 } : undefined);
  if (chosen) actions.get(chosen)?.();
}

export type MenuSpec =
  | { type?: "item"; label: string; enabled?: boolean; checked?: boolean; toolTip?: string; accelerator?: string; icon?: string; symbol?: string; action?: () => void }
  | { type: "separator" }
  | { type: "header"; label: string }
  | { type: "submenu"; label: string; enabled?: boolean; icon?: string; symbol?: string; items: MenuSpec[] }
  | false | null | undefined;

export const separator: MenuSpec = { type: "separator" };

/** A context menu handler for `onContextMenu`. */
export function contextMenu(items: () => MenuSpec[]) {
  return (event: React.MouseEvent) => {
    event.preventDefault();
    event.stopPropagation();
    void popup(items());
  };
}
