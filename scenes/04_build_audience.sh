#!/usr/bin/env bash
# Scene 4:10 — WarehousePG builds the audience and writes it back to Iceberg (CTAS),
# then prints the qualified / control summary (hero: in audience, not control).
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

say "WarehousePG scores members over Iceberg and writes the audience back to Iceberg (CTAS)."
run "make audience" -- make --no-print-directory audience
