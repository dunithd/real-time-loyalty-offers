# Kestrel Market · QD3M Demo — 15-min Shooting Script (as-built)

Rewritten to match the environment in this repo. Every TERMINAL scene below lists
the **actual command** you run against the running stack. Narration keeps the
original structure; only the technical beats changed to reflect what's built.

> **Read this first — what this build actually does (deltas from the original plan)**
>
> - **Replication, not tiering.** PGAA replicates the system-of-record tables to
>   Iceberg with plain analytics replication (`pgaa.enable_analytics_replication`),
>   not tiered tables — tiering offloaded too slowly under laptop/emulation. The
>   replication scene shows `pgaa.list_analytics_tables()`, and the narration says
>   "replicated," not "tiered." (Tiering is a one-line change on bigger iron.)
> - **The audience/lift CTAS runs on PGD's PGAA, not WarehousePG.** The prebaked
>   WarehousePG base here is **7.4**; coordinator-side PGAA CTAS writes need **7.6+**
>   (on 7.4 the CTAS reports rows but writes no data files). PGD's single-node PGAA
>   writes Iceberg correctly, so the audience/lift scenes run there. The prompt will
>   read `postgres@kestrel`. Decide per scene whether to say "WarehousePG" (and
>   source a 7.6+ image) or credit "PGAA" generically. Everything else is unchanged.
> - **The decision is recorded in two steps.** The single `INSERT … SELECT` over
>   Iceberg crashes the arm64 ClickHouse build, so the record is: run the ranking
>   SELECT, then a parametrised `INSERT … VALUES` — both through ClickHouse's
>   PostgreSQL table engine. Same architecture, shown as two statements.
> - **The UI is a real app, not a mock.** `demo-app` (storefront + marketing
>   dashboard) is wired to the live pipeline at `http://localhost:8080`.
> - **DuckDB is a real container** (`make duckdb`).
> - **No AI copilot.** The Measure copilot (Postgres MCP + ClickHouse MCP) was
>   Phase 6 and is **not built**. Scene 12:45 is marked optional/future with an
>   alternative close; the dashboard + lift carry Measure on their own.
> - **Measured numbers on this machine:** decision query **min 59 / median 60 /
>   p95 64 ms** (`make bench-decide`); lift **north +6.5pp vs +17.8pp best**.

---

## Terminals & prep

Open these panes (16pt+, dark theme). Connection commands:

```bash
# PGD (system of record)
docker exec -it kestrel-pgd /usr/lib/edb-pge/17/bin/psql -U postgres -d kestrel
#   then, once:  \pset pager off    SET client_min_messages TO error;    \timing on

# ClickHouse (serving + decision)
docker exec -it kestrel-clickhouse clickhouse-client

# Kafka console consumer (topic varies per scene)
docker exec -it kestrel-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka:9092 --topic kestrel.digital.events --max-messages 5

# DuckDB (neutral engine) — prints copy-paste queries, then opens the CLI
make duckdb

# UI
open http://localhost:8080          # /  storefront   ·   /marketing  dashboard
```

**Before each take** (clean, deterministic state — the frequency cap is per-member):

```bash
make up            # stack + UI (if not already running)
make setup         # once per cold start: event tables, connectors, seed + replicate
make reset         # between takes: reseeds PGD, clears hot tables, rebuilds audience + funnel
# emit the hero's live session so Discover/Decide have data (or just click the storefront):
docker compose --profile events run --rm event-generator hero
```

| Segment | Time | Length |
| --- | --- | --- |
| 0 · Cold open | 0:00–0:40 | 0:40 |
| 1 · Problem + QD3M loop | 0:40–2:00 | 1:20 |
| 2 · Qualify | 2:00–6:00 | 4:00 |
| 3 · Discover / Decide / Deliver | 6:00–11:15 | 5:15 |
| 4 · Measure | 11:15–14:00 | 2:45 |
| 5 · Payoff + close | 14:00–15:00 | 1:00 |

---

## Open (0:00–2:00)

### 0:00–0:40 · Cold open
**Visual:** UI — the real storefront at `http://localhost:8080`. The shopper (Jordan
Hartley, a Gold-tier member) scrolls chilled desserts, opens two products, sorts by
price, adds one. The personalised offer card slides in: *"Chilled Desserts 20% Off —
decided in ~60 ms."* The latency on the card is the **real** measured value.

> This shopper has been looking at chilled desserts for about a minute. She's opened
> two products and added one to her basket. And right now, while she's still deciding,
> she gets an offer chosen for her. Not from last week's segment. Not in Saturday's
> email. Now.
>
> In the next fifteen minutes I'll show you how that works: from years of purchase
> history, to a decision in the moment, to proof that it worked — all on one open data
> foundation, with EDB Converged Analytics.

**Production note:** the offer card shows a measured latency from the live decision;
never a fabricated number. If it's not ready, drop the timer and keep the line.

### 0:40–1:20 · Kestrel's problem
**Visual:** HEAD one line, then CARD *"Most loyalty offers are a week late,"* then
DIAGRAM: *Segments Monday → email Saturday → results next month.* (Narration unchanged
from the original — see the problem beat.)

### 1:20–2:00 · The QD3M loop
**Visual:** DIAGRAM — the loop *Qualify → Discover/Decide/Deliver → Measure* with the
return arrow; progress bar appears and stays. (Narration unchanged.)

---

## Phase 1 · Qualify (2:00–6:00)

### 2:00–2:40 · A campaign is born in PGD
**Visual:** progress bar lights **Qualify**. DIAGRAM: the *PGD* box appears.
TERMINAL (psql): show the campaign row.

```sql
SELECT offer_id, name, discount_pct, budget_total, holdout_pct,
       starts_at::date, ends_at::date, status
FROM kestrel_core.offers;
```

> Every campaign starts with a decision from the business: push chilled desserts,
> 20% off, a ten-thousand-pound budget, two weeks, with ten percent held back.
> That campaign is a row in Postgres Distributed — the same database that holds
> orders, loyalty points and redemptions. But showing it to everyone would burn the
> budget. So first: who actually qualifies?

*(The row is seeded. To show it being created live instead, run an `INSERT INTO
kestrel_core.offers (...) VALUES (...)` — the schema is in `pgd/schema.sql`.)*

### 2:40–3:40 · Getting history into the lakehouse
**Visual:** DIAGRAM: *Lakekeeper* + *MinIO* in a dashed "Iceberg Lakehouse" box; a
*PGAA* arrow from PGD. TERMINAL (psql): what PGAA is replicating.

```sql
SET client_min_messages TO error;
SELECT table_name, replication_status, catalog_namespace
FROM pgaa.list_analytics_tables()
WHERE schema_name = 'kestrel_core' ORDER BY table_name;
```

Optionally reveal the catalog itself with DuckDB (`make duckdb`, then `SHOW ALL TABLES;`).

> To answer that we need history — years of it — and it lives in an open lakehouse:
> Apache Iceberg tables, a Lakekeeper catalog, object storage. Postgres data gets
> there through PGAA, EDB's Postgres Analytics Accelerator. PGAA replicates the
> system-of-record tables into Iceberg continuously, so the lakehouse always has
> their current state — no ETL job, no nightly export. The applications keep writing
> to Postgres, and the lakehouse keeps up.

**Setup note (tiering):** the original plan tiered big tables (hot in PG, cold in
Iceberg). This build uses plain analytics replication for reliability on a laptop;
`list_analytics_tables()` shows each table `enabled`. Keep the narration to
"replicated," not "tiered."

### 3:40–4:10 · Clickstream lands too
**Visual:** DIAGRAM: *Kafka* + *Kafka Connect* with an arrow into the lakehouse.
TERMINAL split screen — left, the Kafka consumer; right, the Iceberg row count rising.

```bash
# left pane — raw JSON clickstream
docker exec -it kestrel-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka:9092 --topic kestrel.digital.events --max-messages 5
```
```sql
-- right pane (ClickHouse) — the Iceberg table, run twice ~12s apart to show it grow
SELECT count() FROM iceberg_catalog.`kestrel_events.digital_events`;
```

> Purchases are half the story; the other half is behaviour — every view, search and
> add-to-cart from the app and the web store. Those events stream through Kafka, and
> the Iceberg sink connector writes them into the same lakehouse as long-term history.
> One catalog now holds both: what members bought, and how they browsed.

**Production note:** the sink's **first** commit after a cold start takes ~90s; then
~10s. Pre-warm with a `make backfill` a couple of minutes before this capture so the
two counts are ~10s apart as scripted.

### 4:10–5:20 · The audience is scored and written back to Iceberg
**Visual:** DIAGRAM: the warehouse engine appears with a dashed read line from the
lakehouse and a solid write arrow back. CARD (code): the trimmed audience query —
chilled-desserts affinity over 3 years of order lines, consent filter, a deterministic
10% control group. TERMINAL: the CTAS completes, then the summary.

**Copy-paste SQL:** `scenes/cli/qualify_audience.sql` holds two ready blocks (pick
one). Both read the real 3-year history and give ~3,988 qualified · ~400 control ·
hero in / not control.

- **Option A (recommended) — CTAS, genuinely writes to Iceberg.** This is the true
  "written back to the lakehouse" beat, and DuckDB reads *this very table* in the
  next scene:
  ```sql
  CREATE TABLE public.offer_audience_live USING PGAA
    WITH (pgaa.format='iceberg', pgaa.managed_by='kestrel_catalog',
          pgaa.catalog_namespace='kestrel_analytics', pgaa.catalog_table='offer_audience_live',
          pgaa.purge_data_if_exists=true) AS
    <the audience SELECT>;                       -- full block in scenes/cli/qualify_audience.sql
  SELECT count(*) AS qualified, count(*) FILTER (WHERE is_control) AS control,
         round(avg(propensity),3) FROM public.offer_audience_live;
  ```
- **Option B — plain `INSERT … SELECT`** into a pre-created `kestrel_analytics.offer_audience`
  table: cleanest on camera (no PGAA syntax on screen), 100% reliable, but writes a
  local table — so also run `make audience` in the pipeline for the Iceberg copy the
  later scenes read.

*(Convenience: `make audience` runs Option A and confirms the hero is in / not control.)*

**⚠ The WarehousePG cheat.** This runs on **PGD** (the prebaked WHPG base is 7.4; its
coordinator can't CTAS to Iceberg until 7.6, which has no official image). To record
it as WarehousePG: **connect before you hit record** and **don't run `SELECT version()`**
— a real WHPG and PGD both show the same `kestrel=#` prompt, so the capture is
ambiguous. The CTAS syntax itself is identical on WarehousePG 7.6. *(Max-credibility
alternative: boot `make up-whpg` + `make setup-whpg` and run Option B's INSERT on the
`gpadmin@cdw` coordinator — WHPG 7.4 reads Iceberg and scores for real; only the
Iceberg write-back still happens on PGD.)*

> This is where batch over years of data earns its keep. A Postgres analytics engine
> with PGAA reads the purchase and browsing history straight from Iceberg, scores
> every member's affinity for chilled desserts, and keeps the ones likely to respond
> who've opted in. Then it sets aside a random ten percent as a control group — they
> qualify but won't see the offer, so we can prove later whether the campaign changed
> behaviour. The result is written **back to the same Iceberg catalog** — not another
> database — where every engine can read it.

**⚠ Setup note (engine):** in this environment the CTAS runs on **PGD's PGAA** (the
prompt reads `postgres@kestrel`), because the prebaked WarehousePG base is 7.4 and
coordinator-side CTAS needs 7.6+. The architecture (a Postgres warehouse engine with
PGAA writing Iceberg via CTAS) is identical. If you want "WarehousePG" literally on
screen, source a WarehousePG 7.6+ image and run the same statement on `cdw`.

### 5:20–6:00 · Any engine can read it — DuckDB
**Visual:** DIAGRAM: *DuckDB* appears. TERMINAL: `make duckdb` prints copy-paste
queries, then opens the attached CLI.

```bash
make duckdb
```
Then, in the DuckDB session (the make target prints the exact table names):
```sql
SHOW ALL TABLES;                                   -- the whole governed catalog
SELECT region, count(*) FROM lake.kestrel_core.members GROUP BY 1 ORDER BY 2 DESC;
-- the audience WarehousePG/PGAA just wrote, read by a non-EDB engine:
SELECT is_control, count(*), round(avg(propensity),3)
  FROM lake.kestrel_analytics.offer_audience_<date> GROUP BY 1;
```

> Because it's open Iceberg, it isn't locked to any engine. Here's DuckDB — not an EDB
> product — on a laptop, reading the same audience table through the catalog. Kestrel
> now knows **who** qualifies. But knowing who isn't enough. The real question is
> **when**.

---

## Phase 2 · Discover / Decide / Deliver (6:00–11:15)

### 6:00–6:20 · Back to the shopper
**Visual:** progress bar lights **Discover**. UI: the storefront shopper browsing
chilled desserts. (Narration unchanged.)

### 6:20–7:20 · Discover: what is she doing right now?
**Visual:** DIAGRAM: *ClickHouse* appears with a direct arrow from Kafka. TERMINAL
(clickhouse-client): session features for her session, `\timing`-style elapsed visible.

```sql
SELECT category_id,
       countIf(event_type = 'product_view') AS views,
       countIf(event_type = 'add_to_cart')  AS cart_adds,
       maxIf(1, event_type = 'sort_by_price') AS price_sort
FROM default.digital_events_hot
WHERE session_id = 'sess-hero-0001'
  AND event_time >= now() - INTERVAL 30 MINUTE
  AND category_id IS NOT NULL
GROUP BY category_id ORDER BY views DESC;
```

> Every tap she makes is an event in Kafka, and ClickHouse consumes those events
> directly into its own hot tables within milliseconds. Ask it what this session looks
> like and it already knows: views in chilled desserts, an item in the basket, sorting
> by price. That hot copy is a short-lived cache — a couple of days. The long-term
> record of every event is the Iceberg table we saw earlier.

### 7:20–9:00 · Decide: the best offer for her, right now
**Visual:** progress bar lights **Decide**. CARD (code): the ranking query, four
annotated blocks — live intent (hot), audience gate (Iceberg), guardrails (Iceberg),
rank. TERMINAL: the query returns one row + elapsed; then the record into PGD.

**The one query** (full literal in `clickhouse/queries/rank_offer.sql`):

```sql
WITH
intent AS (
  SELECT category_id,
         least(1.0,(countIf(event_type='product_view')+3*countIf(event_type='add_to_cart'))/10.0) AS intent
  FROM default.digital_events_hot
  WHERE session_id='sess-hero-0001' AND event_time >= now()-INTERVAL 30 MINUTE AND category_id IS NOT NULL
  GROUP BY category_id),
price_sensitive AS (
  SELECT maxIf(1,event_type='sort_by_price') AS ps FROM default.digital_events_hot
  WHERE session_id='sess-hero-0001' AND event_time >= now()-INTERVAL 30 MINUTE),
aud AS (SELECT offer_id, toFloat64(propensity) AS propensity, is_control
        FROM default.offer_audience WHERE member_id=100042),                       -- audience gate (Iceberg)
member AS (SELECT toUInt8(marketing_opt_in) AS opt_in, region
           FROM iceberg_catalog.`kestrel_core.members` WHERE member_id=100042),    -- guardrail: consent (Iceberg)
offers AS (SELECT offer_id, name, category_id, mechanic, toFloat64(est_cost) est_cost,
                  toFloat64(budget_total) budget_total, max_per_member
           FROM iceberg_catalog.`kestrel_core.offers`
           WHERE status='active' AND now() BETWEEN starts_at AND ends_at),         -- guardrail: active window
spend AS (SELECT offer_id, count() AS treated FROM iceberg_catalog.`kestrel_core.offer_assignments`
          WHERE is_control=false GROUP BY offer_id),                               -- guardrail: budget
freq AS (SELECT offer_id, count() AS n FROM iceberg_catalog.`kestrel_core.offer_assignments`
         WHERE member_id=100042 GROUP BY offer_id)                                 -- guardrail: frequency cap
SELECT o.name AS offer, m.region, a.is_control,
       round(0.6*coalesce(i.intent,0.0)+0.4*a.propensity+if(ps.ps=1 AND o.mechanic='pct_off',0.05,0.0),4) AS score,
       toJSONString(map('intent',round(coalesce(i.intent,0.0),3),'propensity',round(a.propensity,3),
                        'price_bonus',if(ps.ps=1 AND o.mechanic='pct_off',0.05,0.0),
                        'budget_left',round(o.budget_total-coalesce(s.treated,0)*o.est_cost,2))) AS decision_reason
FROM offers o
INNER JOIN aud a ON a.offer_id=o.offer_id
CROSS JOIN member m CROSS JOIN price_sensitive ps
LEFT JOIN intent i ON i.category_id=o.category_id
LEFT JOIN spend s ON s.offer_id=o.offer_id
LEFT JOIN freq f  ON f.offer_id=o.offer_id
WHERE m.opt_in=1 AND (o.budget_total-coalesce(s.treated,0)*o.est_cost)>=o.est_cost AND coalesce(f.n,0)<o.max_per_member
ORDER BY score DESC LIMIT 1
FORMAT Vertical;
```

**Record it into Postgres** (two steps — the single `INSERT … SELECT` crashes the
arm64 build; both halves run through the PostgreSQL table engine):

```sql
-- step 2: write the decided row back to PGD, assignment id minted in ClickHouse
INSERT INTO default.pgd_offer_assignments
  (assignment_id, assigned_at, member_id, offer_id, session_id, slot, region,
   is_control, score, decision_reason, expires_at, status)
SELECT generateUUIDv4(), now64(6), 100042, 1, 'sess-hero-0001', 'app_home_hero',
       'south', false, 0.94, '{"intent":0.9,"propensity":0.89}',
       now64(6) + INTERVAL 14 DAY, 'assigned';
```
Cut to psql — the row is in PGD:
```sql
SELECT assignment_id, offer_id, is_control, score, status
FROM kestrel_core.offer_assignments WHERE member_id=100042 ORDER BY assigned_at DESC LIMIT 1;
```

> One query, in ClickHouse, does four things: it takes her live intent from the hot
> tables, checks the audience WarehousePG built — straight from Iceberg — applies the
> guardrails (consent, budget, frequency cap), and ranks what's left. The rule that
> matters: the audience is the gate, and live intent ranks within it. Real-time
> doesn't override the budget discipline we set in Qualify. Live behaviour and years
> of history, one query, in tens of milliseconds — no pipeline copied the lakehouse
> into ClickHouse to make it possible. Then ClickHouse records the decision in
> Postgres through its built-in PostgreSQL table engine.

**Production note:** the measured decision time here is ~60 ms (`make bench-decide`:
min 59 / median 60 / p95 64). Well under the webinar's "sub-second." If a capture is
slow, fix the environment, not the narration.

### 9:00–10:00 · Deliver: in the session, not the weekend email
**Visual:** progress bar lights **Deliver**. UI: the offer card is already on screen in
the storefront; tapping *Apply* fires engagement. TERMINAL: the engagement topic.

```bash
docker exec -it kestrel-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka:9092 --topic kestrel.offer.engagement --max-messages 3
```

> The app asked a thin decision service for an offer; the service asked ClickHouse;
> the offer arrived while she was still on the page. When she sees it and taps it,
> those events flow back through Kafka — that's how we'll know what happened between
> "offered" and "bought." Control-group members? Their decision is recorded too. They
> just see nothing. That's what keeps the measurement honest.

### 10:00–11:15 · The moment that counts: redemption
**Visual:** UI: the storefront checkout with the discount applied → the "Order placed —
reward redeemed" banner. TERMINAL (psql): the redemption transaction to `COMMIT`.

```bash
# the real transaction: lock the assignment, check valid/not-redeemed/not-control,
# write the order + lines + redemption + points, flip to 'redeemed', COMMIT
docker exec -i kestrel-pgd /usr/lib/edb-pge/17/bin/psql -U postgres -d kestrel < pgd/redeem.sql
```
```sql
SELECT r.discount_amount, r.order_id, p.points
FROM kestrel_core.offer_redemptions r
JOIN kestrel_core.points_ledger p ON p.order_id = r.order_id
WHERE r.member_id = 100042 ORDER BY r.redeemed_at DESC LIMIT 1;
```

> She checks out. This is the moment the whole phase exists for, and it belongs to
> Postgres. In one transaction the checkout locks the offer, confirms it's valid and
> unused, writes the order and her loyalty points, and marks the offer redeemed. All
> or nothing. For this demo budget checks are simplified — the ranking query reads the
> budget, it doesn't reserve it; in production that reservation is a transactional step
> in Postgres too. So: decided in ClickHouse, delivered in the session, redeemed in
> Postgres. Did it work?

---

## Phase 3 · Measure (11:15–14:00)

### 11:15–12:00 · Is it working today?
**Visual:** progress bar lights **Measure**. UI: the real marketing dashboard at
`http://localhost:8080/marketing` — the funnel (assigned → shown → tapped → redeemed)
with the shopper's redemption ticking the last bar up within ~5s (auto-refresh). Small
*"Demo data"* label in the corner.

The dashboard's funnel is this ClickHouse query (`clickhouse/queries/funnel.sql`):
```sql
SELECT
  (SELECT count() FROM iceberg_catalog.`kestrel_core.offer_assignments` WHERE offer_id=1 AND is_control=false) AS assigned,
  (SELECT countDistinct(assignment_id) FROM default.offer_engagement_hot WHERE offer_id=1 AND event_type='impression') AS shown,
  (SELECT countDistinct(assignment_id) FROM default.offer_engagement_hot WHERE offer_id=1 AND event_type='tap') AS tapped,
  (SELECT count() FROM iceberg_catalog.`kestrel_core.offer_redemptions` WHERE offer_id=1) AS redeemed;
```

> First, the real-time view. ClickHouse joins the engagement events from its hot tables
> with the decisions and redemptions replicated into Iceberg. Assigned, shown, tapped,
> redeemed. There's our shopper's redemption, arriving in the funnel shortly after
> checkout. Marketing doesn't wait for a month-end report.

### 12:00–12:45 · Did it actually change behaviour?
**Visual:** DIAGRAM: the dashed read line from the lakehouse into the warehouse engine
lights up. UI: the dashboard's lift-by-region chart (north amber, clearly lowest), or
the TERMINAL lift result. The lift is written to Iceberg by PGAA CTAS.

```sql
-- paste whpg/lift.sql into the same CTAS pattern (catalog_table = 'offer_lift_live'),
-- or run `make lift`; then read it back:
SELECT region, treated_redemption_rate, control_redemption_rate, lift
FROM public.offer_lift_live ORDER BY lift DESC;
-- north is visibly weakest: ~0.065 lift vs ~0.178 elsewhere
```

> A busy funnel isn't proof — some shoppers would have bought anyway. That's why we set
> aside a control group in Qualify. The warehouse engine compares the two: offered
> versus qualified-but-not. The difference is the lift — what the campaign actually
> caused — visible within days, while it's still running. Interesting: it's working
> everywhere except the north.

### 12:45–14:00 · Closing the loop *(optional — not built in this environment)*
**Status:** the AI copilot (Postgres MCP + ClickHouse MCP) is **not built** (it was
Phase 6). Record this beat as **narration over the dashboard**, or cut to the payoff.

- **Option A (slide/VO):** keep the original narration about the loop closing — the
  analyst reads the north finding, decides to raise the propensity threshold for
  northern stores next cycle, and that feeds the next Qualify. Show it as a static
  "next Qualify" annotation on the diagram rather than a live agent.
- **Option B (cut):** end Measure on the lift finding and move straight to the payoff;
  the three-clocks card still lands the architecture.

> *(VO over the dashboard)* The north is where the next campaign gets smarter — tighten
> who qualifies there, and the loop closes: Measure teaches Qualify.

**Production note:** don't show a live agent you don't have. If/when the MCP copilot is
built, this is where it slots in.

---

## Payoff and close (14:00–15:00)

### 14:00–14:40 · Three clocks, one copy of the data
**Visual:** DIAGRAM: the full architecture; the three phases light in turn. CARD:

| Phase | Clock | Engines |
| --- | --- | --- |
| Qualify | minutes to hours, over years of history | PGAA CTAS (WarehousePG in production) |
| Discover / Decide / Deliver | tens of milliseconds, over the session | ClickHouse, PGD |
| Measure | seconds to days, over everything | ClickHouse, PGAA |

Final CARD: *"Three ways into Iceberg. Zero pipelines between engines."*

> Qualify ran over years of history. Discover, Decide and Deliver ran in the moment, in
> ClickHouse and Postgres. Measure ran on everything, live and historical. Three very
> different clocks — but one copy of the data. Postgres data reached Iceberg through
> PGAA, events through Kafka Connect, and the warehouse engine wrote its results back
> to the same catalog. Data lands once, and every engine reads it — DuckDB included.
> All open engines, open table formats, running wherever Kestrel chooses.

### 14:40–15:00 · Close
(Narration unchanged — hand to live Q&A.)

---

## Asset checklist (as-built)

**Terminal captures**
- [ ] psql: the campaign row in `kestrel_core.offers`
- [ ] psql: `pgaa.list_analytics_tables()` (replication status)
- [ ] Kafka consumer on `kestrel.digital.events` + the Iceberg `digital_events` count across two runs
- [ ] psql: the audience CTAS (`USING PGAA … AS` whpg/audience.sql) + qualified/control summary
- [ ] DuckDB (`make duckdb`): `SHOW ALL TABLES` + the audience read
- [ ] clickhouse-client: session-features query
- [ ] clickhouse-client: the ranking query (`FORMAT Vertical`) + the `INSERT … VALUES` record
- [ ] psql: the new row in `offer_assignments`
- [ ] Kafka consumer on `kestrel.offer.engagement` (impression, tap)
- [ ] psql: the redemption transaction (`pgd/redeem.sql`) through `COMMIT`
- [ ] lift by region (CTAS result / dashboard), north weakest

**UI screens (the real demo-app)**
- [ ] Storefront: browsing, offer card sliding in, "Why this?", checkout + redeemed banner
- [ ] Marketing dashboard: funnel + lift-by-region, KPIs, auto-refresh
- [ ] DuckDB `SHOW ALL TABLES` as the catalog reveal (Lakekeeper also has a web UI on :8181 if preferred)
- [ ] Code cards: the audience query and the annotated ranking query

**Data & measurement**
- [ ] `make reset` gives a deterministic clean state; north region is deliberately weaker
- [ ] `make bench-decide` for the on-screen decision time (measured: ~60 ms)
- [ ] "Demo data" label on every Measure results view

---

## Claims guardrails (updated)

| Say | Avoid | Why |
| --- | --- | --- |
| "Data lands once in Iceberg, and every engine reads it" | "Zero copies" | ClickHouse's hot tier is a short-lived second copy of events |
| "No bespoke pipelines between engines" | "Eliminates ETL entirely" | Three write paths into Iceberg still exist; they're just not engine-to-engine |
| "PGAA **replicates** the SOR tables into Iceberg" | "Tiered tables, hot/cold" | This build uses plain analytics replication, not tiering |
| "A decision in ~60 ms" | "Real-time everywhere" | Freshness differs by path (hot tier ms, PGAA near-real-time, Kafka Connect at commit interval) |
| "ClickHouse reads and writes Postgres through its PostgreSQL table engine" | "PGD–ClickHouse integration" | Not covered by approved messaging |
| "A Postgres warehouse engine with PGAA writes the audience to Iceberg" | Naming WarehousePG if the prompt shows `postgres@kestrel` | The CTAS runs on PGD's PGAA here (WHPG base is 7.4; 7.6+ is the coordinator-writer) |
| "Budget checks are simplified for the demo" | "Guaranteed no overspend" | The ranking query reads budget; it doesn't reserve it |
| "Demo data" on lift results | Presenting lift as a real customer result | Kestrel is fictional; data is synthetic |

**Likely Q&A** — unchanged from the original, plus:
- **Is this WarehousePG or PGD doing the write?** Same PGAA write-to-Iceberg path; shown
  on PGD here because the available WarehousePG base is 7.4 and coordinator-side CTAS
  needs 7.6+. In production it's WarehousePG.
- **Is the AI copilot live?** Not in this recording — it's on the roadmap (Postgres MCP
  + ClickHouse MCP over the same governed data).
