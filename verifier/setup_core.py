#!/usr/bin/env python3
"""Phase 1 — build kestrel_core: schema, deterministic seed, then Iceberg.

Order matters. Seed the PLAIN tables first, then enable replication / tiering:
the enable does an initial offload of the existing rows in one shot, far cheaper
than replicating hundreds of thousands of inserts one commit at a time. After
enable, subsequent inserts (the live decision + redemption) replicate incrementally.

Idempotent: schema.sql drops and recreates the schema, so reruns and `make reset`
are safe.
"""

from __future__ import annotations

import sys
import time

import psycopg2
from rich.console import Console

import config
import iceberg_read
import seed as seed_mod

console = Console()

SCHEMA_SQL = "/pgd/schema.sql"
REPLICATE_SQL = "/pgd/replicate.sql"


def _drop_core_iceberg_tables(cfg, core_ns):
    """Drop every table in the kestrel_core namespace from the catalog so a
    re-offload starts clean (purge=true on enable does not reliably clear them)."""
    try:
        cat = iceberg_read.rest_catalog(cfg)
        existing = [t[-1] for t in cat.list_tables(core_ns)]
    except Exception as e:
        console.print(f"[yellow]note[/yellow] could not list {core_ns} tables "
                      f"(first run?): {e}")
        return
    for t in existing:
        try:
            cat.purge_table((core_ns, t))
            console.print(f"  dropped stale Iceberg {core_ns}.{t}")
        except Exception as e:
            console.print(f"[yellow]note[/yellow] drop {core_ns}.{t}: {e}")


def main() -> int:
    cfg = config.load()
    core_ns = config.namespaces(cfg)["core"]
    catalog_name = config.catalog(cfg)["name"]

    console.rule("[bold]Phase 1 — kestrel_core: schema + seed + replication")

    conn = psycopg2.connect(**config.db_params(cfg))
    try:
        # 1. schema (drops + recreates the PG tables, stopping old replication)
        with open(SCHEMA_SQL) as f:
            ddl = f.read()
        with conn.cursor() as cur:
            cur.execute(ddl)
        conn.commit()
        console.print(f"schema applied ({len(seed_mod.TABLES)} tables)")

        # 1b. drop any existing kestrel_core Iceberg tables so the re-offload
        #     REPLACES rather than accumulates. enable_analytics_replication
        #     (purge=true) does not reliably clear a pre-existing catalog table, so
        #     a second setup_core would otherwise double the row counts (verified).
        _drop_core_iceberg_tables(cfg, core_ns)

        # 2. seed
        console.print("seeding (deterministic) ...")
        t0 = time.monotonic()
        counts = seed_mod.seed(conn, cfg)
        for t in seed_mod.TABLES:
            console.print(f"  {t:<20} {counts.get(t, 0):>10,}")
        console.print(f"seed complete in {time.monotonic() - t0:.1f}s")

        # 3. attach catalog, then replicate / tier
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute("SET statement_timeout = '600s'")
            cur.execute("SELECT pgaa.attach_catalog(%s)", (catalog_name,))
            cur.execute("SELECT status FROM pgaa.list_catalogs() WHERE name = %s",
                        (catalog_name,))
            row = cur.fetchone()
            if not row or row[0] != "attached":
                console.print(f"[red]FAIL[/red] catalog {catalog_name} not attached "
                              f"(status={row[0] if row else 'missing'})")
                return 1
            console.print(f"catalog {catalog_name} attached")

            console.print("enabling analytics replication + tiered tables "
                          "(initial offload per table) ...")
            import re
            with open(REPLICATE_SQL) as f:
                # strip -- comments (they can contain semicolons) BEFORE splitting
                cleaned = re.sub(r"--[^\n]*", "", f.read())
                stmts = [s.strip() for s in cleaned.split(";") if s.strip()]
            for stmt in stmts:
                cur.execute(stmt)
                label = stmt.split("'")[1] if "'" in stmt else stmt[:40]
                console.print(f"  {label}")
    finally:
        conn.close()

    # 4. wait for the initial offload to complete. Use PGD's authoritative
    #    replication_status (every kestrel_core table 'enabled'), not a pyiceberg
    #    read — pyiceberg's client trips over some PGAA-written schemas, and the
    #    real downstream consumers (ClickHouse, WHPG) read these tables fine.
    console.print("waiting for the initial offload to complete (replication_status=enabled) ...")
    conn = psycopg2.connect(**config.db_params(cfg))
    conn.autocommit = True
    deadline = time.monotonic() + 300
    try:
        while time.monotonic() < deadline:
            with conn.cursor() as cur:
                cur.execute("SET client_min_messages=error")
                cur.execute(
                    "SELECT count(*) FROM pgaa.list_analytics_tables() "
                    "WHERE schema_name = 'kestrel_core' "
                    "AND replication_status <> 'enabled'"
                )
                pending = cur.fetchone()[0]
            if pending == 0:
                console.print(f"[green]OK[/green] all {len(seed_mod.TABLES)} "
                              f"kestrel_core tables offloaded to Iceberg")
                console.rule("[bold green]Phase 1 setup complete")
                return 0
            time.sleep(5)
    finally:
        conn.close()
    console.print("[yellow]offload still in progress after 300s; check make logs "
                  "for an Iceberg sync error (e.g. an unsupported column type)[/yellow]")
    return 1


if __name__ == "__main__":
    sys.exit(main())
