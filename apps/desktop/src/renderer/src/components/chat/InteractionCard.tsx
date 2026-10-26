import { useState } from "react";
import { Hand } from "lucide-react";
import { interactionValidationError, type AgentInteraction, type AgentInteractionResponse, type InteractionField, type InteractionValue } from "@octo/agents/model";
import { call } from "../../bridge";
import { BorderedButton, PrimaryButton } from "../controls";
import styles from "./chat.module.css";

const OTHER = "\u0000other";

/** Only neutral models and generic actions: no provider JSON, policy inference or consent defaults. */
export function InteractionCard({ request, threadID }: { request: AgentInteraction; threadID: string }) {
  const [values, setValues] = useState<Record<string, InteractionValue>>({});
  const [raw, setRaw] = useState<Record<string, string>>({});
  const [other, setOther] = useState<Set<string>>(new Set());
  const [error, setError] = useState<string>();
  const [submitted, setSubmitted] = useState(false);

  const set = (id: string, value: InteractionValue | undefined) => setValues((current) => {
    const next = { ...current };
    if (value === undefined) delete next[id]; else next[id] = value;
    return next;
  });
  const send = async (response: AgentInteractionResponse) => {
    if (submitted) return;
    if (response.type === "submit") {
      const invalid = interactionValidationError(request, response.values);
      if (invalid) { setError(invalid); return; }
    }
    setSubmitted(true);
    try {
      const failure = await call("store", "respond", request.id, threadID, response);
      setError(failure); setSubmitted(!failure);
    } catch (failure) { setError(String(failure instanceof Error ? failure.message : failure)); setSubmitted(false); }
  };

  const textInput = (field: InteractionField) => (
    <input aria-label={field.label} disabled={submitted} value={raw[field.id] ?? ""}
      inputMode={field.kind === "number" || field.kind === "integer" ? "decimal" : undefined}
      onChange={(e) => {
        const value = e.target.value;
        setRaw((current) => ({ ...current, [field.id]: value }));
        if (!value && !field.required) set(field.id, undefined);
        else if ((field.kind === "number" || field.kind === "integer") && value.trim() && !Number.isNaN(Number(value))) set(field.id, { kind: "number", value: Number(value) });
        else set(field.id, { kind: "text", value });
      }} />
  );
  const choice = (field: InteractionField) => {
    const value = other.has(field.id) ? OTHER : values[field.id]?.kind === "text" ? String(values[field.id]!.value) : "";
    const choose = (next: string) => {
      setOther((current) => { const set = new Set(current); if (next === OTHER) set.add(field.id); else set.delete(field.id); return set; });
      if (next === OTHER) { set(field.id, undefined); setRaw((current) => ({ ...current, [field.id]: "" })); }
      else set(field.id, next ? { kind: "text", value: next } : undefined);
    };
    const options = [...field.options.map((o) => ({ id: o.id, label: o.label })), ...(field.allowsOther ? [{ id: OTHER, label: "Write an answer…" }] : [])];
    const selected = field.options.find((o) => o.id === value);
    return <>
      {field.options.length <= 4
        ? <div role="radiogroup" aria-label={field.label} className={styles.radios}>
            {options.map((o) => (
              <label key={o.id}><input type="radio" name={`${request.id}:${field.id}`} disabled={submitted} checked={value === o.id} onChange={() => choose(o.id)} />{o.label}</label>
            ))}
          </div>
        : <select aria-label={field.label} disabled={submitted} value={value} onChange={(e) => choose(e.target.value)}>
            <option value="">Choose…</option>
            {options.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
          </select>}
      {other.has(field.id) && textInput(field)}
      {selected?.detail && <small>{selected.detail}</small>}
    </>;
  };

  return (
    <section className={styles.interaction} aria-label={request.title}>
      <h3><Hand size={15} />{request.title}</h3>
      {request.target && <strong>Target app: {request.target}</strong>}
      <p className={styles.selectable}>{request.detail}</p>
      {request.fields.map((field) => (
        <div key={field.id} className={styles.field}>
          <span className={styles.fieldLabel}>{field.label}{field.required ? " (required)" : " (optional)"}</span>
          {field.detail && <small>{field.detail}</small>}
          {field.kind === "boolean"
            ? <select aria-label={field.label} disabled={submitted} value={values[field.id]?.kind === "boolean" ? String(values[field.id]!.value) : ""}
                onChange={(e) => set(field.id, e.target.value ? { kind: "boolean", value: e.target.value === "true" } : undefined)}>
                <option value="">Choose…</option><option value="true">Yes / true</option><option value="false">No / false</option>
              </select>
            : field.kind === "choice" ? choice(field) : textInput(field)}
        </div>
      ))}
      <small className={styles.caption}>{request.cancellationDetail}</small>
      {error && <p role="alert" className={styles.errorText}>{error}</p>}
      <div className={styles.actions}>
        <BorderedButton disabled={submitted} onClick={() => void send({ type: "cancel" })}>Cancel</BorderedButton>
        {request.canDecline && <BorderedButton disabled={submitted} onClick={() => void send({ type: "decline" })}>Decline</BorderedButton>}
        <span className={styles.spacer} />
        <PrimaryButton disabled={submitted || interactionValidationError(request, values) !== undefined} onClick={() => void send({ type: "submit", values })}>Submit response</PrimaryButton>
      </div>
    </section>
  );
}
