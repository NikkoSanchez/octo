import { ManagedSubprocess, ProcessFailure, searchPath } from "@octo/core/node";

export type JSONObject = Record<string, unknown>;

/** Splits newline-delimited frames, refusing any frame over `limit` bytes before buffering it. */
export class JSONLineFramer {
  private readonly limit: number;
  private buffer: Buffer[] = [];
  private buffered = 0;

  constructor(limit = 8_000_000) {
    this.limit = limit;
  }

  receive(data: Buffer, emit: (line: Buffer) => void): void {
    let start = 0;
    while (start < data.length) {
      const newline = data.indexOf(10, start);
      const end = newline === -1 ? data.length : newline;
      if (end - start > this.limit - this.buffered) throw new ProcessFailure("oversized");
      this.buffer.push(data.subarray(start, end));
      this.buffered += end - start;
      if (newline === -1) break;
      emit(Buffer.concat(this.buffer));
      this.buffer = []; this.buffered = 0;
      start = newline + 1;
    }
  }

  finish(emit: (line: Buffer) => void): void {
    if (this.buffered > 0) emit(Buffer.concat(this.buffer));
    this.buffer = []; this.buffered = 0;
  }
}

const textDecoder = new TextDecoder();

/** Protocol state on the event loop, over a bounded managed subprocess. */
export class JSONLineProcess {
  onObject?: (object: JSONObject) => void;
  onExit?: (status: number, detail: string) => void;
  private process: ManagedSubprocess | undefined;
  private framer = new JSONLineFramer();
  private stderr: Buffer = Buffer.alloc(0);
  private framingFailed = false;

  get running(): boolean {
    return this.process?.running === true;
  }

  start(executable: string, args: string[], directory: string): void {
    if (this.process) throw new ProcessFailure("exited", "Previous agent process is still closing. Try again shortly.");
    this.framer = new JSONLineFramer(); this.stderr = Buffer.alloc(0); this.framingFailed = false;
    this.process = ManagedSubprocess.launch({
      executable, arguments: args, directory,
      environment: { ...process.env, PATH: searchPath(), NO_COLOR: "1" },
      onOutput: (data) => this.receive(data),
      onError: (data) => {
        if (this.framingFailed) return;
        const joined = Buffer.concat([this.stderr, data]);
        this.stderr = joined.subarray(Math.max(0, joined.length - 8192));
      },
      onExit: (status, failure) => {
        if (!this.framingFailed) this.framer.finish((line) => this.decode(line));
        const detail = failure?.message ?? textDecoder.decode(this.stderr);
        this.process = undefined;
        this.onExit?.(this.framingFailed ? 1 : status, detail);
      },
    });
  }

  private receive(data: Buffer): void {
    if (this.framingFailed) return;
    try {
      this.framer.receive(data, (line) => this.decode(line));
    } catch {
      this.framingFailed = true;
      this.stderr = Buffer.from("Agent protocol frame exceeds 8 MB.");
      this.process?.stop();
    }
  }

  private decode(line: Buffer): void {
    if (line.length === 0) return;
    let object: unknown;
    try { object = JSON.parse(line.toString("utf8")); } catch { return; }
    if (object && typeof object === "object" && !Array.isArray(object)) this.onObject?.(object as JSONObject);
  }

  write(object: JSONObject): void {
    const data = JSON.stringify(object) + "\n";
    if (!this.process || !this.running) throw new ProcessFailure("exited", "Agent process is not running.");
    this.process.send(data);
  }

  writeInput(text: string): void {
    if (!this.process) throw new ProcessFailure("exited", "Agent process is not running.");
    this.process.send(text, true);
  }

  closeInput(): void {
    try { this.process?.send(Buffer.alloc(0), true); } catch { /* already closed */ }
  }

  interrupt(): void { this.process?.interrupt(); }
  stop(): void { this.process?.stop(); }
}

/** A typed wire request ID: numbers and strings are distinct; booleans are not IDs. */
export function requestKey(id: unknown): string | undefined {
  if (typeof id === "string") return "string:" + id;
  if (typeof id === "number" && Number.isFinite(id)) return "number:" + String(id);
  return undefined;
}

interface Pending {
  resolve: (value: JSONObject) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

/** JSON-RPC over newline JSON, for `codex app-server`. */
export class RPCConnection {
  private readonly transport = new JSONLineProcess();
  private nextID = 0;
  private readonly pending = new Map<number, Pending>();
  onNotification?: (method: string, params: JSONObject) => void;
  onRequest?: (id: unknown, method: string, params: JSONObject) => void;
  onDisconnect?: (detail: string) => void;

  constructor() {
    this.transport.onObject = (object) => this.receive(object);
    this.transport.onExit = (_status, detail) => this.disconnected(detail || "Agent connection closed.");
  }

  get running(): boolean {
    return this.transport.running;
  }

  start(executable: string, directory: string): void {
    this.transport.start(executable, ["app-server"], directory);
  }

  request(method: string, params: JSONObject, timeoutMs = 45_000): Promise<JSONObject> {
    const id = ++this.nextID;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) reject(new ProcessFailure("exited", `Agent request timed out: ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.transport.write({ id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error as Error);
      }
    });
  }

  notify(method: string): void {
    this.transport.write({ method, params: {} });
  }

  /** Throws when the connection cannot carry the response. */
  sendResponse(id: unknown, result: JSONObject): void {
    this.transport.write({ id, result });
  }

  respond(id: unknown, result: JSONObject): void {
    try { this.transport.write({ id, result }); } catch { /* connection gone */ }
  }

  reject(id: unknown, method: string): void {
    try { this.transport.write({ id, error: { code: -32601, message: `Octo does not yet support ${method}` } }); } catch { /* connection gone */ }
  }

  private receive(object: JSONObject): void {
    if (typeof object.method === "string") {
      const params = object.params && typeof object.params === "object" && !Array.isArray(object.params) ? object.params as JSONObject : {};
      if ("id" in object && object.id !== undefined) this.onRequest?.(object.id, object.method, params);
      else this.onNotification?.(object.method, params);
    } else if (typeof object.id === "number" && Number.isInteger(object.id)) {
      const pending = this.pending.get(object.id);
      if (!pending) return;
      this.pending.delete(object.id);
      clearTimeout(pending.timer);
      const error = object.error;
      if (error && typeof error === "object") {
        const message = (error as JSONObject).message;
        pending.reject(new ProcessFailure("exited", typeof message === "string" ? message : "Agent request failed."));
      } else {
        const result = object.result;
        pending.resolve(result && typeof result === "object" && !Array.isArray(result) ? result as JSONObject : {});
      }
    }
  }

  private disconnected(detail: string): void {
    const callbacks = [...this.pending.values()];
    this.pending.clear();
    for (const pending of callbacks) { clearTimeout(pending.timer); pending.reject(new ProcessFailure("exited", detail)); }
    this.onDisconnect?.(detail);
  }

  close(): void {
    this.transport.stop();
    this.disconnected("Agent connection closed.");
  }
}
