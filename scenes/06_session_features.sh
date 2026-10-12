#!/usr/bin/env bash
# Scene 6:20 — the hero's live session features in ClickHouse (from the hot
# clickstream). Inject the hero session first so there is live intent to show.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

say "The hero is browsing chilled desserts right now. ClickHouse reads the live session."
run "make hero   (inject the hero's live session)" -- make --no-print-directory hero
sleep 3
run "session features (ClickHouse, last 30 min)" -- make --no-print-directory session-features
