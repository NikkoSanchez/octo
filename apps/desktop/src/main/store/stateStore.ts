import { enablePatches, produce, type Draft, type Patch } from "immer";

enablePatches();

/**
 * Immutable state with change notification as Immer patches. Patches from one event-loop turn are
 * delivered together, numbered so a receiver that misses a batch can ask for a fresh snapshot.
 */
export class StateStore<T extends object> {
  private current: T;
  private version = 0;
  private pending: Patch[] = [];
  private scheduled = false;
  private readonly listeners = new Set<(version: number, patches: Patch[]) => void>();

  constructor(initial: T) {
    this.current = produce(initial, () => {});
  }

  get state(): T {
    return this.current;
  }

  snapshot(): { version: number; state: T } {
    this.flush();
    return { version: this.version, state: this.current };
  }

  update(recipe: (draft: Draft<T>) => void): void {
    let patches: Patch[] = [];
    const next = produce(this.current, recipe, (p) => { patches = p; });
    if (next === this.current || patches.length === 0) return;
    this.current = next;
    this.pending.push(...patches);
    if (!this.scheduled) {
      this.scheduled = true;
      queueMicrotask(() => this.flush());
    }
  }

  subscribe(listener: (version: number, patches: Patch[]) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  flush(): void {
    this.scheduled = false;
    if (this.pending.length === 0) return;
    const patches = this.pending;
    this.pending = [];
    this.version++;
    for (const listener of this.listeners) listener(this.version, patches);
  }
}
