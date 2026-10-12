#!/usr/bin/env bash
# Scene 5:20 — DuckDB (a non-EDB engine) reads the audience from Iceberg with
# vended credentials, showing the lakehouse is open. Optional scene.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

say "DuckDB — not an EDB product — reads the same audience table from Iceberg."
run "tools duckdb_audience.py" -- \
  docker compose --profile tools run --rm -T tools duckdb_audience.py
