-- WIN ZONE — 0011 statistics
-- 1. Player standing in a tournament: position, points, matches left, best possible points, form, and a status
--    that is only "qualified"/"eliminated" when it is mathematically certain.
-- 2. Career numbers per player.
-- 3. Footballer leaderboards (top scorers, assists, player of the match) from the result screens the app reads.
--    The same footballer can play for many teams, so every entry is shown with the team: "Messi (Dream FC)".

-- ---------------------------------------------------------------- 1. standing and qualification race
create or replace function public.player_stats(p_tid uuid)
returns table (user_id uuid, group_no int, pos int, points int, played int, remaining int, max_points int,
               form text, status text, needs int, can_secure boolean, next_at timestamptz, next_opponent text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  t tournaments; v_stage text; n int; g int; p int := 1; k_q int; k_po int; k_out int; v_table_done boolean; s int;
begin
  select * into t from tournaments where id = p_tid;
  if t.id is null or t.status in ('draft') then return; end if;
  v_stage := case when t.format = 'groups_knockout' then 'group' when t.format = 'knockout' then null else 'league' end;
  select count(*) into n from tournament_entries e where e.tournament_id = p_tid and e.status <> 'withdrawn';

  -- qualification lines per format
  if t.format = 'league' then k_q := 1; k_out := 1;
  elsif t.format = 'league_knockout' then k_q := t.league_advance; k_out := t.league_advance;
  elsif t.format = 'groups_knockout' then
    select max(e.group_no) into g from tournament_entries e where e.tournament_id = p_tid;
    g := coalesce(g, 1);
    while p < 2 * g loop p := p * 2; end loop;
    if p > 3 * g then p := p / 2; end if;
    k_q := 2; k_out := case when p > 2 * g then 3 else 2 end;
  elsif t.format = 'league_phase' then
    s := _phase_bracket_size(n);
    k_q := s / 2; k_po := case when n >= s + s / 2 then s + s / 2 else s end; k_out := k_po;
  end if;

  v_table_done := v_stage is null
    or exists (select 1 from fixtures f where f.tournament_id = p_tid and f.stage in ('knockout', 'playoff'))
    or t.status = 'completed';

  return query
  with tbl as (
    select st.user_id as uid, st.group_no as grp, st.rank as pos, st.points as pts, st.played as pl
    from _standings(p_tid, coalesce(v_stage, 'league'), null) st
    where v_stage is not null
    union all
    select e.user_id, null::int, null::int, 0, 0 from tournament_entries e
    where v_stage is null and e.tournament_id = p_tid and e.status <> 'withdrawn'
  ),
  rem as (
    select b.uid,
      case when t.format = 'league_phase' then
             greatest(0, coalesce(t.phase_rounds, 0) - (select count(*) from fixtures f where f.tournament_id = p_tid and f.stage = 'league'
                                                       and f.status in ('completed', 'bye') and b.uid in (f.player_a_id, f.player_b_id)))::int
           else (select count(*) from fixtures f where f.tournament_id = p_tid and f.stage = v_stage
                 and f.status in ('scheduled', 'active', 'stalled', 'disputed') and b.uid in (f.player_a_id, f.player_b_id))::int end as left_n
    from tbl b
  ),
  x as (select b.*, r.left_n, b.pts + 3 * r.left_n as maxp from tbl b join rem r on r.uid = b.uid),
  calc as (
    select x.*,
      (select count(*) from x o where o.uid <> x.uid and o.grp is not distinct from x.grp and o.maxp >= x.pts)::int as can_catch,
      (select count(*) from x o where o.uid <> x.uid and o.grp is not distinct from x.grp and o.pts > x.maxp)::int as already_above,
      (select o.maxp from x o where o.uid <> x.uid and o.grp is not distinct from x.grp order by o.maxp desc offset greatest(k_q, 1) - 1 limit 1) as kth_max
    from x
  ),
  frm as (
    select c.uid, string_agg(case when f.winner_id is null then 'D' when f.winner_id = c.uid then 'W' else 'L' end, '' order by f.completed_at desc) as last5
    from calc c
    left join lateral (
      select * from fixtures f where f.tournament_id = p_tid and f.status = 'completed' and c.uid in (f.player_a_id, f.player_b_id)
      order by f.completed_at desc limit 5
    ) f on true
    group by c.uid
  ),
  nxt as (
    select c.uid, f.scheduled_at as at,
           (select coalesce(pr.display_name, pr.username) from profiles pr
            where pr.id = case when f.player_a_id = c.uid then f.player_b_id else f.player_a_id end) as opp
    from calc c
    left join lateral (
      select * from fixtures f where f.tournament_id = p_tid and f.status in ('scheduled', 'active')
        and c.uid in (f.player_a_id, f.player_b_id) and f.player_a_id is not null and f.player_b_id is not null
      order by f.scheduled_at nulls last limit 1
    ) f on true
  )
  select c.uid, c.grp, c.pos, c.pts, c.pl, c.left_n, c.maxp, reverse(coalesce(fr.last5, '')),
    case
      when t.status = 'completed' then case when c.uid = t.champion_id then 'champion' else 'finished' end
      when v_table_done then
        case when exists (select 1 from fixtures f where f.tournament_id = p_tid and f.stage in ('knockout', 'playoff') and f.status = 'completed'
                          and c.uid in (f.player_a_id, f.player_b_id) and f.winner_id is distinct from c.uid)
               or (v_stage is not null and not exists (select 1 from fixtures f where f.tournament_id = p_tid and f.stage in ('knockout', 'playoff')
                                                       and c.uid in (f.player_a_id, f.player_b_id))
                   and exists (select 1 from fixtures f where f.tournament_id = p_tid and f.stage in ('knockout', 'playoff')))
             then 'eliminated' else 'in' end
      when c.already_above >= k_out then 'eliminated'
      when c.can_catch < k_q then 'qualified'
      when k_po is not null and c.can_catch < k_po then 'playoff_sure'
      else 'in_race'
    end,
    case when not v_table_done and c.can_catch >= k_q then greatest(0, coalesce(c.kth_max, 0) - c.pts + 1) end,
    case when not v_table_done and c.can_catch >= k_q then greatest(0, coalesce(c.kth_max, 0) - c.pts + 1) <= 3 * c.left_n end,
    nx.at, nx.opp
  from calc c left join frm fr on fr.uid = c.uid left join nxt nx on nx.uid = c.uid
  order by c.grp nulls first, c.pos nulls last;
end $$;

-- ---------------------------------------------------------------- 3. footballer statistics from the result screens
alter table public.fixtures add column team_a text;
alter table public.fixtures add column team_b text;

-- what each phone read from the result screen (stored as reported; never decides a result)
create table public.match_reports (
  fixture_id uuid not null references public.fixtures (id) on delete cascade,
  user_id    uuid not null,
  report     jsonb not null,
  created_at timestamptz not null default now(),
  primary key (fixture_id, user_id)
);
-- the cross-checked events used for leaderboards
create table public.footballer_events (
  id            bigserial primary key,
  tournament_id uuid not null references public.tournaments (id) on delete cascade,
  fixture_id    uuid not null references public.fixtures (id) on delete cascade,
  owner_id      uuid not null,               -- the WIN ZONE player whose team the footballer plays for
  team_name     text,
  footballer    text not null,
  footballer_key text not null,              -- normalized for grouping (case, accents, spaces)
  kind          text not null check (kind in ('goal', 'assist', 'potm', 'yellow', 'red')),
  minute        int,
  pen           boolean not null default false,
  rating        numeric(3, 1)
);
create index footballer_events_t_idx on public.footballer_events (tournament_id, kind);
alter table public.match_reports enable row level security;
alter table public.footballer_events enable row level security;
revoke all on public.match_reports, public.footballer_events from anon, authenticated;
grant all on public.match_reports, public.footballer_events to service_role;
grant usage, select on sequence public.footballer_events_id_seq to service_role;

create or replace function public._fkey(p text) returns text language sql immutable as $$
  select regexp_replace(lower(translate(trim(coalesce(p, '')),
    'ÁÀÂÄÃÅáàâäãåÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÖÕóòôöõÚÙÛÜúùûüÇçÑñ', 'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '\s+', ' ', 'g')
$$;

-- one side's list of events from one phone: team 'me'/'opp' is relative to the reporting phone
create or replace function public._side_events(p_report jsonb, p_list text, p_side text) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(coalesce(p_report -> p_list, '[]'::jsonb)) e
  where e ->> 'team' = p_side and coalesce(e ->> 'player', '') <> ''
$$;

-- multiset key of a goal list, to compare two phones
create or replace function public._goal_sig(p_list jsonb) returns text language sql immutable as $$
  select coalesce(string_agg(_fkey(e ->> 'player') || '@' || coalesce(e ->> 'minute', '?'), '|' order by _fkey(e ->> 'player'), e ->> 'minute'), '')
  from jsonb_array_elements(p_list) e
$$;

create or replace function public._reconcile_report(p_fixture uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  f fixtures; ra jsonb; rb jsonb; s int; side text; owner uuid; team text; mine jsonb; theirs jsonb; pick jsonb; e jsonb; potm jsonb;
begin
  select * into f from fixtures where id = p_fixture;
  if f.id is null or f.status <> 'completed' or f.outcome = 'win_by_noshow' or f.player_b_id is null then return; end if;
  select report into ra from match_reports where fixture_id = f.id and user_id = f.player_a_id;
  select report into rb from match_reports where fixture_id = f.id and user_id = f.player_b_id;
  if ra is null and rb is null then return; end if;

  update fixtures set team_a = left(coalesce(ra ->> 'my_team', rb ->> 'opp_team'), 40),
                      team_b = left(coalesce(rb ->> 'my_team', ra ->> 'opp_team'), 40)
  where id = f.id returning * into f;
  delete from footballer_events where fixture_id = f.id;

  foreach side in array array['A', 'B'] loop
    owner := case side when 'A' then f.player_a_id else f.player_b_id end;
    team  := case side when 'A' then f.team_a else f.team_b end;
    s     := case side when 'A' then f.score_a else f.score_b end;
    -- the owner's own phone lists this team's events as 'me'; the opponent's phone as 'opp'
    mine   := case side when 'A' then _side_events(ra, 'goals', 'me')  else _side_events(rb, 'goals', 'me')  end;
    theirs := case side when 'A' then _side_events(rb, 'goals', 'opp') else _side_events(ra, 'goals', 'opp') end;
    -- goals: both phones agree, or the one whose count matches the official score (owner's phone first)
    pick := case
      when jsonb_array_length(mine) = s and _goal_sig(mine) = _goal_sig(theirs) then mine
      when jsonb_array_length(mine) = s then mine
      when jsonb_array_length(theirs) = s then theirs
      else null end;
    if pick is not null then
      for e in select * from jsonb_array_elements(pick) loop
        insert into footballer_events (tournament_id, fixture_id, owner_id, team_name, footballer, footballer_key, kind, minute, pen)
        values (f.tournament_id, f.id, owner, team, left(trim(e ->> 'player'), 40), _fkey(e ->> 'player'), 'goal',
                nullif(e ->> 'minute', '')::int, coalesce((e ->> 'pen')::boolean, false));
      end loop;
    end if;
    -- assists and cards: the owner's phone, else the opponent's
    for e in select * from jsonb_array_elements(coalesce(
                 nullif(case side when 'A' then _side_events(ra, 'assists', 'me') else _side_events(rb, 'assists', 'me') end, '[]'::jsonb),
                 case side when 'A' then _side_events(rb, 'assists', 'opp') else _side_events(ra, 'assists', 'opp') end)) loop
      insert into footballer_events (tournament_id, fixture_id, owner_id, team_name, footballer, footballer_key, kind, minute)
      values (f.tournament_id, f.id, owner, team, left(trim(e ->> 'player'), 40), _fkey(e ->> 'player'), 'assist', nullif(e ->> 'minute', '')::int);
    end loop;
    for e in select * from jsonb_array_elements(coalesce(
                 nullif(case side when 'A' then _side_events(ra, 'cards', 'me') else _side_events(rb, 'cards', 'me') end, '[]'::jsonb),
                 case side when 'A' then _side_events(rb, 'cards', 'opp') else _side_events(ra, 'cards', 'opp') end)) loop
      if e ->> 'type' in ('yellow', 'red') then
        insert into footballer_events (tournament_id, fixture_id, owner_id, team_name, footballer, footballer_key, kind, minute)
        values (f.tournament_id, f.id, owner, team, left(trim(e ->> 'player'), 40), _fkey(e ->> 'player'), e ->> 'type', nullif(e ->> 'minute', '')::int);
      end if;
    end loop;
  end loop;

  -- player of the match (both phones show the same one)
  potm := coalesce(ra -> 'potm', rb -> 'potm');
  if potm is not null and coalesce(potm ->> 'player', '') <> '' then
    owner := case
      when (ra -> 'potm') is not null then case when potm ->> 'team' = 'me' then f.player_a_id else f.player_b_id end
      else case when potm ->> 'team' = 'me' then f.player_b_id else f.player_a_id end end;
    insert into footballer_events (tournament_id, fixture_id, owner_id, team_name, footballer, footballer_key, kind, rating)
    values (f.tournament_id, f.id, owner, case when owner = f.player_a_id then f.team_a else f.team_b end,
            left(trim(potm ->> 'player'), 40), _fkey(potm ->> 'player'), 'potm',
            case when (potm ->> 'rating') ~ '^\d+(\.\d+)?$' then least(10, (potm ->> 'rating')::numeric) end);
  end if;
end $$;

create or replace function public._store_report(p_fixture uuid, p_user uuid, p_report jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f fixtures;
begin
  select * into f from fixtures where id = p_fixture;
  if f.id is null or p_user not in (f.player_a_id, f.player_b_id) then return jsonb_build_object('ok', false, 'reason', 'not_a_participant'); end if;
  if p_report is null or jsonb_typeof(p_report) <> 'object' or length(p_report::text) > 8000 then
    return jsonb_build_object('ok', false, 'reason', 'bad_report');
  end if;
  insert into match_reports (fixture_id, user_id, report) values (p_fixture, p_user, p_report)
  on conflict (fixture_id, user_id) do nothing;        -- the first report counts; it cannot be rewritten later
  perform _reconcile_report(p_fixture);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.submit_match_report_pass(p_pass text, p_report jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p match_passes;
begin
  p := _pass(p_pass);
  if p.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_pass'); end if;
  return _store_report(p.fixture_id, p.user_id, p_report);
end $$;

create or replace function public.submit_match_report(p_fixture_id uuid, p_report jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  return _store_report(p_fixture_id, auth.uid(), p_report);
end $$;

-- reports that arrive before the result is settled are processed when it is
create or replace function public._fixture_reconcile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then perform _reconcile_report(new.id); end if;
  return new;
end $$;
create trigger fixtures_reconcile after update of status on public.fixtures
  for each row execute function public._fixture_reconcile();

-- ---------------------------------------------------------------- 2. career numbers
create or replace function public.career_stats(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with f as (
    select x.* from fixtures x join tournaments t on t.id = x.tournament_id
    where x.status = 'completed' and p_user in (x.player_a_id, x.player_b_id) and t.status <> 'draft'
  )
  select jsonb_build_object(
    'tournaments', (select count(*) from tournament_entries e join tournaments t on t.id = e.tournament_id
                    where e.user_id = p_user and e.status <> 'withdrawn' and t.status in ('live', 'completed')),
    'titles', (select count(*) from tournaments where champion_id = p_user),
    'played', (select count(*) from f),
    'won', (select count(*) from f where winner_id = p_user),
    'drawn', (select count(*) from f where winner_id is null),
    'lost', (select count(*) from f where winner_id is not null and winner_id <> p_user),
    'goals_for', (select coalesce(sum(case when player_a_id = p_user then score_a else score_b end), 0) from f where coalesce(outcome, '') <> 'win_by_noshow'),
    'goals_against', (select coalesce(sum(case when player_a_id = p_user then score_b else score_a end), 0) from f where coalesce(outcome, '') <> 'win_by_noshow'),
    'goals', (select count(*) from footballer_events where owner_id = p_user and kind = 'goal'))
$$;

-- leaderboards: kind = goal | assist | potm. Shown as "Footballer (Team)" plus the WIN ZONE player.
create or replace function public.footballer_leaders(p_tid uuid, p_kind text, p_limit int default 10)
returns table (footballer text, team_name text, owner_id uuid, owner_name text, total int, pens int, avg_rating numeric)
language sql stable security definer set search_path = public as $$
  select (array_agg(e.footballer order by e.id desc))[1], (array_agg(e.team_name order by e.id desc))[1], e.owner_id,
         (select coalesce(p.display_name, p.username) from profiles p where p.id = e.owner_id),
         count(*)::int, count(*) filter (where e.pen)::int, round(avg(e.rating), 1)
  from footballer_events e join tournaments t on t.id = e.tournament_id
  where e.tournament_id = p_tid and e.kind = p_kind and t.status <> 'draft'
  group by e.footballer_key, e.owner_id
  order by count(*) desc, avg(e.rating) desc nulls last, min(e.id)
  limit least(greatest(coalesce(p_limit, 10), 1), 50)
$$;

-- ---------------------------------------------------------------- grants
revoke execute on function public._fkey(text), public._side_events(jsonb, text, text), public._goal_sig(jsonb),
  public._reconcile_report(uuid), public._store_report(uuid, uuid, jsonb), public._fixture_reconcile() from public, anon, authenticated;
revoke execute on function public.player_stats(uuid), public.career_stats(uuid), public.footballer_leaders(uuid, text, int),
  public.submit_match_report_pass(text, jsonb), public.submit_match_report(uuid, jsonb) from public;
grant execute on function public.player_stats(uuid), public.career_stats(uuid), public.footballer_leaders(uuid, text, int),
  public.submit_match_report_pass(text, jsonb) to anon, authenticated;
grant execute on function public.submit_match_report(uuid, jsonb) to authenticated;
grant execute on all functions in schema public to service_role;
