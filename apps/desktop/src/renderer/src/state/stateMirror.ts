import type { StatePatch } from "../../../shared/state";
interface Snapshot<T> { state: T; version: number }
interface Batch { version: number; patches: StatePatch[] }

/** A snapshot plus ordered patches. Lost batches trigger a fresh snapshot, never a partial state. */
export class StateMirror<T> {
  private snapshot?: Snapshot<T>;
  private pending: Batch[] = [];
  private refreshing = false;
  private disposed = false;
  constructor(private read: () => Promise<Snapshot<T>>, private apply: (state: T, patches: StatePatch[]) => T,
    private publish: (snapshot: Snapshot<T>) => void, private failed: (error: unknown) => void) {}
  receive(batch: Batch): void {
    if (this.disposed || batch.version <= (this.snapshot?.version ?? -1)) return;
    this.pending.push(batch);
    if (this.refreshing) return;
    if (!this.snapshot || batch.version !== this.snapshot.version + 1) { void this.refresh(); return; }
    this.drain();
  }
  private drain(): boolean {
    if (!this.snapshot) return false;
    const next = this.pending.filter((b) => b.version > this.snapshot!.version).sort((a, b) => a.version - b.version);
    let snapshot = this.snapshot;
    for (const batch of next) {
      if (batch.version <= snapshot.version) continue;
      if (batch.version !== snapshot.version + 1) return false;
      snapshot = { version: batch.version, state: this.apply(snapshot.state, batch.patches) };
    }
    this.pending = [];
    this.snapshot = snapshot;
    this.publish(snapshot);
    return true;
  }
  async refresh(): Promise<void> {
    if (this.disposed || this.refreshing) return;
    this.refreshing = true;
    try {
      do {
        const snapshot = await this.read();
        if (this.disposed) return;
        this.snapshot = snapshot;
        // Events can arrive while IPC is delivering this snapshot. Retain them across a gap.
      } while (!this.drain());
    } catch (error) { if (!this.disposed) this.failed(error); }
    finally { this.refreshing = false; }
  }
  dispose(): void { this.disposed = true; this.pending = []; }
}
