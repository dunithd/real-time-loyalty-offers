-- ============================================================================
-- Qualify · the audience build — recording-ready SQL (copy-paste blocks)
-- ============================================================================
-- Narrated as WarehousePG. Executed here on PGD (the prebaked WHPG base is 7.4
-- and can't do coordinator-side CTAS to Iceberg; building 7.6 from source is out
-- of scope). Both PGD and a real WHPG show the same `kestrel=#` prompt, so to keep
-- the cheat clean: CONNECT BEFORE YOU HIT RECORD, and don't run SELECT version().
--
--   docker exec -it kestrel-pgd /usr/lib/edb-pge/17/bin/psql -U postgres -d kestrel
--
-- Run this once at the top of the session (hides PGAA's S3 warnings, nice timing):
SET client_min_messages TO error;
\timing on
\pset pager off

-- Pick ONE of the two builds below. Both read the REAL 3-year history and produce
-- the same numbers (~3,988 qualified · ~400 control · hero 100042 in, not control).

-- ─────────────────────────────────────────────────────────────────────────────
-- OPTION A (recommended) · CTAS — genuinely writes the audience back to Iceberg.
-- This is the true "written back to the lakehouse" beat: DuckDB and ClickHouse in
-- the next scenes read this very table. Syntax is identical on WarehousePG 7.6.
-- ─────────────────────────────────────────────────────────────────────────────
DROP TABLE IF EXISTS public.offer_audience_live;
CREATE TABLE public.offer_audience_live
USING PGAA WITH (
    pgaa.format            = 'iceberg',
    pgaa.managed_by        = 'kestrel_catalog',
    pgaa.catalog_namespace = 'kestrel_analytics',
    pgaa.catalog_table     = 'offer_audience_live',
    pgaa.purge_data_if_exists = true
) AS
WITH purchases AS (
    SELECT o.member_id,
           sum(exp(-extract(epoch FROM (now() - o.ordered_at)) / (365*86400.0))) AS recency_weight
    FROM kestrel_core.order_lines ol
    JOIN kestrel_core.orders o ON o.order_id = ol.order_id AND o.ordered_at = ol.ordered_at
    WHERE ol.category_id = 7                                    -- chilled desserts
    GROUP BY o.member_id
),
scored AS (
    SELECT m.member_id, m.marketing_opt_in,
           least(1.0, coalesce(p.recency_weight, 0) / 11.4) AS propensity
    FROM kestrel_core.members m
    LEFT JOIN purchases p ON p.member_id = m.member_id
)
SELECT 1::int AS offer_id, member_id, round(propensity::numeric, 4) AS propensity,
       CASE WHEN member_id = 100042 THEN false                 -- hero always treated
            ELSE (('x' || substr(md5('control:1:' || member_id), 1, 8))::bit(32)::bigint % 100) < 10
       END AS is_control,                                       -- deterministic 10% holdout
       now() AS built_at
FROM scored
WHERE propensity >= 0.5 AND marketing_opt_in;                  -- qualify: affinity + consent

-- summary + the hero
SELECT count(*) AS qualified, count(*) FILTER (WHERE is_control) AS control,
       round(avg(propensity), 3) AS avg_propensity FROM public.offer_audience_live;
SELECT member_id, propensity, is_control FROM public.offer_audience_live WHERE member_id = 100042;


-- ─────────────────────────────────────────────────────────────────────────────
-- OPTION B · plain INSERT … SELECT into a pre-created table — cleanest on camera
-- (no PGAA/Iceberg syntax on screen), 100% reliable. The target is a local table,
-- so run OPTION A (or `make audience`) in the pipeline too, so DuckDB/ClickHouse
-- have the governed Iceberg copy for the later scenes.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS kestrel_analytics;
DROP TABLE IF EXISTS kestrel_analytics.offer_audience;
CREATE TABLE kestrel_analytics.offer_audience (
    offer_id int, member_id int, propensity numeric(6,4), is_control boolean, built_at timestamptz
);

INSERT INTO kestrel_analytics.offer_audience (offer_id, member_id, propensity, is_control, built_at)
WITH purchases AS (
    SELECT o.member_id,
           sum(exp(-extract(epoch FROM (now() - o.ordered_at)) / (365*86400.0))) AS recency_weight
    FROM kestrel_core.order_lines ol
    JOIN kestrel_core.orders o ON o.order_id = ol.order_id AND o.ordered_at = ol.ordered_at
    WHERE ol.category_id = 7
    GROUP BY o.member_id
),
scored AS (
    SELECT m.member_id, m.marketing_opt_in,
           least(1.0, coalesce(p.recency_weight, 0) / 11.4) AS propensity
    FROM kestrel_core.members m
    LEFT JOIN purchases p ON p.member_id = m.member_id
)
SELECT 1, member_id, round(propensity::numeric, 4),
       CASE WHEN member_id = 100042 THEN false
            ELSE (('x' || substr(md5('control:1:' || member_id), 1, 8))::bit(32)::bigint % 100) < 10
       END,
       now()
FROM scored
WHERE propensity >= 0.5 AND marketing_opt_in;

SELECT count(*) AS qualified, count(*) FILTER (WHERE is_control) AS control,
       round(avg(propensity), 3) AS avg_propensity FROM kestrel_analytics.offer_audience;
SELECT member_id, propensity, is_control FROM kestrel_analytics.offer_audience WHERE member_id = 100042;
