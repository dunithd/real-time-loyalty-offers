#!/usr/bin/env bash
# Scene 9:00 — the shopper sees and taps the offer. Emit impression + tap on the
# engagement topic for the hero's live assignment.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

say "The offer is shown and tapped — engagement events on kestrel.offer.engagement."
run "make engagement" -- make --no-print-directory engagement
sleep 3
run "engagement in ClickHouse hot tier" -- docker exec -i kestrel-clickhouse clickhouse-client -q \
  "SELECT event_type, count() FROM default.offer_engagement_hot WHERE offer_id = 1 GROUP BY event_type ORDER BY event_type"
