-- WIN ZONE — 0005 existing login accounts
-- Accounts created before this schema existed (e.g. by the old app) get a WIN ZONE profile, and
-- any player can confirm their age from the site. Safe to run on an empty database.

create or replace function public._unique_username(p_base text) returns text
language plpgsql security definer set search_path = public as $$
declare v text; v_try int := 0;
begin
  v := regexp_replace(coalesce(p_base, ''), '[^A-Za-z0-9_]', '', 'g');
  if length(v) < 3 then v := 'player' || v; end if;
  v := left(v, 20);
  while exists (select 1 from profiles where lower(username) = lower(v)) and v_try < 30 loop
    v := left(v, 15) || substr(md5(random()::text), 1, 4);
    v_try := v_try + 1;
  end loop;
  return v;
end $$;

create or replace function public._backfill_profiles() returns int
language plpgsql security definer set search_path = public as $$
declare u record; v_name text; v_n int := 0;
begin
  for u in select id, email, raw_user_meta_data from auth.users x
           where not exists (select 1 from profiles p where p.id = x.id) loop
    v_name := _unique_username(coalesce(u.raw_user_meta_data ->> 'username', split_part(u.email, '@', 1)));
    insert into profiles (id, username, display_name) values (u.id, v_name, v_name);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

select public._backfill_profiles();

-- A signed-in player confirms they are 18 or older (required before registering).
create or replace function public.confirm_age() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  update profiles set age_confirmed_at = coalesce(age_confirmed_at, now()) where id = auth.uid();
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public._unique_username(text), public._backfill_profiles() from public, anon, authenticated;
revoke execute on function public.confirm_age() from public, anon;
grant execute on function public.confirm_age() to authenticated;
