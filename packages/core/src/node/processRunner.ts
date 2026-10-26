import { ManagedSubprocess } from "./managedSubprocess";
import { searchPath } from "./executables";
import { CancellationError, ProcessFailure } from "./processErrors";

export interface ProcessResult {
  status: number;
  output: Buffer;
  error: Buffer;
}

export interface RunOptions {
  directory: string;
  input?: Buffer | string;
  /** Adds to or replaces the inherited variables. */
  environment?: Record<string, string>;
  /** Seconds; 30 by default. */
  timeout?: number;
  /** Bytes; 8 MB by default. */
  outputLimit?: number;
  signal?: AbortSignal;
}

/** Runs a finite subprocess to completion with a deadline and an output cap. */
export function runProcess(executable: string, args: string[], options: RunOptions): Promise<ProcessResult> {
  const input = typeof options.input === "string" ? Buffer.from(options.input) : options.input;
  if ((input?.length ?? 0) > 36 * 1024 * 1024) return Promise.reject(new ProcessFailure("oversized"));
  if (options.signal?.aborted) return Promise.reject(new CancellationError());
  return new Promise((resolve, reject) => {
    const output: Buffer[] = [], error: Buffer[] = [];
    let child: ManagedSubprocess;
    const onAbort = () => child?.stop();
    try {
      child = ManagedSubprocess.launch({
        executable, arguments: args, directory: options.directory,
        environment: { ...process.env, PATH: searchPath(), GIT_TERMINAL_PROMPT: "0", ...options.environment },
        timeout: options.timeout ?? 30, outputLimit: Math.max(0, options.outputLimit ?? 8_000_000),
        onOutput: (data) => output.push(data), onError: (data) => error.push(data),
        onExit: (status, failure) => {
          options.signal?.removeEventListener("abort", onAbort);
          if (options.signal?.aborted) reject(new CancellationError());
          else if (failure) reject(failure);
          else resolve({ status, output: Buffer.concat(output), error: Buffer.concat(error) });
        },
      });
    } catch (launchError) {
      reject(launchError);
      return;
    }
    options.signal?.addEventListener("abort", onAbort, { once: true });
    try { child.send(input ?? Buffer.alloc(0), true); } catch { child.stop(); }
  });
}
