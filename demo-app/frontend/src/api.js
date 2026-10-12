// Thin API client. All calls hit the FastAPI backend (same origin in prod,
// proxied in dev). The backend does the real Kafka / ClickHouse / PGD work.

async function j(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}`);
  return res.json();
}

export const api = {
  status: () => j("GET", "/api/status"),
  catalog: () => j("GET", "/api/catalog"),
  hero: () => j("GET", "/api/hero"),
  emit: (ev) => j("POST", "/api/events", ev),
  decide: (session_id, member_id) => j("POST", "/api/decide", { session_id, member_id }),
  accept: (session_id, member_id) => j("POST", "/api/accept", { session_id, member_id }),
  redeem: (member_id) => j("POST", "/api/redeem", { member_id }),
  campaign: () => j("GET", "/api/campaign"),
  funnel: () => j("GET", "/api/funnel"),
  lift: () => j("GET", "/api/lift"),
};

// Category id -> emoji + accent, for storefront tiles (no real product images).
export const CATEGORY_META = {
  1: { emoji: "🥐", label: "Bakery" },
  2: { emoji: "🥬", label: "Produce" },
  3: { emoji: "🧀", label: "Dairy" },
  4: { emoji: "🧊", label: "Frozen" },
  5: { emoji: "🥤", label: "Beverages" },
  6: { emoji: "🍿", label: "Snacks" },
  7: { emoji: "🍨", label: "Chilled Desserts" },
  8: { emoji: "🍱", label: "Ready Meals" },
  9: { emoji: "🧻", label: "Household" },
  10: { emoji: "🧴", label: "Health & Beauty" },
  11: { emoji: "🐾", label: "Pet" },
  12: { emoji: "🍷", label: "Alcohol" },
};
