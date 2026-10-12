# Kestrel Market — Design Notes

Running record of verified component behaviour and the measured numbers that drive the
demo narration. Facts here are checked against EDB docs or the Voltline reference, not
memory (per the working agreements in CLAUDE.md). Cite the doc page next to any config
choice that depends on it.

---

## Verified API facts (front-loaded before writing schema)

Checked 2026-10-05 against EDB docs. These are the three paths Voltline does NOT
demonstrate, so they were verified first because they shape the schema and core logic.

### 1. PGAA tiered tables — `pgaa.convert_to_tiered_table`

Source: https://www.enterprisedb.com/docs/pgaa/latest/reference/functions

```sql
CALL pgaa.convert_to_tiered_table(
    relation                   := 'relation_name'::regclass,
    range_partition_column     := 'column_name',
    partition_increment        := 'interval_string',
    analytics_offload_period   := 'interval',
    initial_lower_bound        := 'start_date_string',
    retention_period           := 'interval' DEFAULT NULL,
    enable_replication         := boolean    DEFAULT false,
    minimum_advance_partitions := integer    DEFAULT 2,
    maximum_advance_partitions := integer    DEFAULT 5,
    drop_after_retention_period:= boolean    DEFAULT true,
    purge_analytics_target     := boolean    DEFAULT false
);
```

Consequences for the Kestrel schema (the 5 tiered tables):
- The table must be **range-partitioned on `range_partition_column`**, which is a
  DATE/TIMESTAMP column. That column must be part of the primary key (standard Postgres
  partitioning rule), so PKs are composite, e.g. `(assignment_id, assigned_at)`.
- No sequences, no foreign keys on tiered tables (PGD/BDR constraint stated in CLAUDE.md;
  design uses UUIDs / app-generated ids and no FKs).
- Unique constraints on a partitioned table must include the partition column — so
  "redeem once" is enforced by the redemption transaction (lock + check), not a constraint.

For the 4 dimension tables (`stores`, `products`, `members`, `offers`) use plain
analytics replication instead:
```sql
CALL pgaa.enable_analytics_replication(relation regclass, purge_analytics_target boolean DEFAULT false);
```

Catalog wiring (same as Voltline, verified):
`pgaa.add_catalog(name, type, options::json)` → `pgaa.attach_catalog(name)`; in PGD these
run inside `bdr.replicate_ddl_command(...)` and the group option
`analytics_write_catalog` is set via `bdr.alter_node_group_option`.

### 2. WarehousePG → Iceberg CTAS (the audience / lift write path)

Source: https://www.enterprisedb.com/docs/pgaa/latest/ctas/

```sql
CREATE TABLE <local_name>
USING PGAA
WITH (
    pgaa.format           = 'iceberg',
    pgaa.managed_by       = '<catalog_name>',
    pgaa.catalog_namespace= '<namespace>',
    pgaa.catalog_table    = '<iceberg_table_name>'
) AS
SELECT ...;
```

- "On WarehousePG 7.6 and later versions, the writer is the coordinator." → pin WHPG 7.6+.
- **CTAS is atomic and write-once.** To change the data you drop and recreate at a new
  path. This is exactly why Kestrel writes a new dated table per run
  (`offer_audience_<yyyymmdd>`) and exposes the current one through a stable view.
- Register the catalog first with `pgaa.add_catalog()` (same options as PGD).

### 3. ClickHouse ↔ Iceberg (read) and ClickHouse → PGD (write)

Source: https://www.enterprisedb.com/docs/clickhouse/latest/reading_iceberg/

```sql
SET allow_experimental_database_iceberg = 1;
CREATE DATABASE iceberg_catalog
ENGINE = DataLakeCatalog('http://lakekeeper:8181/catalog')
SETTINGS catalog_type = 'rest', warehouse = 'kestrel';
-- reference: iceberg_catalog.`<namespace>.<table>`  (backticks required)
```

- The Iceberg **catalog** integration is **read-only**: no INSERT/UPDATE/DELETE against
  `iceberg_catalog.*`. Kestrel honours this — ClickHouse only reads Iceberg.
- The single ClickHouse write path (recording a decision into PGD `offer_assignments`) is
  the **standard ClickHouse PostgreSQL table engine**, which is independent of the Iceberg
  catalog and unaffected by its read-only restriction. `assignment_id` is generated in
  ClickHouse with `generateUUIDv4()`.

### JSON clickstream (user decision, no Avro / no schema registry) — VERIFIED

Clickstream and engagement events are plain JSON — no Apicurio. Chosen approach
(verified working 2026-10-05): flat JSON on the wire; `JsonConverter` with
`schemas.enable=false`; Iceberg event tables PRE-CREATED via pyiceberg; sink runs
`auto-create-enabled=false` and maps JSON fields by name into the existing table.
ClickHouse reads the same flat JSON as `JSONEachRow`.
- Verified: 10,000 events produced → `kestrel_events.digital_events` in Iceberg
  (pyiceberg count = 10000), sink logged "Commit complete to table
  kestrel_events.digital_events, committed to 1 table(s)".
- **Timing note for recording:** the FIRST Iceberg commit after a cold start takes
  ~90s (writer init under emulation); subsequent commits follow the ~10s interval.
  For scene 03 ("row count grows across two reads"), pre-warm the sink by producing
  some events ~2 min before recording, then the two reads are ~10s apart as scripted.

---

## Measured numbers (measured on this machine 2026-10-05 — re-measure before recording)

| Number | Where | Value | Notes |
|---|---|---|---|
| Decision query latency | `make bench-decide` | min 59ms / median 60ms / p95 64ms (20 runs) | JIT off; single-threaded; ClickHouse stable across all 20 |
| Kafka sink commit interval | Phase 1 | 10s | first commit after cold start ~90s, then ~10s |
| Audience qualified / control | scene 04 | 4,000 qualified / ~400 control (~10%) | hero in audience, not control, propensity 0.887 |
| Lift by region | scene 10 | north lift 0.065 vs ~0.17 elsewhere | north treated redemption 0.07 vs ~0.18 — visibly weakest |
| Funnel | scene 11 | assigned 3594 / shown 1 / tapped 1 / redeemed 715 | shown/tapped = hero live; redeemed = pre-seeded + hero |

## ClickHouse on Apple Silicon — the critical stability findings

ClickHouse + Lakekeeper was (as predicted) the single most fragile piece. Three
issues, all resolved:

1. **Version.** 26.1 reads Lakekeeper correctly but the arm64 build hit illegal
   instructions; 25.5 is stable but mis-constructs the S3 key for Lakekeeper
   metadata locations (doubles the path → S3_ERROR on every table). **25.10 is the
   sweet spot** — reads correctly and is stable with the settings below. Pinned.
2. **JIT compilation = THE crash.** ClickHouse JIT-compiles hot expressions after
   `min_count_to_compile_expression` (default 3) executions; the compiled code used
   an instruction the arm64 build traps as illegal, crashing the server on ~every
   4th query (the tell: it always failed on run 4). Disabled via
   `compile_expressions=0`, `compile_aggregate_expressions=0`,
   `compile_sort_description=0` in `clickhouse/users.d/iceberg.xml` → 20/20 clean.
   Also forced `input_format_parquet_use_native_reader=1` (the default Arrow
   multi-threaded reader also showed instability). Interpreted execution is correct
   and fast enough on this small data (60ms decision).
3. **Record step split in two.** The single `INSERT … SELECT` (joins/aggregates
   over Iceberg + a PostgreSQL-engine write) still crashed; `clickhouse/record_decision.sh`
   runs the ranking SELECT, captures the row, and does a parametrised `INSERT … VALUES`
   with `generateUUIDv4()` — both stable, still entirely ClickHouse through the PG engine.

## Reset hygiene

`setup_core.py` drops the `kestrel_core` Iceberg tables (pyiceberg `purge_table`)
before re-offloading: `enable_analytics_replication(purge=true)` does NOT reliably
clear a pre-existing catalog table, so a second run otherwise DOUBLES every row
count (verified: 7999 vs PGD 3999). With the drop, re-runs match PGD exactly.

---

## Demo-app UI (`demo-app/`)

A single container (profile `app`, host port 8080) that is a face over the exact
pipeline — no faked data. FastAPI backend (`backend/kestrel.py`) produces the same
flat JSON to Kafka, runs the same `clickhouse/queries/rank_offer.sql`, records with
the same 2-step PostgreSQL-engine insert, and redeems with the same `pgd/redeem.sql`.
React/Vite/Tailwind frontend, two roles switched by route:

- `/` **storefront** — the hero (member 100042) browses; view/add/sort emit real
  clickstream; after a dessert add, `/api/decide` runs the live decision (waits for
  the session's events to land in the hot tier and stabilise, ~2-4s), shows the
  personalised offer + the real decision_reason + measured latency; apply records
  to PGD + emits impression/tap; checkout runs the PGD redemption. A "Converged
  pipeline — live" drawer narrates each engine hop on camera.
- `/marketing` **Campaign Command Center** — live funnel (ClickHouse) + lift by
  region (Iceberg `offer_lift_daily`, north flagged weakest) + KPIs, auto-refresh 5s.

Notes:
- `kafka-python-ng` (not `kafka-python`) — the latter breaks on Python 3.12.
- Funnel coherence: impressions/taps only exist live, so `clickhouse/seed_engagement.sql`
  (run by `make reset` / `make seed-engagement`) seeds realistic campaign
  impressions (~90% of treated) and taps (~45%) into the hot tier, giving a proper
  assigned→shown→tapped→redeemed funnel; the live shopper's engagement adds on top.
- `stream_flush_interval_ms=1000` (users.d) cuts Kafka→hot lag to ~2-4s so the
  offer appears quickly.
- Run order: spine up + `make setup` + `make reset` (seeds audience + funnel), then
  `make build-app && make up-app` (or just `make up`, which now includes the app).

## Environment facts (this machine)

- Docker Desktop 27.4.0. Catalog tier validated 2026-10-05: `kestrel` warehouse
  created in Lakekeeper, STS-enabled.
- PGD/PGAA image builds from the EDB token in a few minutes (token valid).
- Prebaked WarehousePG base image `whpg7_cdw:latest` is present locally → the WHPG
  cluster uses the prebaked Dockerfile (no multi-GB token build) and the Phase 2
  WHPG→Iceberg CTAS path is viable without falling back to PGD PGAA CTAS.
- `clickhouse/clickhouse-server:26.1` cached locally.

## Deviations from the architecture (flag as they happen)

- **Plain analytics replication instead of tiered tables** (2026-10-05, approved
  by the user for demo reliability). CLAUDE.md specifies the five fact tables as
  tiered tables (`pgaa.convert_to_tiered_table(enable_replication := true)`). The
  verified syntax worked and the conversion succeeded, but under amd64 emulation
  the initial offload created ~36 monthly partition Iceberg tables per fact table
  (148 total) and moved the 1.9M seeded rows far too slowly — after 5 minutes only
  4 of 148 partitions had offloaded, and the per-partition table names would
  complicate every downstream read. Reverted all ten tables to
  `pgaa.enable_analytics_replication` (the Voltline model): one clean Iceberg
  table per source table, single-pass offload, live inserts replicated within 2s.
  **Narration change:** scene 02 shows `list_analytics_tables()` (replication),
  not `list_tiered_tables()`. Tiering can be shown later on one small table if
  wanted — the verified call is in git history (commit a1708fb, pgd/replicate.sql).

- **Audience + lift written from PGD, not WarehousePG** (CLAUDE.md-sanctioned
  fallback). WHPG was to build the audience and lift via PGAA CTAS, but the
  prebaked `whpg7_cdw` base is **7.4.0** and coordinator-side CTAS writes need
  **7.6+** (verified: on 7.4 the CTAS reports the SELECT cardinality but writes no
  data files; ClickHouse/MinIO see an empty table). PGD's single-node PGAA writes
  Iceberg correctly (verified end-to-end), so `build_audience.py` / `build_lift.py`
  run the CTAS on PGD. **Narration change:** "PGAA writes the audience to Iceberg"
  rather than "WarehousePG writes it". WHPG is now OPTIONAL and off the critical
  path (also frees memory on the 8GB Docker VM); `make up-whpg` + `make setup-whpg`
  still stand it up as an Iceberg *reader* if the batch-engine story is wanted.
  To make WHPG the writer, source a WarehousePG 7.6+ image.

- **JSON events, no Apicurio** (user decision): the Kafka lane has no schema
  registry. The Iceberg sink runs schemaless (`schemas.enable=false`,
  `auto-create-enabled=false`) into event tables PRE-CREATED via pyiceberg, so
  flat JSON on the wire serves both ClickHouse (`JSONEachRow`) and the sink. If
  the schemaless sink refuses to map into pre-created tables at runtime, fallback
  is JsonConverter `schemas.enable=true` with the generator emitting
  schema+payload envelopes (and a ClickHouse view to unwrap). Decide at Phase 1.
