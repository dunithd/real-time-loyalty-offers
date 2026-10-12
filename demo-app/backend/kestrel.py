"""Service layer for the Kestrel demo-app.

A thin face over the EXACT same pipeline the scripts use: it produces the same
flat JSON to Kafka, runs the same clickhouse/queries/rank_offer.sql against
ClickHouse, records with the same 2-step (rank SELECT + parametrised INSERT into
the PGD PostgreSQL engine), and redeems with the same PGD transaction. No parallel
logic, no faked data.

Everything here talks to the in-network services (pgd, clickhouse, kafka) by name.
"""

from __future__ import annotations

import json
import time
import uuid
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras
import requests
import tomli
from kafka import KafkaProducer

CONFIG_PATH = "/config/demo-config.toml"
QUERIES_DIR = "/queries"
CH_URL = "http://clickhouse:8123/"


def _cfg() -> dict:
    with open(CONFIG_PATH, "rb") as f:
        return tomli.load(f)


CFG = _cfg()
DB = {
    "host": CFG["database"]["transactional"]["host"],
    "port": CFG["database"]["transactional"]["port"],
    "dbname": CFG["database"]["transactional"]["database"],
    "user": CFG["database"]["transactional"]["user"],
    "password": CFG["database"]["transactional"]["password"],
}
KAFKA = CFG["kafka"]
HERO = CFG["hero"]

_producer: KafkaProducer | None = None


def producer() -> KafkaProducer:
    global _producer
    if _producer is None:
        _producer = KafkaProducer(
            bootstrap_servers=KAFKA["bootstrap"],
            key_serializer=lambda k: str(k).encode(),
            value_serializer=lambda v: json.dumps(v).encode(),
            acks=1, linger_ms=20,
        )
    return _producer


def pg(**kw):
    return psycopg2.connect(**DB, **kw)


# ── ClickHouse over HTTP ─────────────────────────────────────────────────────

def ch_query(sql: str, params: dict | None = None, fmt: str = "JSONEachRow") -> list[dict]:
    """Run a SELECT, return rows as dicts. params become ClickHouse {name:Type} values."""
    sql = sql.strip().rstrip(";")
    q = {"default_format": fmt}
    for k, v in (params or {}).items():
        q[f"param_{k}"] = v
    r = requests.post(CH_URL, params=q, data=sql.encode(), timeout=60)
    r.raise_for_status()
    out = []
    for line in r.text.splitlines():
        if line.strip():
            out.append(json.loads(line))
    return out


def ch_exec(sql: str, params: dict | None = None) -> None:
    q = {}
    for k, v in (params or {}).items():
        q[f"param_{k}"] = v
    r = requests.post(CH_URL, params=q, data=sql.encode(), timeout=60)
    r.raise_for_status()


def _sql(name: str) -> str:
    with open(f"{QUERIES_DIR}/{name}") as f:
        return f.read()


# ── Events (clickstream + engagement) ────────────────────────────────────────

def _ms() -> int:
    return int(datetime.now(timezone.utc).timestamp() * 1000)


def emit_digital(session_id: str, member_id: int, event_type: str,
                 product_id: int | None, category_id: int | None,
                 channel: str = "app") -> None:
    ev = {
        "event_id": str(uuid.uuid4()), "event_ts": _ms(),
        "member_id": member_id, "session_id": session_id,
        "event_type": event_type, "product_id": product_id,
        "category_id": category_id, "channel": channel,
    }
    producer().send(KAFKA["topic_digital"], key=member_id, value=ev)
    producer().flush()


def emit_engagement(session_id: str, member_id: int, event_type: str,
                    offer_id: int, assignment_id: str, channel: str = "app") -> None:
    ev = {
        "event_id": str(uuid.uuid4()), "event_ts": _ms(),
        "member_id": member_id, "session_id": session_id,
        "event_type": event_type, "offer_id": offer_id,
        "assignment_id": assignment_id, "channel": channel,
    }
    producer().send(KAFKA["topic_engagement"], key=member_id, value=ev)
    producer().flush()


# ── Catalog (from PGD — the system of record) ────────────────────────────────

def catalog() -> dict:
    with pg() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT category_id, name FROM kestrel_core.categories ORDER BY category_id")
        categories = cur.fetchall()
        # A curated, demo-friendly slice: a handful per category, desserts first.
        cur.execute("""
            SELECT p.product_id, p.name, p.category_id, c.name AS category, p.price
            FROM kestrel_core.products p
            JOIN kestrel_core.categories c ON c.category_id = p.category_id
            WHERE p.product_id % 20 = 1 OR p.category_id = 7
            ORDER BY (p.category_id = 7) DESC, p.category_id, p.product_id
            LIMIT 60
        """)
        products = cur.fetchall()
    return {"categories": [dict(c) for c in categories],
            "products": [dict(p) for p in products],
            "dessert_category_id": 7}


def hero_persona() -> dict:
    with pg() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT member_id, tier, region, marketing_opt_in FROM kestrel_core.members WHERE member_id = %s",
                    (HERO["member_id"],))
        m = cur.fetchone()
    return {
        "member_id": HERO["member_id"], "name": "Jordan Hartley",
        "tier": (m or {}).get("tier", "gold"), "region": (m or {}).get("region", "south"),
        "opt_in": (m or {}).get("marketing_opt_in", True),
    }


# ── Decide / record / redeem ─────────────────────────────────────────────────

def session_event_count(session_id: str) -> int:
    rows = ch_query(
        "SELECT count() AS n FROM default.digital_events_hot "
        "WHERE session_id = {session_id:String} AND event_time >= now() - INTERVAL 30 MINUTE",
        {"session_id": session_id})
    return int(rows[0]["n"]) if rows else 0


def decide(member_id: int, session_id: str, wait_s: float = 15.0) -> dict | None:
    """Run the one-query decision. Waits until the session's clickstream has fully
    landed in the hot table (Kafka -> ClickHouse lag) AND the event count has been
    stable for ~1.5s — so the add_to_cart / sort_by_price that drive live intent
    are counted, not just the first session_start to arrive."""
    deadline = time.monotonic() + wait_s
    last = -1
    stable_since = None
    while time.monotonic() < deadline:
        n = session_event_count(session_id)
        if n > 0:
            if n == last:
                if stable_since and (time.monotonic() - stable_since) >= 1.5:
                    break
                if stable_since is None:
                    stable_since = time.monotonic()
            else:
                last, stable_since = n, None
        time.sleep(0.4)
    t0 = time.perf_counter()
    rows = ch_query(_sql("rank_offer.sql"),
                    {"member_id": member_id, "session_id": session_id})
    elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
    if not rows:
        return None
    r = rows[0]
    r["decision_reason"] = json.loads(r["decision_reason"]) if isinstance(r.get("decision_reason"), str) else r.get("decision_reason")
    r["latency_ms"] = elapsed_ms
    return r


def record_decision(member_id: int, session_id: str) -> dict | None:
    """2-step record: rank, then INSERT the row into PGD via the PostgreSQL engine
    with a ClickHouse-minted UUID. Returns the stored assignment."""
    d = decide(member_id, session_id, wait_s=0)
    if not d:
        return None
    ch_exec(
        """INSERT INTO default.pgd_offer_assignments
           (assignment_id, assigned_at, member_id, offer_id, session_id, slot, region,
            is_control, score, decision_reason, expires_at, status)
           SELECT generateUUIDv4(), now64(6), {member:Int32}, {offer:Int32}, {session:String},
                  'app_home_hero', {region:String}, {control:Bool}, {score:Float64},
                  {reason:String}, now64(6) + INTERVAL 14 DAY, 'assigned'""",
        {"member": member_id, "offer": d["offer_id"], "session": session_id,
         "region": d["region"], "control": 1 if d["is_control"] else 0,
         "score": d["score"], "reason": json.dumps(d["decision_reason"])})
    # read the stored row back from PGD (the system of record)
    with pg() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""SELECT assignment_id::text, offer_id, is_control, score, status
                       FROM kestrel_core.offer_assignments
                       WHERE member_id = %s AND session_id = %s
                       ORDER BY assigned_at DESC LIMIT 1""", (member_id, session_id))
        row = cur.fetchone()
    out = dict(d)
    out.update(row or {})
    return out


def accept_offer(member_id: int, session_id: str) -> dict | None:
    """Record the decision, then emit impression + tap engagement for it."""
    rec = record_decision(member_id, session_id)
    if not rec:
        return None
    for etype in ("impression", "tap"):
        emit_engagement(session_id, member_id, etype, rec["offer_id"], rec["assignment_id"])
    return rec


def redeem(member_id: int) -> dict:
    """Run the PGD redemption transaction for the hero's live assignment."""
    with pg() as conn:
        conn.autocommit = True
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            with open("/pgd/redeem.sql") as f:
                cur.execute(f.read())
            cur.execute("""SELECT r.discount_amount, r.order_id, l.points, o.total
                           FROM kestrel_core.offer_redemptions r
                           JOIN kestrel_core.points_ledger l ON l.order_id = r.order_id
                           JOIN kestrel_core.orders o ON o.order_id = r.order_id
                           WHERE r.member_id = %s ORDER BY r.redeemed_at DESC LIMIT 1""",
                        (member_id,))
            row = cur.fetchone()
    return dict(row) if row else {}


# ── Marketing: funnel + lift ─────────────────────────────────────────────────

def funnel(offer_id: int = 1) -> dict:
    rows = ch_query(_sql("funnel.sql"), {"offer_id": offer_id})
    return rows[0] if rows else {"assigned": 0, "shown": 0, "tapped": 0, "redeemed": 0}


def lift(offer_id: int = 1) -> list[dict]:
    """Read lift from the stable default.offer_lift view, which build_lift points at
    the latest offer_lift_daily_* table in the Iceberg analytics namespace (the
    governed shared copy, written by PGAA CTAS and read live by ClickHouse).
    Empty until `make lift` has run."""
    try:
        return ch_query(
            "SELECT region, treated_members, control_members, "
            "treated_redemption_rate, control_redemption_rate, lift, "
            "avg_basket_treated, avg_basket_control "
            "FROM default.offer_lift ORDER BY lift DESC")
    except Exception:
        return []


def campaign() -> dict:
    with pg() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""SELECT offer_id, name, discount_pct, budget_total, holdout_pct,
                              starts_at, ends_at, status
                       FROM kestrel_core.offers WHERE offer_id = 1""")
        row = cur.fetchone()
    return dict(row) if row else {}


def status() -> dict:
    """Readiness for the UI: is the audience built, is the hero in it?"""
    out = {"audience_ready": False, "hero_in_audience": False, "qualified": 0}
    try:
        rows = ch_query("SELECT count() AS n, countIf(member_id = {hero:Int64}) AS hero "
                        "FROM default.offer_audience",
                        {"hero": HERO["member_id"]})
        if rows:
            out["qualified"] = int(rows[0]["n"])
            out["audience_ready"] = out["qualified"] > 0
            out["hero_in_audience"] = int(rows[0]["hero"]) > 0
    except Exception as e:
        out["error"] = str(e)
    return out
