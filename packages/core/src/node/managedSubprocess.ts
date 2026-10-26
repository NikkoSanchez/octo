import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { constants as osConstants } from "node:os";
import { ProcessFailure } from "./processErrors";

export interface LaunchOptions {
  executable: string;
  /** Argument array; never joined into a shell string. */
  arguments: string[];
  directory: string;
  environment: Record<string, string | undefined>;
  /** Seconds. */
  timeout?: number;
  /** Total stdout+stderr bytes before the process is stopped as oversized. */
  outputLimit?: number;
  onOutput: (data: Buffer) => void;
  onError: (data: Buffer) => void;
  onExit: (status: number, failure: Error | undefined) => void;
}

const QUEUE_LIMIT = 36 * 1024 * 1024;
const STOP_GRACE_MS = 300;
const WRITE_STALL_MS = 15_000;
const EXIT_DRAIN_MS = 500;

/**
 * Owns a process group and bounded pipes. The child leads its own group (`detached`), so stop and
 * interrupt reach its descendants; ones that deliberately start another session are outside this
 * lifecycle boundary. Stop sends TERM, then KILL after 300 ms.
 */
export class ManagedSubprocess {
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly pid: number;
  private pendingBytes = 0;
  private closeRequested = false;
  private stopping = false;
  private finished = false;
  private failure: Error | undefined;
  private stopTimer: NodeJS.Timeout | undefined;
  private writeStall: NodeJS.Timeout | undefined;

  private constructor(child: ChildProcessWithoutNullStreams, pid: number) {
    this.child = child;
    this.pid = pid;
  }

  get running(): boolean {
    return !this.finished && !this.stopping;
  }

  static launch(options: LaunchOptions): ManagedSubprocess {
    const values = [options.executable, options.directory, ...options.arguments,
      ...Object.entries(options.environment).flatMap(([k, v]) => [k, v ?? ""])];
    if (values.some((value) => value.includes("\0"))) {
      throw new ProcessFailure("exited", "Process arguments and environment must not contain NUL bytes.");
    }
    const env: Record<string, string> = {};
    for (const [key, value] of Object.entries(options.environment)) if (value !== undefined) env[key] = value;
    const child = spawn(options.executable, options.arguments, {
      cwd: options.directory, env, detached: true, stdio: ["pipe", "pipe", "pipe"], windowsHide: true,
    });
    if (child.pid === undefined) {
      // Spawn failures (ENOENT, EACCES) surface synchronously through the error event below.
      let reason: Error | undefined;
      child.once("error", (error) => { reason = error; });
      throw new ProcessFailure("exited", `Could not start ${options.executable}.` + (reason ? ` ${reason.message}` : ""));
    }
    const process = new ManagedSubprocess(child, child.pid);
    process.pump(options);
    return process;
  }

  /** Queues input. Throws when the process no longer accepts input or the queue is full. */
  send(data: Buffer | string, closeInput = false): void {
    if (this.finished || this.stopping || this.closeRequested) throw new ProcessFailure("exited", "Agent process is not accepting input.");
    const bytes = typeof data === "string" ? Buffer.from(data) : data;
    if (bytes.length > QUEUE_LIMIT - this.pendingBytes) throw new ProcessFailure("oversized");
    this.closeRequested = closeInput;
    if (bytes.length > 0) {
      this.pendingBytes += bytes.length;
      this.armWriteStall();
      this.child.stdin.write(bytes, () => {
        this.pendingBytes -= bytes.length;
        if (this.pendingBytes === 0) this.clearWriteStall();
      });
    }
    if (closeInput) this.child.stdin.end();
  }

  stop(): void {
    if (this.finished || this.stopping) return;
    this.stopping = true;
    this.signalGroup("SIGTERM");
    this.stopTimer = setTimeout(() => this.signalGroup("SIGKILL"), STOP_GRACE_MS);
  }

  interrupt(): void {
    if (!this.finished) this.signalGroup("SIGINT");
  }

  private fail(error: Error): void {
    if (!this.failure) this.failure = error;
    this.stop();
  }

  private signalGroup(signal: NodeJS.Signals): void {
    try { process.kill(-this.pid, signal); } catch { /* group already gone */ }
  }

  private armWriteStall(): void {
    if (this.writeStall) return;
    this.writeStall = setTimeout(() => this.fail(new ProcessFailure("exited", "Process input timed out.")), WRITE_STALL_MS);
  }
  private clearWriteStall(): void {
    if (this.writeStall) clearTimeout(this.writeStall);
    this.writeStall = undefined;
  }

  private pump(options: LaunchOptions): void {
    const { child } = this;
    let total = 0;
    let outputOpen = true, errorOpen = true, exited = false;
    let status = 0;
    let deadline: NodeJS.Timeout | undefined;
    let drain: NodeJS.Timeout | undefined;
    if (options.timeout !== undefined) {
      deadline = setTimeout(() => this.fail(new ProcessFailure("timedOut")), options.timeout * 1000);
    }
    const accept = (data: Buffer, handler: (data: Buffer) => void) => {
      if (this.failure) return;
      if (options.outputLimit !== undefined) {
        if (data.length > options.outputLimit - total) { this.fail(new ProcessFailure("oversized")); return; }
        total += data.length;
      }
      handler(data);
    };
    const finish = () => {
      if (this.finished) return;
      this.finished = true;
      if (deadline) clearTimeout(deadline);
      if (drain) clearTimeout(drain);
      if (this.stopTimer) clearTimeout(this.stopTimer);
      this.clearWriteStall();
      options.onExit(status, this.failure);
    };
    const maybeFinish = () => { if (exited && !outputOpen && !errorOpen) finish(); };
    child.stdout.on("data", (data: Buffer) => accept(data, options.onOutput));
    child.stderr.on("data", (data: Buffer) => accept(data, options.onError));
    child.stdout.on("close", () => { outputOpen = false; maybeFinish(); });
    child.stderr.on("close", () => { errorOpen = false; maybeFinish(); });
    // A closed child stdin must produce EPIPE, never terminate the app.
    child.stdin.on("error", (error: NodeJS.ErrnoException) => {
      if (error.code !== "EPIPE") this.fail(new ProcessFailure("exited", "Process input pipe closed."));
    });
    child.on("error", (error) => {
      if (!this.failure) this.failure = new ProcessFailure("exited", error.message);
    });
    child.on("exit", (code, signal) => {
      exited = true;
      status = code ?? 128 + (signal ? (osConstants.signals[signal] ?? 0) : 0);
      // Descendants still holding the group's pipes are cleaned up with the leader.
      this.signalGroup("SIGKILL");
      drain = setTimeout(finish, EXIT_DRAIN_MS);
      maybeFinish();
    });
  }
}
