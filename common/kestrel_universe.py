"""Kestrel Market — the deterministic data universe.

Single source of truth for the id spaces and the built-in signal, imported by
BOTH the PGD seeder (verifier/seed.py) and the live event generator
(event-generator/generator.py) so the two never disagree about which member,
product or category ids exist.

Everything here is a pure function of the ids and the fixed seed — no randomness
that isn't seeded — so regeneration produces identical data (CLAUDE.md:
"Fixed random seed; regeneration must produce identical data.").

Built-in signal (CLAUDE.md "Synthetic data"):
  * a "dessert lover" member segment with strong chilled_desserts affinity;
  * the north region responding less to the campaign;
  * a fixed hero shopper + hero campaign, every scene uses the same pair.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass

# ── Fixed dimensions ─────────────────────────────────────────────────────────

REGIONS = ["north", "midlands", "south", "london"]
CHANNELS = ["store", "app", "web"]
TIERS = ["bronze", "silver", "gold"]

# 12 categories; chilled_desserts is the hero category.
CATEGORY_NAMES = [
    "bakery", "produce", "dairy", "frozen", "beverages", "snacks",
    "chilled_desserts", "ready_meals", "household", "health_beauty",
    "pet", "alcohol",
]
DESSERT_CATEGORY_ID = CATEGORY_NAMES.index("chilled_desserts") + 1  # => 7

# Member ids are 100000-based so the hero id (100042) sits inside the range.
MEMBER_ID_BASE = 100000

# Hero shopper + campaign (mirrors demo-config.toml [hero]). Kept here too so the
# generator can inject the hero session without parsing the toml.
HERO_MEMBER_ID = 100042
HERO_SESSION_ID = "sess-hero-0001"
HERO_OFFER_ID = 1


# ── Deterministic helpers ────────────────────────────────────────────────────

def _hash_unit(*parts: object) -> float:
    """A stable float in [0,1) from the given parts (seeded hash, not RNG state).

    Used wherever a decision must be reproducible across independent processes
    (seeder vs generator) and across reruns — e.g. the control-group split.
    """
    h = hashlib.sha256("|".join(str(p) for p in parts).encode()).hexdigest()
    return int(h[:15], 16) / float(16**15)


def member_ids(n_members: int) -> range:
    return range(MEMBER_ID_BASE, MEMBER_ID_BASE + n_members)


def member_index(member_id: int) -> int:
    return member_id - MEMBER_ID_BASE


# ── Dimension builders ───────────────────────────────────────────────────────

def categories() -> list[tuple[int, str]]:
    return [(i + 1, name) for i, name in enumerate(CATEGORY_NAMES)]


def stores(n_stores: int) -> list[tuple[int, str, str]]:
    """(store_id, name, region). Regions round-robin so each has n/4 stores."""
    out = []
    for s in range(1, n_stores + 1):
        region = REGIONS[(s - 1) % len(REGIONS)]
        out.append((s, f"Kestrel {region.title()} #{s:02d}", region))
    return out


def products(n_products: int) -> list[tuple[int, str, int, float]]:
    """(product_id, name, category_id, price)."""
    out = []
    for p in range(1, n_products + 1):
        category_id = ((p - 1) % len(CATEGORY_NAMES)) + 1
        cat = CATEGORY_NAMES[category_id - 1]
        # chilled_desserts priced a touch higher; everything in a sane range.
        base = 3.5 if category_id == DESSERT_CATEGORY_ID else 1.0
        price = round(base + (p % 50) * 0.20, 2)
        out.append((p, f"{cat.replace('_', ' ').title()} {p}", category_id, price))
    return out


@dataclass(frozen=True)
class Member:
    member_id: int
    tier: str
    home_store_id: int
    region: str
    marketing_opt_in: bool
    is_dessert_lover: bool


def member(member_id: int, n_stores: int) -> Member:
    i = member_index(member_id)
    # Region must be INDEPENDENT of the dessert-lover segment (i % 4 == 2), or the
    # whole audience lands in one region and the regional lift has nothing to
    # compare. Using i // 4 spreads lovers evenly across all four regions.
    region = REGIONS[(i // 4) % len(REGIONS)]
    # a store in the member's region (regions are stores s where (s-1)%4 == idx)
    region_idx = REGIONS.index(region)
    region_stores = [s for s in range(1, n_stores + 1) if (s - 1) % len(REGIONS) == region_idx]
    home_store_id = region_stores[i % len(region_stores)]
    tier = TIERS[0] if i % 10 <= 5 else (TIERS[1] if i % 10 <= 8 else TIERS[2])
    marketing_opt_in = (i % 5 != 0)          # ~80% opted in
    is_dessert_lover = (i % 4 == 2)          # ~25% of members; hero (idx 42) qualifies
    return Member(member_id, tier, home_store_id, region, marketing_opt_in, is_dessert_lover)


def members(n_members: int, n_stores: int) -> list[Member]:
    out = [member(mid, n_stores) for mid in member_ids(n_members)]
    # Guarantee the hero is exactly as the narrative needs: dessert lover, opted
    # in, non-north region. (idx 42 already satisfies all three; assert to be safe.)
    hero = next(m for m in out if m.member_id == HERO_MEMBER_ID)
    assert hero.is_dessert_lover and hero.marketing_opt_in and hero.region != "north", hero
    return out


# ── Signal parameters ────────────────────────────────────────────────────────

def dessert_share(is_dessert_lover: bool) -> float:
    """Fraction of a member's order lines that are chilled_desserts."""
    return 0.45 if is_dessert_lover else 0.04


def orders_per_member(member_id: int, history_years: int) -> int:
    """Deterministic order count over the history window (~20 avg for 3 years)."""
    u = _hash_unit("orders", member_id)
    per_year = 3 + int(u * 11)          # 3..13 orders/year
    return per_year * history_years


def is_control(member_id: int, offer_id: int, holdout_pct: float) -> bool:
    """Seeded holdout split — reproducible across seeder and any rerun."""
    return _hash_unit("control", offer_id, member_id) < (holdout_pct / 100.0)


def qualifies_for_dessert_offer(m: Member, threshold: float = 0.5) -> bool:
    """Audience gate used to pre-seed assignments: dessert propensity >= threshold
    AND opted in. Propensity here mirrors what WHPG computes in Phase 2."""
    return m.marketing_opt_in and dessert_propensity(m) >= threshold


def dessert_propensity(m: Member) -> float:
    """A 0..1 chilled_desserts propensity, deterministic per member. Dessert
    lovers land high; others low. Phase 2's WHPG query computes the real thing
    from order history — this is the seed-side twin used for pre-seeded data."""
    base = 0.72 if m.is_dessert_lover else 0.18
    jitter = (_hash_unit("prop", m.member_id) - 0.5) * 0.2
    return max(0.0, min(1.0, base + jitter))


def north_is_weaker(region: str) -> float:
    """Treated redemption rate by region for the pre-seeded lift population.
    North visibly weaker (CLAUDE.md: "The seed data must make the north region
    visibly weaker")."""
    return 0.08 if region == "north" else 0.19


CONTROL_REDEMPTION_RATE = 0.05   # flat, all regions, for the control group
