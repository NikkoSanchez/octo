import { newID } from "@octo/core";
import { CancellationError, ProcessFailure } from "@octo/core/node";
import { JSONLineProcess, type JSONObject } from "./jsonLine";

interface Pending {
  resolve: (value: JSONObject) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

/** Claude Agent SDK control protocol over NDJSON. No SDK runtime or second MCP client. */
export class ClaudeConnection {
  readonly transport = new JSONLineProcess();
  onObject?: (object: JSONObject) => void;
  onDisconnect?: (detail: string) => void;
  private readonly pending = new Map<string, Pending>();
  private closed = false;

  constructor() {
    this.transport.onObject = (object) => this.receive(object);
    this.transport.onExit = (_status, detail) => this.disconnect(detail || "Claude connection closed before a result.");
  }

  start(executable: string, directory: string, args: string[]): void {
    this.transport.start(executable, args, directory);
  }

  request(request: JSONObject, timeoutMs = 30_000, signal?: AbortSignal): Promise<JSONObject> {
    const id = newID();
    return new Promise((resolve, reject) => {
      if (this.closed || signal?.aborted) { reject(new CancellationError()); return; }
      const timer = setTimeout(() => this.settle(id, new ProcessFailure("exited", "Claude control request timed out.")), timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      signal?.addEventListener("abort", () => this.settle(id, new CancellationError()), { once: true });
      try {
        this.transport.write({ type: "control_request", request_id: id, request });
      } catch (error) {
        this.settle(id, error as Error);
      }
    });
  }

  respond(id: string, response: JSONObject): void {
    if (this.closed) throw new ProcessFailure("exited", "Claude request is no longer active.");
    this.transport.write({ type: "control_response", response: { subtype: "success", request_id: id, response } });
  }

  reject(id: string, message: string): void {
    this.transport.write({ type: "control_response", response: { subtype: "error", request_id: id, error: message } });
  }

  private receive(object: JSONObject): void {
    if (this.closed) return;
    const response = object.response;
    if (object.type === "control_response" && response && typeof response === "object" && !Array.isArray(response) &&
        typeof (response as JSONObject).request_id === "string") {
      const r = response as JSONObject;
      if (r.subtype === "error") this.settle(r.request_id as string, new ProcessFailure("exited", typeof r.error === "string" ? r.error : "Claude control request failed."));
      else if (r.subtype === "success") {
        const body = r.response && typeof r.response === "object" && !Array.isArray(r.response) ? r.response as JSONObject : {};
        this.settle(r.request_id as string, undefined, body);
      }
    } else {
      this.onObject?.(object);
    }
  }

  private settle(id: string, error?: Error, value?: JSONObject): void {
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    clearTimeout(pending.timer);
    if (error) pending.reject(error); else pending.resolve(value ?? {});
  }

  private disconnect(detail: string): void {
    if (this.closed) return;
    this.closeWith(new ProcessFailure("exited", detail));
    this.onDisconnect?.(detail);
  }

  close(): void { this.closeWith(new CancellationError()); }

  private closeWith(error: Error): void {
    this.closed = true;
    for (const id of [...this.pending.keys()]) this.settle(id, error);
    this.transport.stop();
  }

  /** Lets the CLI persist and close normally after its result, with a bounded fallback. */
  finish(): void {
    this.closed = true;
    this.transport.closeInput();
    const process = this.transport;
    setTimeout(() => process.stop(), 2_000).unref();
  }
}
