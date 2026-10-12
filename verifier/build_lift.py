#!/usr/bin/env python3
"""Measure — compute campaign lift via PGD PGAA CTAS and write it to Iceberg.

Wraps whpg/lift.sql in a PGAA CTAS write to offer_lift_daily_<yyyymmdd> in
kestrel_analytics, then prints lift by region (north visibly weaker). scene 10.
"""

from __future__ import annotations

import sys
from datetime import datetime

import psycopg2
from rich.console import Console
from rich.table import Table

import config

console = Console()
LIFT_SQL = "/whpg/lift.sql"


def main() -> int:
    cfg = config.load()
    cat = config.catalog(cfg)
    analytics_ns = config.namespaces(cfg)["analytics"]
    catalog_name = cat["name"]
    datestr = datetime.now().strftime("%Y%m%d_%H%M%S")
    table = f"offer_lift_daily_{datestr}"

    with open(LIFT_SQL) as f:
        select_sql = f.read().strip().rstrip(";")

    console.rule(f"[bold]Measure — CTAS {analytics_ns}.{table} via PGD PGAA CTAS")

    conn = psycopg2.connect(**config.db_params(cfg))  # PGD PGAA CTAS (WHPG 7.4 cannot write Iceberg)
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(f"DROP TABLE IF EXISTS public.{table}")
            ctas = (
                f"CREATE TABLE public.{table} USING PGAA WITH ("
                f"pgaa.format = 'iceberg', "
                f"pgaa.managed_by = '{catalog_name}', "
                f"pgaa.catalog_namespace = '{analytics_ns}', "
                f"pgaa.catalog_table = '{table}', "
                f"pgaa.purge_data_if_exists = true) AS\n{select_sql}"
            )
            cur.execute("SET statement_timeout = '300s'")
            cur.execute(ctas)
            cur.execute(f"""SELECT region, treated_members, control_members,
                                   treated_redemption_rate, control_redemption_rate,
                                   lift, avg_basket_treated, avg_basket_control
                            FROM public.{table} ORDER BY lift DESC""")
            rows = cur.fetchall()
    finally:
        conn.close()

    t = Table(title=f"{analytics_ns}.{table}")
    for col in ["region", "treated", "control", "treated_rate", "control_rate",
                "lift", "basket_treated", "basket_control"]:
        t.add_column(col)
    for r in rows:
        t.add_row(*[str(x) for x in r])
    console.print(t)

    _point_clickhouse_view(analytics_ns, table)
    console.rule("[bold green]Lift written (north should be weakest)")
    return 0


def _point_clickhouse_view(analytics_ns, table):
    """(Re)create the stable default.offer_lift view over the latest dated lift
    table, so ClickHouse and the demo-app read the current lift through one name."""
    import urllib.request
    ddl = (f"CREATE OR REPLACE VIEW default.offer_lift AS "
           f"SELECT * FROM iceberg_catalog.`{analytics_ns}.{table}`")
    req = urllib.request.Request("http://clickhouse:8123/", data=ddl.encode(),
                                 headers={"Content-Type": "text/plain"}, method="POST")
    try:
        urllib.request.urlopen(req, timeout=30).read()
        console.print(f"  clickhouse view default.offer_lift -> {table}")
    except Exception as e:
        console.print(f"[yellow]note[/yellow] could not point ClickHouse view: {e}")


if __name__ == "__main__":
    sys.exit(main())
