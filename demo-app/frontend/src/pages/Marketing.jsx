import { useEffect, useState, useCallback } from "react";
import Logo from "../components/Logo.jsx";
import FunnelChart from "../components/FunnelChart.jsx";
import LiftChart from "../components/LiftChart.jsx";
import { api } from "../api";

export default function Marketing() {
  const [campaign, setCampaign] = useState(null);
  const [funnel, setFunnel] = useState(null);
  const [lift, setLift] = useState([]);
  const [status, setStatus] = useState(null);
  const [updated, setUpdated] = useState(null);

  const load = useCallback(async () => {
    const [c, f, l, s] = await Promise.all([
      api.campaign(), api.funnel(), api.lift(), api.status(),
    ]);
    setCampaign(c); setFunnel(f); setLift(l.rows || []); setStatus(s);
    setUpdated(new Date());
  }, []);

  useEffect(() => {
    load().catch(console.error);
    const t = setInterval(() => load().catch(() => {}), 5000); // live during the demo
    return () => clearInterval(t);
  }, [load]);

  const redeemed = funnel?.redeemed || 0;
  const assigned = funnel?.assigned || 0;
  const committed = Math.round(assigned * 1.8);
  const budget = Number(campaign?.budget_total || 0);
  const best = lift.length ? [...lift].sort((a, b) => b.lift - a.lift)[0] : null;
  const worst = lift.length ? [...lift].sort((a, b) => a.lift - b.lift)[0] : null;

  return (
    <div className="min-h-screen bg-slate-100 pb-16">
      {/* header */}
      <header className="border-b border-slate-800 bg-ink-900 text-white">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center gap-4 px-5 py-4">
          <Logo dark />
          <div className="ml-1 border-l border-white/15 pl-4">
            <div className="text-[11px] font-semibold uppercase tracking-widest text-brand-300">
              Campaign Command Center
            </div>
            <div className="text-lg font-bold leading-tight">
              {campaign?.name || "Loading campaign…"}
            </div>
          </div>
          <div className="ml-auto flex items-center gap-3 text-xs text-ink-400">
            {campaign?.status && (
              <span className="rounded-full bg-brand-600/20 px-2.5 py-1 font-semibold text-brand-300">
                ● {campaign.status}
              </span>
            )}
            <span>
              updated {updated ? updated.toLocaleTimeString() : "…"}
              <span className="ml-2 inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-brand-400 align-middle" />
            </span>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-5">
        {/* KPI tiles */}
        <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Kpi label="Qualified audience" value={status?.qualified?.toLocaleString() ?? "—"}
            sub="propensity ≥ 0.5 · opted in" />
          <Kpi label="Redemptions" value={redeemed.toLocaleString()}
            sub="live from ClickHouse + Iceberg" accent />
          <Kpi label="Budget" value={`£${(budget / 1000).toFixed(0)}k`}
            sub={`£${committed.toLocaleString()} committed`} />
          <Kpi label="Best vs weakest lift"
            value={best ? `${(best.lift * 100).toFixed(1)} / ${(worst.lift * 100).toFixed(1)}pp` : "—"}
            sub={best ? `${best.region} vs ${worst.region}` : "run make lift"} />
        </div>

        <div className="mt-4 grid gap-4 lg:grid-cols-2">
          {/* funnel */}
          <Card title="Conversion funnel"
            source={[{ e: "clickhouse", t: "live hot tier" }, { e: "iceberg", t: "governed copy" }]}>
            {funnel ? <FunnelChart data={funnel} /> : <Empty />}
          </Card>

          {/* lift */}
          <Card title="Campaign lift by region"
            source={[{ e: "iceberg", t: "offer_lift_daily" }, { e: "pgd", t: "PGAA CTAS" }]}>
            {lift.length ? (
              <LiftChart rows={lift} />
            ) : (
              <div className="grid h-64 place-items-center text-sm text-ink-400">
                No lift yet — run <code className="mx-1 rounded bg-slate-100 px-1.5 py-0.5">make lift</code>
              </div>
            )}
          </Card>
        </div>

        {/* provenance strip */}
        <div className="mt-4 rounded-2xl bg-white p-4 text-xs text-ink-600 shadow-card ring-1 ring-slate-100">
          <span className="font-semibold text-ink-900">One copy, every engine.</span>{" "}
          Transactions and audience land once in <b>Apache Iceberg</b>; the funnel is served live by{" "}
          <b>ClickHouse</b> over its hot tier plus Iceberg, and the regional lift is written by{" "}
          <b>PGAA CTAS</b> and read back from the same governed tables — no copies to reconcile.
        </div>
      </main>
    </div>
  );
}

const ENGCLS = {
  clickhouse: "bg-amber-100 text-amber-700",
  iceberg: "bg-sky-100 text-sky-700",
  pgd: "bg-brand-100 text-brand-700",
};

function Card({ title, source, children }) {
  return (
    <div className="rounded-2xl bg-white p-5 shadow-card ring-1 ring-slate-100">
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-sm font-bold text-ink-900">{title}</h2>
        <div className="flex gap-1.5">
          {source.map((s) => (
            <span key={s.e} className={`rounded-full px-2 py-0.5 text-[10px] font-semibold ${ENGCLS[s.e]}`}>
              {s.t}
            </span>
          ))}
        </div>
      </div>
      {children}
    </div>
  );
}

function Kpi({ label, value, sub, accent }) {
  return (
    <div className={`rounded-2xl p-4 shadow-card ring-1 ${accent ? "bg-brand-600 text-white ring-brand-600" : "bg-white text-ink-900 ring-slate-100"}`}>
      <div className={`text-[11px] font-semibold uppercase tracking-wide ${accent ? "text-brand-100" : "text-ink-400"}`}>
        {label}
      </div>
      <div className="mt-1 text-2xl font-extrabold">{value}</div>
      <div className={`mt-0.5 text-[11px] ${accent ? "text-brand-50/80" : "text-ink-400"}`}>{sub}</div>
    </div>
  );
}

function Empty() {
  return <div className="grid h-48 place-items-center text-sm text-ink-400">Loading…</div>;
}
