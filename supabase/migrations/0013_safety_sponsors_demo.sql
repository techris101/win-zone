-- WIN ZONE — 0013 trust and safety, sponsors, demo mode
-- Player reports and suspensions, account deletion, dispute evidence (private storage), responsible play
-- (take a break, limit on tournaments at once, blocked countries), sponsor placements, demo tournaments
-- played by bots. Nothing here involves money.

-- ---------------------------------------------------------------- columns
alter table public.profiles add column banned_until timestamptz;            -- 'infinity' = permanent
alter table public.profiles add column ban_reason text;
alter table public.profiles add column break_until timestamptz;             -- chosen by the player, cannot be shortened
alter table public.profiles add column max_active_tournaments int check (max_active_tournaments is null or max_active_tournaments between 1 and 20);
alter table public.profiles add column deleted_at timestamptz;
alter table public.countries add column blocked boolean not null default false;
alter table public.tournaments add column is_demo boolean not null default false;
alter table public.sponsors add column active boolean not null default true;
alter table public.sponsors add column show_on_home boolean not null default false;
alter table public.sponsors add constraint sponsors_urls_https
  check ((logo_url is null or logo_url ~ '^https://') and (website is null or website ~ '^https://'));
alter table public.sponsors add constraint sponsors_name_len check (length(name) between 1 and 60);

-- ---------------------------------------------------------------- reports
create table public.player_reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null,
  reported_id uuid not null,
  fixture_id  uuid references public.fixtures (id) on delete set null,
  reason      text not null check (reason in ('cheating', 'abuse', 'impersonation', 'no_show', 'other')),
  details     text check (details is null or length(details) <= 1000),
  status      text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at  timestamptz not null default now()
);
create index player_reports_open_idx on public.player_reports (status, created_at);
alter table public.player_reports enable row level security;
grant select on public.player_reports to authenticated;
create policy reports_admin on public.player_reports for select to authenticated using (public.is_admin());
create policy reports_own   on public.player_reports for select to authenticated using (reporter_id = auth.uid());

create table public.dispute_evidence (
  id         uuid primary key default gen_random_uuid(),
  fixture_id uuid not null references public.fixtures (id) on delete cascade,
  user_id    uuid not null,
  path       text not null unique,
  note       text check (note is null or length(note) <= 300),
  created_at timestamptz not null default now()
);
alter table public.dispute_evidence enable row level security;
grant select on public.dispute_evidence to authenticated;
create policy evidence_read on public.dispute_evidence for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
grant select on public.player_reports, public.dispute_evidence to service_role;

-- ---------------------------------------------------------------- helpers
create or replace function public._is_banned(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select banned_until > now() from profiles where id = p_user), false)
$$;

-- ---------------------------------------------------------------- reports: players
create or replace function public.report_player(p_username text, p_reason text, p_details text default null, p_fixture_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_target uuid; v_recent int;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  select id into v_target from profiles where lower(username) = lower(trim(p_username)) and deleted_at is null and not is_bot;
  if v_target is null then return jsonb_build_object('ok', false, 'reason', 'player_not_found'); end if;
  if v_target = v_uid then return jsonb_build_object('ok', false, 'reason', 'cannot_report_self'); end if;
  if p_reason not in ('cheating', 'abuse', 'impersonation', 'no_show', 'other') then
    return jsonb_build_object('ok', false, 'reason', 'bad_reason');
  end if;
  if p_fixture_id is not null and not exists (
      select 1 from fixtures where id = p_fixture_id and v_uid in (player_a_id, player_b_id) and v_target in (player_a_id, player_b_id)) then
    return jsonb_build_object('ok', false, 'reason', 'not_your_match');
  end if;
  select count(*) into v_recent from player_reports where reporter_id = v_uid and created_at > now() - interval '1 day';
  if v_recent >= 5 then return jsonb_build_object('ok', false, 'reason', 'too_many_reports'); end if;
  if exists (select 1 from player_reports where reporter_id = v_uid and reported_id = v_target and status = 'open') then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  insert into player_reports (reporter_id, reported_id, fixture_id, reason, details)
  values (v_uid, v_target, p_fixture_id, p_reason, nullif(left(trim(coalesce(p_details, '')), 1000), ''));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- reports and suspensions: admins
create or replace function public.list_reports(p_status text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'reason', r.reason, 'details', r.details, 'status', r.status, 'created_at', r.created_at,
      'fixture_id', r.fixture_id,
      'reporter', (select username from profiles where id = r.reporter_id),
      'reported', (select username from profiles where id = r.reported_id),
      'reported_id', r.reported_id,
      'reported_banned_until', (select banned_until from profiles where id = r.reported_id),
      'reports_against', (select count(*) from player_reports x where x.reported_id = r.reported_id)) order by r.created_at desc)
    from player_reports r where p_status is null or r.status = p_status), '[]'::jsonb);
end $$;

create or replace function public.review_report(p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if p_status not in ('actioned', 'dismissed', 'open') then raise exception 'bad status'; end if;
  update player_reports set status = p_status, reviewed_by = auth.uid(), reviewed_at = now() where id = p_id;
  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'review_report', 'player_report', p_id, jsonb_build_object('status', p_status));
  return jsonb_build_object('ok', found);
end $$;

-- p_days null = permanent. Leaves registration of open tournaments; matches already planned stay for the admin to settle.
create or replace function public.ban_player(p_username text, p_days int, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_target uuid; v_until timestamptz; v_left int;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  select id into v_target from profiles where lower(username) = lower(trim(p_username)) and deleted_at is null;
  if v_target is null then return jsonb_build_object('ok', false, 'reason', 'player_not_found'); end if;
  if v_target = auth.uid() then return jsonb_build_object('ok', false, 'reason', 'cannot_ban_self'); end if;
  if exists (select 1 from user_roles where user_id = v_target and role = 'admin') then
    return jsonb_build_object('ok', false, 'reason', 'remove_admin_role_first');
  end if;
  if p_days is not null and (p_days < 1 or p_days > 3650) then return jsonb_build_object('ok', false, 'reason', 'bad_days'); end if;
  v_until := case when p_days is null then 'infinity'::timestamptz else now() + make_interval(days => p_days) end;
  update profiles set banned_until = v_until, ban_reason = nullif(left(trim(coalesce(p_reason, '')), 300), '') where id = v_target;
  update tournament_entries e set status = 'withdrawn'
  from tournaments t where t.id = e.tournament_id and e.user_id = v_target and t.status in ('draft', 'open') and e.status <> 'withdrawn';
  get diagnostics v_left = row_count;
  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'ban_player', 'profile', v_target, jsonb_build_object('days', p_days, 'reason', p_reason, 'left_tournaments', v_left));
  insert into notifications (user_id, kind, title, body, url, dedupe_key)
  values (v_target, 'account', 'Account suspended',
          case when p_days is null then 'Your account is suspended. Contact WIN ZONE if you think this is a mistake.'
               else 'Your account is suspended for ' || p_days || ' days. Contact WIN ZONE if you think this is a mistake.' end,
          '/contact.html', 'ban:' || extract(epoch from now())::bigint)
  on conflict do nothing;
  return jsonb_build_object('ok', true, 'until', v_until, 'left_tournaments', v_left);
end $$;

create or replace function public.unban_player(p_username text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_target uuid;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  select id into v_target from profiles where lower(username) = lower(trim(p_username));
  if v_target is null then return jsonb_build_object('ok', false, 'reason', 'player_not_found'); end if;
  update profiles set banned_until = null, ban_reason = null where id = v_target;
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'unban_player', 'profile', v_target);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.list_banned() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('username', username, 'until', banned_until, 'reason', ban_reason) order by banned_until desc)
                   from profiles where banned_until > now()), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- responsible play
-- A break can only be started or made longer by the player; it ends by itself.
create or replace function public.take_break(p_days int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_until timestamptz; v_left int;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  if p_days is null or p_days not in (1, 7, 30, 90, 180, 365) then return jsonb_build_object('ok', false, 'reason', 'bad_days'); end if;
  v_until := now() + make_interval(days => p_days);
  update profiles set break_until = greatest(coalesce(break_until, now()), v_until) where id = auth.uid()
  returning break_until into v_until;
  update tournament_entries e set status = 'withdrawn'
  from tournaments t where t.id = e.tournament_id and e.user_id = auth.uid() and t.status in ('draft', 'open') and e.status <> 'withdrawn';
  get diagnostics v_left = row_count;
  return jsonb_build_object('ok', true, 'until', v_until, 'left_tournaments', v_left);
end $$;

create or replace function public.set_play_limit(p_max int) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  if p_max is not null and (p_max < 1 or p_max > 20) then return jsonb_build_object('ok', false, 'reason', 'bad_limit'); end if;
  update profiles set max_active_tournaments = p_max where id = auth.uid();
  return jsonb_build_object('ok', true, 'max', p_max);
end $$;

create or replace function public.set_country_blocked(p_code text, p_blocked boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  update countries set blocked = coalesce(p_blocked, false) where code = upper(p_code);
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_country'); end if;
  insert into audit_logs (actor, action, entity, details)
  values (auth.uid(), 'set_country_blocked', 'country', jsonb_build_object('code', upper(p_code), 'blocked', p_blocked));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- existing functions, extended
create or replace function public._notify(
  p_user uuid, p_tid uuid, p_fixture uuid, p_kind text, p_params jsonb, p_dedupe text,
  p_url text default null, p_actions jsonb default null, p_wide boolean default false, p_at timestamptz default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_lang text; v_tz text; v_params jsonb := coalesce(p_params, '{}'::jsonb); v_msg jsonb; v_name text; v_slug text;
begin
  if p_user is null then return; end if;
  if exists (select 1 from profiles where id = p_user and (is_bot or deleted_at is not null)) then return; end if;
  if p_wide and not exists (select 1 from tournament_follows where user_id = p_user and tournament_id = p_tid and state in ('playing', 'following')) then
    return;
  end if;
  select pr.lang, c.tz into v_lang, v_tz from profiles pr left join countries c on c.code = pr.country where pr.id = p_user;
  select name, slug into v_name, v_slug from tournaments where id = p_tid;
  v_params := v_params || jsonb_build_object('t', coalesce(v_name, ''));
  if p_at is not null then
    v_params := v_params || jsonb_build_object('when', to_char(p_at at time zone coalesce(v_tz, 'Africa/Kigali'), 'DD/MM HH24:MI'));
  end if;
  v_msg := _msg(v_lang, p_kind, v_params);
  insert into notifications (user_id, tournament_id, fixture_id, kind, title, body, url, actions, dedupe_key)
  values (p_user, p_tid, p_fixture, p_kind, v_msg ->> 'title', v_msg ->> 'body',
          coalesce(p_url, case when v_slug is not null then '/t/' || v_slug end), p_actions, p_dedupe)
  on conflict (user_id, dedupe_key) do nothing;
end $$;

create or replace function public.register_for_tournament(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments; v_uid uuid := auth.uid(); v_count int; pr profiles;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  select * into t from tournaments where id = p_tid;
  if t.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if t.is_demo then return jsonb_build_object('ok', false, 'reason', 'demo_tournament'); end if;
  if t.status <> 'open' then return jsonb_build_object('ok', false, 'reason', 'registration_closed'); end if;
  if t.registration_closes_at is not null and now() > t.registration_closes_at then
    return jsonb_build_object('ok', false, 'reason', 'registration_closed');
  end if;
  select * into pr from profiles where id = v_uid;
  if pr.country is null then return jsonb_build_object('ok', false, 'reason', 'country_required'); end if;
  if pr.banned_until > now() then return jsonb_build_object('ok', false, 'reason', 'account_suspended'); end if;
  if pr.break_until > now() then return jsonb_build_object('ok', false, 'reason', 'on_break', 'until', pr.break_until); end if;
  if exists (select 1 from countries where code = pr.country and blocked) then
    return jsonb_build_object('ok', false, 'reason', 'country_not_available');
  end if;

  if exists (select 1 from tournament_entries where tournament_id = p_tid and user_id = v_uid and status <> 'withdrawn') then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if pr.max_active_tournaments is not null and (
       select count(*) from tournament_entries e join tournaments x on x.id = e.tournament_id
       where e.user_id = v_uid and e.status in ('registered', 'checked_in') and x.status in ('open', 'planning', 'live')) >= pr.max_active_tournaments then
    return jsonb_build_object('ok', false, 'reason', 'play_limit_reached');
  end if;
  select count(*) into v_count from tournament_entries where tournament_id = p_tid and status <> 'withdrawn';
  if v_count >= t.size then return jsonb_build_object('ok', false, 'reason', 'tournament_full'); end if;

  insert into tournament_entries (tournament_id, user_id) values (p_tid, v_uid)
  on conflict (tournament_id, user_id) do update set status = 'registered';
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.set_my_country(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text := upper(coalesce(p_code, ''));
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  if not exists (select 1 from countries where code = v) then return jsonb_build_object('ok', false, 'reason', 'unknown_country'); end if;
  if exists (select 1 from countries where code = v and blocked) then return jsonb_build_object('ok', false, 'reason', 'country_not_available'); end if;
  update profiles set country = v where id = auth.uid();
  return jsonb_build_object('ok', true, 'tz', (select tz from countries where code = v));
end $$;

create or replace function public.my_profile() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name,
                              'country', p.country, 'country_name', c.name, 'tz', c.tz, 'lang', p.lang,
                              'team_name', p.team_name, 'banned_until', case when p.banned_until > now() then p.banned_until end,
                              'ban_reason', case when p.banned_until > now() then p.ban_reason end,
                              'break_until', case when p.break_until > now() then p.break_until end,
                              'max_active_tournaments', p.max_active_tournaments, 'country_blocked', coalesce(c.blocked, false))
    from profiles p left join countries c on c.code = p.country where p.id = auth.uid()
  ), '{}'::jsonb)
$$;

create or replace function public.rankings(p_limit int default 100, p_search text default null)
returns table (user_id uuid, username text, display_name text, team_name text, played int, won int, drawn int, lost int,
               gf int, ga int, titles int, points int, win_rate numeric, rank int)
language sql stable security definer set search_path = public as $$
  with f as (
    select x.* from fixtures x join tournaments t on t.id = x.tournament_id
    where x.status = 'completed' and x.player_a_id is not null and x.player_b_id is not null
  ),
  r as (
    select player_a_id as uid, (winner_id = player_a_id)::int as w, (winner_id is null)::int as d,
           (winner_id is not null and winner_id <> player_a_id)::int as l,
           case when outcome = 'win_by_noshow' then 0 else coalesce(score_a, 0) end as gf,
           case when outcome = 'win_by_noshow' then 0 else coalesce(score_b, 0) end as ga from f
    union all
    select player_b_id, (winner_id = player_b_id)::int, (winner_id is null)::int,
           (winner_id is not null and winner_id <> player_b_id)::int,
           case when outcome = 'win_by_noshow' then 0 else coalesce(score_b, 0) end,
           case when outcome = 'win_by_noshow' then 0 else coalesce(score_a, 0) end from f
  ),
  agg as (
    select uid, count(*)::int as played, sum(w)::int as won, sum(d)::int as drawn, sum(l)::int as lost, sum(gf)::int as gf, sum(ga)::int as ga
    from r group by uid
  ),
  ranked as (
    select a.uid, p.username, p.display_name, p.team_name, a.played, a.won, a.drawn, a.lost, a.gf, a.ga,
           (select count(*) from tournaments t where t.champion_id = a.uid)::int as titles,
           (a.won * 3 + a.drawn)::int as points,
           round(100.0 * a.won / greatest(a.played, 1), 1) as win_rate
    from agg a join profiles p on p.id = a.uid where not p.is_bot and p.deleted_at is null
  )
  select * from (
    select ranked.*, (row_number() over (order by titles desc, points desc, win_rate desc, gf - ga desc, lower(username)))::int as rank
    from ranked
  ) q
  where p_search is null or q.username ilike '%' || p_search || '%' or q.display_name ilike '%' || p_search || '%' or q.team_name ilike '%' || p_search || '%'
  order by rank
  limit least(greatest(coalesce(p_limit, 100), 1), 500)
$$;

create or replace function public.public_player(p_username text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p profiles;
begin
  select * into p from profiles where lower(username) = lower(trim(p_username)) and not is_bot and deleted_at is null;
  if p.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  return jsonb_build_object('ok', true,
    'id', p.id, 'username', p.username, 'display_name', p.display_name, 'team_name', p.team_name, 'since', p.created_at,
    'career', career_stats(p.id),
    'rank', (select r.rank from rankings(500, null) r where r.user_id = p.id),
    'tournaments', coalesce((
      select jsonb_agg(jsonb_build_object('name', t.name, 'slug', t.slug, 'status', t.status, 'format', t.format,
                                          'champion', t.champion_id = p.id) order by t.created_at desc)
      from tournament_entries e join tournaments t on t.id = e.tournament_id
      where e.user_id = p.id and e.status <> 'withdrawn' and t.status in ('open', 'planning', 'live', 'completed')), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(x order by x ->> 'at' desc) from (
        select jsonb_build_object('at', f.completed_at, 'tournament', t.name, 'slug', t.slug,
          'opponent', (select coalesce(o.display_name, o.username) from profiles o where o.id = case when f.player_a_id = p.id then f.player_b_id else f.player_a_id end),
          'opponent_username', (select o.username from profiles o where o.id = case when f.player_a_id = p.id then f.player_b_id else f.player_a_id end),
          'me', case when f.player_a_id = p.id then f.score_a else f.score_b end,
          'opp', case when f.player_a_id = p.id then f.score_b else f.score_a end,
          'result', case when f.winner_id is null then 'D' when f.winner_id = p.id then 'W' else 'L' end) as x
        from fixtures f join tournaments t on t.id = f.tournament_id
        where f.status = 'completed' and p.id in (f.player_a_id, f.player_b_id)
        order by f.completed_at desc limit 10) q), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- account deletion
-- A player with match history is kept as an anonymous "Deleted player" so results and tables stay correct;
-- everything personal is removed. A player with no history is removed completely.
create or replace function public.handle_deleted_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from user_roles where user_id = old.id;
  delete from push_subscriptions where user_id = old.id;
  delete from notifications where user_id = old.id;
  delete from tournament_follows where user_id = old.id;
  if exists (select 1 from tournament_entries where user_id = old.id and status <> 'withdrawn')
     or exists (select 1 from fixtures where old.id in (player_a_id, player_b_id)) then
    update profiles set username = 'deleted_' || substr(md5(old.id::text), 1, 8), display_name = 'Deleted player',
           avatar_url = null, team_name = null, country = null, deleted_at = now(), break_until = null,
           max_active_tournaments = null
    where id = old.id;
    delete from tournament_entries e using tournaments t
    where t.id = e.tournament_id and e.user_id = old.id and t.status in ('draft', 'open');
  else
    delete from tournament_entries where user_id = old.id;
    delete from profiles where id = old.id;
  end if;
  return old;
end $$;

create or replace function public.delete_my_account(p_confirm text) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid(); p profiles;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  select * into p from profiles where id = v_uid;
  if p.id is null or lower(trim(coalesce(p_confirm, ''))) <> lower(p.username) then
    return jsonb_build_object('ok', false, 'reason', 'confirm_username');
  end if;
  if exists (select 1 from tournament_entries e join tournaments t on t.id = e.tournament_id
             where e.user_id = v_uid and e.status in ('registered', 'checked_in') and t.status in ('planning', 'live')) then
    return jsonb_build_object('ok', false, 'reason', 'in_live_tournament');
  end if;
  if exists (select 1 from user_roles where user_id = v_uid and role = 'admin')
     and (select count(*) from user_roles where role = 'admin') = 1 then
    return jsonb_build_object('ok', false, 'reason', 'last_admin');
  end if;
  insert into audit_logs (actor, action, entity, entity_id) values (v_uid, 'delete_account', 'profile', v_uid);
  delete from auth.users where id = v_uid;        -- the trigger above cleans up
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- dispute evidence (private files)
-- Files live in the private "evidence" bucket at <fixture id>/<user id>/<file>. Only the uploader and admins can open them.
create or replace function public._can_add_evidence(p_fixture text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  begin v_id := p_fixture::uuid; exception when others then return false; end;
  return exists (select 1 from fixtures where id = v_id and auth.uid() in (player_a_id, player_b_id)
                   and status in ('active', 'completed', 'disputed', 'stalled')
                   and coalesce(completed_at, now()) > now() - interval '3 days')
     and (select count(*) from dispute_evidence where fixture_id = v_id and user_id = auth.uid()) < 5;
end $$;

create or replace function public.add_dispute_evidence(p_fixture_id uuid, p_path text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); f fixtures; v_has_storage boolean;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  select * into f from fixtures where id = p_fixture_id;
  if f.id is null or v_uid not in (f.player_a_id, f.player_b_id) then return jsonb_build_object('ok', false, 'reason', 'not_a_participant'); end if;
  if not _can_add_evidence(p_fixture_id::text) then return jsonb_build_object('ok', false, 'reason', 'evidence_closed'); end if;
  if p_path is null or p_path !~ ('^' || p_fixture_id::text || '/' || v_uid::text || '/[A-Za-z0-9_.-]{1,80}$') then
    return jsonb_build_object('ok', false, 'reason', 'bad_path');
  end if;
  select exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'objects') into v_has_storage;
  if v_has_storage then
    execute 'select exists (select 1 from storage.objects where bucket_id = ''evidence'' and name = $1)' into v_has_storage using p_path;
    if not v_has_storage then return jsonb_build_object('ok', false, 'reason', 'file_not_uploaded'); end if;
  end if;
  insert into dispute_evidence (fixture_id, user_id, path, note) values (f.id, v_uid, p_path, nullif(left(trim(coalesce(p_note, '')), 300), ''))
  on conflict (path) do nothing;
  insert into disputes (fixture_id, user_id, note) values (f.id, v_uid, 'Evidence added')
  on conflict (fixture_id, user_id) do update set status = 'open';
  perform _event(f.id, 'evidence_added', v_uid, jsonb_build_object('path', p_path));
  return jsonb_build_object('ok', true);
end $$;

do $$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('evidence', 'evidence', false, 5242880, array['image/png', 'image/jpeg', 'image/webp']),
           ('sponsor-logos', 'sponsor-logos', true, 1048576, array['image/png', 'image/jpeg', 'image/webp'])
    on conflict (id) do nothing;
    execute $p$create policy wz_evidence_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'evidence' and (storage.foldername(name))[2] = auth.uid()::text
                  and public._can_add_evidence((storage.foldername(name))[1]))$p$;
    execute $p$create policy wz_evidence_read on storage.objects for select to authenticated
      using (bucket_id = 'evidence' and ((storage.foldername(name))[2] = auth.uid()::text or public.is_admin()))$p$;
    execute $p$create policy wz_logos_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'sponsor-logos' and public.is_admin())$p$;
    execute $p$create policy wz_logos_update on storage.objects for update to authenticated
      using (bucket_id = 'sponsor-logos' and public.is_admin())$p$;
    execute $p$create policy wz_logos_delete on storage.objects for delete to authenticated
      using (bucket_id = 'sponsor-logos' and public.is_admin())$p$;
  end if;
end $$;

-- ---------------------------------------------------------------- sponsors
drop policy sponsors_public on public.sponsors;
create policy sponsors_public on public.sponsors for select using (active);   -- admins also see paused ones through sponsors_admin_w

create or replace function public.save_sponsor(p_id uuid, p_name text, p_logo_url text, p_website text,
                                               p_active boolean default true, p_show_on_home boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_id;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if coalesce(trim(p_name), '') = '' then return jsonb_build_object('ok', false, 'reason', 'name_required'); end if;
  if (nullif(trim(p_logo_url), '') is not null and trim(p_logo_url) !~ '^https://')
     or (nullif(trim(p_website), '') is not null and trim(p_website) !~ '^https://') then
    return jsonb_build_object('ok', false, 'reason', 'links_must_start_with_https');
  end if;
  if v_id is null then
    insert into sponsors (name, logo_url, website, active, show_on_home)
    values (left(trim(p_name), 60), nullif(trim(p_logo_url), ''), nullif(trim(p_website), ''), coalesce(p_active, true), coalesce(p_show_on_home, false))
    returning id into v_id;
  else
    update sponsors set name = left(trim(p_name), 60), logo_url = nullif(trim(p_logo_url), ''), website = nullif(trim(p_website), ''),
           active = coalesce(p_active, true), show_on_home = coalesce(p_show_on_home, false)
    where id = v_id;
  end if;
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'save_sponsor', 'sponsor', v_id);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.set_sponsor_placement(p_tid uuid, p_sponsor uuid, p_type text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if p_type not in ('title', 'bracket_logo', 'round', 'prize') then return jsonb_build_object('ok', false, 'reason', 'bad_type'); end if;
  delete from sponsor_placements where tournament_id = p_tid and sponsor_id = p_sponsor and placement_type = p_type;
  if p_on then
    if p_type = 'title' then delete from sponsor_placements where tournament_id = p_tid and placement_type = 'title'; end if;
    insert into sponsor_placements (tournament_id, sponsor_id, placement_type) values (p_tid, p_sponsor, p_type);
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.delete_sponsor(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  delete from sponsors where id = p_id;
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'delete_sponsor', 'sponsor', p_id);
  return jsonb_build_object('ok', found);
end $$;

-- ---------------------------------------------------------------- demo mode: tournaments played by bots
create or replace function public._ensure_bots(p_n int) returns uuid[]
language plpgsql security definer set search_path = public as $$
declare
  names constant text[] := array['Kagame_FC','NileStriker','Volcano_10','LakeKivuKing','Akagera_Ace','RedLion77','Inzovu_9','Gorilla_GK',
    'Ishema_FC','Umurava','Kigali_Wolf','Musanze_Hawk','Huye_Hammer','Rubavu_Rush','Nyungwe_Ninja','Amahoro_11','Intare_FC','Isimbi_7',
    'Rusizi_Ray','Gisenyi_Gun','Kibuye_Kid','Muhazi_Maestro','Bugesera_Bolt','Karongi_Kop','Nyagatare_9','Gatsibo_Glide','Kayonza_King',
    'Rwamagana_R','Ngoma_Nova','Kirehe_Kite','Nyanza_Nine','Ruhango_Rocket','Muhanga_Mamba','Kamonyi_Kick','Gicumbi_Gale','Burera_Blaze',
    'Gakenke_Ghost','Rulindo_Ray','Nyabihu_Nova','Ngororero_N','Rutsiro_Rex','Nyamasheke_N','Gisagara_G','Nyaruguru_N','Kicukiro_K',
    'Gasabo_Gold','Nyarugenge_N','Remera_Rover','Kimironko_K','Kacyiru_Ace','Nyamirambo_N','Kanombe_Kid','Gikondo_Gun','Kimihurura_K',
    'Zion_Pitch','Atlas_Volt','Cobalt_Nine','Saber_Line','Orbit_Wing','Delta_Keeper','Nova_Press','Echo_Cross','Pulse_Ten','Granite_FC'];
  have uuid[]; i int := 0; v_name text; v_id uuid;
begin
  select coalesce(array_agg(id order by username), '{}') into have from profiles where is_bot;
  while coalesce(array_length(have, 1), 0) < p_n loop
    i := i + 1;
    v_name := case when i <= array_length(names, 1) then names[i] else 'Bot_' || i end;
    if not exists (select 1 from profiles where lower(username) = lower(v_name)) then
      v_id := gen_random_uuid();
      insert into profiles (id, username, display_name, is_bot, country, lang) values (v_id, v_name, v_name, true, 'RW', 'en');
      have := have || v_id;
    end if;
  end loop;
  return have[1:p_n];
end $$;

-- the earliest unfinished round of a demo tournament is brought forward so the demo keeps moving
create or replace function public._play_demo() returns int
language plpgsql security definer set search_path = public as $$
declare t tournaments; f fixtures; v_stage text; v_round int; a int; b int; pa int; pb int; v_w uuid; v_n int := 0;
begin
  for t in select * from tournaments where is_demo and status = 'live' loop
    select x.stage, x.round into v_stage, v_round from fixtures x
    where x.tournament_id = t.id and x.status in ('scheduled', 'active', 'stalled') and x.player_a_id is not null and x.player_b_id is not null
    order by case x.stage when 'knockout' then 2 when 'playoff' then 1 else 0 end, x.round limit 1;
    if v_stage is null then continue; end if;
    update fixtures set scheduled_at = now() + make_interval(secs => 60 + floor(random() * 240)::int)
    where tournament_id = t.id and stage = v_stage and round = v_round and status = 'scheduled'
      and player_a_id is not null and player_b_id is not null and (scheduled_at is null or scheduled_at > now() + interval '6 minutes');

    for f in select * from fixtures where tournament_id = t.id and status in ('scheduled', 'active', 'stalled')
               and player_a_id is not null and player_b_id is not null and scheduled_at <= now() for update loop
      a := floor(random() * random() * 5)::int; b := floor(random() * random() * 5)::int; pa := null; pb := null;
      if a = b and f.stage in ('playoff', 'knockout') then
        pa := 3 + floor(random() * 3)::int; pb := case when random() < 0.5 then pa - 1 else pa + 1 end;
      end if;
      v_w := case when a > b then f.player_a_id when b > a then f.player_b_id
                  when pa is not null then case when pa > pb then f.player_a_id else f.player_b_id end end;
      update fixtures set status = 'completed', kickoff_at = coalesce(kickoff_at, scheduled_at), winner_id = v_w,
             outcome = case when v_w is null then 'draw' else 'win_by_score' end,
             score_a = a, score_b = b, pen_a = pa, pen_b = pb, completed_at = now()
      where id = f.id;
      perform _after_final(f.id);
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end $$;

create or replace function public.create_demo_tournament(p_name text, p_size int default 8, p_format text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tid uuid; v_slug text; v_bots uuid[]; v_fmt text; b uuid; g uuid;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if p_size is null or p_size < 4 or p_size > 64 then return jsonb_build_object('ok', false, 'reason', 'size_4_to_64'); end if;
  v_fmt := coalesce(nullif(p_format, ''), recommend_format(p_size));
  if v_fmt not in ('knockout', 'league', 'league_knockout', 'groups_knockout', 'league_phase') then
    return jsonb_build_object('ok', false, 'reason', 'bad_format');
  end if;
  select id into g from games where active order by slug limit 1;
  v_slug := 'demo-' || substr(md5(random()::text), 1, 6);
  insert into tournaments (slug, name, game_id, format, size, status, is_demo, created_by, starts_at, prize_description, schedule_speed)
  values (v_slug, left(coalesce(nullif(trim(p_name), ''), 'Demo Cup'), 60), g, v_fmt, p_size, 'open', true, auth.uid(),
          now() + interval '5 minutes', 'Demo: played by bots, no prize', 'oneday')
  returning id into v_tid;
  v_bots := _ensure_bots(p_size);
  foreach b in array v_bots loop
    insert into tournament_entries (tournament_id, user_id) values (v_tid, b);   -- the last one fills it and plans it
  end loop;
  update tournaments set status = 'live' where id = v_tid and status = 'planning';
  perform _play_demo();
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'create_demo_tournament', 'tournament', v_tid);
  return jsonb_build_object('ok', true, 'id', v_tid, 'slug', v_slug);
end $$;

create or replace function public.delete_demo_tournament(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if not exists (select 1 from tournaments where id = p_tid and is_demo) then return jsonb_build_object('ok', false, 'reason', 'not_a_demo'); end if;
  delete from tournaments where id = p_tid;
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'delete_demo_tournament', 'tournament', p_tid);
  return jsonb_build_object('ok', true);
end $$;

do $$ begin
  perform cron.schedule('winzone-demo', '* * * * *', 'select public._play_demo()');
exception when others then raise notice 'pg_cron not available: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function public._is_banned(uuid), public._ensure_bots(int), public._play_demo() from public, anon, authenticated;
revoke execute on function public._can_add_evidence(text) from public, anon;
grant execute on function public._can_add_evidence(text) to authenticated;   -- used by the storage rule
revoke execute on function public.report_player(text, text, text, uuid), public.list_reports(text), public.review_report(uuid, text),
  public.ban_player(text, int, text), public.unban_player(text), public.list_banned(), public.take_break(int), public.set_play_limit(int),
  public.set_country_blocked(text, boolean), public.delete_my_account(text), public.add_dispute_evidence(uuid, text, text),
  public.save_sponsor(uuid, text, text, text, boolean, boolean), public.set_sponsor_placement(uuid, uuid, text, boolean),
  public.delete_sponsor(uuid), public.create_demo_tournament(text, int, text), public.delete_demo_tournament(uuid) from public, anon;
grant execute on function public.report_player(text, text, text, uuid), public.list_reports(text), public.review_report(uuid, text),
  public.ban_player(text, int, text), public.unban_player(text), public.list_banned(), public.take_break(int), public.set_play_limit(int),
  public.set_country_blocked(text, boolean), public.delete_my_account(text), public.add_dispute_evidence(uuid, text, text),
  public.save_sponsor(uuid, text, text, text, boolean, boolean), public.set_sponsor_placement(uuid, uuid, text, boolean),
  public.delete_sponsor(uuid), public.create_demo_tournament(text, int, text), public.delete_demo_tournament(uuid) to authenticated;
grant execute on all functions in schema public to service_role;
grant select on public.player_reports, public.dispute_evidence to service_role;
