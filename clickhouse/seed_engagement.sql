-- Seed realistic campaign engagement into the hot tier so the marketing funnel is
-- coherent (assigned → shown → tapped → redeemed, monotonically decreasing),
-- instead of only the single live shopper's impression/tap.
--
-- Every treated (non-control) assignment gets an impression for ~90% of members
-- and a tap for ~45% — deterministic via a hash of the assignment id, so a
-- re-seed reproduces the same funnel. Redemptions (621) stay below taps, giving a
-- believable funnel. The live shopper's own impression/tap add on top.
--
-- Reads the assignments live from PGD through the PostgreSQL engine; run after
-- `make reset` clears the hot tables (the Makefile does this in `make reset`).

INSERT INTO default.offer_engagement_hot
    (event_time, member_id, session_id, event_type, offer_id, assignment_id, channel)
SELECT
    now64(3) - toIntervalHour(cityHash64(toString(assignment_id)) % 72),
    member_id, '', 'impression', offer_id, toString(assignment_id), 'app'
FROM default.pgd_offer_assignments
WHERE is_control = false
  AND cityHash64(toString(assignment_id)) % 100 < 90;

INSERT INTO default.offer_engagement_hot
    (event_time, member_id, session_id, event_type, offer_id, assignment_id, channel)
SELECT
    now64(3) - toIntervalHour(cityHash64(toString(assignment_id)) % 48),
    member_id, '', 'tap', offer_id, toString(assignment_id), 'app'
FROM default.pgd_offer_assignments
WHERE is_control = false
  AND cityHash64(concat(toString(assignment_id), 'tap')) % 100 < 45;
