#!/usr/bin/env python3
"""Deliver — emit impression + tap for the hero's live assignment.

Looks up the hero's most recent non-control 'assigned' assignment in PGD, then
produces two flat-JSON engagement events (impression, then tap) to
kestrel.offer.engagement. These feed ClickHouse's hot engagement tier (funnel)
and land in Iceberg via the Kafka sink.
"""

from __future__ import annotations

import json
import sys
import time
import uuid
from datetime import datetime, timezone

import psycopg2
from kafka import KafkaProducer

import config


def main() -> int:
    cfg = config.load()
    hero = config.hero(cfg)
    topic = config.kafka(cfg)["topic_engagement"]
    bootstrap = config.kafka(cfg)["bootstrap"]

    conn = psycopg2.connect(**config.db_params(cfg))
    with conn.cursor() as cur:
        cur.execute(
            """SELECT assignment_id, offer_id, session_id
               FROM kestrel_core.offer_assignments
               WHERE member_id = %s AND is_control = false AND status = 'assigned'
               ORDER BY assigned_at DESC LIMIT 1""",
            (hero["member_id"],),
        )
        row = cur.fetchone()
    conn.close()
    if not row:
        print("no live assignment for hero — run `make record-decision` first", file=sys.stderr)
        return 1
    assignment_id, offer_id, session_id = row
    print(f"hero assignment {assignment_id} offer {offer_id}")

    p = KafkaProducer(
        bootstrap_servers=bootstrap,
        key_serializer=lambda k: str(k).encode(),
        value_serializer=lambda v: json.dumps(v).encode(),
        acks=1,
    )
    for etype in ("impression", "tap"):
        ev = {
            "event_id": str(uuid.uuid4()),
            "event_ts": int(datetime.now(timezone.utc).timestamp() * 1000),
            "member_id": hero["member_id"],
            "session_id": session_id or hero["session_id"],
            "event_type": etype,
            "offer_id": int(offer_id),
            "assignment_id": str(assignment_id),
            "channel": "app",
        }
        p.send(topic, key=hero["member_id"], value=ev)
        print(f"  {etype} -> {topic}")
        time.sleep(0.3)
    p.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
