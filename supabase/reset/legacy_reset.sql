-- WIN ZONE: ONE-TIME WIPE OF THE OLD STAKING APP.   *** PERMANENT. NO UNDO. ***
-- Run this ONCE, by hand, in Supabase: SQL Editor -> New query -> paste -> Run.
-- It erases everything in the "public" schema (the old app's tables, functions, policies).
-- It does NOT touch login accounts (auth.users) or anything outside "public".

-- Safety 1: refuse if the NEW WIN ZONE tables already exist (so this can never wipe live data).
do $$ begin
  if to_regclass('public.tournaments') is not null or to_regclass('public.fixtures') is not null then
    raise exception 'REFUSING TO RUN: the new WIN ZONE tables already exist. This script is only for the old staking database.';
  end if;
end $$;

-- Safety 2: refuse if any extension lives inside "public" (dropping the schema would remove it).
do $$ declare v text; begin
  select string_agg(e.extname, ', ') into v
  from pg_extension e join pg_namespace n on n.oid = e.extnamespace where n.nspname = 'public';
  if v is not null then
    raise exception 'REFUSING TO RUN: extensions are installed inside public (%). Tell Beanie before continuing.', v;
  end if;
end $$;

drop schema public cascade;
create schema public;

grant usage on schema public to postgres, anon, authenticated, service_role;
grant all on schema public to postgres, service_role;
alter default privileges in schema public grant all on tables    to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;
