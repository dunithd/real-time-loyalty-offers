-- Kestrel Market — PGD system-of-record schema.
--
-- PGAA mirrors the Postgres schema name into the Iceberg namespace, so every
-- table lands at kestrel_core.<table>.
--
-- Two groups of tables:
--   * Dimensions (categories, stores, products, members, offers) — small, go to
--     Iceberg via plain analytics replication (pgaa.enable_analytics_replication).
--   * Fact/event tables (orders, order_lines, offer_assignments,
--     offer_redemptions, points_ledger) — go to Iceberg via tiered tables
--     (pgaa.convert_to_tiered_table with enable_replication := true).
--
-- Tiered-table constraints (verified against EDB docs — see DESIGN_NOTES.md):
--   * range partition column must be DATE/TIMESTAMP and part of the primary key
--     -> primary keys are composite, e.g. (order_id, ordered_at);
--   * no sequences and no foreign keys -> app-generated bigints and UUIDs, and
--     referential integrity is a seed/application invariant, not a constraint;
--   * a unique constraint on a partitioned table must include the partition
--     column -> "redeem once" is enforced by the redemption transaction
--     (SELECT ... FOR UPDATE + check), not by a constraint.
--
-- This file creates plain (non-partitioned) tables with the right composite PKs.
-- pgd/replicate.sql runs AFTER the seed: it enables replication on the
-- dimensions and converts the five fact tables to tiered tables.

DROP SCHEMA IF EXISTS kestrel_core CASCADE;
CREATE SCHEMA kestrel_core;

-- ── Dimensions ───────────────────────────────────────────────────────────────

CREATE TABLE kestrel_core.categories (
    category_id   int  PRIMARY KEY,
    name          text NOT NULL            -- includes 'chilled_desserts'
);

CREATE TABLE kestrel_core.stores (
    store_id      int  PRIMARY KEY,
    name          text NOT NULL,
    region        text NOT NULL            -- north | midlands | south | london
);

CREATE TABLE kestrel_core.products (
    product_id    int  PRIMARY KEY,
    name          text NOT NULL,
    category_id   int  NOT NULL,
    price         numeric(10,2) NOT NULL
);

CREATE TABLE kestrel_core.members (
    member_id        int  PRIMARY KEY,
    tier             text NOT NULL,        -- bronze | silver | gold
    home_store_id    int  NOT NULL,
    region           text NOT NULL,
    marketing_opt_in boolean NOT NULL
);

CREATE TABLE kestrel_core.offers (
    offer_id       int  PRIMARY KEY,
    name           text NOT NULL,
    category_id    int  NOT NULL,
    mechanic       text NOT NULL,          -- pct_off | points_multiplier
    discount_pct   numeric(5,2) NOT NULL,
    est_cost       numeric(8,2) NOT NULL,  -- modelled cost of one redemption
    budget_total   numeric(12,2) NOT NULL,
    max_per_member int  NOT NULL,
    -- frequency-cap window as text (e.g. '14 days'), NOT a Postgres interval:
    -- PGAA cannot offload Arrow Interval(MonthDayNano) to Iceberg (the sync worker
    -- errors "Feature Arrow datatype Interval(MonthDayNano) is not supported" and
    -- blocks the whole offload queue). See DESIGN_NOTES.md.
    cap_window     text NOT NULL,
    holdout_pct    numeric(5,2) NOT NULL,
    starts_at      timestamptz NOT NULL,
    ends_at        timestamptz NOT NULL,
    status         text NOT NULL           -- draft | active | ended
);

-- ── Fact / event tables (become tiered tables after seed) ────────────────────
--
-- Composite PKs include the DATE/TIMESTAMP partition column. No sequences, no
-- FKs (see header). ids are app-generated bigints; assignment_id is a UUID so
-- ClickHouse can mint it with generateUUIDv4() when recording a decision.

CREATE TABLE kestrel_core.orders (
    order_id    bigint      NOT NULL,
    ordered_at  timestamptz NOT NULL,          -- range partition column
    member_id   int         NOT NULL,
    store_id    int         NOT NULL,
    channel     text        NOT NULL,          -- store | app | web
    total       numeric(12,2) NOT NULL,
    PRIMARY KEY (order_id, ordered_at)
);

CREATE TABLE kestrel_core.order_lines (
    order_id    bigint      NOT NULL,
    ordered_at  timestamptz NOT NULL,          -- range partition column (carried from orders)
    line_no     int         NOT NULL,
    product_id  int         NOT NULL,
    category_id int         NOT NULL,
    qty         int         NOT NULL,
    amount      numeric(12,2) NOT NULL,
    PRIMARY KEY (order_id, ordered_at, line_no)
);

CREATE TABLE kestrel_core.offer_assignments (
    assignment_id   uuid        NOT NULL,
    assigned_at     timestamptz NOT NULL,      -- range partition column
    member_id       int         NOT NULL,
    offer_id        int         NOT NULL,
    session_id      text,
    slot            text,                       -- e.g. 'app_home_hero'
    region          text        NOT NULL,
    is_control      boolean     NOT NULL,
    score           numeric(6,4),
    decision_reason jsonb,
    expires_at      timestamptz,
    status          text        NOT NULL,       -- assigned | redeemed | expired
    PRIMARY KEY (assignment_id, assigned_at)
);

CREATE TABLE kestrel_core.offer_redemptions (
    redemption_id   bigint      NOT NULL,
    redeemed_at     timestamptz NOT NULL,       -- range partition column
    assignment_id   uuid        NOT NULL,
    order_id        bigint      NOT NULL,
    member_id       int         NOT NULL,
    offer_id        int         NOT NULL,
    discount_amount numeric(12,2) NOT NULL,
    PRIMARY KEY (redemption_id, redeemed_at)
);

CREATE TABLE kestrel_core.points_ledger (
    entry_id    bigint      NOT NULL,
    posted_at   timestamptz NOT NULL,           -- range partition column
    member_id   int         NOT NULL,
    order_id    bigint,
    points      int         NOT NULL,
    kind        text        NOT NULL,           -- earn | burn
    PRIMARY KEY (entry_id, posted_at)
);
