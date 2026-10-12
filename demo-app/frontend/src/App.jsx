import { Outlet, NavLink, useLocation } from "react-router-dom";

// Shell: each page renders its own chrome; App only overlays the role switcher
// the demo operator uses to flip between the shopper and the marketing views.
function RolePill() {
  const base =
    "px-3.5 py-1.5 text-sm font-semibold rounded-full transition-colors";
  return (
    <div className="fixed top-3 right-3 z-50 flex items-center gap-1 rounded-full bg-white/90 backdrop-blur shadow-card ring-1 ring-slate-200 p-1">
      <span className="pl-2 pr-1 text-[11px] font-semibold uppercase tracking-wide text-ink-400">
        View
      </span>
      <NavLink
        to="/"
        className={({ isActive }) =>
          `${base} ${isActive ? "bg-brand-600 text-white shadow" : "text-ink-700 hover:bg-slate-100"}`
        }
      >
        🛒 Shopper
      </NavLink>
      <NavLink
        to="/marketing"
        className={({ isActive }) =>
          `${base} ${isActive ? "bg-ink-900 text-white shadow" : "text-ink-700 hover:bg-slate-100"}`
        }
      >
        📊 Marketing
      </NavLink>
    </div>
  );
}

export default function App() {
  useLocation(); // re-render on route change for the pill active state
  return (
    <>
      <RolePill />
      <Outlet />
    </>
  );
}
