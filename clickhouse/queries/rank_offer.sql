-- Decide — the one-query decision (CLAUDE.md "Decision (ClickHouse, Decide)").
-- Combines, in a single query in a single engine:
--   * LIVE intent      — from the hot clickstream (digital_events_hot)
--   * the AUDIENCE gate — offer_audience (WarehousePG CTAS, read from Iceberg)
--   * GUARDRAILS        — offer active/in-window, member opt-in, soft budget,
--                         frequency cap (all read from Iceberg kestrel_core)
-- then scores and returns the single best offer with a decision_reason JSON.
--
-- Parameters: {member_id:Int64}, {session_id:String}.
-- The audience is the gate; live intent ranks within it (a member not in the
-- audience gets no offer).
WITH
intent AS (
    SELECT category_id,
           least(1.0, (countIf(event_type = 'product_view')
                       + 3 * countIf(event_type = 'add_to_cart')) / 10.0) AS intent
    FROM default.digital_events_hot
    WHERE session_id = {session_id:String}
      AND event_time >= now() - INTERVAL 30 MINUTE
      AND category_id IS NOT NULL
    GROUP BY category_id
),
price_sensitive AS (
    SELECT maxIf(1, event_type = 'sort_by_price') AS ps
    FROM default.digital_events_hot
    WHERE session_id = {session_id:String}
      AND event_time >= now() - INTERVAL 30 MINUTE
),
aud AS (
    SELECT offer_id, toFloat64(propensity) AS propensity, is_control
    FROM default.offer_audience
    WHERE member_id = {member_id:Int64}
),
member AS (
    SELECT toUInt8(marketing_opt_in) AS opt_in, region
    FROM iceberg_catalog.`kestrel_core.members`
    WHERE member_id = {member_id:Int64}
),
offers AS (
    SELECT offer_id, name, category_id, mechanic,
           toFloat64(est_cost) AS est_cost, toFloat64(budget_total) AS budget_total,
           max_per_member
    FROM iceberg_catalog.`kestrel_core.offers`
    WHERE status = 'active' AND now() BETWEEN starts_at AND ends_at
),
spend AS (
    SELECT offer_id, count() AS treated
    FROM iceberg_catalog.`kestrel_core.offer_assignments`
    WHERE is_control = false
    GROUP BY offer_id
),
freq AS (
    SELECT offer_id, count() AS n
    FROM iceberg_catalog.`kestrel_core.offer_assignments`
    WHERE member_id = {member_id:Int64}
    GROUP BY offer_id
)
SELECT
    o.offer_id                                                        AS offer_id,
    o.name                                                            AS offer_name,
    m.region                                                          AS region,
    a.is_control                                                      AS is_control,
    round(0.6 * coalesce(i.intent, 0.0)
          + 0.4 * a.propensity
          + if(ps.ps = 1 AND o.mechanic = 'pct_off', 0.05, 0.0), 4)   AS score,
    toJSONString(map(
        'intent',          round(coalesce(i.intent, 0.0), 3),
        'propensity',      round(a.propensity, 3),
        'price_sensitive', toFloat64(ps.ps),
        'price_bonus',     if(ps.ps = 1 AND o.mechanic = 'pct_off', 0.05, 0.0),
        'budget_left',     round(o.budget_total - coalesce(s.treated, 0) * o.est_cost, 2),
        'freq_count',      toFloat64(coalesce(f.n, 0))
    ))                                                                AS decision_reason
FROM offers AS o
INNER JOIN aud    AS a  ON a.offer_id = o.offer_id
CROSS JOIN member AS m
CROSS JOIN price_sensitive AS ps
LEFT  JOIN intent AS i  ON i.category_id = o.category_id
LEFT  JOIN spend  AS s  ON s.offer_id = o.offer_id
LEFT  JOIN freq   AS f  ON f.offer_id = o.offer_id
WHERE m.opt_in = 1
  AND (o.budget_total - coalesce(s.treated, 0) * o.est_cost) >= o.est_cost
  AND coalesce(f.n, 0) < o.max_per_member
ORDER BY score DESC
LIMIT 1;
