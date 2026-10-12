import { CATEGORY_META } from "../api";

export default function ProductCard({ product, onView, onAdd, highlight }) {
  const meta = CATEGORY_META[product.category_id] || { emoji: "🛍️" };
  return (
    <div
      className={`group relative flex flex-col rounded-2xl bg-white p-3 shadow-card ring-1 transition
        ${highlight ? "ring-brand-300" : "ring-slate-100 hover:ring-brand-200"}`}
    >
      {highlight && (
        <span className="absolute left-3 top-3 z-10 rounded-full bg-brand-600 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-white">
          Featured
        </span>
      )}
      <button
        onClick={() => onView(product)}
        className="flex aspect-[4/3] items-center justify-center rounded-xl bg-gradient-to-br from-slate-50 to-slate-100 text-5xl transition group-hover:scale-[1.03]"
        aria-label={`View ${product.name}`}
      >
        <span>{meta.emoji}</span>
      </button>
      <div className="mt-2.5 flex-1">
        <div className="text-[13px] font-semibold leading-snug text-ink-900 line-clamp-2">
          {product.name}
        </div>
        <div className="mt-0.5 text-[11px] text-ink-400">{meta.label}</div>
      </div>
      <div className="mt-2 flex items-center justify-between">
        <span className="text-sm font-bold text-ink-900">
          £{Number(product.price).toFixed(2)}
        </span>
        <button
          onClick={() => onAdd(product)}
          className="rounded-lg bg-brand-600 px-2.5 py-1.5 text-xs font-semibold text-white transition hover:bg-brand-700 active:scale-95"
        >
          Add
        </button>
      </div>
    </div>
  );
}
