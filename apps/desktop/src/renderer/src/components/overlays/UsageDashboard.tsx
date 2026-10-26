import { useEffect, useMemo, useState } from "react";
import { ChartLine, RotateCw, X } from "lucide-react";
import { harnessTitle, type HarnessID } from "@octo/core";
import { summarizeUsage, type UsageRecord, type UsageSummary } from "@octo/agents/model";
import { useApp } from "../../state/app";
import { useUI } from "../../state/ui";
import { call, run } from "../../bridge";
import { cx, EmptyState, HoverButton, Spinner } from "../controls";
import { ProviderIcon } from "../ProviderIcon";
import { Sheet } from "./Sheet";
import { UsageWindowRow, usageKey, usageThread } from "./AccountUsage";
import styles from "./overlays.module.css";

type Page = "Tokens" | "Limits";
type Range = "Past 24h" | "7 days" | "30 days" | "90 days";
const RANGES: Range[] = ["Past 24h", "7 days", "30 days", "90 days"];

function interval(range: Range, now = Date.now()): { start: number; end: number } {
  if (range === "Past 24h") return { start: now - 86_400_000, end: now };
  const days = range === "7 days" ? 7 : range === "30 days" ? 30 : 90;
  const start = new Date(now); start.setHours(0, 0, 0, 0); start.setDate(start.getDate() + 1 - days);
  return { start: start.getTime(), end: now };
}

/** Three significant digits with K/M/B suffixes, matching compact dashboard totals. */
export function formatTokens(value: number): string {
  const unit = ([[1e9, "B"], [1e6, "M"], [1e3, "K"]] as const).find(([size]) => value >= size);
  if (!unit) return String(value);
  const scaled = value / unit[0];
  return `${Number(scaled.toFixed(scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2))}${unit[1]}`;
}
const percent = (share: number) => `${(share * 100).toFixed(share >= 0.1 || share === 0 ? 1 : 2)}%`;
const providerColor = (provider: HarnessID) => provider === "claude" ? "var(--orange)" : "color-mix(in srgb, var(--foreground) 85%, transparent)";

/** Token usage from the CLIs' local session logs, and the account limits reported to this session. */
export function UsageDashboard() {
  const [page, setPage] = useState<Page>("Tokens");
  const [range, setRange] = useState<Range>("30 days");
  const [summary, setSummary] = useState<UsageSummary>();
  const [loading, setLoading] = useState(false), [reload, setReload] = useState(0), [error, setError] = useState<string>();
  const close = () => useUI.setState({ usageDashboard: false });

  useEffect(() => {
    let active = true;
    const span = interval(range);
    setLoading(true); setError(undefined);
    void call("app", "usageRecords", span.start)
      .then((records: UsageRecord[]) => { if (active) setSummary(summarizeUsage(records, span)); })
      .catch((failure) => { if (active) setError(String(failure instanceof Error ? failure.message : failure)); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [range, reload]);

  const day = (ms: number) => new Date(ms).toLocaleDateString(undefined, { month: "short", day: "numeric" });
  return (
    <Sheet label="Usage" className={styles.dashboardSheet} close={close}>
      <header className={styles.dashboardHeader}>
        <span className={styles.secondary}>Usage</span><span className={styles.secondary}>/</span><span>All providers</span>
        {summary && <small>{day(summary.interval.start)} to {day(summary.interval.end)}</small>}
        <span className={styles.spacer} />
        {(["Tokens", "Limits"] as Page[]).map((item) => (
          <HoverButton key={item} aria-pressed={page === item} className={cx(styles.headerChoice, page === item && styles.chosen)} onClick={() => setPage(item)}>{item}</HoverButton>
        ))}
        <i className={styles.headerDivider} />
        {RANGES.map((item) => (
          <HoverButton key={item} aria-pressed={range === item} disabled={page === "Limits"} className={cx(styles.headerChoice, range === item && styles.chosen)} onClick={() => setRange(item)}>{item}</HoverButton>
        ))}
        <HoverButton aria-label="Refresh usage" help="Re-read session logs" disabled={loading} onClick={() => setReload((n) => n + 1)}><RotateCw size={14} /></HoverButton>
        <span style={{ opacity: loading ? 1 : 0 }}><Spinner /></span>
        <HoverButton aria-label="Close usage" help="Close" onClick={close}><X size={14} /></HoverButton>
      </header>
      <div className={styles.dashboardBody}>
        <div className={styles.dashboardContent}>
          {page === "Limits" ? <Limits />
            : error ? <p className={styles.error}>{error}</p>
            : !summary ? <div className={styles.centered}><Spinner /><span>Reading local session logs…</span></div>
            : <Tokens summary={summary} />}
        </div>
      </div>
    </Sheet>
  );
}

function Tokens({ summary }: { summary: UsageSummary }) {
  const [breakdown, setBreakdown] = useState<"Model" | "Day">("Model");
  if (summary.total === 0) {
    return <EmptyState icon={<ChartLine size={32} strokeWidth={1.4} />} title="No token usage in this range" description="Usage is read from local Codex and Claude Code session logs on this Mac." />;
  }
  const rows = breakdown === "Model" ? summary.models : summary.days;
  return (
    <div className={styles.tokens}>
      <div className={styles.overview}>
        <div className={styles.providers}>
          <div><div className={styles.bigTotal}>{formatTokens(summary.total)}</div><span className={styles.secondary}>{summary.sessions} sessions</span></div>
          {summary.providers.map((provider) => (
            <div key={provider.id} className={styles.providerRow}>
              <div><i className={styles.dot} style={{ background: providerColor(provider.id) }} /><span>{harnessTitle(provider.id)}</span>
                <small>{provider.sessions} sessions</small><span className={styles.spacer} /><span>{formatTokens(provider.tokens)}</span></div>
              <small className={styles.share}>{percent(provider.tokens / summary.total)} of tokens</small>
            </div>
          ))}
        </div>
        <div className={styles.chartColumn}>
          <h3>{summary.hourly ? "Hourly processed tokens" : "Daily processed tokens"}</h3>
          <UsageChart summary={summary} />
        </div>
      </div>
      <section>
        <h3>Totals</h3>
        <div className={styles.stats}>
          {([["Processed tokens", summary.total], ["Cached input", summary.cachedInput], ["Cache writes", summary.cacheWrite], ["Uncached input", summary.uncachedInput], ["Output", summary.output]] as const)
            .map(([title, value]) => <div key={title}><small>{title}</small><span>{formatTokens(value)}</span></div>)}
        </div>
      </section>
      <section>
        <div className={styles.breakdownHeader}>
          <h3>Breakdown</h3><span className={styles.spacer} />
          {(["Model", "Day"] as const).map((item) => (
            <HoverButton key={item} aria-pressed={breakdown === item} className={cx(styles.headerChoice, breakdown === item && styles.chosen)} onClick={() => setBreakdown(item)}>{item}</HoverButton>
          ))}
        </div>
        <table className={styles.breakdown}>
          <thead><tr><th>{breakdown}</th><th>Share</th><th>Tokens</th></tr></thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id}>
                <td>{row.provider && <i className={styles.dot} title={harnessTitle(row.provider)} style={{ background: providerColor(row.provider) }} />}
                  {row.date !== undefined ? new Date(row.date).toLocaleDateString(undefined, { dateStyle: "medium" }) : row.title}</td>
                <td>{percent(row.share)}</td><td>{formatTokens(row.tokens)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
      <small className={styles.secondary}>Counted from local Codex and Claude Code session logs on this Mac, including sessions outside Octo. Costs are not estimated.</small>
    </div>
  );
}

/** Area and line marks per provider, with a hover rule listing each provider's tokens. */
function UsageChart({ summary }: { summary: UsageSummary }) {
  const [hover, setHover] = useState<number>();
  const providers = summary.providers.map((p) => p.id);
  const starts = useMemo(() => [...new Set(summary.series.map((p) => p.start))].sort((a, b) => a - b), [summary]);
  const max = Math.max(1, ...summary.series.map((p) => p.tokens));
  const width = 640, height = 280, left = 52, bottom = 24, plotWidth = width - left - 8, plotHeight = height - bottom - 8;
  const x = (index: number) => left + (starts.length < 2 ? plotWidth / 2 : (index / (starts.length - 1)) * plotWidth);
  const y = (tokens: number) => 8 + plotHeight - (tokens / max) * plotHeight;
  const label = (ms: number) => summary.hourly ? new Date(ms).toLocaleTimeString(undefined, { hour: "numeric" }) : new Date(ms).toLocaleDateString(undefined, { month: "short", day: "numeric" }).toUpperCase();
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => Math.round(max * f));
  const labels = starts.length <= 5 ? starts.map((_, i) => i) : [0, 1, 2, 3, 4].map((i) => Math.round((i / 4) * (starts.length - 1)));
  return (
    <svg className={styles.chart} viewBox={`0 0 ${width} ${height}`} role="img" aria-label={summary.hourly ? "Hourly processed tokens by provider" : "Daily processed tokens by provider"}
      onPointerMove={(e) => {
        const r = e.currentTarget.getBoundingClientRect(), px = ((e.clientX - r.left) / r.width) * width;
        setHover(Math.max(0, Math.min(starts.length - 1, Math.round(((px - left) / plotWidth) * (starts.length - 1)))));
      }} onPointerLeave={() => setHover(undefined)}>
      {ticks.map((tick) => <g key={tick}><line x1={left} x2={width - 8} y1={y(tick)} y2={y(tick)} className={styles.gridLine} /><text x={left - 6} y={y(tick) + 4} textAnchor="end" className={styles.axis}>{formatTokens(tick)}</text></g>)}
      {labels.map((i) => <text key={i} x={x(i)} y={height - 6} textAnchor="middle" className={styles.axis}>{label(starts[i])}</text>)}
      {providers.map((provider) => {
        const points = starts.map((start, i) => [x(i), y(summary.series.find((p) => p.start === start && p.provider === provider)?.tokens ?? 0)] as const);
        const line = points.map(([px, py], i) => `${i ? "L" : "M"}${px},${py}`).join(" ");
        return <g key={provider} style={{ color: providerColor(provider) }}>
          <path d={`${line} L${points.at(-1)![0]},${y(0)} L${points[0][0]},${y(0)} Z`} fill="currentColor" opacity={0.22} />
          <path d={line} fill="none" stroke="currentColor" strokeWidth={2} strokeLinejoin="round" />
        </g>;
      })}
      {hover !== undefined && starts[hover] !== undefined && (() => {
        const hx = x(hover), boxX = Math.min(Math.max(hx - 70, left), width - 148);
        return <g>
          <line x1={hx} x2={hx} y1={8} y2={y(0)} className={styles.chartRule} />
          <rect x={boxX} y={10} width={140} height={22 + providers.length * 16} rx={6} className={styles.tooltipBox} />
          <text x={boxX + 8} y={26} className={styles.tooltipTitle}>{summary.hourly ? new Date(starts[hover]).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric" }) : new Date(starts[hover]).toLocaleDateString(undefined, { month: "short", day: "numeric" })}</text>
          {providers.map((provider, i) => (
            <text key={provider} x={boxX + 8} y={42 + i * 16} className={styles.tooltipText}>
              {harnessTitle(provider)} {formatTokens(summary.series.find((p) => p.start === starts[hover] && p.provider === provider)?.tokens ?? 0)}
            </text>
          ))}
        </g>;
      })()}
    </svg>
  );
}

/** Latest account limits per provider already reported to this app session. */
function Limits() {
  const data = useApp((s) => ({ descriptors: s.descriptors, snapshots: s.usageSnapshots, errors: s.usageErrors, loading: s.loadingUsage, state: s }));
  const latest = new Map<string, (typeof data.snapshots)[string]>();
  for (const [key, usage] of Object.entries(data.snapshots)) {
    const provider = key.split(":")[0];
    if (!latest.has(provider) || latest.get(provider)!.fetchedAt < usage.fetchedAt) latest.set(provider, usage);
  }
  return (
    <div className={styles.limits}>
      {data.descriptors.map((descriptor) => {
        const usage = latest.get(descriptor.id), thread = usageThread(data.state, descriptor.id), key = thread && usageKey(thread);
        return (
          <section key={descriptor.id}>
            <div className={styles.limitsHeader}>
              <ProviderIcon harness={descriptor.id} size={18} /><h3>{harnessTitle(descriptor.id)}</h3><span className={styles.spacer} />
              {usage && <small>{descriptor.supportsUsageRefresh ? "Updated" : "Reported"} {new Date(usage.fetchedAt).toLocaleTimeString(undefined, { timeStyle: "short" })}</small>}
              {descriptor.supportsUsageRefresh && thread && (
                <HoverButton aria-label={`Refresh ${harnessTitle(descriptor.id)} limits`} help={`Refresh ${harnessTitle(descriptor.id)} limits`}
                  disabled={!!key && data.loading.includes(key)} onClick={() => run("store", "loadUsage", descriptor.id)}><RotateCw size={14} /></HoverButton>
              )}
            </div>
            {!descriptor.supportsUsageLimits ? <p className={styles.secondary}>Account limits are not exposed by this adapter.</p>
              : usage ? usage.buckets.map((bucket) => (
                  <div key={bucket.id} className={styles.limitBucket}><strong>{bucket.title}</strong>{bucket.windows.map((w) => <UsageWindowRow key={w.id} window={w} />)}</div>
                ))
              : <p className={styles.secondary}>{descriptor.supportsUsageRefresh ? "Limits have not been loaded yet. Use refresh to read them from the CLI."
                  : `${harnessTitle(descriptor.id)} reports limits alongside responses. They appear here after the next response in any ${harnessTitle(descriptor.id)} chat.`}</p>}
            {key && data.errors[key] && <p className={styles.secondary}>{data.errors[key]}</p>}
          </section>
        );
      })}
    </div>
  );
}
