import { useEffect, useMemo, useState } from "react";
import { api, CATEGORY_META } from "../api";
import Logo from "../components/Logo.jsx";
import ProductCard from "../components/ProductCard.jsx";
import OfferBanner from "../components/OfferBanner.jsx";
import TechDrawer from "../components/TechDrawer.jsx";

const DESSERT = 7;

export default function Storefront() {
  const [hero, setHero] = useState(null);
  const [catalog, setCatalog] = useState({ categories: [], products: [] });
  const [status, setStatus] = useState(null);
  const [session] = useState(() => `sess-hero-${Date.now()}`);
  const [cat, setCat] = useState(DESSERT); // start on the desserts aisle
  const [sortPrice, setSortPrice] = useState(false);
  const [cart, setCart] = useState([]);
  const [phase, setPhase] = useState("browsing"); // browsing|deciding|offer|redeemed
  const [offer, setOffer] = useState(null);
  const [assignment, setAssignment] = useState(null);
  const [redemption, setRedemption] = useState(null);
  const [log, setLog] = useState([]);

  const member = hero?.member_id;
  const addLog = (engine, text) => setLog((l) => [...l, { engine, text }]);

  useEffect(() => {
    (async () => {
      const [h, c, s] = await Promise.all([api.hero(), api.catalog(), api.status()]);
      setHero(h); setCatalog(c); setStatus(s);
      await api.emit({ session_id: session, member_id: h.member_id, event_type: "session_start" });
      addLog("kafka", `session_start → ${s.audience_ready ? "audience ready" : "no audience — run make audience"}`);
    })().catch(console.error);
  }, [session]);

  const products = useMemo(() => {
    let list = catalog.products.filter((p) => cat === 0 || p.category_id === cat);
    if (sortPrice) list = [...list].sort((a, b) => a.price - b.price);
    return list;
  }, [catalog, cat, sortPrice]);

  async function viewProduct(p) {
    await api.emit({ session_id: session, member_id: member, event_type: "product_view",
      product_id: p.product_id, category_id: p.category_id });
    addLog("kafka", `product_view · ${p.name}`);
  }

  async function addToCart(p) {
    setCart((c) => [...c, p]);
    await api.emit({ session_id: session, member_id: member, event_type: "add_to_cart",
      product_id: p.product_id, category_id: p.category_id });
    addLog("kafka", `add_to_cart · ${p.name}`);
    if (p.category_id === DESSERT && !offer && phase === "browsing") {
      runDecide();
    }
  }

  async function toggleSort() {
    const next = !sortPrice;
    setSortPrice(next);
    if (next) {
      await api.emit({ session_id: session, member_id: member, event_type: "sort_by_price", category_id: cat });
      addLog("kafka", "sort_by_price · price-sensitive signal");
    }
  }

  async function runDecide() {
    setPhase("deciding");
    addLog("clickhouse", "one query: live session (hot) + audience + guardrails (Iceberg)…");
    try {
      const { offer: o } = await api.decide(session, member);
      if (o) {
        setOffer(o); setPhase("offer");
        addLog("clickhouse", `ranked → ${o.offer_name} · score ${o.score} · ${o.latency_ms} ms`);
      } else {
        setPhase("browsing");
        addLog("clickhouse", "no offer (not in audience / capped / budget)");
      }
    } catch (e) { setPhase("browsing"); addLog("clickhouse", "decide error"); }
  }

  async function applyOffer() {
    const { assignment: a } = await api.accept(session, member);
    setAssignment(a);
    addLog("pgd", `decision recorded → offer_assignments (${a.assignment_id.slice(0, 8)}…)`);
    addLog("kafka", "impression + tap → engagement topic");
  }

  async function redeem() {
    const { redemption: r } = await api.redeem(member);
    setRedemption(r); setPhase("redeemed");
    addLog("pgd", `redeemed in one txn → order, redemption, points (£${r.discount_amount} off)`);
  }

  const subtotal = cart.reduce((s, p) => s + Number(p.price), 0);
  const discount = assignment ? +(subtotal * 0.2).toFixed(2) : 0;

  return (
    <div className="min-h-screen bg-dot pb-32">
      {/* header */}
      <header className="sticky top-0 z-30 border-b border-slate-200 bg-white/85 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center gap-4 px-4 py-3">
          <Logo />
          <div className="relative hidden flex-1 sm:block">
            <input
              className="w-full rounded-xl bg-slate-100 py-2 pl-9 pr-3 text-sm outline-none ring-1 ring-transparent focus:bg-white focus:ring-brand-300"
              placeholder="Search Kestrel Market…"
            />
            <span className="pointer-events-none absolute left-3 top-2.5 text-ink-400">🔍</span>
          </div>
          <button
            onClick={toggleSort}
            className={`rounded-xl px-3 py-2 text-sm font-semibold ring-1 transition ${
              sortPrice ? "bg-brand-50 text-brand-700 ring-brand-300" : "text-ink-700 ring-slate-200 hover:bg-slate-50"
            }`}
          >
            ↕ Price
          </button>
          {hero && (
            <div className="flex items-center gap-2 rounded-xl bg-slate-100 py-1.5 pl-1.5 pr-3">
              <span className="grid h-7 w-7 place-items-center rounded-lg bg-brand-600 text-sm font-bold text-white">
                {hero.name.split(" ").map((n) => n[0]).join("")}
              </span>
              <div className="leading-tight">
                <div className="text-xs font-semibold text-ink-900">{hero.name}</div>
                <div className="text-[10px] uppercase tracking-wide text-ink-400">
                  {hero.tier} · {hero.region}
                </div>
              </div>
            </div>
          )}
          <div className="relative grid h-10 w-10 place-items-center rounded-xl bg-slate-100">
            🛒
            {cart.length > 0 && (
              <span className="absolute -right-1 -top-1 grid h-5 w-5 place-items-center rounded-full bg-brand-600 text-[10px] font-bold text-white">
                {cart.length}
              </span>
            )}
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-4">
        {/* hero banner */}
        <div className="mt-5 overflow-hidden rounded-3xl bg-gradient-to-br from-brand-700 via-brand-600 to-brand-500 p-6 text-white sm:p-8">
          <div className="max-w-lg">
            <div className="text-[11px] font-bold uppercase tracking-widest text-brand-100">
              Chilled & delicious
            </div>
            <h1 className="mt-1 text-3xl font-extrabold leading-tight sm:text-4xl">
              The dessert aisle, personalised to you.
            </h1>
            <p className="mt-2 text-sm text-brand-50/90">
              Add a treat to your basket — rewards you’ll actually use appear in real time.
            </p>
          </div>
        </div>

        {/* offer / deciding slot */}
        <div className="mt-5">
          {phase === "deciding" && (
            <div className="flex items-center gap-3 rounded-2xl bg-white p-5 shadow-card ring-1 ring-slate-100">
              <span className="h-5 w-5 animate-spin rounded-full border-2 border-brand-200 border-t-brand-600" />
              <span className="text-sm font-medium text-ink-700">
                Finding a reward for your basket…
              </span>
            </div>
          )}
          {offer && phase !== "redeemed" && (
            <OfferBanner offer={offer} onApply={applyOffer} applied={!!assignment} />
          )}
          {phase === "redeemed" && redemption && (
            <div className="animate-offer rounded-2xl bg-white p-6 shadow-card ring-1 ring-brand-200">
              <div className="flex items-center gap-4">
                <div className="grid h-14 w-14 place-items-center rounded-2xl bg-brand-50 text-3xl">✅</div>
                <div>
                  <div className="text-xl font-extrabold text-ink-900">Order placed — reward redeemed</div>
                  <div className="mt-1 text-sm text-ink-700">
                    You saved <span className="font-bold text-brand-700">£{redemption.discount_amount}</span> and
                    earned <span className="font-bold text-brand-700">{redemption.points} points</span>. One PGD
                    transaction: order → redemption → points ledger.
                  </div>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* category chips */}
        <div className="mt-6 flex gap-2 overflow-x-auto pb-1">
          <Chip active={cat === 0} onClick={() => setCat(0)}>All</Chip>
          {catalog.categories.map((c) => (
            <Chip key={c.category_id} active={cat === c.category_id} onClick={() => setCat(c.category_id)}>
              {CATEGORY_META[c.category_id]?.emoji} {CATEGORY_META[c.category_id]?.label || c.name}
            </Chip>
          ))}
        </div>

        {/* product grid */}
        <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
          {products.map((p) => (
            <ProductCard key={p.product_id} product={p} onView={viewProduct} onAdd={addToCart}
              highlight={p.category_id === DESSERT} />
          ))}
        </div>

        {/* cart / checkout */}
        {cart.length > 0 && (
          <div className="sticky bottom-4 z-20 mt-8">
            <div className="mx-auto flex max-w-2xl items-center justify-between gap-4 rounded-2xl bg-ink-900 px-5 py-3.5 text-white shadow-card">
              <div className="text-sm">
                <span className="font-semibold">{cart.length} item{cart.length > 1 ? "s" : ""}</span>
                <span className="mx-2 text-ink-400">·</span>
                <span>Subtotal £{subtotal.toFixed(2)}</span>
                {discount > 0 && (
                  <span className="ml-2 text-brand-300">− £{discount.toFixed(2)} offer</span>
                )}
              </div>
              {phase === "redeemed" ? (
                <span className="rounded-xl bg-brand-600 px-4 py-2 text-sm font-bold">Completed ✓</span>
              ) : (
                <button
                  onClick={assignment ? redeem : runDecide}
                  className="rounded-xl bg-brand-500 px-4 py-2 text-sm font-bold text-ink-900 transition hover:bg-brand-400 active:scale-95"
                >
                  {assignment ? "Checkout & redeem" : "Checkout"}
                </button>
              )}
            </div>
          </div>
        )}
      </main>

      <TechDrawer log={log} />
    </div>
  );
}

function Chip({ active, onClick, children }) {
  return (
    <button
      onClick={onClick}
      className={`whitespace-nowrap rounded-full px-3.5 py-1.5 text-sm font-semibold ring-1 transition ${
        active ? "bg-ink-900 text-white ring-ink-900" : "bg-white text-ink-700 ring-slate-200 hover:bg-slate-50"
      }`}
    >
      {children}
    </button>
  );
}
