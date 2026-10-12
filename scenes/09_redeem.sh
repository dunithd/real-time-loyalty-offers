#!/usr/bin/env bash
# Scene 10:00 — redemption. One PGD transaction to COMMIT: lock the assignment,
# write the order, the redemption and the points, flip the assignment to redeemed.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

say "The shopper redeems. One transaction in PGD — the system of record."
run "psql -d kestrel -f pgd/redeem.sql" -- make --no-print-directory redeem
sleep 2
run "the assignment is now redeemed" -- kpsql -P pager=off -c \
  "SELECT a.assignment_id, a.status, r.discount_amount, r.order_id
   FROM kestrel_core.offer_assignments a
   JOIN kestrel_core.offer_redemptions r ON r.assignment_id = a.assignment_id
   WHERE a.member_id = 100042 ORDER BY a.assigned_at DESC LIMIT 1;"
