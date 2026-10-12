#!/usr/bin/env python3
"""Qualify — build the campaign audience via PGD PGAA CTAS and write it to Iceberg.

Wraps whpg/audience.sql in the PGAA CTAS write (verified syntax, DESIGN_NOTES.md)
that lands offer_audience_<yyyymmdd> in the kestrel_analytics namespace. CTAS is
write-once, so each run writes a fresh dated table; the current one is reached
through the stable `offer_audience` view, which this also (re)points in ClickHouse.

Prints the qualified / control summary (scene 04).
"""

from __future__ import annotations

import sys
from datetime import datetime

import psycopg2
from rich.console import Console

import config

console = Console()

AUDIENCE_SQL = "/whpg/audience.sql"


def main() -> int:
    cfg = config.load()
    cat = config.catalog(cfg)
    analytics_ns = config.namespaces(cfg)["analytics"]
    catalog_name = cat["name"]
    # Unique table name per build (write-once). A new name every run means
    # ClickHouse's DataLakeCatalog always discovers a FRESH table — reusing a name
    # with purge left ClickHouse reading a deleted metadata.json (S3_ERROR). The
    # stable `offer_audience` view below always points at the latest one.
    datestr = datetime.now().strftime("%Y%m%d_%H%M%S")
    table = f"offer_audience_{datestr}"

    with open(AUDIENCE_SQL) as f:
        select_sql = f.read().strip().rstrip(";")

    console.rule(f"[bold]Qualify — CTAS {analytics_ns}.{table} via PGD PGAA CTAS")

    conn = psycopg2.connect(**config.db_params(cfg))  # PGD PGAA CTAS (WHPG 7.4 cannot write Iceberg)
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            # fresh local + Iceberg table (write-once)
            cur.execute(f"DROP TABLE IF EXISTS public.{table}")
            ctas = (
                f"CREATE TABLE public.{table} USING PGAA WITH ("
                f"pgaa.format = 'iceberg', "
                f"pgaa.managed_by = '{catalog_name}', "
                f"pgaa.catalog_namespace = '{analytics_ns}', "
                f"pgaa.catalog_table = '{table}', "
                # write-once CTAS; purge lets a rerun on the same date overwrite
                # (needed for make reset / re-recording takes)
                f"pgaa.purge_data_if_exists = true) AS\n{select_sql}"
            )
            cur.execute("SET statement_timeout = '300s'")
            cur.execute(ctas)
            console.print(f"[green]written[/green] {analytics_ns}.{table}")

            # summary (scene 04)
            cur.execute(f"""
                SELECT count(*) AS qualified,
                       count(*) FILTER (WHERE is_control) AS control,
                       round(avg(propensity)::numeric, 3) AS avg_propensity
                FROM public.{table}
            """)
            q, c, avgp = cur.fetchone()
            console.print(f"  qualified      {q:,}")
            console.print(f"  control (hold) {c:,}")
            console.print(f"  avg propensity {avgp}")
            cur.execute(f"SELECT is_control, propensity FROM public.{table} "
                        f"WHERE member_id = {config.hero(cfg)['member_id']}")
            row = cur.fetchone()
            if row:
                console.print(f"  hero (member {config.hero(cfg)['member_id']}): "
                              f"is_control={row[0]} propensity={row[1]}")
            else:
                console.print("[red]WARN[/red] hero not in audience!")
    finally:
        conn.close()

    _point_clickhouse_view(cfg, analytics_ns, table)
    console.rule("[bold green]Audience built")
    return 0


def _point_clickhouse_view(cfg, analytics_ns, table):
    """(Re)create the stable ClickHouse view over the latest dated audience table."""
    import urllib.request

    ddl = (
        f"CREATE OR REPLACE VIEW default.offer_audience AS "
        f"SELECT offer_id, member_id, propensity, is_control, built_at "
        f"FROM iceberg_catalog.`{analytics_ns}.{table}`"
    )
    req = urllib.request.Request(
        "http://clickhouse:8123/", data=ddl.encode(),
        headers={"Content-Type": "text/plain"}, method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=30).read()
        console.print(f"  clickhouse view default.offer_audience -> {table}")
    except Exception as e:  # ClickHouse may not be up in a WHPG-only run
        console.print(f"[yellow]note[/yellow] could not point ClickHouse view "
                      f"(is clickhouse up?): {e}")


if __name__ == "__main__":
    sys.exit(main())
