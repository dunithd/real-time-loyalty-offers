# Kestrel Market — QD3M Converged Analytics Demo

## Mission

Build a **reliably recordable** demo of Kestrel Market, a fictional omnichannel retailer, running
personalised loyalty offers on EDB Converged Analytics. The webinar recording is **tomorrow
(Tuesday 6 October 2026)**.

The goal is not a finished product. The goal is that every terminal scene in the shooting script can be
recorded cleanly, repeatedly, from a known starting state. When forced to choose, prefer:

- a scene that works every time, over one that is more complete;
- fewer moving parts, over more realistic architecture;
- a scripted, deterministic command, over an interactive one.

## Reference implementation: Voltline (read this first)

> **PLACEHOLDER: copy the Voltline demo source into `reference/voltline/` before starting.**
>
> ```
> reference/voltline/        <- Voltline EV-charging-network Converged Analytics demo goes here
> ```

Voltline is an earlier Converged Analytics demo with the same component family. Before writing any
Kestrel code, read it to learn how the pieces are wired, and reuse its patterns:

- the Docker Compose layout, images, versions, ports, networks and health checks;
- PGD + PGAA configuration, and how PGAA is attached to the Lakekeeper catalog;
- Lakekeeper and MinIO setup, including warehouse creation and credential vending;
- Kafka Connect with the Iceberg sink connector (connector config, commit interval);
- how ClickHouse reads Iceberg through Lakekeeper (catalog database settings);
- how WarehousePG reads (and, if present, writes) Iceberg through PGAA;
- how DuckDB connects with vended credentials.

Rules for using the reference:

- Reuse wiring, config and setup scripts. **Do not reuse Voltline domain names, tables or narrative.**
- Voltline's architecture principle carries over unchanged: PGAA and the Kafka Iceberg sink write to
  Iceberg; ClickHouse, WarehousePG and DuckDB read it. Kestrel adds exactly two new write paths:
  WarehousePG writing `offer_audience` / `offer_lift_daily` to Iceberg (CTAS), and ClickHouse inserting
  decisions into PGD through its PostgreSQL table engine.
- If Voltline and this file disagree on Kestrel behaviour, this file wins. If Voltline and EDB docs
  disagree on how a component works, check the docs and tell me.

EDB docs index for verification: https://www.enterprisedb.com/docs/llms.txt (pages also serve
markdown with `Accept: text/markdown`).

## The story the build serves: QD3M

The demo follows how data becomes a business result. Every build task maps to one phase.

1. **Qualify** — "Who deserves this offer?" A campaign is created in PGD. Transactions reach Iceberg
   through PGAA; clickstream reaches Iceberg through Kafka Connect. WarehousePG scores members and writes
   a campaign audience (with a 10% control group) back to Iceberg.
2. **Discover / Decide / Deliver** — "What do they need right now?" ClickHouse reads live session
   events from Kafka, and in one query combines them with the audience and guardrails read from Iceberg,
   ranks offers, and records the decision in PGD. The shopper redeems in a PGD transaction.
3. **Measure** — "Did it work?" ClickHouse live funnel, WarehousePG lift (treated vs control), and an AI
   agent copilot over Postgres MCP + ClickHouse MCP.

## Architecture principles (do not violate without asking)

- **Data lands once in Iceberg, and every engine reads it.** Analytical engines never query each other.
- **One catalog:** Lakekeeper (Iceberg REST) on MinIO.
- **PGD is the system of record** for offers, members, orders, assignments, redemptions and the points
  ledger. Applications write to PGD, never directly to Iceberg.
- **ClickHouse reads PGD-origin data from Iceberg, not from PGD.** The single exception is *writing*
  decisions into `offer_assignments` through the PostgreSQL table engine.
- **ClickHouse's Kafka-fed hot tables are a short-lived serving cache** (TTL 2 days). Iceberg is the
  long-term record of events.
- **No bespoke pipelines between engines.** If something seems to need one, stop and ask.

## Components

| Component | Role in Kestrel |
| --- | --- |
| EDB PGD + PGAA | System of record; analytics replication and tiered tables into Iceberg; redemption transactions; operational reads |
| Lakekeeper + MinIO | Iceberg REST catalog and object storage (warehouse: `kestrel`) |
| Kafka + Kafka Connect (Iceberg sink) | Clickstream and engagement events; long-term persistence into Iceberg |
| WarehousePG + PGAA | Audience scoring and holdout split (Qualify); lift analysis (Measure); writes results to Iceberg via CTAS |
| EDB ClickHouse | Hot session tables from Kafka; decision query over hot + Iceberg; decision insert into PGD; live funnel |
| DuckDB | Optional: reads `offer_audience` with vended credentials to show openness |

## Data model

### PGD tables

| Table | Mode into Iceberg | Notes |
| --- | --- | --- |
| `stores` | analytics replication | `store_id`, `name`, `region` (`north`, `midlands`, `south`, `london`) |
| `products` | analytics replication | `product_id`, `name`, `category_id`, `price` |
| `members` | analytics replication | `member_id`, `tier`, `home_store_id`, `region`, `marketing_opt_in` |
| `offers` | analytics replication | `offer_id`, `name`, `category_id`, `mechanic`, `discount_pct`, `est_cost`, `budget_total`, `max_per_member`, `cap_window`, `holdout_pct`, `starts_at`, `ends_at`, `status` |
| `orders` | tiered, `enable_replication := true` | `order_id`, `ordered_at`, `member_id`, `store_id`, `channel` (`store`, `app`, `web`), `total` |
| `order_lines` | tiered, `enable_replication := true` | `order_id`, `ordered_at`, `line_no`, `product_id`, `category_id`, `qty`, `amount` |
| `offer_assignments` | tiered, `enable_replication := true` | `assignment_id` (uuid), `assigned_at`, `member_id`, `offer_id`, `session_id`, `slot`, `region`, `is_control`, `score`, `decision_reason` (jsonb), `expires_at`, `status` (`assigned`, `redeemed`) |
| `offer_redemptions` | tiered, `enable_replication := true` | `redemption_id`, `redeemed_at`, `assignment_id`, `order_id`, `member_id`, `offer_id`, `discount_amount` |
| `points_ledger` | tiered, `enable_replication := true` | `entry_id`, `posted_at`, `member_id`, `order_id`, `points`, `kind` (`earn`, `burn`) |

**Tiered-table constraints (verified in PGD docs; design around them):**

- The range partition column must be `DATE` or `TIMESTAMP` and part of the primary key, so primary keys
  are composite, for example `(assignment_id, assigned_at)`.
- Tables with sequences or foreign keys are not supported: use UUIDs or app-generated ids, and no FKs.
- Unique constraints on partitioned tables must include the partition column, so "redeem once" is
  enforced by the redemption transaction (lock and check), not by a constraint.
- Do not rename tiered or replicated tables, or their schema, after enabling.

### Kafka topics

| Topic | Producer | Consumers |
| --- | --- | --- |
| `kestrel.digital.events` | event generator (app/web clickstream) | Kafka Connect → Iceberg `digital_events`; ClickHouse hot table |
| `kestrel.offer.engagement` | event generator / decision scripts (`impression`, `tap`, `dismiss`) | Kafka Connect → Iceberg `offer_engagement`; ClickHouse hot table |

Event fields: `event_id`, `event_ts`, `member_id`, `session_id`, `event_type` (`session_start`,
`product_view`, `search`, `add_to_cart`, `remove_from_cart`, `checkout_started`, `sort_by_price`),
`product_id`, `category_id`, `channel`. Engagement events add `offer_id` and `assignment_id`.

Set the Iceberg sink commit interval low for the demo (around 10 seconds) so row counts visibly grow
during recording.

### WarehousePG outputs (written to Iceberg with CTAS)

- `offer_audience_<yyyymmdd>`: `offer_id`, `member_id`, `propensity` (0..1), `is_control`,
  `built_at`. Built per offer when a campaign launches.
- `offer_lift_daily_<yyyymmdd>`: `offer_id`, `region`, `treated_members`, `control_members`,
  `treated_redemption_rate`, `control_redemption_rate`, `lift`, `avg_basket_treated`,
  `avg_basket_control`.
- PGAA CTAS output is **write-once**: each run writes a new dated table. The current one is reached
  through a stable view: `offer_audience` / `offer_lift_daily` in ClickHouse (and in PGD if the agent
  needs it). Requires WarehousePG 7.6+ for coordinator-side CTAS writes.

## Core logic

### Audience (WarehousePG, Qualify)

- Affinity per member for the offer's category, from 2+ years of `order_lines` and `digital_events`:
  weighted recency and frequency of purchases, plus browse signal. Normalise to 0..1.
- Qualify where `propensity >= threshold` (start at 0.5) **and** `marketing_opt_in`.
- Randomly mark `holdout_pct` (10%) of qualified members `is_control = true`, deterministically (seeded
  hash of member and offer) so reruns match.

### Session features (ClickHouse, Discover)

From the hot tables, for one `session_id`, over the last 30 minutes: views and cart adds per category,
dwell time, `price_sensitive` (any `sort_by_price`), and checkout started yes/no.

### Decision (ClickHouse, Decide): one query

1. **Live intent** per category: `least(1.0, (views + 3 * cart_adds) / 10.0)`.
2. **Audience gate:** join `offer_audience` on member and offer. Not in the audience means no offer.
   *The audience is the gate; live intent ranks within it.*
3. **Guardrails** (read from Iceberg): offer active and in window; member `marketing_opt_in`; soft
   budget check `budget_total - sum(est_cost of non-control assignments) >= est_cost`; frequency cap
   from the member's recent assignments.
4. **Score:** `0.6 * intent + 0.4 * propensity`, plus `0.05` for `pct_off` when price-sensitive.
5. Return the top offer with `score`, `is_control` and a `decision_reason` JSON.

Then record it: `INSERT` into a ClickHouse table using the **PostgreSQL table engine** pointing at PGD
`offer_assignments`, with the `assignment_id` generated in ClickHouse (`generateUUIDv4()`). Control-group
decisions are recorded too (`is_control = true`) but not shown.

Known, accepted simplification: the budget check is a read, not a reservation, and Iceberg lags PGD by
the replication interval. Fine for one shopper at a time; don't hide it in output.

### Redemption (PGD, Deliver)

One transaction:
`SELECT … FOR UPDATE` on the assignment → check `status = 'assigned'`, not expired, not control →
insert the order and order lines → insert the redemption → insert the points-ledger entry →
`UPDATE` the assignment to `redeemed` → `COMMIT`.

### Lift (WarehousePG, Measure)

Treated versus control redemption rate and average basket per region for the campaign window. Write
`offer_lift_daily_<date>` via CTAS. The seed data must make the **north region visibly weaker**.

## Synthetic data

- Fixed random seed; regeneration must produce identical data.
- Sizes fit a laptop: around 20k members, 40 stores across 4 regions, 600 products across 12 categories
  (including `chilled_desserts`), about 3 years of orders (~400k orders), plus clickstream history.
- Built-in signal: strong chilled-desserts affinity for a known member segment, and the north region
  responding less to the campaign.
- **Hero shopper** for the recording: a fixed `member_id` and `session_id` in the audience, *not* in the
  control group, in a non-north region. Every scene uses this pair.
- Hero campaign: "Chilled Desserts 20% Off", £10,000 budget, two weeks, 10% holdout.

## Build phases (in priority order)

Each phase ends when its scenes record cleanly from `make reset`. Commit after each phase. Do not
start a lower-priority phase while a higher one is flaky.

### Phase 0 — Environment (from Voltline)

- [ ] Compose stack adapted from Voltline: PGD + PGAA, Lakekeeper, MinIO, Kafka, Kafka Connect,
      WarehousePG + PGAA, ClickHouse, DuckDB CLI.
- [ ] `make up`, `make down`, `make reset` (back to the pre-recording state), `make health`
      (every component green).
- [ ] Kestrel warehouse/namespace in Lakekeeper; PGAA attached to the catalog in both PGD and
      WarehousePG; ClickHouse catalog database connected.

### Phase 1 — Qualify foundation (highest priority)

- [ ] PGD schema (tables above) and deterministic seed loader.
- [ ] Analytics replication on `stores`, `products`, `members`, `offers`.
- [ ] `pgaa.convert_to_tiered_table(…, enable_replication := true)` on the five tiered tables.
- [ ] Topics, event generator (history backfill plus a live mode), Kafka Connect Iceberg sink for both
      topics.
- [ ] Verify all tables appear in Lakekeeper and are readable from ClickHouse and WarehousePG.

### Phase 2 — Audience (Qualify)

- [ ] `whpg/audience.sql`: CTAS of `offer_audience_<date>` to the catalog, plus a qualified/control
      summary query.
- [ ] Stable `offer_audience` view in ClickHouse pointing at the latest dated table.
- [ ] Optional: DuckDB reads `offer_audience` with vended credentials.

### Phase 3 — Discover and Decide (the webinar's promise)

- [ ] ClickHouse Kafka engine tables plus materialized views into hot MergeTree tables (TTL 2 days) for
      both topics.
- [ ] `clickhouse/session_features.sql` for the hero session.
- [ ] `clickhouse/rank_offer.sql`: the one-query decision (above), parameterised by member and session.
- [ ] `clickhouse/record_decision.sql`: PostgreSQL-engine table and the `INSERT`.
- [ ] `make bench-decide`: run the ranking query 20 times and print min, median and p95. This number
      goes on screen; it must be measured, never assumed.

### Phase 4 — Deliver and redeem

- [ ] Script that emits `impression` and `tap` for the hero assignment to `kestrel.offer.engagement`.
- [ ] `pgd/redeem.sql`: the redemption transaction for the hero assignment.

### Phase 5 — Measure (stretch for tomorrow)

- [ ] `whpg/lift.sql`: lift CTAS plus the result query (north visibly weaker).
- [ ] `clickhouse/funnel.sql`: assigned → shown → tapped → redeemed by minute.

### Phase 6 — Later (not for tomorrow)

- Funnel dashboard UI, Kestrel app mock, AI agent over Postgres MCP + ClickHouse MCP, abandoned-cart
  nudges (refreshable materialized view), Instruqt packaging.

## Recording scenes

One script per terminal capture in `scenes/`, numbered to match the shooting script. Each script:
prints the command, pauses briefly, runs it, and shows elapsed time where relevant. Pre-typed and
deterministic, with no interactive prompts. Large font friendly: narrow result sets, `LIMIT` rows, no
wide `SELECT *` unless the scene calls for it.

| Script | Shooting-script scene | Phase |
| --- | --- | --- |
| `scenes/01_campaign_insert.sh` | 2:00 campaign born in PGD | 1 |
| `scenes/02_tiering_replication.sh` | 2:40 `list_tiered_tables()` and `bdr.analytics_table` | 1 |
| `scenes/03_clickstream_to_iceberg.sh` | 3:40 Kafka consumer plus Iceberg row count (two runs) | 1 |
| `scenes/04_build_audience.sh` | 4:10 WarehousePG CTAS plus summary | 2 |
| `scenes/05_duckdb_audience.sh` | 5:20 DuckDB reads the audience (optional) | 2 |
| `scenes/06_session_features.sh` | 6:20 hero session features in ClickHouse | 3 |
| `scenes/07_decide_and_record.sh` | 7:20 ranking query, elapsed time, insert, then the row in PGD | 3 |
| `scenes/08_engagement.sh` | 9:00 impression and tap events on the engagement topic | 4 |
| `scenes/09_redeem.sh` | 10:00 redemption transaction to `COMMIT` | 4 |
| `scenes/10_lift.sh` | 12:00 lift by region (pre-run) | 5 |

## Fallbacks allowed for tomorrow

- If the WarehousePG → Iceberg CTAS fails, write the audience from PGD with PGAA CTAS, and flag it so the
  narration can change.
- If ClickHouse can't read the catalog reliably, use Voltline's direct Iceberg table function or engine
  approach against the same tables.
- Pre-run any slow step and record its result rather than its execution. Note which scenes are pre-run.

Any other deviation from the architecture principles: ask first.

## Working agreements

- Verify component behaviour against EDB docs or Voltline, not memory. Cite the doc page in comments
  when a config choice depends on it.
- Keep it simple; resist over-engineering. Plain SQL and shell beat frameworks.
- Never hardcode or fabricate latency, row counts or lift numbers in scripts or comments; print what
  was measured.
- Avoid claims in output text that overstate the architecture. Don't say "zero copies" (the ClickHouse
  hot tier is a cache) or "real-time everywhere" (freshness differs by path).
- At the end of each phase, give a short status: what records cleanly, what's flaky, what's pre-run.
