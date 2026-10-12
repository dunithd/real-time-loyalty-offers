#!/usr/bin/env python3
"""Deterministic PGD seed for Kestrel Market.

Fixed seed -> identical data on every run (CLAUDE.md). Loads via COPY for speed:
~20k members, ~400k orders, ~1.2M order lines, points ledger, and a pre-seeded
hero-campaign assignment/redemption population whose north region redeems visibly
less (so the Phase 5 lift is real and deterministic, independent of the live demo).

The hero member is deliberately NOT pre-assigned: their assignment is created live
by ClickHouse in the Decide scene and redeemed live in the Deliver scene.

Order of operations (see setup_core.py): this seeds PLAIN tables; replication and
tiered-table conversion happen AFTER, so the initial offload is one shot per table.
"""

from __future__ import annotations

import io
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone

import kestrel_universe as ku

# Reference "now" — dynamic so the demo is EVERGREEN: the 3-year history is always
# "the last 3 years" and the campaign window always straddles today. A fixed date
# would expire the offer (now() NOT BETWEEN starts_at AND ends_at) once wall-clock
# time moved past it, and the decision would return no offer.
REF = datetime.now(timezone.utc)
UUID_NS = uuid.UUID("00000000-0000-0000-0000-00000000c0de")

TABLES = [
    "categories", "stores", "products", "members", "offers",
    "orders", "order_lines", "offer_assignments", "offer_redemptions",
    "points_ledger",
]


def _copy(cur, table, columns, rows):
    """Bulk load rows (list of tuples) into kestrel_core.<table> via COPY."""
    buf = io.StringIO()
    for r in rows:
        buf.write("\t".join(_fmt(v) for v in r))
        buf.write("\n")
    buf.seek(0)
    cur.copy_expert(
        f"COPY kestrel_core.{table} ({', '.join(columns)}) FROM STDIN WITH (FORMAT text)",
        buf,
    )


def _fmt(v):
    if v is None:
        return r"\N"
    if isinstance(v, bool):
        return "t" if v else "f"
    if isinstance(v, datetime):
        return v.isoformat()
    return str(v)


def seed(conn, cfg) -> dict[str, int]:
    dd = cfg["demo_data"]
    hero_cfg = cfg["hero"]
    n_members = dd["members"]
    n_stores = dd["stores"]
    n_products = dd["products"]
    history_years = dd["history_years"]

    counts: dict[str, int] = {}
    cur = conn.cursor()

    # ── Dimensions ───────────────────────────────────────────────────────────
    cats = ku.categories()
    _copy(cur, "categories", ["category_id", "name"], cats)
    counts["categories"] = len(cats)

    stores = ku.stores(n_stores)
    _copy(cur, "stores", ["store_id", "name", "region"], stores)
    counts["stores"] = len(stores)

    products = ku.products(n_products)
    _copy(cur, "products", ["product_id", "name", "category_id", "price"], products)
    counts["products"] = len(products)
    product_price = {p[0]: p[3] for p in products}
    products_by_cat: dict[int, list[int]] = {}
    for pid, _n, cid, _pr in products:
        products_by_cat.setdefault(cid, []).append(pid)

    mems = ku.members(n_members, n_stores)
    _copy(
        cur, "members",
        ["member_id", "tier", "home_store_id", "region", "marketing_opt_in"],
        [(m.member_id, m.tier, m.home_store_id, m.region, m.marketing_opt_in) for m in mems],
    )
    counts["members"] = len(mems)

    # ── Offers (hero campaign + a couple of inactive ones for realism) ───────
    starts_at = REF - timedelta(days=4)      # campaign straddles "now" with runway
    ends_at = REF + timedelta(days=10)       # ~2-week window, stays active after a reset
    offers = [(
        ku.HERO_OFFER_ID, hero_cfg["offer_name"], ku.DESSERT_CATEGORY_ID, "pct_off",
        hero_cfg["discount_pct"], 1.80, hero_cfg["budget_total"], 1, "14 days",
        hero_cfg["holdout_pct"], starts_at, ends_at, "active",
    )]
    _copy(
        cur, "offers",
        ["offer_id", "name", "category_id", "mechanic", "discount_pct", "est_cost",
         "budget_total", "max_per_member", "cap_window", "holdout_pct",
         "starts_at", "ends_at", "status"],
        offers,
    )
    counts["offers"] = len(offers)

    # ── Orders + lines + points ledger (3-year history) ──────────────────────
    order_rows, line_rows, points_rows = [], [], []
    order_id = 1
    entry_id = 1
    span_days = history_years * 365
    store_region = {s[0]: s[2] for s in stores}

    for m in mems:
        rng = random.Random(f"{dd['random_seed']}:orders:{m.member_id}")
        n_orders = ku.orders_per_member(m.member_id, history_years)
        d_share = ku.dessert_share(m.is_dessert_lover)
        for _ in range(n_orders):
            days_ago = rng.randint(1, span_days)
            ordered_at = REF - timedelta(days=days_ago, minutes=rng.randint(0, 1439))
            channel = rng.choice(ku.CHANNELS)
            n_lines = rng.randint(1, 5)
            total = 0.0
            for line_no in range(1, n_lines + 1):
                if rng.random() < d_share:
                    cid = ku.DESSERT_CATEGORY_ID
                else:
                    cid = rng.randint(1, len(ku.CATEGORY_NAMES))
                pid = rng.choice(products_by_cat[cid])
                qty = rng.randint(1, 3)
                amount = round(float(product_price[pid]) * qty, 2)
                total += amount
                line_rows.append((order_id, ordered_at, line_no, pid, cid, qty, amount))
            total = round(total, 2)
            order_rows.append((order_id, ordered_at, m.member_id, m.home_store_id, channel, total))
            points_rows.append((entry_id, ordered_at, m.member_id, order_id, int(total), "earn"))
            order_id += 1
            entry_id += 1

    _copy(cur, "orders",
          ["order_id", "ordered_at", "member_id", "store_id", "channel", "total"],
          order_rows)
    _copy(cur, "order_lines",
          ["order_id", "ordered_at", "line_no", "product_id", "category_id", "qty", "amount"],
          line_rows)
    _copy(cur, "points_ledger",
          ["entry_id", "posted_at", "member_id", "order_id", "points", "kind"],
          points_rows)
    counts["orders"] = len(order_rows)
    counts["order_lines"] = len(line_rows)
    counts["points_ledger"] = len(points_rows)

    # ── Pre-seeded hero-campaign assignments + redemptions (for lift) ────────
    # Every qualified member except the hero is assigned; 10% control; treated
    # members in the north redeem visibly less. The hero is assigned/redeemed
    # live during the demo, so they are skipped here.
    offer = offers[0]
    offer_id = offer[0]
    est_cost = float(offer[5])
    discount_pct = float(offer[4])
    holdout_pct = float(offer[9])
    assign_rows, redeem_rows = [], []
    redemption_id = 1
    # reuse the order id space already consumed above for redemption orders
    redeem_order_id = order_id

    for m in mems:
        if m.member_id == ku.HERO_MEMBER_ID:
            continue
        if not ku.qualifies_for_dessert_offer(m):
            continue
        rng = random.Random(f"{dd['random_seed']}:assign:{m.member_id}")
        is_control = ku.is_control(m.member_id, offer_id, holdout_pct)
        assigned_at = starts_at + timedelta(minutes=rng.randint(0, 9 * 1440))
        aid = uuid.uuid5(UUID_NS, f"{offer_id}:{m.member_id}")
        prop = round(ku.dessert_propensity(m), 4)
        status = "assigned"

        # Decide redemption outcome. Control members can still buy — they just
        # weren't shown the offer — at a low flat rate; treated members redeem at
        # the region rate, which carries the north-weak signal.
        rate = ku.CONTROL_REDEMPTION_RATE if is_control else ku.north_is_weaker(m.region)
        redeemed = rng.random() < rate
        if redeemed:
            status = "redeemed"
            redeemed_at = assigned_at + timedelta(hours=rng.randint(1, 72))
            # a small redemption order
            basket = round(8.0 + rng.random() * 20.0, 2)
            discount_amount = round(basket * discount_pct / 100.0, 2)
            order_rows_single = (redeem_order_id, redeemed_at, m.member_id,
                                 m.home_store_id, "app", basket)
            # append to orders + a dessert line so baskets are real
            order_rows.append(order_rows_single)
            line_rows.append((redeem_order_id, redeemed_at, 1,
                              products_by_cat[ku.DESSERT_CATEGORY_ID][0],
                              ku.DESSERT_CATEGORY_ID, 1, basket))
            redeem_rows.append((redemption_id, redeemed_at, str(aid), redeem_order_id,
                                m.member_id, offer_id, discount_amount))
            redemption_id += 1
            redeem_order_id += 1

        assign_rows.append((
            str(aid), assigned_at, m.member_id, offer_id, None, "app_home_hero",
            m.region, is_control, prop, None,
            assigned_at + timedelta(days=14), status,
        ))

    _copy(cur, "offer_assignments",
          ["assignment_id", "assigned_at", "member_id", "offer_id", "session_id",
           "slot", "region", "is_control", "score", "decision_reason",
           "expires_at", "status"],
          assign_rows)
    # append the extra redemption orders/lines written above
    _copy(cur, "orders",
          ["order_id", "ordered_at", "member_id", "store_id", "channel", "total"],
          order_rows[counts["orders"]:])
    _copy(cur, "order_lines",
          ["order_id", "ordered_at", "line_no", "product_id", "category_id", "qty", "amount"],
          line_rows[counts["order_lines"]:])
    _copy(cur, "offer_redemptions",
          ["redemption_id", "redeemed_at", "assignment_id", "order_id", "member_id",
           "offer_id", "discount_amount"],
          redeem_rows)
    counts["orders"] = len(order_rows)
    counts["order_lines"] = len(line_rows)
    counts["offer_assignments"] = len(assign_rows)
    counts["offer_redemptions"] = len(redeem_rows)

    conn.commit()
    cur.close()
    return counts


if __name__ == "__main__":
    import psycopg2
    import config

    cfg = config.load()
    conn = psycopg2.connect(**config.db_params(cfg))
    c = seed(conn, cfg)
    for t in TABLES:
        print(f"  {t:<22} {c.get(t, 0):>10,}")
    sys.exit(0)
