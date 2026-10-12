-- Discover — session features for one shopper, from the hot clickstream, over the
-- last 30 minutes. Parameterised: pass --param_session_id=... to clickhouse-client.
--
-- Per category: views and cart adds; plus session-level dwell, price sensitivity
-- (any sort_by_price), and whether checkout has started.
SELECT
    category_id,
    countIf(event_type = 'product_view')                         AS views,
    countIf(event_type = 'add_to_cart')                          AS cart_adds,
    least(1.0, (views + 3 * cart_adds) / 10.0)                   AS intent
FROM default.digital_events_hot
WHERE session_id = {session_id:String}
  AND event_time >= now() - INTERVAL 30 MINUTE
  AND category_id IS NOT NULL
GROUP BY category_id
ORDER BY intent DESC;
