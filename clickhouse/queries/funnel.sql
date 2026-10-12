-- Measure — the live funnel for the hero campaign: assigned -> shown (impression)
-- -> tapped -> redeemed. Assignments and redemptions are read from Iceberg
-- (kestrel_core, PGAA), impressions/taps from the hot engagement tier. One row,
-- four counts; parameter {offer_id:Int64}.
SELECT
    (SELECT count() FROM iceberg_catalog.`kestrel_core.offer_assignments`
       WHERE offer_id = {offer_id:Int64} AND is_control = false)        AS assigned,
    (SELECT countDistinct(assignment_id) FROM default.offer_engagement_hot
       WHERE offer_id = {offer_id:Int64} AND event_type = 'impression') AS shown,
    (SELECT countDistinct(assignment_id) FROM default.offer_engagement_hot
       WHERE offer_id = {offer_id:Int64} AND event_type = 'tap')        AS tapped,
    (SELECT count() FROM iceberg_catalog.`kestrel_core.offer_redemptions`
       WHERE offer_id = {offer_id:Int64})                              AS redeemed;
