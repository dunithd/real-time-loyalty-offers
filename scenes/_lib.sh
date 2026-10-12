#!/usr/bin/env bash
# Shared helpers for the recording scenes. Each scene prints the command it is
# about to run (large-font friendly), pauses briefly, runs it, and shows elapsed
# time where it matters. Deterministic, no interactive prompts.
#
# Env knobs: PAUSE (seconds before each command, default 1.5), NO_PAUSE=1 to skip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PAUSE="${PAUSE:-1.5}"
BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'; NC=$'\033[0m'

say()  { printf '\n%s%s%s\n' "$CYAN" "$*" "$NC"; }
step() { printf '\n%s$ %s%s\n' "$BOLD" "$*" "$NC"; [ "${NO_PAUSE:-0}" = 1 ] || sleep "$PAUSE"; }

# run <display-cmd> -- <actual command...>   (prints then runs)
run() {
    local display=() ; while [ "$1" != "--" ]; do display+=("$1"); shift; done; shift
    step "${display[*]}"
    "$@"
}

# psql into PGD
kpsql() { docker exec -i kestrel-pgd /usr/lib/edb-pge/17/bin/psql -U postgres -d kestrel "$@"; }
# clickhouse-client
kch()   { docker exec -i kestrel-clickhouse clickhouse-client "$@"; }
# psql into WHPG coordinator
kwhpg() { docker exec -i cdw /usr/edb/whpg7/bin/psql -U gpadmin -d kestrel "$@"; }

timed() { local t0 t1; t0=$(date +%s.%N); "$@"; t1=$(date +%s.%N); printf '%s(elapsed %.2fs)%s\n' "$DIM" "$(echo "$t1 - $t0" | bc)" "$NC"; }
