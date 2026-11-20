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
q -c "create type public.old_side as enum ('a', 'b');
      create table public.profiles (id uuid primary key, balance numeric);
      create table public.user_roles (user_id uuid, is_admin boolean);
      create table public.matches (id serial primary key, stake numeric);
      create table public.wallets (id serial primary key, amount numeric);
      create function public.old_signup() returns trigger language plpgsql as \$\$ begin insert into public.wallets(amount) values (0); return new; end \$\$;
      create trigger old_on_signup after insert on auth.users for each row execute function public.old_signup();
      create table public.bets (id serial primary key, match_id int references public.matches(id), side public.old_side);
      create view public.old_leaderboard as select id, amount from public.wallets;
      create domain public.old_money as numeric(12,2);
      create aggregate public.old_sum(numeric) (sfunc = numeric_add, stype = numeric, initcond = '0');
      insert into auth.users (email, raw_user_meta_data) values ('olduser@example.com', '{}');"

# the migrations must fail loudly on the old schema (never silently mix with it)
if q -f ../migrations/0001_schema.sql 2>/dev/null; then echo "FAIL: migrations ran on top of the old schema"; exit 1; fi
echo "ok: migrations refuse to run on the old schema"

# an extension living in public (like pg_net on a real project) must survive the wipe, with its own objects
q -c "create extension pg_trgm with schema public"
EXT_FUNCS_BEFORE=$(q -tAc "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')")

run ../reset/legacy_reset.sql
[ "$(q -tAc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','v','m','S') and not exists (select 1 from pg_depend d where d.objid=c.oid and d.deptype='e')")" = "0" ] || { echo "FAIL: old objects remain in public"; exit 1; }
[ "$(q -tAc "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')")" = "0" ] || { echo "FAIL: old functions remain"; exit 1; }
[ "$(q -tAc "select count(*) from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typtype in ('e','d')")" = "0" ] || { echo "FAIL: old types remain"; exit 1; }
[ "$(q -tAc "select count(*) from pg_trigger where tgname='old_on_signup'")" = "0" ] || { echo "FAIL: old auth trigger remains"; exit 1; }
[ "$(q -tAc "select count(*) from pg_extension where extname='pg_trgm'")" = "1" ] || { echo "FAIL: extension was removed"; exit 1; }
[ "$(q -tAc "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')")" = "$EXT_FUNCS_BEFORE" ] || { echo "FAIL: extension functions were removed"; exit 1; }
[ "$(q -tAc "select count(*) from auth.users")" = "1" ] || { echo "FAIL: login accounts were touched"; exit 1; }
echo "ok: old tables, views, functions, types and the auth trigger wiped; extension and login accounts kept"

for f in ../migrations/*.sql; do run "$f"; done
[ "$(q -tAc "select username from public.profiles")" = "olduser" ] || { echo "FAIL: old account was not given a profile"; exit 1; }
echo "ok: migrations build cleanly and the old account got a profile"

if q -f ../reset/legacy_reset.sql 2>/dev/null; then echo "FAIL: reset ran on a live WIN ZONE database"; exit 1; fi
echo "ok: reset refuses to run once the new schema exists"
echo "RESET TESTS PASSED"
