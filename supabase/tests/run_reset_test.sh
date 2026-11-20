#!/usr/bin/env bash
# Proves the one-time legacy wipe: refuses when unsafe, wipes an old-style schema, then lets the migrations build cleanly.
set -euo pipefail
cd "$(dirname "$0")"
URI="${1:-postgresql://postgres@localhost:5432/winzone_reset}"
ADMIN="${URI%/*}/postgres"
psql "$ADMIN" -v ON_ERROR_STOP=1 -qc "drop database if exists winzone_reset" -c "create database winzone_reset"
q()   { psql "$URI" -v ON_ERROR_STOP=1 -q "$@"; }
run() { q -f "$1"; }
run 00_stub_supabase.sql

# an "old app": same table names as the new schema, an old trigger on auth.users, one old user
q -c "create table public.profiles (id uuid primary key, balance numeric);
      create table public.user_roles (user_id uuid, is_admin boolean);
      create table public.matches (id serial primary key, stake numeric);
      create table public.wallets (id serial primary key, amount numeric);
      create function public.old_signup() returns trigger language plpgsql as \$\$ begin insert into public.wallets(amount) values (0); return new; end \$\$;
      create trigger old_on_signup after insert on auth.users for each row execute function public.old_signup();
      insert into auth.users (email, raw_user_meta_data) values ('olduser@example.com', '{}');"

# the migrations must fail loudly on the old schema (never silently mix with it)
if q -f ../migrations/0001_schema.sql 2>/dev/null; then echo "FAIL: migrations ran on top of the old schema"; exit 1; fi
echo "ok: migrations refuse to run on the old schema"

# safety 2: an extension inside public blocks the wipe
q -c "create extension if not exists pg_trgm with schema public"
if q -f ../reset/legacy_reset.sql 2>/dev/null; then echo "FAIL: reset ran with an extension in public"; exit 1; fi
q -c "drop extension pg_trgm"
echo "ok: reset refuses when an extension lives in public"

run ../reset/legacy_reset.sql
[ "$(q -tAc "select count(*) from information_schema.tables where table_schema='public'")" = "0" ] || { echo "FAIL: public not empty"; exit 1; }
[ "$(q -tAc "select count(*) from auth.users")" = "1" ] || { echo "FAIL: login accounts were touched"; exit 1; }
echo "ok: old tables wiped, login accounts kept"

for f in ../migrations/*.sql; do run "$f"; done
[ "$(q -tAc "select username from public.profiles")" = "olduser" ] || { echo "FAIL: old account was not given a profile"; exit 1; }
echo "ok: migrations build cleanly and the old account got a profile"

if q -f ../reset/legacy_reset.sql 2>/dev/null; then echo "FAIL: reset ran on a live WIN ZONE database"; exit 1; fi
echo "ok: reset refuses to run once the new schema exists"
echo "RESET TESTS PASSED"
