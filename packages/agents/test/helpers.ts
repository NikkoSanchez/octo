import { chmodSync, mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type { AgentEvent, AgentHarness } from "../src";

export const fixtures = join(import.meta.dirname, "fixtures");
export const fixture = (name: string) => join(fixtures, name);

export function temporaryRoot(): string {
  const root = join(realpathSync(tmpdir()), "octo-agents-" + randomUUID());
  mkdirSync(root, { recursive: true });
  return root;
}
export const removeRoot = (root: string) => rmSync(root, { recursive: true, force: true });

export function executable(directory: string, name: string, script: string): string {
  const path = join(directory, name);
  writeFileSync(path, script);
  chmodSync(path, 0o700);
  return path;
}

/** Strips a common leading indent from a template script so Python sees column-zero code. */
export function dedent(text: string): string {
  const lines = text.replace(/^\n/, "").split("\n");
  const indent = Math.min(...lines.filter((l) => l.trim()).map((l) => l.length - l.trimStart().length));
  return lines.map((l) => l.slice(indent)).join("\n");
}

export function deferred<T = void>(): { promise: Promise<T>; resolve: (value: T) => void; reject: (error: unknown) => void } {
  let resolve!: (value: T) => void, reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

export function within<T>(promise: Promise<T>, ms: number, what = "event"): Promise<T> {
  return Promise.race([promise, new Promise<T>((_, reject) => setTimeout(() => reject(new Error(`Timed out waiting for ${what}`)), ms))]);
}

export const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export async function eventually(check: () => boolean, ms = 2000): Promise<void> {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > ms) throw new Error("Condition not met in time");
    await sleep(20);
  }
}

/** Resolves on the turn's terminal event; `on` sees every event first. */
export function untilEnd(harness: AgentHarness, on: (event: AgentEvent) => void = () => {}): Promise<AgentEvent> {
  const done = deferred<AgentEvent>();
  harness.onEvent = (event) => {
    on(event);
    if (event.type === "finished" || event.type === "interrupted" || event.type === "failed") done.resolve(event);
  };
  return done.promise;
}
