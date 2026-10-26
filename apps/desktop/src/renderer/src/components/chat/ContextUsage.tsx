import { useRef, useState } from "react";
import { ArrowRightLeft, CircleCheck } from "lucide-react";
import { percentUsed, remainingTokens, usedFraction, usedTokens, type ContextCompaction, type ConversationUsage, type TokenCounts } from "@octo/core";
import { HoverButton } from "../controls";
import { Popover } from "../Popover";
import styles from "./chat.module.css";

const tokens = (value: number | undefined) => value === undefined ? "—" : value.toLocaleString();

/** A quiet context ring with T3 Code's usage popover. Unknown values stay unavailable. */
export function ContextUsage({ usage, compaction, provider, supportsUsage, supportsCompaction }: {
  usage?: ConversationUsage; compaction?: ContextCompaction; provider: string; supportsUsage: boolean; supportsCompaction: boolean;
}) {
  const [open, setOpen] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const fraction = usage && usedFraction(usage), percent = usage && percentUsed(usage);
  const tint = fraction === undefined ? "var(--secondary)" : fraction > 0.9 ? "var(--red)" : fraction >= 0.8 ? "var(--yellow)" : "var(--secondary)";
  const label = compaction?.state === "compacting" ? "Compacting context"
    : percent !== undefined ? `Context ${percent}% used`
    : usage ? `Context ${usedTokens(usage).toLocaleString()} tokens used; capacity unavailable`
    : supportsUsage ? "Context and token usage: awaiting report" : "Context and token usage unavailable";
  const circumference = 2 * Math.PI * 7.25;
  return (
    <>
      <HoverButton ref={button} className={styles.contextButton} aria-label="Context and token usage" aria-description={label} help={`${label}. Click for details.`}
        aria-expanded={open} onClick={() => setOpen((v) => !v)}>
        <svg width={17} height={17} viewBox="0 0 17 17" aria-hidden="true">
          <circle cx={8.5} cy={8.5} r={7.25} fill="none" stroke="var(--secondary)" strokeOpacity={0.2} strokeWidth={2.5} />
          {fraction !== undefined
            ? <circle cx={8.5} cy={8.5} r={7.25} fill="none" stroke={tint} strokeWidth={2.5} strokeLinecap="round"
                strokeDasharray={`${circumference * fraction} ${circumference}`} transform="rotate(-90 8.5 8.5)" />
            : <text x={8.5} y={12} textAnchor="middle" fontSize={10} fill="var(--secondary)">–</text>}
        </svg>
        {percent !== undefined && <span style={{ color: tint }}>{percent}%</span>}
      </HoverButton>
      {open && (
        <Popover anchor={button} label="Context window" width={370} close={() => setOpen(false)}>
          <div className={styles.contextDetails}>
            <div className={styles.contextHeader}><strong>Context window</strong>{percent !== undefined && <span style={{ color: tint }}>{percent}% used</span>}</div>
            {usage ? <>
              <div className={styles.contextBlock}>
                {fraction !== undefined && <progress max={1} value={fraction} aria-label="Context window usage" style={{ accentColor: tint }} />}
                <div className={styles.contextTotal}>
                  <span>{tokens(usedTokens(usage))}</span>
                  <small>{usage.contextWindow ? `of ${tokens(usage.contextWindow)} tokens` : "tokens · capacity unavailable"}</small>
                </div>
                {remainingTokens(usage) !== undefined && <small>{tokens(remainingTokens(usage))} tokens remaining in the reported window</small>}
                <small>Based on the latest model response; unsent drafts are not included.</small>
              </div>
              <hr />
              <strong>Token usage</strong>
              <table className={styles.tokenTable}>
                <thead><tr><th /><th>Last response</th><th>Session total</th></tr></thead>
                <tbody>
                  <TokenRow title="Total processed" field="total" usage={usage} emphasized />
                  <TokenRow title="Input" field="input" usage={usage} />
                  <TokenRow title="Cached input" field="cachedInput" usage={usage} />
                  {(usage.latest.cacheWriteInput !== undefined || usage.session?.cacheWriteInput !== undefined) && <TokenRow title="Cache writes" field="cacheWriteInput" usage={usage} />}
                  <TokenRow title="Output" field="output" usage={usage} />
                  <TokenRow title="Reasoning" field="reasoning" usage={usage} />
                </tbody>
              </table>
              <small>Cache counts are included in input; reasoning is included in output. Session totals can exceed the context window.</small>
              <small className={styles.fine}>Last reported {new Date(usage.updatedAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" })}</small>
            </> : (
              <small>{supportsUsage
                ? `Waiting for ${provider} to report context and token usage. Values appear as the agent works.`
                : `Context and token usage are not available through the current ${provider} adapter.`}</small>
            )}
            <hr />
            {compaction && <>
              <span className={styles.compaction}>
                {compaction.state === "completed" ? <CircleCheck size={13} /> : <ArrowRightLeft size={13} />}
                {compaction.state === "compacting" ? "Compacting context…" : compaction.state === "completed" ? "Context compacted" : "Compaction ended without confirmed completion"}
              </span>
              {compaction.endedAt && <small>{new Date(compaction.endedAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" })}</small>}
            </>}
            <small>{!supportsCompaction ? "Compaction status is not available through this adapter."
              : usage?.autoCompactThreshold ? `Compaction is handled by ${provider}, which reports compacting automatically at ${tokens(usage.autoCompactThreshold)} tokens.`
              : `Compaction is handled by ${provider}. The exact automatic threshold is not reported.`}</small>
          </div>
        </Popover>
      )}
    </>
  );
}

function TokenRow({ title, field, usage, emphasized = false }: { title: string; field: keyof TokenCounts; usage: ConversationUsage; emphasized?: boolean }) {
  return (
    <tr style={{ fontWeight: emphasized ? 600 : 400 }}>
      <td>{title}</td><td>{tokens(usage.latest[field])}</td><td>{tokens(usage.session?.[field])}</td>
    </tr>
  );
}
