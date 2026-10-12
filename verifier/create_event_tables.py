#!/usr/bin/env python3
"""Pre-create the two Iceberg event tables in the kestrel_events namespace.

The Kafka Connect Iceberg sink runs with auto-create off and schemaless JSON
(see DESIGN_NOTES.md), so the target tables must exist first with an explicit
schema. The generator emits flat JSON whose keys and types match these columns
exactly; ClickHouse reads the same flat JSON as JSONEachRow. Timestamps are epoch
milliseconds (long) everywhere, so nothing has to parse an ISO string.

Idempotent: existing tables are left as-is. Run as part of `make setup`.
"""

from __future__ import annotations

import sys

from pyiceberg.exceptions import NamespaceAlreadyExistsError, TableAlreadyExistsError
from pyiceberg.schema import Schema
from pyiceberg.types import BooleanType, LongType, NestedField, StringType
from rich.console import Console

import config
import iceberg_read

console = Console()

# Field ids are arbitrary but must be unique and stable within a table.
DIGITAL_EVENTS_SCHEMA = Schema(
    NestedField(1, "event_id", StringType(), required=False),
    NestedField(2, "event_ts", LongType(), required=False),      # epoch millis
    NestedField(3, "member_id", LongType(), required=False),
    NestedField(4, "session_id", StringType(), required=False),
    NestedField(5, "event_type", StringType(), required=False),
    NestedField(6, "product_id", LongType(), required=False),
    NestedField(7, "category_id", LongType(), required=False),
    NestedField(8, "channel", StringType(), required=False),
)

OFFER_ENGAGEMENT_SCHEMA = Schema(
    NestedField(1, "event_id", StringType(), required=False),
    NestedField(2, "event_ts", LongType(), required=False),      # epoch millis
    NestedField(3, "member_id", LongType(), required=False),
    NestedField(4, "session_id", StringType(), required=False),
    NestedField(5, "event_type", StringType(), required=False),  # impression|tap|dismiss
    NestedField(6, "offer_id", LongType(), required=False),
    NestedField(7, "assignment_id", StringType(), required=False),
    NestedField(8, "channel", StringType(), required=False),
)

TABLES = [
    ("digital_events", DIGITAL_EVENTS_SCHEMA),
    ("offer_engagement", OFFER_ENGAGEMENT_SCHEMA),
]


def main() -> int:
    cfg = config.load()
    events_ns = config.namespaces(cfg)["events"]
    cat = iceberg_read.rest_catalog(cfg)

    console.rule(f"[bold]Pre-creating Iceberg event tables in {events_ns}")

    try:
        cat.create_namespace(events_ns)
        console.print(f"namespace {events_ns} created")
    except NamespaceAlreadyExistsError:
        console.print(f"namespace {events_ns} already exists")

    for name, schema in TABLES:
        try:
            cat.create_table((events_ns, name), schema=schema)
            console.print(f"[green]created[/green] {events_ns}.{name}")
        except TableAlreadyExistsError:
            console.print(f"{events_ns}.{name} already exists")

    console.rule("[bold green]Event tables ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
