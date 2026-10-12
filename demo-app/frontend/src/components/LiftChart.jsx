import { useState } from "react";

const BRAND = "#059669";
const WEAK = "#d97706"; // amber status: the underperforming region

const pp = (v) => `${(v * 100).toFixed(1)}pp`;
const pct = (v) => `${(v * 100).toFixed(1)}%`;

// Single measure (lift) across regions, as a custom bar chart (no chart lib —
// crisp and reliable on camera). North is flagged with a status color + an
// explicit "weakest" note, never color alone; hover any bar for the detail.
export default function LiftChart({ rows }) {
  const data = [...rows].sort((a, b) => b.lift - a.lift);
  const max = Math.max(...data.map((d) => d.lift), 0.01);
  const weakest = data.reduce((m, r) => (r.lift < m.lift ? r : m), data[0]);
  const [hover, setHover] = useState(null);

  return (
    <div>
      <div className="relative flex h-56 items-end justify-around gap-3 px-1">
        {data.map((d) => {
          const isWeak = d.region === weakest?.region;
          const h = Math.max((d.lift / max) * 100, 3);
          return (
            <div
              key={d.region}
              className="group relative flex h-full flex-1 flex-col items-center justify-end"
              onMouseEnter={() => setHover(d.region)}
              onMouseLeave={() => setHover(null)}
            >
              <div className="mb-1 text-xs font-bold text-ink-700">+{pp(d.lift)}</div>
              <div
                className="w-full max-w-[64px] rounded-t-md transition-all duration-700"
                style={{ height: `${h}%`, background: isWeak ? WEAK : BRAND }}
              />
              {hover === d.region && (
                <div className="absolute bottom-full z-10 mb-1 w-40 rounded-xl bg-white p-3 text-xs shadow-card ring-1 ring-slate-200">
                  <div className="font-bold capitalize text-ink-900">{d.region}</div>
                  <div className="mt-1 grid grid-cols-2 gap-x-3 gap-y-0.5 text-ink-700">
                    <span>Lift</span><span className="text-right font-semibold">{pp(d.lift)}</span>
                    <span>Treated</span><span className="text-right">{pct(d.treated_redemption_rate)}</span>
                    <span>Control</span><span className="text-right">{pct(d.control_redemption_rate)}</span>
                    <span>Basket</span><span className="text-right">£{d.avg_basket_treated}</span>
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>
      <div className="mt-2 flex items-center justify-around gap-3 border-t border-slate-100 px-1 pt-2">
        {data.map((d) => (
          <div key={d.region} className="flex-1 text-center text-xs font-medium capitalize text-ink-500">
            {d.region}
          </div>
        ))}
      </div>
      <div className="mt-2 flex items-start gap-2 text-xs text-ink-500">
        <span className="mt-0.5 inline-block h-2.5 w-2.5 shrink-0 rounded-sm" style={{ background: WEAK }} />
        <span>
          <span className="capitalize">{weakest?.region}</span> is the weakest-responding region
          ({pp(weakest?.lift || 0)} vs {pp(data[0]?.lift || 0)} best) — a clear place to rework the creative.
        </span>
      </div>
    </div>
  );
}
