#!/usr/bin/env bash
# Scene 2:00 — the campaign is born in PGD. Show the hero campaign row in the
# system of record and confirm PGAA is configured to replicate it to Iceberg.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

say "Kestrel Market — a new loyalty campaign lives in PGD (the system of record)."

run "psql -d kestrel -c 'SELECT offer_id, name, discount_pct, budget_total, status FROM kestrel_core.offers'" -- \
  kpsql -P pager=off -c "SELECT offer_id, name, discount_pct, budget_total, status, starts_at::date, ends_at::date FROM kestrel_core.offers;"

run "psql -d kestrel -c \"SELECT name FROM pgaa.list_catalogs()\"" -- \
  kpsql -P pager=off -c "SELECT name, status FROM pgaa.list_catalogs();"
