-- WIN ZONE: ONE-TIME WIPE OF THE OLD STAKING APP.   *** PERMANENT. NO UNDO. ***
-- Run this ONCE, by hand, in Supabase: SQL Editor -> New query -> paste -> Run.
--
-- Deletes the old app's tables, views, functions and custom types inside the "public" schema.
-- Leaves alone: login accounts (auth.users), everything outside "public", and every installed
-- extension (for example pg_net), including anything an extension put in "public".
-- Runs as a single block: if anything fails, nothing is deleted.

do $$
declare
  r record;
  n_tables int := 0;
  n_funcs int := 0;
begin
  -- Safety: refuse if the NEW WIN ZONE tables already exist, so this can never wipe live data.
  if to_regclass('public.tournaments') is not null or to_regclass('public.fixtures') is not null then
    raise exception 'REFUSING TO RUN: the new WIN ZONE tables already exist. This script is only for the old staking database.';
  end if;

  -- views and materialized views
  for r in
    select c.relname, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('v', 'm')
      and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
  loop
    execute format('drop %s if exists public.%I cascade', case r.relkind when 'm' then 'materialized view' else 'view' end, r.relname);
  end loop;

  -- tables (cascade removes their policies, triggers, indexes and owned sequences)
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p', 'f') and not c.relispartition
      and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
  loop
    execute format('drop table if exists public.%I cascade', r.relname);
    n_tables := n_tables + 1;
  end loop;

  -- leftover sequences
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'S'
      and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype in ('e', 'a', 'i'))
  loop
    execute format('drop sequence if exists public.%I cascade', r.relname);
  end loop;

  -- functions, procedures, aggregates (cascade also removes triggers that call them, even on auth.users)
  for r in
    select p.oid::regprocedure::text as sig, p.prokind from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('drop %s if exists %s cascade', case r.prokind when 'p' then 'procedure' when 'a' then 'aggregate' else 'function' end, r.sig);
    n_funcs := n_funcs + 1;
  end loop;

  -- custom types and domains
  for r in
    select t.oid::regtype::text as tname, t.typtype from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typtype in ('e', 'd')
      and not exists (select 1 from pg_depend d where d.classid = 'pg_type'::regclass and d.objid = t.oid and d.deptype = 'e')
  loop
    execute format('drop %s if exists %s cascade', case r.typtype when 'd' then 'domain' else 'type' end, r.tname);
  end loop;

  raise notice 'Wiped % old tables and % old functions. Extensions were left untouched.', n_tables, n_funcs;
end $$;
