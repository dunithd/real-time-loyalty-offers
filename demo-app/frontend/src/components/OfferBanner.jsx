import { useState } from "react";

// The personalized offer the live decision produced. Shows the headline plus an
// optional "why?" panel with the REAL decision_reason and measured latency.
export default function OfferBanner({ offer, onApply, applied }) {
  const [why, setWhy] = useState(false);
  const r = offer.decision_reason || {};
  const factors = [
    { label: "Live intent", value: r.intent, hint: "from your session, in ClickHouse" },
    { label: "Category affinity", value: r.propensity, hint: "2 yrs of history, from Iceberg" },
    { label: "Price-sensitivity boost", value: r.price_bonus, hint: "you sorted by price" },
  ];
  return (
    <div className="animate-offer overflow-hidden rounded-2xl bg-gradient-to-br from-brand-600 to-brand-700 text-white shadow-card">
      <div className="flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-start gap-4">
          <div className="animate-pulsering grid h-14 w-14 shrink-0 place-items-center rounded-2xl bg-white/15 text-3xl">
            🍨
          </div>
          <div>
            <div className="text-[11px] font-bold uppercase tracking-wider text-brand-100">
              Picked for you · just now
            </div>
            <div className="mt-0.5 text-xl font-extrabold leading-tight">
              {offer.offer_name}
            </div>
            <div className="mt-1 text-sm text-brand-50/90">
              A personal reward on the aisle you love — decided in{" "}
              <span className="font-semibold">{offer.latency_ms} ms</span>.
            </div>
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <button
            onClick={() => setWhy((v) => !v)}
            className="rounded-xl bg-white/10 px-3 py-2.5 text-sm font-semibold text-white ring-1 ring-white/25 transition hover:bg-white/20"
          >
            Why this?
          </button>
          <button
            onClick={onApply}
            disabled={applied}
            className="rounded-xl bg-white px-4 py-2.5 text-sm font-bold text-brand-700 shadow transition hover:bg-brand-50 active:scale-95 disabled:opacity-70"
          >
            {applied ? "✓ Applied" : "Apply offer"}
          </button>
        </div>
      </div>

      {why && (
        <div className="border-t border-white/15 bg-black/10 px-5 py-4">
          <div className="grid gap-3 sm:grid-cols-3">
            {factors.map((f) => (
              <div key={f.label} className="rounded-xl bg-white/10 p-3">
                <div className="text-[11px] font-semibold uppercase tracking-wide text-brand-100">
                  {f.label}
                </div>
                <div className="mt-0.5 text-lg font-bold">
                  {f.value != null ? Number(f.value).toFixed(2) : "—"}
                </div>
                <div className="text-[11px] text-brand-50/80">{f.hint}</div>
              </div>
            ))}
          </div>
          <div className="mt-3 text-[11px] text-brand-50/80">
            One query in ClickHouse combined your live session with the governed
            audience and guardrails in Iceberg, then recorded the decision back to
            Postgres. Budget remaining: £{r.budget_left?.toLocaleString?.() ?? r.budget_left}.
          </div>
        </div>
      )}
    </div>
  );
}
