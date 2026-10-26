export type ProcessFailureKind = "missing" | "exited" | "oversized" | "timedOut";

export class ProcessFailure extends Error {
  readonly kind: ProcessFailureKind;
  constructor(kind: ProcessFailureKind, detail?: string) {
    super(ProcessFailure.describe(kind, detail));
    this.kind = kind;
    this.name = "ProcessFailure";
  }
  static describe(kind: ProcessFailureKind, detail?: string): string {
    switch (kind) {
      case "missing": return `${detail ?? "The executable"} is not installed or not on PATH.`;
      case "exited": return detail ?? "The process exited.";
      case "timedOut": return "Process exceeded its time limit.";
      case "oversized": return "Output exceeds the supported size limit.";
    }
  }
}

export class CancellationError extends Error {
  constructor() {
    super("The operation was cancelled.");
    this.name = "CancellationError";
  }
}
