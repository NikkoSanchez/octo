import { describe, expect, it } from "vitest";
import { StateMirror } from "./stateMirror";
const deferred = <T>() => { let resolve!: (value: T) => void; const promise = new Promise<T>((r) => { resolve = r; }); return { promise, resolve }; };
describe("renderer state mirror", () => {
  it("replays events received while a snapshot is in flight and ignores duplicates", async () => {
    const initial = deferred<{ state: number; version: number }>(); const states: number[] = [];
    const mirror = new StateMirror(() => initial.promise, (s, patches) => s + Number(patches[0].value), (s) => states.push(s.state), (e) => { throw e; });
    const loading = mirror.refresh();
    mirror.receive({ version: 2, patches: [{ op: "replace", path: [], value: 3 }] });
    mirror.receive({ version: 2, patches: [{ op: "replace", path: [], value: 3 }] });
    initial.resolve({ version: 1, state: 10 }); await loading;
    mirror.receive({ version: 1, patches: [] });
    expect(states).toEqual([13]);
  });
  it("retains pending patches across a second snapshot when a version is missing", async () => {
    let reads = 0; const states: number[] = [];
    const mirror = new StateMirror(async () => ++reads === 1 ? { state: 1, version: 1 } : { state: 2, version: 2 }, (s, p) => s + Number(p[0].value), (s) => states.push(s.state), (e) => { throw e; });
    const loading = mirror.refresh();
    mirror.receive({ version: 3, patches: [{ op: "replace", path: [], value: 3 }] });
    await loading; expect(states).toEqual([5]); expect(reads).toBe(2);
  });
  it("does not publish from an owner retired during an IPC request", async () => {
    const initial = deferred<{ state: number; version: number }>(); const states: number[] = [];
    const mirror = new StateMirror(() => initial.promise, (s) => s, (s) => states.push(s.state), (e) => { throw e; });
    const loading = mirror.refresh(); mirror.dispose(); initial.resolve({ state: 7, version: 1 }); await loading;
    expect(states).toEqual([]);
  });
  it("recovers after a failed snapshot on the next event", async () => {
    let count = 0; const errors: unknown[] = [], states: number[] = [];
    const mirror = new StateMirror(async () => { if (++count === 1) throw new Error("Disconnected"); return { state: 3, version: 3 }; }, (s) => s, (s) => states.push(s.state), (e) => errors.push(e));
    await mirror.refresh(); mirror.receive({ version: 3, patches: [] }); await new Promise((r) => setImmediate(r));
    expect(errors).toHaveLength(1); expect(states).toEqual([3]);
  });
});
