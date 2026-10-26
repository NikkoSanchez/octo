import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { CancellationError, ProcessFailure, runProcess } from "../src/node";
import { removeRoot, temporaryRoot } from "./helpers";

const python = "/usr/bin/python3";
const roots: string[] = [];
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });

describe("runProcess", () => {
  it("drains both pipes and preserves arguments and input", async () => {
    const script = "import sys; data=sys.stdin.buffer.read(); sys.stdout.buffer.write(data); sys.stdout.write(sys.argv[1]); sys.stderr.write('e'*100000)";
    const input = Buffer.alloc(200_000, 120);
    const value = "space ' quote ; $(not-a-command)";
    const result = await runProcess(python, ["-c", script, value], { directory: "/tmp", input });
    expect(result.status).toBe(0);
    expect(result.output.equals(Buffer.concat([input, Buffer.from(value)]))).toBe(true);
    expect(result.error.length).toBe(100_000);
  });

  it("enforces the output limit and the deadline", async () => {
    for (const [script, limit, timeout] of [["import sys; sys.stdout.write('x'*1000000)", 4096, 5], ["import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)", 4096, 0.3]] as const) {
      const start = Date.now();
      await expect(runProcess(python, ["-c", script], { directory: "/tmp", timeout, outputLimit: limit })).rejects.toBeInstanceOf(ProcessFailure);
      expect(Date.now() - start).toBeLessThan(3000);
    }
  });

  it("stops the process group, including a descendant, on cancellation", async () => {
    const root = temporaryRoot(); roots.push(root);
    const pidFile = join(root, "pid");
    const script = "import subprocess,sys,time,signal; p=subprocess.Popen(['/bin/sleep','30']); open(sys.argv[1],'w').write(str(p.pid)); signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)";
    const controller = new AbortController();
    const task = runProcess(python, ["-c", script, pidFile], { directory: root, signal: controller.signal });
    for (let i = 0; i < 100 && !(existsSync(pidFile) && readFileSync(pidFile, "utf8")); i++) await new Promise((r) => setTimeout(r, 20));
    const childPID = Number(readFileSync(pidFile, "utf8"));
    controller.abort();
    await expect(task).rejects.toBeInstanceOf(CancellationError);
    let alive = true;
    for (let i = 0; i < 100 && alive; i++) {
      try { process.kill(childPID, 0); await new Promise((r) => setTimeout(r, 20)); } catch { alive = false; }
    }
    expect(alive).toBe(false);
  });

  it("does not leak the app's file descriptors to children", async () => {
    // Node opens every descriptor close-on-exec; check that a fresh one is absent in the child.
    const { openSync, closeSync } = await import("node:fs");
    const descriptor = openSync("/dev/null", "r");
    try {
      const script = "import os,sys\ntry:\n os.fstat(int(sys.argv[1])); sys.exit(1)\nexcept OSError:\n sys.exit(0)";
      const result = await runProcess(python, ["-c", script, String(descriptor)], { directory: "/tmp" });
      expect(result.status).toBe(0);
    } finally {
      closeSync(descriptor);
    }
  });
});
