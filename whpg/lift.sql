-- Measure — campaign lift by region on WarehousePG over kestrel_core (Iceberg via
-- PGAA read-handles). Treated vs control redemption rate and average basket per
-- region for the hero campaign. build_lift.py wraps this in a PGAA CTAS write to
-- offer_lift_daily_<yyyymmdd> in kestrel_analytics.
--
-- The seed makes the north region's TREATED redemption rate visibly lower, so the
-- lift (treated_rate - control_rate) is smallest in the north.
WITH assigned AS (
    SELECT a.member_id, a.region, a.is_control,
           (r.redemption_id IS NOT NULL) AS redeemed,
           r.order_id
    FROM kestrel_core.offer_assignments a
    LEFT JOIN kestrel_core.offer_redemptions r
      ON r.assignment_id = a.assignment_id
    WHERE a.offer_id = 1
),
baskets AS (
    SELECT o.order_id, o.ordered_at, o.total
    FROM kestrel_core.orders o
)
SELECT
    a.region,
    count(*) FILTER (WHERE NOT a.is_control)                                   AS treated_members,
    count(*) FILTER (WHERE a.is_control)                                       AS control_members,
    round(avg((a.redeemed AND NOT a.is_control)::int)::numeric, 4)             AS treated_redemption_rate,
    round(avg((a.redeemed AND a.is_control)::int)::numeric, 4)                 AS control_redemption_rate,
    round((avg((a.redeemed AND NOT a.is_control)::int)
         - avg((a.redeemed AND a.is_control)::int))::numeric, 4)               AS lift,
    round(avg(bk.total) FILTER (WHERE a.redeemed AND NOT a.is_control)::numeric, 2) AS avg_basket_treated,
    round(avg(bk.total) FILTER (WHERE a.redeemed AND a.is_control)::numeric, 2)     AS avg_basket_control
FROM assigned a
LEFT JOIN baskets bk ON bk.order_id = a.order_id
GROUP BY a.region
ORDER BY lift DESC;
