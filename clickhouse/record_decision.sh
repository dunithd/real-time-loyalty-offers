#!/usr/bin/env bash
# Decide (record) — ClickHouse computes the decision, then ClickHouse writes it
# into PGD through the PostgreSQL table engine.
#
# Done in TWO ClickHouse steps on purpose. The single INSERT ... SELECT (joins +
# aggregates over Iceberg, then a PostgreSQL-engine write) hits an illegal
# instruction in the clickhouse-server 25.10 arm64 build under the Docker VM and
# crashes the server. Both halves are fine on their own, so we run the ranking
# SELECT, capture the one row, and INSERT it with generateUUIDv4() — still
# entirely inside ClickHouse, still through the PostgreSQL engine. See
# DESIGN_NOTES.md.
#
# Usage: record_decision.sh <member_id> <session_id>
set -euo pipefail

MEMBER="${1:?member_id required}"
SESSION="${2:?session_id required}"
CH="docker exec -i kestrel-clickhouse clickhouse-client"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Step 1 — rank. One row: offer_id, offer_name, region, is_control, score, reason.
row="$($CH --param_member_id="$MEMBER" --param_session_id="$SESSION" \
        --format TSVRaw --multiquery < "$ROOT/clickhouse/queries/rank_offer.sql")"

if [ -z "$row" ]; then
    echo "no offer qualified for member $MEMBER / session $SESSION" >&2
    exit 1
fi

IFS=$'\t' read -r offer_id offer_name region is_control score reason <<<"$row"
echo "decision: offer=$offer_id ($offer_name) region=$region is_control=$is_control score=$score"

# Step 2 — record it into PGD via the PostgreSQL table engine. assignment_id is
# minted in ClickHouse with generateUUIDv4().
$CH --param_member="$MEMBER" --param_offer="$offer_id" --param_session="$SESSION" \
    --param_region="$region" --param_control="$is_control" --param_score="$score" \
    --param_reason="$reason" -q "
INSERT INTO default.pgd_offer_assignments
    (assignment_id, assigned_at, member_id, offer_id, session_id, slot, region,
     is_control, score, decision_reason, expires_at, status)
SELECT generateUUIDv4(), now64(6), {member:Int32}, {offer:Int32}, {session:String},
       'app_home_hero', {region:String}, {control:Bool}, {score:Float64},
       {reason:String}, now64(6) + INTERVAL 14 DAY, 'assigned'"

echo "recorded into PGD kestrel_core.offer_assignments"
