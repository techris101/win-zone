#!/usr/bin/env bash
# Runs the migrations + tests against a throwaway local Postgres. Usage: run_local.sh [psql-connection-uri]
set -euo pipefail
cd "$(dirname "$0")"
URI="${1:-postgresql://postgres@localhost:5432/winzone_test}"
ADMIN="${URI%/*}/postgres"
psql "$ADMIN" -v ON_ERROR_STOP=1 -qc "drop database if exists winzone_test" -c "create database winzone_test"
run() { psql "$URI" -v ON_ERROR_STOP=1 -q -f "$1"; }
run 00_stub_supabase.sql
for f in ../migrations/*.sql; do echo "migrate $f"; run "$f"; done
run 10_flow.sql
run 20_safety.sql
run 30_match_fixes.sql
run 40_live.sql
echo "ALL TESTS PASSED"
