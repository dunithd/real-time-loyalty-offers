#!/usr/bin/env python3
"""Kestrel clickstream + engagement event generator.

Emits FLAT JSON (no Avro, no registry) to two Kafka topics:
  * kestrel.digital.events   — clickstream (app/web browsing)
  * kestrel.offer.engagement — impression / tap / dismiss on an offer

The same flat JSON feeds ClickHouse (JSONEachRow hot tables) and the Kafka
Connect Iceberg sink (schemaless, into pre-created tables). Timestamps are epoch
milliseconds so nothing has to parse a string.

Modes:
  history   backfill N historical clickstream events (dessert lovers browse
            chilled_desserts more) — gives the audience a browse signal in Iceberg.
  live      continuous ambient clickstream at --eps events/sec (Act 0-style motion
            and growing Iceberg row counts).
  hero      inject the hero's live session (strong chilled_desserts intent +
            sort_by_price) so the Decide query sees live intent for the hero.
  engagement emit impression + tap for one assignment (Deliver scene).

Deterministic where it matters: history uses the fixed seed; member/product ids
come from the shared universe so they always exist in PGD.
"""

from __future__ import annotations

import argparse
import json
import random
import time
import uuid
from datetime import datetime, timedelta, timezone

import tomli
from kafka import KafkaProducer

import kestrel_universe as ku

REF = datetime(2026, 10, 5, 12, 0, 0, tzinfo=timezone.utc)
CONFIG_PATH = "/config/demo-config.toml"

BROWSE_EVENTS = ["session_start", "product_view", "search", "add_to_cart",
                 "remove_from_cart", "checkout_started", "sort_by_price"]


def load_cfg():
    with open(CONFIG_PATH, "rb") as f:
        return tomli.load(f)


def make_producer(bootstrap):
    return KafkaProducer(
        bootstrap_servers=bootstrap,
        key_serializer=lambda k: str(k).encode(),
        value_serializer=lambda v: json.dumps(v).encode(),
        linger_ms=50,
        acks=1,
    )


def ms(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)


def digital_event(member_id, session_id, event_type, product_id, category_id,
                  channel, when):
    return {
        "event_id": str(uuid.uuid4()),
        "event_ts": ms(when),
        "member_id": member_id,
        "session_id": session_id,
        "event_type": event_type,
        "product_id": product_id,
        "category_id": category_id,
        "channel": channel,
    }


def engagement_event(member_id, session_id, event_type, offer_id, assignment_id,
                     channel, when):
    return {
        "event_id": str(uuid.uuid4()),
        "event_ts": ms(when),
        "member_id": member_id,
        "session_id": session_id,
        "event_type": event_type,
        "offer_id": offer_id,
        "assignment_id": assignment_id,
        "channel": channel,
    }


# ── modes ────────────────────────────────────────────────────────────────────

def run_history(cfg, p, topic, n_events):
    dd = cfg["demo_data"]
    mems = ku.members(dd["members"], dd["stores"])
    products_by_cat: dict[int, list[int]] = {}
    for pid, _n, cid, _pr in ku.products(dd["products"]):
        products_by_cat.setdefault(cid, []).append(pid)
    rng = random.Random(f"{dd['random_seed']}:history")
    span = dd["history_years"] * 365
    sent = 0
    for _ in range(n_events):
        m = rng.choice(mems)
        when = REF - timedelta(days=rng.randint(1, span), minutes=rng.randint(0, 1439))
        # dessert lovers browse chilled_desserts a lot more
        if rng.random() < (0.5 if m.is_dessert_lover else 0.08):
            cid = ku.DESSERT_CATEGORY_ID
        else:
            cid = rng.randint(1, len(ku.CATEGORY_NAMES))
        pid = rng.choice(products_by_cat[cid])
        ev = digital_event(m.member_id, f"hist-{m.member_id}-{sent}",
                           rng.choice(["product_view", "search", "add_to_cart"]),
                           pid, cid, rng.choice(ku.CHANNELS), when)
        p.send(topic, key=m.member_id, value=ev)
        sent += 1
        if sent % 5000 == 0:
            print(f"  history: {sent:,} events")
    p.flush()
    print(f"history complete: {sent:,} events to {topic}")


def run_live(cfg, p, topic, eps, seconds):
    dd = cfg["demo_data"]
    mems = ku.members(dd["members"], dd["stores"])
    products_by_cat: dict[int, list[int]] = {}
    for pid, _n, cid, _pr in ku.products(dd["products"]):
        products_by_cat.setdefault(cid, []).append(pid)
    rng = random.Random()
    interval = 1.0 / max(1, eps)
    deadline = time.monotonic() + seconds if seconds else None
    sent = 0
    try:
        while deadline is None or time.monotonic() < deadline:
            m = rng.choice(mems)
            cid = rng.randint(1, len(ku.CATEGORY_NAMES))
            pid = rng.choice(products_by_cat[cid])
            ev = digital_event(m.member_id, f"live-{m.member_id}",
                               rng.choice(BROWSE_EVENTS), pid, cid,
                               rng.choice(ku.CHANNELS), datetime.now(timezone.utc))
            p.send(topic, key=m.member_id, value=ev)
            sent += 1
            if sent % 200 == 0:
                p.flush()
                print(f"  live: {sent:,} events")
            time.sleep(interval)
    except KeyboardInterrupt:
        pass
    p.flush()
    print(f"live stopped: {sent:,} events to {topic}")


def run_hero(cfg, p, topic):
    """The hero's live session: strong chilled_desserts intent + price sensitivity."""
    hero = cfg["hero"]
    mid = hero["member_id"]
    sid = hero["session_id"]
    products_by_cat: dict[int, list[int]] = {}
    for pid, _n, cid, _pr in ku.products(cfg["demo_data"]["products"]):
        products_by_cat.setdefault(cid, []).append(pid)
    dessert = products_by_cat[ku.DESSERT_CATEGORY_ID]
    now = datetime.now(timezone.utc)
    script = [
        ("session_start", None, None),
        ("product_view", dessert[0], ku.DESSERT_CATEGORY_ID),
        ("product_view", dessert[1], ku.DESSERT_CATEGORY_ID),
        ("sort_by_price", None, ku.DESSERT_CATEGORY_ID),   # price-sensitive signal
        ("product_view", dessert[2], ku.DESSERT_CATEGORY_ID),
        ("add_to_cart", dessert[0], ku.DESSERT_CATEGORY_ID),
        ("add_to_cart", dessert[2], ku.DESSERT_CATEGORY_ID),
        ("checkout_started", None, None),
    ]
    for i, (etype, pid, cid) in enumerate(script):
        ev = digital_event(mid, sid, etype, pid, cid, "app",
                           now + timedelta(seconds=i * 2))
        p.send(topic, key=mid, value=ev)
        print(f"  hero {etype} product={pid} category={cid}")
    p.flush()
    print(f"hero session sent for member {mid} / {sid}")


def run_engagement(cfg, p, topic, assignment_id, offer_id, member_id, session_id):
    now = datetime.now(timezone.utc)
    for i, etype in enumerate(["impression", "tap"]):
        ev = engagement_event(member_id, session_id, etype, offer_id,
                              assignment_id, "app", now + timedelta(seconds=i))
        p.send(topic, key=member_id, value=ev)
        print(f"  {etype} offer={offer_id} assignment={assignment_id}")
    p.flush()
    print(f"engagement sent to {topic}")


def main():
    cfg = load_cfg()
    k = cfg["kafka"]
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["history", "live", "hero", "engagement"])
    ap.add_argument("--events", type=int, default=40000)
    ap.add_argument("--eps", type=int, default=50)
    ap.add_argument("--seconds", type=int, default=0, help="0 = run until Ctrl-C")
    ap.add_argument("--assignment-id")
    ap.add_argument("--offer-id", type=int, default=ku.HERO_OFFER_ID)
    ap.add_argument("--member-id", type=int, default=ku.HERO_MEMBER_ID)
    ap.add_argument("--session-id", default=ku.HERO_SESSION_ID)
    args = ap.parse_args()

    p = make_producer(k["bootstrap"])
    if args.mode == "history":
        run_history(cfg, p, k["topic_digital"], args.events)
    elif args.mode == "live":
        run_live(cfg, p, k["topic_digital"], args.eps, args.seconds)
    elif args.mode == "hero":
        run_hero(cfg, p, k["topic_digital"])
    elif args.mode == "engagement":
        run_engagement(cfg, p, k["topic_engagement"], args.assignment_id,
                       args.offer_id, args.member_id, args.session_id)


if __name__ == "__main__":
    main()
