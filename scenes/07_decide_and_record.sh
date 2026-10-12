#!/usr/bin/env bash
# Scene 7:20 — the one-query decision in ClickHouse: live intent + the audience
# gate + guardrails, ranked, timed, then recorded into PGD. Finally show the row
# landing back in PGD (the system of record).
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

say "One query, one engine: live intent + audience + guardrails -> the best offer."
run "decision query (ClickHouse)" -- timed make --no-print-directory decide

say "Measured latency over 20 runs (this number goes on screen):"
run "make bench-decide" -- make --no-print-directory bench-decide

say "Record the decision — ClickHouse INSERTs it into PGD via the PostgreSQL engine:"
run "make record-decision" -- make --no-print-directory record-decision
sleep 2
run "see it in PGD" -- kpsql -P pager=off -c \
  "SELECT assignment_id, member_id, offer_id, is_control, score, status FROM kestrel_core.offer_assignments WHERE member_id = 100042 ORDER BY assigned_at DESC LIMIT 1;"
