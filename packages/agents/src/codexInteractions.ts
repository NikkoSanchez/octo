// Wire decoding for Codex app-server v2 interactions (generated with 0.158.0-alpha.2.1). Deliberately
// a strict subset: unknown constraints cannot silently weaken a form.
import { ProcessFailure } from "@octo/core/node";
import { interactionValidationError, makeField, makeInteraction, type AgentInteraction, type AgentInteractionResponse, type InteractionField, type InteractionOption } from "./interaction";
import type { JSONObject } from "./jsonLine";

const invalid = (reason: string) => new ProcessFailure("exited", `Unsupported Codex interaction: ${reason}`);
const isObject = (value: unknown): value is JSONObject => typeof value === "object" && value !== null && !Array.isArray(value);
const isNull = (value: unknown) => value === null || value === undefined;
const length = (text: string) => Array.from(text).length;

function checkKeys(data: JSONObject, allowed: string[]): void {
  if (Object.keys(data).some((key) => !allowed.includes(key))) throw new ProcessFailure("exited", "Unsupported form constraints. Use the owning CLI workflow.");
}

function bound(raw: unknown): number | undefined {
  if (isNull(raw)) return undefined;
  if (typeof raw !== "number" || raw < 0 || raw > 4096 || Math.round(raw) !== raw) throw new ProcessFailure("exited", "Unsupported length bound.");
  return raw;
}

export class CodexInteraction {
  readonly request: AgentInteraction;
  readonly questions: boolean;
  private readonly persistence: Record<string, Record<string, string>>;
  private readonly metadataScopeField?: string;

  private constructor(request: AgentInteraction, questions: boolean, persistence: Record<string, Record<string, string>>, metadataScopeField?: string) {
    this.request = request; this.questions = questions; this.persistence = persistence; this.metadataScopeField = metadataScopeField;
  }

  static decode(p: JSONObject, questions: boolean): CodexInteraction {
    const fields: InteractionField[] = [];
    const persistence: Record<string, Record<string, string>> = {};
    let message: string;
    let target: string | undefined;
    let metadataScopeField: string | undefined;
    if (questions) {
      const items = p.questions;
      if (!Array.isArray(items) || items.length === 0 || items.length > 16) throw invalid("invalid questions");
      message = "Answer the provider’s questions explicitly.";
      for (const item of items) {
        if (!isObject(item) || typeof item.id !== "string" || item.id === "" || typeof item.header !== "string" ||
            typeof item.question !== "string" || item.isSecret === true) throw invalid("invalid or secret question; use the CLI’s authentication workflow");
        for (const flag of ["isSecret", "isOther"]) {
          if (item[flag] !== undefined && typeof item[flag] !== "boolean") throw invalid("invalid question flags");
        }
        const field = makeField({ id: item.id, label: item.header, detail: item.question, kind: "text", required: true });
        if (!isNull(item.options)) {
          const options = item.options;
          if (!Array.isArray(options) || options.length === 0 || options.length > 32) throw invalid("invalid question choices");
          field.kind = "choice";
          field.options = options.map((option) => {
            if (!isObject(option) || typeof option.label !== "string" || typeof option.description !== "string") throw invalid("invalid question option");
            return { id: option.label, label: option.label, detail: option.description };
          });
          field.allowsOther = item.isOther === true;
        }
        fields.push(field);
      }
    } else {
      const schema = p.requestedSchema;
      if (!["form", "openai/form", "openaiForm"].includes(typeof p.mode === "string" ? p.mode : "") || typeof p.message !== "string" ||
          !isObject(schema) || schema.type !== "object" || !isObject(schema.properties) ||
          !Object.values(schema.properties).every(isObject) || Object.keys(schema.properties).length > 16) {
        throw invalid("only bounded forms are supported; URL/device verification must use the owning CLI");
      }
      message = p.message;
      checkKeys(schema, ["type", "properties", "required", "$schema", "additionalProperties"]);
      if (!isNull(schema.additionalProperties) && schema.additionalProperties !== false) throw invalid("additional properties");
      let required: string[] = [];
      if (!isNull(schema.required)) {
        if (!Array.isArray(schema.required) || !schema.required.every((r) => typeof r === "string")) throw invalid("required fields");
        required = schema.required as string[];
      }
      const properties = schema.properties as Record<string, JSONObject>;
      if (!required.every((r) => r in properties) || new Set(required).size !== required.length) throw invalid("unknown or repeated required field");
      if (isObject(p._meta)) {
        const meta = p._meta;
        const nested = [meta.target, meta.tool_params].filter(isObject);
        for (const data of [meta, ...nested]) {
          const found = ["app_name", "appName", "app", "name"].map((k) => data[k]).find((v) => typeof v === "string") as string | undefined;
          if (found !== undefined) { target = found; break; }
        }
      }
      if (target === undefined && message.startsWith("Allow ChatGPT to use ") && message.endsWith("?")) {
        target = message.slice("Allow ChatGPT to use ".length, -1);
      }
      // Message remains visible even if metadata does not identify the app.
      for (const key of Object.keys(properties).sort()) {
        const data = properties[key];
        checkKeys(data, ["type", "title", "description", "default", "enum", "enumNames", "oneOf", "minLength", "maxLength", "minimum", "maximum"]);
        for (const name of ["title", "description"]) {
          if (!isNull(data[name]) && typeof data[name] !== "string") throw invalid("invalid field label");
        }
        const type = data.type;
        if (typeof type !== "string") throw invalid("field type");
        const field = makeField({
          id: key, label: typeof data.title === "string" ? data.title : key, detail: typeof data.description === "string" ? data.description : "",
          kind: "text", required: required.includes(key),
        });
        switch (type) {
          case "string": {
            if (!isNull(data.oneOf)) {
              if (!isNull(data.enum) || !Array.isArray(data.oneOf)) throw invalid("conflicting choices");
              field.options = data.oneOf.map((choice): InteractionOption => {
                if (!isObject(choice)) throw invalid("choice value");
                checkKeys(choice, ["const", "title"]);
                if (typeof choice.const !== "string") throw invalid("choice value");
                return { id: choice.const, label: typeof choice.title === "string" ? choice.title : choice.const, detail: "" };
              });
              field.kind = "choice";
            } else if (!isNull(data.enum)) {
              if (!Array.isArray(data.enum) || !data.enum.every((c) => typeof c === "string")) throw invalid("string enum");
              const choices = data.enum as string[];
              let labels = choices;
              if (!isNull(data.enumNames)) {
                if (!Array.isArray(data.enumNames) || !data.enumNames.every((c) => typeof c === "string") || data.enumNames.length !== choices.length) throw invalid("enum labels");
                labels = data.enumNames as string[];
              }
              field.options = choices.map((id, index) => ({ id, label: labels[index], detail: "" }));
              field.kind = "choice";
            }
            field.minLength = bound(data.minLength);
            field.maxLength = bound(data.maxLength);
            if (field.minLength !== undefined && field.maxLength !== undefined && field.minLength > field.maxLength) throw invalid("length bounds");
            // Only exact, provider-advertised values affect the extension metadata.
            for (const option of field.options) {
              if (["approval", "persist"].includes(key) && ["session", "always"].includes(option.id)) {
                persistence[key] = { ...(persistence[key] ?? {}), [option.id]: option.id };
              }
            }
            break;
          }
          case "boolean":
            field.kind = "boolean";
            if (key === "always") persistence[key] = { true: "always" };
            if (key === "session") persistence[key] = { true: "session" };
            break;
          case "number": case "integer":
            field.kind = type === "integer" ? "integer" : "number";
            break;
          default:
            throw invalid(`field type ${type}`);
        }
        if (type !== "string" && ["enum", "enumNames", "oneOf", "minLength", "maxLength"].some((name) => !isNull(data[name]))) throw invalid("constraints on non-string field");
        for (const name of ["minimum", "maximum"] as const) {
          const raw = data[name];
          if (isNull(raw)) continue;
          if (!["number", "integer"].includes(type) || typeof raw !== "number" || !Number.isFinite(raw)) throw invalid("numeric constraint");
          field[name] = raw;
        }
        if (field.minimum !== undefined && field.maximum !== undefined && field.minimum > field.maximum) throw invalid("numeric bounds");
        fields.push(field);
      }
    }
    // The bundled Computer Use policy advertises duration in metadata, with an empty form. This is a
    // separate protocol extension, not a schema default. Keep it narrowly identified so generic forms
    // cannot acquire broader consent.
    const meta = isObject(p._meta) ? p._meta : undefined;
    const params = meta && isObject(meta.tool_params) ? meta.tool_params : undefined;
    const scopes = meta?.persist;
    if (!questions && fields.length === 0 && p.mode === "form" && meta &&
        meta.codex_approval_kind === "mcp_tool_call" && meta.connector_id === "computer-use" &&
        params && typeof params.app === "string" && params.app.trim() !== "" &&
        typeof meta.tool_name === "string" && meta.tool_name !== "" &&
        Array.isArray(scopes) && scopes.length > 0 && scopes.length <= 2 && scopes.every((s) => typeof s === "string") &&
        new Set(scopes).size === scopes.length && scopes.every((s) => s === "session" || s === "always")) {
      const key = "octo.accessDuration";
      metadataScopeField = key;
      target = params.app;
      if (Array.isArray(meta.tool_params_display)) {
        const display = meta.tool_params_display.find((d) => isObject(d) && d.name === "app") as JSONObject | undefined;
        if (display && typeof display.value === "string" && display.value !== "") target = `${display.value} (${params.app})`;
      }
      const options: InteractionOption[] = [{ id: "once", label: "Allow once", detail: "Approve only this request." }];
      if (scopes.includes("session")) options.push({ id: "session", label: "Allow for this chat session", detail: "Let Computer Use access this app for the current provider session." });
      if (scopes.includes("always")) options.push({ id: "always", label: "Always allow this app", detail: "The provider remembers this permission beyond the current chat session." });
      fields.push(makeField({ id: key, label: "App access", detail: "Choose how long to allow access to this app.", kind: "choice", required: true, options }));
      persistence[key] = Object.fromEntries((scopes as string[]).map((s) => [s, s]));
    }
    if (new Set(fields.map((f) => f.id)).size !== fields.length) throw invalid("repeated field ID");
    for (const field of fields) {
      if (field.id === "" || length(field.id) > 256 || length(field.label) > 1024 || length(field.detail) > 8192 ||
          (field.kind === "choice" && (field.options.length === 0 || field.options.length > 32)) ||
          new Set(field.options.map((o) => o.id)).size !== field.options.length ||
          !field.options.every((o) => o.id !== "" && length(o.id) <= 1024 && length(o.label) <= 1024 && length(o.detail) <= 4096)) {
        throw invalid("field/choice bounds or duplicates");
      }
    }
    if (length(message) > 16384 || (target !== undefined && length(target) > 1024)) throw invalid("request too large");
    const request = makeInteraction({
      title: questions ? "Input requested" : "Access / information requested", detail: message, target, fields, canDecline: !questions,
      cancellationDetail: questions ? "Cancel sends no answers; it does not approve a choice." : "Decline refuses this request. Cancel dismisses it without consent.",
    });
    if (request.target === undefined) delete request.target;
    return new CodexInteraction(request, questions, persistence, metadataScopeField);
  }

  response(response: AgentInteractionResponse): JSONObject {
    switch (response.type) {
      case "cancel": return this.questions ? { answers: {} } : { action: "cancel", content: null };
      case "decline":
        if (this.questions) throw new ProcessFailure("exited", "Decline is unavailable for this request.");
        return { action: "decline", content: null };
      case "submit": {
        const error = interactionValidationError(this.request, response.values);
        if (error) throw new ProcessFailure("exited", error);
        const content: JSONObject = {};
        const scopes = new Set<string>();
        for (const [key, value] of Object.entries(response.values)) {
          let lookup: string;
          if (value.kind === "text") { content[key] = this.questions ? { answers: [value.value] } : value.value; lookup = value.value; }
          else if (value.kind === "boolean") { content[key] = value.value; lookup = String(value.value); }
          else { content[key] = value.value; lookup = ""; }
          const scope = this.persistence[key]?.[lookup];
          if (scope) scopes.add(scope);
        }
        if (this.metadataScopeField) delete content[this.metadataScopeField];
        if (scopes.size > 1) throw new ProcessFailure("exited", "Conflicting access durations; choose a single duration.");
        if (this.questions) return { answers: content };
        const result: JSONObject = { action: "accept", content };
        const [scope] = scopes;
        if (scope) result._meta = { persist: scope };
        return result;
      }
    }
  }
}
