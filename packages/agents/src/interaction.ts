import { newID } from "@octo/core";

export type InteractionValue = { kind: "text"; value: string } | { kind: "boolean"; value: boolean } | { kind: "number"; value: number };

export const textValue = (value: string): InteractionValue => ({ kind: "text", value });
export const booleanValue = (value: boolean): InteractionValue => ({ kind: "boolean", value });
export const numberValue = (value: number): InteractionValue => ({ kind: "number", value });

export interface InteractionOption {
  id: string;
  label: string;
  detail: string;
}

export type InteractionFieldKind = "text" | "boolean" | "number" | "integer" | "choice";

export interface InteractionField {
  id: string;
  label: string;
  detail: string;
  kind: InteractionFieldKind;
  required: boolean;
  options: InteractionOption[];
  allowsOther: boolean;
  minLength?: number;
  maxLength?: number;
  minimum?: number;
  maximum?: number;
}

export function makeField(fields: Partial<InteractionField> & Pick<InteractionField, "id" | "label" | "kind" | "required">): InteractionField {
  return { detail: "", options: [], allowsOther: false, ...fields };
}

export interface AgentInteraction {
  /** Unforgeable local identity; never a reusable provider request number. */
  id: string;
  title: string;
  detail: string;
  target?: string;
  fields: InteractionField[];
  canDecline: boolean;
  cancellationDetail: string;
}

export function makeInteraction(fields: Omit<AgentInteraction, "id"> & { id?: string }): AgentInteraction {
  return { ...fields, id: fields.id ?? newID() };
}

export type AgentInteractionResponse =
  | { type: "submit"; values: Record<string, InteractionValue> }
  | { type: "decline" }
  | { type: "cancel" };

export function interactionValidationError(interaction: AgentInteraction, values: Record<string, InteractionValue>): string | undefined {
  const ids = new Set(interaction.fields.map((f) => f.id));
  if (Object.keys(values).some((key) => !ids.has(key))) return "Unexpected response field.";
  for (const field of interaction.fields) {
    const value = values[field.id];
    if (value === undefined) {
      if (field.required) return `Choose or enter ${field.label}.`;
      continue;
    }
    const isText = field.kind === "text" || field.kind === "choice";
    const isNumber = field.kind === "number" || field.kind === "integer";
    if (isText && value.kind === "text") {
      const text = value.value;
      if (field.kind === "choice" && !field.allowsOther && !field.options.some((o) => o.id === text)) return `Choose an advertised option for ${field.label}.`;
      const length = Array.from(text).length;
      if (length < (field.minLength ?? 0) || length > (field.maxLength ?? 4096)) return `Check the length of ${field.label}.`;
    } else if (field.kind === "boolean" && value.kind === "boolean") {
      // valid
    } else if (isNumber && value.kind === "number") {
      const n = value.value;
      if (!Number.isFinite(n) || (field.kind === "integer" && Math.round(n) !== n) ||
          n < (field.minimum ?? -Number.MAX_VALUE) || n > (field.maximum ?? Number.MAX_VALUE)) return `Enter a valid number for ${field.label}.`;
    } else {
      return `Invalid value for ${field.label}.`;
    }
  }
  return undefined;
}
