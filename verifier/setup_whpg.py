#!/usr/bin/env python3
"""Register the Lakekeeper catalog in WarehousePG and create read-handles.

WHPG reads kestrel_core and kestrel_events from Iceberg via PGAA, then (in
build_audience / build_lift) WRITES results back with CTAS. This registers the
catalog and creates empty-column tables USING PGAA that adopt each Iceberg
table's schema. Connects to the coordinator (cdw). Idempotent.
"""

from __future__ import annotations

import json
import sys
import urllib.request

import psycopg2
from rich.console import Console

import config

console = Console()

# namespace -> tables to expose as read-handles
HANDLES = {
    "core": ["members", "offers", "orders", "order_lines",
             "offer_assignments", "offer_redemptions", "stores"],
    "events": ["digital_events"],
}


def warehouse_uuid(base_url: str, name: str) -> str:
    with urllib.request.urlopen(f"{base_url}/management/v1/warehouse", timeout=15) as r:
        data = json.load(r)
    for w in data.get("warehouses", []):
        if w.get("name") == name:
            return w["id"]
    raise SystemExit(f"warehouse '{name}' not found in Lakekeeper")


def main() -> int:
    cfg = config.load()
    cat = config.catalog(cfg)
    ns = config.namespaces(cfg)
    catalog_name = cat["name"]
    base_url = cat["url"].removesuffix("/catalog")
    uuid = warehouse_uuid(base_url, cat["warehouse_name"])

    console.rule("[bold]WarehousePG — register catalog + read-handles")
    console.print(f"warehouse {cat['warehouse_name']} -> {uuid}")

    options = json.dumps({
        "url": cat["url"],
        "warehouse": uuid,
        "warehouse_name": cat["warehouse_name"],
    })

    conn = psycopg2.connect(**config.whpg_params(cfg))
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute("CREATE EXTENSION IF NOT EXISTS pgaa CASCADE")
            cur.execute("SELECT count(*) FROM pgaa.list_catalogs() WHERE name = %s",
                        (catalog_name,))
            if cur.fetchone()[0]:
                cur.execute("SELECT pgaa.update_catalog(%s, %s)", (catalog_name, options))
                console.print(f"catalog {catalog_name} updated")
            else:
                cur.execute("SELECT pgaa.add_catalog(%s, %s, %s)",
                            (catalog_name, "iceberg-rest", options))
                console.print(f"catalog {catalog_name} added")

            # Attach before creating read-handles — a freshly added catalog is
            # 'detached', and reads/handles against a detached catalog fail with
            # "Iceberg error: Entity not found in catalog".
            cur.execute("SET statement_timeout = '120s'")
            cur.execute("SELECT pgaa.attach_catalog(%s)", (catalog_name,))
            cur.execute("SELECT status FROM pgaa.list_catalogs() WHERE name = %s",
                        (catalog_name,))
            console.print(f"catalog {catalog_name} status: {cur.fetchone()[0]}")

            for key, tables in HANDLES.items():
                namespace = ns[key]
                cur.execute(f"CREATE SCHEMA IF NOT EXISTS {namespace}")
                for t in tables:
                    cur.execute(f"DROP TABLE IF EXISTS {namespace}.{t}")
                    cur.execute(
                        f"CREATE TABLE {namespace}.{t} () USING PGAA WITH ("
                        f"pgaa.managed_by = '{catalog_name}', "
                        f"pgaa.catalog_namespace = '{namespace}', "
                        f"pgaa.catalog_table = '{t}', "
                        f"pgaa.format = 'iceberg')"
                    )
                    console.print(f"  read-handle {namespace}.{t}")

            cur.execute("SELECT count(*) FROM kestrel_core.members")
            console.print(f"[green]OK[/green] kestrel_core.members -> "
                          f"{cur.fetchone()[0]:,} rows via PGAA")
    finally:
        conn.close()

    console.rule("[bold green]WHPG read-handles ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
