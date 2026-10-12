#!/usr/bin/env python3
"""Scene 05 — DuckDB reads the campaign audience from Iceberg with vended creds.

DuckDB is deliberately not an EDB product: reading the WarehousePG-written
audience back through a neutral engine shows the lakehouse is open. Finds the
latest offer_audience_<date> table in kestrel_analytics and prints a summary.
"""

from __future__ import annotations

import sys

from rich.console import Console

import config
import iceberg_read

console = Console()


def main() -> int:
    cfg = config.load()
    analytics_ns = config.namespaces(cfg)["analytics"]
    tables = [t for t in iceberg_read.list_tables(cfg, analytics_ns)
              if t.startswith("offer_audience_")]
    if not tables:
        console.print("[red]no offer_audience_* table yet — run `make audience` first")
        return 1
    table = sorted(tables)[-1]
    console.rule(f"[bold]DuckDB reads {analytics_ns}.{table} from Iceberg")

    con = iceberg_read.duckdb_connect(cfg)
    rows = con.execute(
        f'''SELECT count(*) AS qualified,
                   count(*) FILTER (WHERE is_control) AS control,
                   round(avg(propensity), 3) AS avg_propensity
            FROM lake."{analytics_ns}"."{table}"'''
    ).fetchall()
    console.print(f"qualified={rows[0][0]:,}  control={rows[0][1]:,}  "
                  f"avg_propensity={rows[0][2]}")

    hero = config.hero(cfg)["member_id"]
    hrow = con.execute(
        f'''SELECT member_id, propensity, is_control
            FROM lake."{analytics_ns}"."{table}" WHERE member_id = {hero}'''
    ).fetchall()
    if hrow:
        console.print(f"hero {hrow[0][0]}: propensity={hrow[0][1]} "
                      f"is_control={hrow[0][2]}")
    console.rule("[bold green]DuckDB read OK (openness shown)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
