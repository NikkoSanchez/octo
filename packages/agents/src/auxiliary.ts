// Finite, schema-constrained model requests kept apart from conversation sessions: thread titles and
// commit message drafts. Each caller supplies its prompt, JSON schema and validation. A failed request
// throws `ProcessFailure("exited")` with the CLI's own explanation.
import { promises as fs } from "node:fs";
import { join } from "node:path";
import { CancellationError, PrivateTemporaryDirectory, ProcessFailure, runProcess } from "@octo/core/node";

export interface StructuredRequest {
  prompt: string;
  schema: string;
  model: string;
  reasoningEffort?: string;
  executable: string;
  /** Seconds. */
  timeout: number;
  signal?: AbortSignal;
}

/** `codex exec` logs progress to standard error; its last line holds the failure. */
function lastLine(data: Buffer): string | undefined {
  const lines = data.toString("utf8").split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const last = lines[lines.length - 1];
  return last ? Array.from(last).slice(0, 300).join("") : undefined;
}

/**
 * An ephemeral Codex request using standard CLI authentication, without loading user integrations or
 * repository instructions. `outputLimit` bounds the answer file.
 */
export async function codexStructuredRequest(request: StructuredRequest & { outputLimit: number }): Promise<unknown> {
  const temporary = new PrivateTemporaryDirectory();
  try {
    const schemaFile = join(temporary.path, "schema.json");
    const output = join(temporary.path, "output.json");
    await fs.writeFile(schemaFile, request.schema, { mode: 0o600 });
    const args = ["exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check",
      "--sandbox", "read-only", "--model", request.model,
      "--output-schema", schemaFile, "--output-last-message", output,
      "-c", "features.shell_tool=false", "-c", "features.apps=false",
      "-c", "features.remote_plugin=false", "-c", "features.multi_agent=false",
      "-c", "features.memories=false", "-c", "web_search=\"disabled\"",
      "-c", "tools.view_image=false", "-c", "project_doc_max_bytes=0"];
    if (request.reasoningEffort !== undefined) args.push("-c", `model_reasoning_effort="${request.reasoningEffort}"`);
    args.push("-");
    const result = await runProcess(request.executable, args, {
      directory: temporary.path, input: request.prompt, timeout: request.timeout, outputLimit: 256_000, signal: request.signal,
    });
    if (result.status !== 0) throw new ProcessFailure("exited", lastLine(result.error) ?? `Codex exited with status ${result.status}.`);
    if (request.signal?.aborted) throw new CancellationError();
    const info = await fs.stat(output);
    if (info.size > request.outputLimit) throw new ProcessFailure("oversized");
    return JSON.parse(await fs.readFile(output, "utf8"));
  } finally {
    temporary.dispose();
  }
}

/**
 * A print-mode Claude request with no tools, MCP servers, slash commands, settings files (so no user
 * hooks) or saved session, run in an empty owner-only directory so no CLAUDE.md loads. `--bare` would
 * also do this but skips keychain reads, which signed-in subscribers need. Checked against Claude Code
 * 2.1.302: `structured_output` carries the schema-validated object, and an error result explains
 * itself in `result`.
 */
export async function claudeStructuredRequest(request: StructuredRequest): Promise<unknown> {
  const temporary = new PrivateTemporaryDirectory();
  try {
    const args = ["-p", "--model", request.model, "--output-format", "json", "--json-schema", request.schema,
      "--tools", "", "--strict-mcp-config", "--setting-sources", "",
      "--disable-slash-commands", "--no-session-persistence"];
    if (request.reasoningEffort !== undefined) args.push("--effort", request.reasoningEffort);
    const result = await runProcess(request.executable, args, {
      directory: temporary.path, input: request.prompt, timeout: request.timeout, outputLimit: 256_000, signal: request.signal,
    });
    if (request.signal?.aborted) throw new CancellationError();
    let response: Record<string, unknown> | undefined;
    try {
      const parsed = JSON.parse(result.output.toString("utf8"));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) response = parsed;
    } catch { response = undefined; }
    if (result.status === 0 && response && response.is_error !== true && response.structured_output !== undefined && response.structured_output !== null) {
      return response.structured_output;
    }
    const reason = response?.is_error === true ? (typeof response.result === "string" ? response.result : undefined) : result.error.toString("utf8");
    const detail = reason ? Array.from(reason.trim()).slice(0, 300).join("") : "";
    throw new ProcessFailure("exited", detail || "Claude returned no structured answer.");
  } finally {
    temporary.dispose();
  }
}
