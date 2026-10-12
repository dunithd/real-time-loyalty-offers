#!/usr/bin/env bash
# Scene 12:00 — did it work? Campaign lift by region on WarehousePG (treated vs
# control), written to Iceberg. The north region is visibly weaker. Pre-run.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

say "Measure: lift by region on WarehousePG — treated vs control. North is weaker."
run "make lift" -- make --no-print-directory lift
