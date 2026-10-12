#!/usr/bin/env bash
# Measure the decision-query latency: run rank_offer.sql N times via
# clickhouse-client and print min / median / p95. The number goes on screen, so
# it is measured, never assumed (CLAUDE.md). Runs inside the ClickHouse container
# so there is no cross-container DNS to flake.
set -euo pipefail

MEMBER="${1:-100042}"
SESSION="${2:-sess-hero-0001}"
N="${3:-20}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQL="$(cat "$ROOT/clickhouse/queries/rank_offer.sql")"

docker exec -i -e SQL="$SQL" -e MEMBER="$MEMBER" -e SESSION="$SESSION" -e N="$N" \
  kestrel-clickhouse bash -c '
    clickhouse-client --param_member_id="$MEMBER" --param_session_id="$SESSION" -q "$SQL" >/dev/null 2>&1
    for i in $(seq 1 "$N"); do
      s=$(date +%s%N)
      clickhouse-client --param_member_id="$MEMBER" --param_session_id="$SESSION" -q "$SQL" >/dev/null 2>&1
      e=$(date +%s%N)
      echo $(( (e - s) / 1000000 ))
    done | sort -n | awk "
      {a[NR]=\$1}
      END {
        printf \"decision query over %d runs (ms):\n\", NR
        printf \"  min    %6d\n\", a[1]
        printf \"  median %6d\n\", a[int((NR+1)/2)]
        printf \"  p95    %6d\n\", a[int(NR*0.95)<1?1:int(NR*0.95)]
      }"
  '
