import { useState } from "react";

const ENGINE = {
  kafka: { label: "Kafka", cls: "bg-slate-800 text-white" },
  clickhouse: { label: "ClickHouse", cls: "bg-amber-500 text-white" },
  iceberg: { label: "Iceberg", cls: "bg-sky-600 text-white" },
  pgd: { label: "PGD", cls: "bg-brand-700 text-white" },
};

// A live "under the hood" feed so the webinar can SEE the pipeline fire as the
// shopper clicks. Fed a log of {engine, text, ts} entries from the storefront.
export default function TechDrawer({ log }) {
  const [open, setOpen] = useState(true);
  return (
    <div
      className={`fixed bottom-0 left-0 z-40 w-full max-w-sm transition-transform duration-300 ${
        open ? "translate-y-0" : "translate-y-[calc(100%-2.75rem)]"
      }`}
    >
      <div className="m-3 overflow-hidden rounded-2xl bg-white shadow-card ring-1 ring-slate-200">
        <button
          onClick={() => setOpen((v) => !v)}
          className="flex w-full items-center justify-between bg-ink-900 px-4 py-2.5 text-white"
        >
          <span className="flex items-center gap-2 text-sm font-semibold">
            <span className="h-2 w-2 animate-pulse rounded-full bg-brand-400" />
            Converged pipeline — live
          </span>
          <span className="text-ink-400">{open ? "▾" : "▴"}</span>
        </button>
        <div className="max-h-64 space-y-1.5 overflow-y-auto p-3">
          {log.length === 0 && (
            <div className="py-6 text-center text-xs text-ink-400">
              Browse the store — events will stream here.
            </div>
          )}
          {log.map((e, i) => {
            const eng = ENGINE[e.engine] || { label: e.engine, cls: "bg-slate-200 text-ink-700" };
            return (
              <div key={i} className="flex items-start gap-2 text-xs">
                <span
                  className={`mt-0.5 shrink-0 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ${eng.cls}`}
                >
                  {eng.label}
                </span>
                <span className="text-ink-700">{e.text}</span>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
