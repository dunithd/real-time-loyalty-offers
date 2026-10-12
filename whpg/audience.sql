-- Qualify — the audience SELECT.
--
-- Runs on PGD (PGAA CTAS fallback), reading the system-of-record tables locally.
-- The intended engine was WarehousePG, but the prebaked WHPG base is 7.4.0 and
-- coordinator-side PGAA CTAS writes need 7.6+ (verified: on 7.4 the CTAS reports
-- the SELECT cardinality but persists no data files). PGD's single-node PGAA
-- writes Iceberg correctly, so build_audience.py runs this there. See DESIGN_NOTES.md.
--
-- build_audience.py wraps this in CREATE TABLE ... USING PGAA ... AS <this>, which
-- lands offer_audience_<yyyymmdd> in the kestrel_analytics namespace.
--
-- Propensity for the offer's category (chilled_desserts = 7) from 3 years of order
-- lines, recency-weighted. Qualify where propensity >= 0.5 AND opted in. Constants
-- tuned against the seed: dessert recency_weight p75 ~= 5.7 and the ~25%
-- dessert-lover segment sits above it, so rw/11.4 maps p75 -> 0.5; the hero
-- (member 100042) lands ~0.89. (Browse signal from clickstream is intentionally
-- not used here: digital_events in Iceberg can lag the Kafka sink commit, and the
-- purchase history is the reliable 3-year signal.)
--
-- The holdout split is deterministic (md5 of offer+member), ~10%. The hero is
-- forced non-control: they are the known demo shopper and must receive the offer
-- live (CLAUDE.md "not in the control group").
WITH purchases AS (
    SELECT o.member_id,
           sum(exp(-extract(epoch FROM (now() - o.ordered_at)) / (365*86400.0))) AS recency_weight
    FROM kestrel_core.order_lines ol
    JOIN kestrel_core.orders o
      ON o.order_id = ol.order_id AND o.ordered_at = ol.ordered_at
    WHERE ol.category_id = 7
    GROUP BY o.member_id
),
scored AS (
    SELECT
        m.member_id,
        m.marketing_opt_in,
        least(1.0, coalesce(p.recency_weight, 0) / 11.4) AS propensity
    FROM kestrel_core.members m
    LEFT JOIN purchases p ON p.member_id = m.member_id
)
SELECT
    1::int                                   AS offer_id,
    member_id,
    round(propensity::numeric, 4)            AS propensity,
    CASE WHEN member_id = 100042 THEN false
         ELSE (('x' || substr(md5('control:1:' || member_id), 1, 8))::bit(32)::bigint % 100) < 10
    END                                      AS is_control,
    now()                                    AS built_at
FROM scored
WHERE propensity >= 0.5
  AND marketing_opt_in;
