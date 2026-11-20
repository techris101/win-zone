-- WIN ZONE — 0012 player pages and rankings, team names and app support.

-- ---------------------------------------------------------------- new columns
alter table public.profiles add column team_name text check (team_name is null or length(team_name) between 2 and 30);
grant select (team_name) on public.profiles to anon, authenticated;     -- the in-game team name is public (shown on leaderboards)

-- ---------------------------------------------------------------- team name (lets the app tell which side of the screen is yours)
create or replace function public.set_my_team_name(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text := upper(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'));
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  if length(v) not between 2 and 30 then return jsonb_build_object('ok', false, 'reason', 'bad_name'); end if;
  update profiles set team_name = v where id = auth.uid();
  return jsonb_build_object('ok', true, 'team_name', v);
end $$;

create or replace function public.set_team_name_pass(p_pass text, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p match_passes; v text := upper(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'));
begin
  p := _pass(p_pass);
  if p.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_pass'); end if;
  if length(v) not between 2 and 30 then return jsonb_build_object('ok', false, 'reason', 'bad_name'); end if;
  update profiles set team_name = v where id = p.user_id;
  return jsonb_build_object('ok', true, 'team_name', v);
end $$;

-- the app reads the screen with rules kept on the server, so they can be tuned without a new app version
create or replace function public.game_profile_pass(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p match_passes; v jsonb;
begin
  p := _pass(p_pass);
  if p.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_pass'); end if;
  select gp.profile into v from fixtures f join tournaments t on t.id = f.tournament_id join game_profiles gp on gp.game_id = t.game_id
  where f.id = p.fixture_id;
  return jsonb_build_object('ok', true, 'profile', coalesce(v, '{}'::jsonb));
end $$;

update public.game_profiles set profile = $p${
  "version": 1,
  "package": null,
  "sample_interval_ms": 2000,
  "confirm_frames": 2,
  "result_keywords": ["HIGHLIGHTS", "CONTINUE", "MATCH RATING", "PLAYER OF THE MATCH", "POSSESSION", "SHOTS", "TACKLES", "PASSES", "CORNERS", "FOULS", "BOOKINGS", "OFFSIDES"],
  "result_min_hits": 3,
  "quit_keywords": ["OPPONENT QUIT", "FORFEITS THE MATCH"],
  "menu_keywords": ["MATCH CODE", "SEARCH", "MORE INFO", "FRIEND MATCH", "CLAN MATCH", "SETTINGS", "SQUAD", "CAREER"],
  "opponent_labels": ["OPPONENT"],
  "potm_label": "PLAYER OF THE MATCH",
  "header_band": [0.0, 0.30],
  "events_band": [0.20, 0.46],
  "clock_regex": "^(\\d{1,3})[:.](\\d{2})$",
  "pen_regex": "^\\((\\d{1,2})\\)$",
  "event_regex": "^(.+?)\\s*\\(([\\d\\s,']+(?:pen)?[\\d\\s,'pen]*)\\)$",
  "inplay_top_band": [0.0, 0.22],
  "inplay_needs_clock": true,
  "inplay_max_lines": 30
}$p$::jsonb
where game_id = (select id from public.games where slug = 'football-1v1') and (profile = '{}'::jsonb or not profile ? 'version');

create or replace function public._submit_screen_state(
  p_uid uuid, p_fixture_id uuid, p_layout text,
  p_score_me int, p_score_opp int, p_pen_me int, p_pen_opp int,
  p_clock_seconds int, p_client_seq bigint, p_raw jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := p_uid; f fixtures; cur match_latest_state; ev jsonb; v_kick boolean;
  v_in_play_since timestamptz; v_last_in_play timestamptz;
  sa match_latest_state; sb match_latest_state;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  if p_layout not in ('in_play', 'result', 'opponent_quit', 'menu', 'unknown') then
    return jsonb_build_object('ok', false, 'reason', 'bad_layout');
  end if;

  select * into f from fixtures where id = p_fixture_id for update;
  if f.id is null or v_uid not in (f.player_a_id, f.player_b_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_a_participant');
  end if;
  if f.status not in ('scheduled', 'active', 'stalled') then
    return jsonb_build_object('ok', true, 'kickoff_ready', f.kickoff_at is not null,
      'finalize_ready', false, 'fixture_status', f.status);
  end if;

  select * into cur from match_latest_state where fixture_id = f.id and user_id = v_uid;

  if cur.fixture_id is null or p_client_seq > cur.client_seq then
    insert into match_state_log (fixture_id, user_id, client_seq, layout, score_me, score_opp, pen_me, pen_opp, clock_seconds, raw)
    values (f.id, v_uid, p_client_seq, p_layout, p_score_me, p_score_opp, p_pen_me, p_pen_opp, p_clock_seconds, p_raw);

    if p_layout = 'in_play' then
      v_last_in_play := now();
      v_in_play_since := case when cur.layout = 'in_play' and cur.last_in_play_at > now() - interval '10 seconds'
                              then cur.in_play_since else now() end;
    else
      v_last_in_play := cur.last_in_play_at;
      v_in_play_since := null;
    end if;

    insert into match_latest_state as m (fixture_id, user_id, layout, score_me, score_opp, pen_me, pen_opp,
                                         clock_seconds, client_seq, in_play_since, last_in_play_at, updated_at)
    values (f.id, v_uid, p_layout, p_score_me, p_score_opp, p_pen_me, p_pen_opp,
            p_clock_seconds, p_client_seq, v_in_play_since, v_last_in_play, now())
    on conflict (fixture_id, user_id) do update
    set layout = excluded.layout, score_me = excluded.score_me, score_opp = excluded.score_opp,
        pen_me = excluded.pen_me, pen_opp = excluded.pen_opp, clock_seconds = excluded.clock_seconds,
        client_seq = excluded.client_seq, in_play_since = excluded.in_play_since,
        last_in_play_at = excluded.last_in_play_at, updated_at = now();

    -- Latch the terminal report. Later screens (e.g. after tapping Continue) never erase it.
    if p_layout in ('result', 'opponent_quit') then
      update match_latest_state
      set terminal_kind = p_layout, terminal_at = now(),
          t_score_me = p_score_me, t_score_opp = p_score_opp,
          t_pen_me = p_pen_me, t_pen_opp = p_pen_opp, t_clock = p_clock_seconds
      where fixture_id = f.id and user_id = v_uid and terminal_kind is null;
      if p_layout = 'opponent_quit' then
        update match_latest_state set terminal_kind = 'opponent_quit'
        where fixture_id = f.id and user_id = v_uid and terminal_kind = 'result';
      end if;
    end if;

    -- Kickoff: both phones in_play for 5 s straight, inside the first 5 minutes of match clock.
    if f.kickoff_at is null then
      select * into sa from match_latest_state where fixture_id = f.id and user_id = f.player_a_id;
      select * into sb from match_latest_state where fixture_id = f.id and user_id = f.player_b_id;
      if sa.in_play_since is not null and sb.in_play_since is not null
         and now() - sa.in_play_since >= interval '5 seconds' and now() - sb.in_play_since >= interval '5 seconds'
         and sa.last_in_play_at > now() - interval '10 seconds' and sb.last_in_play_at > now() - interval '10 seconds'
         and coalesce(sa.clock_seconds, 0) <= 300 and coalesce(sb.clock_seconds, 0) <= 300 then
        update fixtures set kickoff_at = now(), status = 'active' where id = f.id;
        perform _event(f.id, 'kickoff', v_uid);
      end if;
    end if;
  end if;

  select * into f from fixtures where id = p_fixture_id;
  v_kick := f.kickoff_at is not null;
  ev := _evaluate_fixture(p_fixture_id);
  return jsonb_build_object('ok', true, 'kickoff_ready', v_kick,
    'finalize_ready', ev ->> 'status' <> 'wait', 'reason', ev ->> 'reason', 'fixture_status', f.status);
end $$;

create or replace function public.redeem_app_handoff(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h app_handoffs; f fixtures; g games; v_pass text; v_opp uuid; v_opp_name text; v_my_team text; v_opp_team text; v_pkg text;
begin
  select * into h from app_handoffs
  where code_hash = _hash(coalesce(p_code, '')) and used_at is null and expires_at > now() for update;
  if h.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_or_expired'); end if;
  update app_handoffs set used_at = now() where id = h.id;

  select * into f from fixtures where id = h.fixture_id;
  if f.status in ('completed', 'cancelled', 'disputed', 'bye') then
    return jsonb_build_object('ok', false, 'reason', 'fixture_closed');
  end if;
  select gm.* into g from tournaments t join games gm on gm.id = t.game_id where t.id = f.tournament_id;

  delete from match_passes where user_id = h.user_id and fixture_id = h.fixture_id;
  v_pass := _random_token(32);   -- 64 hex characters
  insert into match_passes (token_hash, user_id, fixture_id, expires_at)
  values (_hash(v_pass), h.user_id, h.fixture_id, now() + interval '8 hours');

  v_opp := case when h.user_id = f.player_a_id then f.player_b_id else f.player_a_id end;
  select coalesce(display_name, username), team_name into v_opp_name, v_opp_team from profiles where id = v_opp;
  select team_name into v_my_team from profiles where id = h.user_id;
  select gp.profile ->> 'package' into v_pkg from game_profiles gp where gp.game_id = g.id;
  return jsonb_build_object('ok', true, 'pass', v_pass, 'fixture_id', f.id,
    'my_side', case when h.user_id = f.player_a_id then 'A' else 'B' end,
    'opponent', v_opp_name, 'stage', f.stage, 'scheduled_at', f.scheduled_at, 'status', f.status,
    'regulation_seconds', g.regulation_seconds, 'extra_time_seconds', g.extra_time_seconds,
    'tournament_id', f.tournament_id, 'my_team', v_my_team, 'opp_team', v_opp_team, 'launch_package', v_pkg);
end $$;


create or replace function public.my_profile() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name,
                              'country', p.country, 'country_name', c.name, 'tz', c.tz, 'lang', p.lang,
                              'team_name', p.team_name)
    from profiles p left join countries c on c.code = p.country where p.id = auth.uid()
  ), '{}'::jsonb)
$$;




-- ---------------------------------------------------------------- player pages and global rankings
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
    from agg a join profiles p on p.id = a.uid where not p.is_bot
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
  select * into p from profiles where lower(username) = lower(trim(p_username)) and not is_bot;
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

-- ---------------------------------------------------------------- grants
revoke execute on function public.set_my_team_name(text), public.set_team_name_pass(text, text), public.game_profile_pass(text),
  public.rankings(int, text), public.public_player(text) from public;
grant execute on function public.set_my_team_name(text) to authenticated;
grant execute on function public.set_team_name_pass(text, text), public.game_profile_pass(text), public.rankings(int, text),
  public.public_player(text) to anon, authenticated;
grant execute on all functions in schema public to service_role;
