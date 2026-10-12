// The campaign funnel: assigned -> shown -> tapped -> redeemed. Four descending
// stages, one measure. Horizontal bars (widths relative to the top stage) with
// direct value labels and stage-to-stage conversion — a custom build keeps it
// crisp and readable on camera.
const STAGES = [
  { key: "assigned", label: "Assigned", hint: "treated audience (Iceberg)" },
  { key: "shown", label: "Shown", hint: "impressions (ClickHouse hot)" },
  { key: "tapped", label: "Tapped", hint: "taps (ClickHouse hot)" },
  { key: "redeemed", label: "Redeemed", hint: "redemptions (Iceberg)" },
];
const SHADE = ["#047857", "#059669", "#10b981", "#34d399"];

export default function FunnelChart({ data }) {
  const top = Math.max(data.assigned || 0, 1);
  return (
    <div className="space-y-2.5">
      {STAGES.map((s, i) => {
        const v = data[s.key] || 0;
        const w = Math.max((v / top) * 100, v > 0 ? 6 : 1.5);
        const prev = i > 0 ? data[STAGES[i - 1].key] || 0 : null;
        const conv = prev ? (prev > 0 ? Math.round((v / prev) * 100) : 0) : null;
        return (
          <div key={s.key}>
            <div className="mb-1 flex items-baseline justify-between text-xs">
              <span className="font-semibold text-ink-900">{s.label}</span>
              <span className="text-ink-400">{s.hint}</span>
            </div>
            <div className="flex items-center gap-3">
              <div className="h-9 flex-1 rounded-lg bg-slate-100">
                <div
                  className="flex h-9 items-center rounded-lg px-3 text-sm font-bold text-white transition-[width] duration-700"
                  style={{ width: `${w}%`, background: SHADE[i] }}
                >
                  {v.toLocaleString()}
                </div>
              </div>
              <div className="w-14 shrink-0 text-right text-xs text-ink-500">
                {conv != null ? `${conv}%` : ""}
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
}
