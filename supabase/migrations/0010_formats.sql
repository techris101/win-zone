-- WIN ZONE — 0010 formats, tie-breaks, schedule speeds (from docs/RESEARCH.md, approved 2026-11-20)
-- New formats: groups of 3-4 + knockout (World Cup / AFCON style) and league phase + play-offs + knockout
-- (Champions League style, Swiss pairing). One tie-break order for every table. Three schedule speeds.

alter table public.tournaments drop constraint tournaments_format_check;
alter table public.tournaments add constraint tournaments_format_check
  check (format in ('knockout', 'league', 'league_knockout', 'groups_knockout', 'league_phase'));
alter table public.tournaments add column schedule_speed text not null default 'standard' check (schedule_speed in ('standard', 'fast', 'oneday'));
alter table public.tournaments add column phase_rounds int check (phase_rounds between 3 and 12);
alter table public.fixtures drop constraint fixtures_stage_check;
alter table public.fixtures add constraint fixtures_stage_check check (stage in ('league', 'group', 'playoff', 'knockout'));
alter table public.fixtures add column group_no int;
alter table public.tournament_entries add column group_no int;

-- ---------------------------------------------------------------- standings with the approved tie-break order
-- points, goal difference, goals scored, head-to-head points among the tied, wins, strength of opponents
-- (their total points), fewer forfeit/no-show losses, earlier registration.
-- Forfeit or no-show wins count 3-0. A league-phase bye counts as a win with no goals.
create or replace function public._standings(p_tid uuid, p_stage text, p_group int)
returns table (user_id uuid, group_no int, played int, won int, drawn int, lost int, gf int, ga int, gd int,
               points int, h2h int, sos int, forfeits int, rank int)
language sql stable security definer set search_path = public as $$
  with fx as (
    select f.* from fixtures f
    where f.tournament_id = p_tid and f.stage = p_stage and (p_group is null or f.group_no = p_group)
      and (f.status = 'completed' or (f.status = 'bye' and p_stage = 'league'))
  ),
  res as (
    select f.id, f.player_a_id as pa, f.player_b_id as pb, f.winner_id, f.status, f.outcome,
           case when f.status = 'bye' then 0
                when f.outcome in ('win_by_forfeit', 'win_by_noshow') then case when f.winner_id = f.player_a_id then 3 else 0 end
                else coalesce(f.score_a, 0) end as sa,
           case when f.status = 'bye' then 0
                when f.outcome in ('win_by_forfeit', 'win_by_noshow') then case when f.winner_id = f.player_b_id then 3 else 0 end
                else coalesce(f.score_b, 0) end as sb
    from fx f
  ),
  rows as (
    select id, pa as uid, pb as oid, sa as gf, sa - sb as diff, sb as ga, status = 'bye' as bye,
           (outcome in ('win_by_forfeit', 'win_by_noshow') and winner_id is distinct from pa) as ff_loss
    from res where pa is not null
    union all
    select id, pb, pa, sb, sb - sa, sa, false, (outcome in ('win_by_forfeit', 'win_by_noshow') and winner_id is distinct from pb)
    from res where pb is not null and status <> 'bye'
  ),
  ent as (
    select e.user_id as uid, e.group_no as grp, e.created_at as joined
    from tournament_entries e
    where e.tournament_id = p_tid and e.status <> 'withdrawn' and (p_group is null or e.group_no = p_group)
  ),
  base as (
    select n.uid, n.grp, n.joined,
           count(r.id)::int as played,
           count(*) filter (where r.id is not null and (r.bye or r.diff > 0))::int as won,
           count(*) filter (where r.id is not null and not r.bye and r.diff = 0)::int as drawn,
           count(*) filter (where r.id is not null and not r.bye and r.diff < 0)::int as lost,
           coalesce(sum(r.gf), 0)::int as gf, coalesce(sum(r.ga), 0)::int as ga,
           count(*) filter (where r.ff_loss)::int as forfeits
    from ent n left join rows r on r.uid = n.uid
    group by n.uid, n.grp, n.joined
  ),
  scored as (select b.*, (b.gf - b.ga) as gd, (b.won * 3 + b.drawn)::int as points from base b),
  extra as (
    select s1.uid,
      coalesce((select sum(case when r.diff > 0 then 3 when r.diff = 0 then 1 else 0 end)
                from rows r join scored s2 on s2.uid = r.oid
                where r.uid = s1.uid and not r.bye and s2.points = s1.points and s2.gd = s1.gd and s2.gf = s1.gf), 0)::int as h2h,
      coalesce((select sum(s3.points) from rows r join scored s3 on s3.uid = r.oid where r.uid = s1.uid and not r.bye), 0)::int as sos
    from scored s1
  )
  select s.uid, s.grp, s.played, s.won, s.drawn, s.lost, s.gf, s.ga, s.gd, s.points, x.h2h, x.sos, s.forfeits,
         (row_number() over (partition by case when p_group is null and p_stage = 'group' then s.grp end
                             order by s.points desc, s.gd desc, s.gf desc, x.h2h desc, s.won desc, x.sos desc, s.forfeits asc, s.joined asc))::int
  from scored s join extra x on x.uid = s.uid
  order by s.grp nulls first, 14
$$;

drop function if exists public.league_table(uuid);
create function public.league_table(p_tid uuid)
returns table (user_id uuid, played int, won int, drawn int, lost int, gf int, ga int, gd int,
               points int, h2h int, sos int, forfeits int, rank int)
language sql stable security definer set search_path = public as $$
  select user_id, played, won, drawn, lost, gf, ga, gd, points, h2h, sos, forfeits, rank
  from _standings(p_tid, 'league', null)
$$;

-- every group's table at once (group_no 1 = "Group A")
create or replace function public.group_tables(p_tid uuid)
returns table (user_id uuid, group_no int, played int, won int, drawn int, lost int, gf int, ga int, gd int,
               points int, h2h int, sos int, forfeits int, rank int)
language sql stable security definer set search_path = public as $$
  select * from _standings(p_tid, 'group', null)
$$;

create or replace function public._clock_class(p_stage text, p_clock int, p_reg int, p_ext int)
returns text language sql immutable as $$
  select case
    when p_clock is null then 'anomaly'
    when p_clock < p_reg - 5 then 'early'
    when p_clock <= p_reg + 5 then 'regulation'
    when p_stage in ('league', 'group') then 'anomaly'
    when p_clock < p_ext - 5 then 'early'
    else 'extra'
  end
$$;

create or replace function public._evaluate_fixture(p_fixture_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  f fixtures; g games; sa match_latest_state; sb match_latest_state;
  ca text; cb text; a_claim boolean; b_claim boolean;
  v_a_me int; v_a_opp int; v_winner uuid; v_pa int; v_pb int;
begin
  select * into f from fixtures where id = p_fixture_id;
  select gm.* into g from tournaments t join games gm on gm.id = t.game_id where t.id = f.tournament_id;
  select * into sa from match_latest_state where fixture_id = f.id and user_id = f.player_a_id;
  select * into sb from match_latest_state where fixture_id = f.id and user_id = f.player_b_id;

  if f.kickoff_at is null then
    return jsonb_build_object('status', 'wait', 'reason', 'no_kickoff');
  end if;
  if sa.terminal_kind is null and sb.terminal_kind is null then
    return jsonb_build_object('status', 'wait', 'reason', 'no_terminal');
  end if;

  ca := case when sa.terminal_kind is null then null
             when sa.terminal_kind = 'opponent_quit' then 'quit'
             else _clock_class(f.stage, sa.t_clock, g.regulation_seconds, g.extra_time_seconds) end;
  cb := case when sb.terminal_kind is null then null
             when sb.terminal_kind = 'opponent_quit' then 'quit'
             else _clock_class(f.stage, sb.t_clock, g.regulation_seconds, g.extra_time_seconds) end;
  a_claim := ca in ('quit', 'early');
  b_claim := cb in ('quit', 'early');

  -- Forfeit paths: the phone that still shows a result wins, whatever the score.
  if a_claim and b_claim then
    return jsonb_build_object('status', 'dispute', 'reason', 'both_claim_forfeit');
  elsif a_claim or b_claim then
    declare
      w match_latest_state := case when a_claim then sa else sb end;
      o match_latest_state := case when a_claim then sb else sa end;
    begin
      if o.terminal_kind is not null then
        return jsonb_build_object('status', 'dispute', 'reason', 'conflicting_terminals');
      end if;
      if now() - w.terminal_at < interval '20 seconds' then
        return jsonb_build_object('status', 'wait', 'reason', 'grace');
      end if;
      if o.last_in_play_at is not null and o.last_in_play_at > w.terminal_at + interval '2 seconds' then
        return jsonb_build_object('status', 'dispute', 'reason', 'opponent_still_playing');
      end if;
      return jsonb_build_object(
        'status', 'win', 'outcome', 'win_by_forfeit', 'winner_id', w.user_id,
        'score_a', case when a_claim then w.t_score_me else w.t_score_opp end,
        'score_b', case when a_claim then w.t_score_opp else w.t_score_me end,
        'pen_a',   case when a_claim then w.t_pen_me else w.t_pen_opp end,
        'pen_b',   case when a_claim then w.t_pen_opp else w.t_pen_me end);
    end;
  end if;

  -- Normal full time: both phones must have reported a result.
  if sa.terminal_kind is null or sb.terminal_kind is null then
    return jsonb_build_object('status', 'wait', 'reason', 'waiting_for_other_phone');
  end if;
  if ca = 'anomaly' or cb = 'anomaly' then
    return jsonb_build_object('status', 'dispute', 'reason', 'clock_anomaly');
  end if;
  if ca <> cb then
    return jsonb_build_object('status', 'dispute', 'reason', 'clock_mismatch');
  end if;
  -- Mirror check: my goals on one phone must equal opponent goals on the other.
  if sa.t_score_me is distinct from sb.t_score_opp or sa.t_score_opp is distinct from sb.t_score_me
     or coalesce(sa.t_pen_me, -1) <> coalesce(sb.t_pen_opp, -1)
     or coalesce(sa.t_pen_opp, -1) <> coalesce(sb.t_pen_me, -1) then
    return jsonb_build_object('status', 'dispute', 'reason', 'score_mismatch');
  end if;

  v_a_me := sa.t_score_me; v_a_opp := sa.t_score_opp;
  v_pa := sa.t_pen_me;     v_pb := sa.t_pen_opp;
  if v_a_me > v_a_opp then v_winner := f.player_a_id;
  elsif v_a_me < v_a_opp then v_winner := f.player_b_id;
  elsif v_pa is not null and v_pb is not null and v_pa <> v_pb then
    v_winner := case when v_pa > v_pb then f.player_a_id else f.player_b_id end;
  end if;

  if v_winner is null then
    if f.stage in ('league', 'group') then
      return jsonb_build_object('status', 'draw', 'outcome', 'draw',
        'score_a', v_a_me, 'score_b', v_a_opp, 'pen_a', v_pa, 'pen_b', v_pb);
    end if;
    return jsonb_build_object('status', 'dispute', 'reason', 'knockout_level_no_winner');
  end if;
  -- A knockout cannot end level at regulation; a draw here means the screen was misread.
  if f.stage in ('knockout', 'playoff') and ca = 'regulation' and v_a_me = v_a_opp then
    return jsonb_build_object('status', 'dispute', 'reason', 'knockout_level_at_regulation');
  end if;

  return jsonb_build_object('status', 'win', 'outcome', 'win_by_score', 'winner_id', v_winner,
    'score_a', v_a_me, 'score_b', v_a_opp, 'pen_a', v_pa, 'pen_b', v_pb);
end $$;

create or replace function public._auto_time(p_tid uuid, p_stage text, p_round int) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare t tournaments; v_pre int; v_po int; v_offset int; v_base timestamptz;
begin
  select * into t from tournaments where id = p_tid;
  select coalesce(max(round), 0) into v_pre from fixtures where tournament_id = p_tid and stage in ('league', 'group');
  select case when exists (select 1 from fixtures where tournament_id = p_tid and stage = 'playoff') then 1 else 0 end into v_po;
  v_offset := case p_stage
    when 'league' then p_round - 1
    when 'group' then p_round - 1
    when 'playoff' then v_pre + p_round - 1
    else v_pre + v_po + p_round - 1 end;
  if t.schedule_speed = 'oneday' then
    -- one-day event: a round every 45 minutes from the start, at least 15 minutes' notice
    v_base := coalesce(t.starts_at, now() + interval '30 minutes');
    return greatest(now() + interval '15 minutes', v_base + make_interval(mins => v_offset * 45));
  end if;
  return _next_slot(coalesce(t.schedule_tz, 'Africa/Kigali'), t.slot_hour,
                    greatest(now() + interval '12 hours',
                             coalesce(t.starts_at, now() + interval '24 hours') + make_interval(hours => v_offset * t.round_gap_hours)));
end $$;

-- ---------------------------------------------------------------- groups of 3-4 + knockout
create or replace function public._generate_groups(p_tid uuid, p_players uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare
  n int := coalesce(array_length(p_players, 1), 0); g int; i int; k int; v_grp int; members uuid[]; arr uuid[];
  m int; r int; a uuid; b uuid; fid uuid; v_slot int;
begin
  if n < 6 then raise exception 'groups need at least 6 players'; end if;
  g := ceil(n / 4.0)::int;
  -- snake order spreads the seeds over the groups
  for i in 1..n loop
    k := (i - 1) / g;
    v_grp := case when k % 2 = 0 then ((i - 1) % g) + 1 else g - ((i - 1) % g) end;
    update tournament_entries set group_no = v_grp where tournament_id = p_tid and user_id = p_players[i];
  end loop;

  for v_grp in 1..g loop
    select array_agg(user_id order by seed) into members from tournament_entries
    where tournament_id = p_tid and group_no = v_grp and status <> 'withdrawn';
    arr := members;
    if array_length(arr, 1) % 2 = 1 then arr := arr || null::uuid; end if;
    m := array_length(arr, 1);
    for r in 1..(m - 1) loop
      for i in 1..(m / 2) loop
        a := arr[i]; b := arr[m + 1 - i];
        if a is not null and b is not null then
          v_slot := (v_grp - 1) * 10 + i;
          if (r + i) % 2 = 1 then
            insert into fixtures (tournament_id, stage, round, slot, group_no, player_a_id, player_b_id, host_player_id)
            values (p_tid, 'group', r, v_slot, v_grp, a, b, a) returning id into fid;
          else
            insert into fixtures (tournament_id, stage, round, slot, group_no, player_a_id, player_b_id, host_player_id)
            values (p_tid, 'group', r, v_slot, v_grp, b, a, b) returning id into fid;
          end if;
          perform _ensure_matchroom(fid);
          update fixtures set scheduled_at = _auto_time(p_tid, 'group', r) where id = fid;
        end if;
      end loop;
      arr := arr[1:1] || arr[m:m] || arr[2:m - 1];
    end loop;
  end loop;
end $$;

-- top 2 of each group + best third-placed players fill the next bracket size (World Cup 2026 / AFCON);
-- if there are not enough third-placed players, the bracket shrinks to group winners + best runners-up.
-- Players from different groups are compared per match played (groups can have 3 or 4 players).
create or replace function public._start_knockout_from_groups(p_tid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare g int; p int := 1; v_q uuid[]; r record;
begin
  select max(group_no) into g from tournament_entries where tournament_id = p_tid;
  while p < 2 * g loop p := p * 2; end loop;
  if p > 3 * g then p := p / 2; end if;

  with st as (
    select s.*, s.points::numeric / greatest(s.played, 1) as ppm, s.gd::numeric / greatest(s.played, 1) as gdpm,
           s.gf::numeric / greatest(s.played, 1) as gfpm, s.won::numeric / greatest(s.played, 1) as wpm
    from _standings(p_tid, 'group', null) s
  ),
  ordered as (
    select user_id, rank as pos, row_number() over (order by rank, ppm desc, gdpm desc, gfpm desc, wpm desc, forfeits, group_no) as seed
    from st
  )
  select array_agg(user_id order by seed) into v_q from (select * from ordered order by seed limit p) q;

  perform _generate_knockout(p_tid, v_q);
  for r in select user_id from tournament_entries where tournament_id = p_tid and status <> 'withdrawn'
           and not (user_id = any (v_q)) loop
    perform _eliminated(r.user_id, p_tid, 'not_qualified');
  end loop;
end $$;

-- have two players already met in the league phase?
create or replace function public._have_met(p_tid uuid, p_a uuid, p_b uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from fixtures where tournament_id = p_tid and stage = 'league'
                 and ((player_a_id = p_a and player_b_id = p_b) or (player_a_id = p_b and player_b_id = p_a)))
$$;

-- pair a ranked list with no rematches, preferring opponents close in the table (depth-first with backtracking).
-- returns [a1, b1, a2, b2, ...] or null when no rematch-free pairing exists.
create or replace function public._swiss_match(p_tid uuid, p_pool uuid[]) returns uuid[]
language plpgsql stable set search_path = public as $$
declare a uuid; j int; rest uuid[]; res uuid[];
begin
  if coalesce(array_length(p_pool, 1), 0) = 0 then return '{}'; end if;
  a := p_pool[1];
  for j in 2..array_length(p_pool, 1) loop
    if not _have_met(p_tid, a, p_pool[j]) then
      rest := array_remove(array_remove(p_pool, a), p_pool[j]);
      res := _swiss_match(p_tid, rest);
      if res is not null then return array[a, p_pool[j]] || res; end if;
    end if;
  end loop;
  return null;
end $$;

-- ---------------------------------------------------------------- league phase (Swiss pairing) + play-offs + knockout
-- each round pairs players with similar standings who have not met yet; with an odd number, the lowest-ranked
-- player who has not had a bye gets one (counts as a win, no goals).
create or replace function public._pair_phase_round(p_tid uuid, p_round int) returns void
language plpgsql security definer set search_path = public as $$
declare
  order_ids uuid[]; pool uuid[]; pairs uuid[]; v_bye uuid; a uuid; b uuid; i int; j int; v_slot int := 0; fid uuid; found boolean;
begin
  if p_round = 1 then
    select array_agg(user_id order by seed) into order_ids from tournament_entries where tournament_id = p_tid and status <> 'withdrawn';
  else
    select array_agg(user_id order by rank) into order_ids from league_table(p_tid);
  end if;

  if array_length(order_ids, 1) % 2 = 1 then
    select x into v_bye from unnest(order_ids) with ordinality as o(x, ord)
    where not exists (select 1 from fixtures where tournament_id = p_tid and stage = 'league' and status = 'bye' and player_a_id = o.x)
    order by ord desc limit 1;
    if v_bye is null then v_bye := order_ids[array_length(order_ids, 1)]; end if;
    insert into fixtures (tournament_id, stage, round, slot, player_a_id, status, winner_id, outcome, completed_at)
    values (p_tid, 'league', p_round, 999, v_bye, 'bye', v_bye, 'bye', now());
    order_ids := array_remove(order_ids, v_bye);
  end if;

  -- best pairing without rematches (closest standings first); only if none exists, allow the fewest rematches
  pairs := _swiss_match(p_tid, order_ids);
  if pairs is null then
    pairs := '{}';
    pool := order_ids;
    while coalesce(array_length(pool, 1), 0) >= 2 loop
      a := pool[1]; found := false;
      for j in 2..array_length(pool, 1) loop
        if not _have_met(p_tid, a, pool[j]) then b := pool[j]; found := true; exit; end if;
      end loop;
      if not found then b := pool[2]; end if;
      pairs := pairs || a || b;
      pool := array_remove(array_remove(pool, a), b);
    end loop;
  end if;

  for i in 1..(coalesce(array_length(pairs, 1), 0) / 2) loop
    a := pairs[2 * i - 1]; b := pairs[2 * i];
    v_slot := v_slot + 1;
    insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, host_player_id)
    values (p_tid, 'league', p_round, v_slot, a, b, a) returning id into fid;
    perform _ensure_matchroom(fid);
    update fixtures set scheduled_at = _auto_time(p_tid, 'league', p_round) where id = fid;
  end loop;
end $$;

-- knockout size: 16 with 32+ players, 8 with 16+, else 4. Top half of it qualify directly; the next ranks
-- (as many as the bracket size) play a single play-off round (9th v 24th, 10th v 23rd ...); the rest are out.
create or replace function public._phase_bracket_size(p_players int) returns int
language sql immutable as $$ select case when p_players >= 32 then 16 when p_players >= 16 then 8 else 4 end $$;

create or replace function public._start_after_phase(p_tid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n int; s int; ranked uuid[]; i int; fid uuid; v_keep int; r record;
begin
  select array_agg(user_id order by rank) into ranked from league_table(p_tid);
  n := coalesce(array_length(ranked, 1), 0);
  s := _phase_bracket_size(n);
  if n >= s + s / 2 then
    for i in 1..(s / 2) loop
      insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, host_player_id)
      values (p_tid, 'playoff', 1, i, ranked[s / 2 + i], ranked[s / 2 + s + 1 - i], ranked[s / 2 + i]) returning id into fid;
      perform _ensure_matchroom(fid);
      update fixtures set scheduled_at = _auto_time(p_tid, 'playoff', 1) where id = fid;
    end loop;
    v_keep := s + s / 2;
  else
    perform _generate_knockout(p_tid, ranked[1:least(s, n)]);
    v_keep := least(s, n);
  end if;
  for r in select x from unnest(ranked) with ordinality as o(x, ord) where ord > v_keep loop
    perform _eliminated(r.x, p_tid, 'not_qualified');
  end loop;
end $$;

create or replace function public._start_knockout_after_playoff(p_tid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare ranked uuid[]; s int; seeds uuid[]; w uuid; i int;
begin
  if exists (select 1 from fixtures where tournament_id = p_tid and stage = 'knockout') then return; end if;
  select array_agg(user_id order by rank) into ranked from league_table(p_tid);
  s := _phase_bracket_size(coalesce(array_length(ranked, 1), 0));
  seeds := ranked[1:s / 2];
  for i in 1..(s / 2) loop
    select winner_id into w from fixtures where tournament_id = p_tid and stage = 'playoff' and slot = i;
    seeds := seeds || w;
  end loop;
  perform _generate_knockout(p_tid, seeds);
end $$;

create or replace function public._plan_tournament(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments; v_players uuid[]; n int; v_adv int; v_tz text;
begin
  select * into t from tournaments where id = p_tid for update;
  if t.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if t.status not in ('draft', 'open') then return jsonb_build_object('ok', false, 'reason', 'already_planned'); end if;

  select array_agg(user_id order by random()) into v_players
  from tournament_entries where tournament_id = p_tid and status <> 'withdrawn';
  n := coalesce(array_length(v_players, 1), 0);
  if n < 2 then return jsonb_build_object('ok', false, 'reason', 'need_two_players'); end if;
  update tournaments set status = 'planning' where id = p_tid;   -- claim it first: no re-entry, no double planning

  update tournament_entries e set seed = q.rn
  from (select user_id, row_number() over () as rn from unnest(v_players) as user_id) q
  where e.tournament_id = p_tid and e.user_id = q.user_id;

  -- time zone: the most common one among the players, unless the admin already chose one
  if t.schedule_tz is null then
    select c.tz into v_tz
    from tournament_entries e join profiles p on p.id = e.user_id join countries c on c.code = p.country
    where e.tournament_id = p_tid and e.status <> 'withdrawn'
    group by c.tz order by count(*) desc, c.tz limit 1;
    update tournaments set schedule_tz = coalesce(v_tz, 'Africa/Kigali') where id = p_tid;
  end if;

  if t.format = 'knockout' then
    perform _generate_knockout(p_tid, v_players);
  elsif t.format = 'groups_knockout' then
    perform _generate_groups(p_tid, v_players);
  elsif t.format = 'league_phase' then
    update tournaments set phase_rounds = coalesce(phase_rounds, greatest(least(6, n - 1), ceil(log(2, n::numeric))::int)) where id = p_tid;
    perform _pair_phase_round(p_tid, 1);
  else
    if t.format = 'league_knockout' then
      v_adv := t.league_advance;
      while v_adv > n loop v_adv := v_adv / 2; end loop;
      if v_adv < 2 then v_adv := 2; end if;
      update tournaments set league_advance = v_adv where id = p_tid;
    end if;
    perform _generate_league(p_tid, v_players);
  end if;

  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'plan_tournament', 'tournament', p_tid, jsonb_build_object('players', n));
  return jsonb_build_object('ok', true, 'players', n);
end $$;

create or replace function public._after_final(p_fixture_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  f fixtures; t tournaments; nxt fixtures; v_remaining int; v_champ uuid;
begin
  select * into f from fixtures where id = p_fixture_id;
  select * into t from tournaments where id = f.tournament_id;

  if f.stage = 'playoff' then
    if not exists (select 1 from fixtures where tournament_id = f.tournament_id and stage = 'playoff' and status not in ('completed', 'cancelled', 'bye')) then
      perform _start_knockout_after_playoff(f.tournament_id);
    end if;
    return;
  end if;
  if f.stage = 'group' then
    if not exists (select 1 from fixtures where tournament_id = f.tournament_id and stage = 'group' and status not in ('completed', 'cancelled', 'bye')) then
      perform _start_knockout_from_groups(f.tournament_id);
    end if;
    return;
  end if;
  if f.stage = 'league' and t.format = 'league_phase' then
    if not exists (select 1 from fixtures where tournament_id = f.tournament_id and stage = 'league' and round = f.round and status not in ('completed', 'cancelled', 'bye')) then
      if f.round < t.phase_rounds then
        perform _pair_phase_round(f.tournament_id, f.round + 1);
      elsif not exists (select 1 from fixtures where tournament_id = f.tournament_id and stage in ('playoff', 'knockout')) then
        perform _start_after_phase(f.tournament_id);
      end if;
    end if;
    return;
  end if;
  if f.stage = 'knockout' then
    if f.winner_id is null then raise exception 'knockout fixture % has no winner', f.id; end if;
    if f.next_fixture_id is null then
      update tournaments set status = 'completed', champion_id = f.winner_id where id = f.tournament_id;
    else
      update fixtures
      set player_a_id = case when f.next_side = 'A' then f.winner_id else player_a_id end,
          player_b_id = case when f.next_side = 'B' then f.winner_id else player_b_id end
      where id = f.next_fixture_id
        and (case f.next_side when 'A' then player_a_id else player_b_id end) is null
      returning * into nxt;
      if not found then
        raise exception 'bracket slot already filled for fixture %', f.next_fixture_id;
      end if;
      if nxt.player_a_id is not null and nxt.player_b_id is not null then
        update fixtures set host_player_id = player_a_id where id = nxt.id;
        perform _ensure_matchroom(nxt.id);
        update fixtures set scheduled_at = _auto_time(f.tournament_id, 'knockout', nxt.round) where id = nxt.id;
      end if;
    end if;

  elsif f.stage = 'league' then
    select count(*) into v_remaining from fixtures
    where tournament_id = f.tournament_id and stage = 'league'
      and status not in ('completed', 'cancelled', 'bye');
    if v_remaining = 0 then
      if t.format = 'league' then
        select user_id into v_champ from league_table(t.id) where rank = 1;
        update tournaments set status = 'completed', champion_id = v_champ where id = t.id;
      elsif t.format = 'league_knockout'
            and not exists (select 1 from fixtures where tournament_id = t.id and stage = 'knockout') then
        perform _start_knockout(t.id);
      end if;
    end if;
  end if;
end $$;

create or replace function public.update_tournament(p_tid uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments; v_active int;
begin
  select * into t from tournaments where id = p_tid for update;
  if t.id is null then raise exception 'not_found'; end if;
  if not (is_admin() or t.created_by = auth.uid()) then raise exception 'not_allowed'; end if;
  if t.status in ('completed', 'cancelled') then return jsonb_build_object('ok', false, 'reason', 'tournament_finished'); end if;

  if p_patch ? 'size' then
    if t.status not in ('draft', 'open') then return jsonb_build_object('ok', false, 'reason', 'size_locked'); end if;
    select count(*) into v_active from tournament_entries where tournament_id = p_tid and status <> 'withdrawn';
    if (p_patch ->> 'size')::int < greatest(v_active, 2) then return jsonb_build_object('ok', false, 'reason', 'size_below_players'); end if;
  end if;
  if p_patch ? 'schedule_speed' and p_patch ->> 'schedule_speed' not in ('standard', 'fast', 'oneday') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_speed');
  end if;
  if p_patch ? 'phase_rounds' and ((p_patch ->> 'phase_rounds')::int not between 3 and 12 or t.status not in ('draft', 'open')) then
    return jsonb_build_object('ok', false, 'reason', 'bad_phase_rounds');
  end if;
  if p_patch ? 'format' and (t.status not in ('draft', 'open') or p_patch ->> 'format' not in ('knockout', 'league', 'league_knockout', 'groups_knockout', 'league_phase')) then
    return jsonb_build_object('ok', false, 'reason', 'format_locked');
  end if;
  if p_patch ? 'schedule_tz' and not exists (select 1 from pg_timezone_names where name = p_patch ->> 'schedule_tz') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_time_zone');
  end if;

  update tournaments set
    name = coalesce(nullif(p_patch ->> 'name', ''), name),
    prize_description = case when p_patch ? 'prize_description' then nullif(p_patch ->> 'prize_description', '') else prize_description end,
    starts_at = case when p_patch ? 'starts_at' then nullif(p_patch ->> 'starts_at', '')::timestamptz else starts_at end,
    size = coalesce((p_patch ->> 'size')::int, size),
    league_advance = coalesce((p_patch ->> 'league_advance')::int, league_advance),
    schedule_tz = coalesce(nullif(p_patch ->> 'schedule_tz', ''), schedule_tz),
    slot_hour = coalesce((p_patch ->> 'slot_hour')::int, slot_hour),
    schedule_speed = coalesce(p_patch ->> 'schedule_speed', schedule_speed),
    phase_rounds = coalesce((p_patch ->> 'phase_rounds')::int, phase_rounds),
    format = coalesce(p_patch ->> 'format', format),
    round_gap_hours = coalesce((p_patch ->> 'round_gap_hours')::int,
                               case p_patch ->> 'schedule_speed' when 'standard' then 48 when 'fast' then 24 end, round_gap_hours)
  where id = p_tid;
  insert into audit_logs (actor, action, entity, entity_id, details) values (auth.uid(), 'update_tournament', 'tournament', p_tid, p_patch);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public._fixture_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  t tournaments; p uuid; v_me int; v_opp int; v_kind text; v_left int; v_lang text; r record; v_top uuid[];
begin
  select * into t from tournaments where id = new.tournament_id;
  if t.status not in ('live', 'completed') or new.player_a_id is null or new.player_b_id is null then return new; end if;

  -- a match result
  if new.status = 'completed' and old.status is distinct from 'completed' then
    foreach p in array array[new.player_a_id, new.player_b_id] loop
      v_me := case when p = new.player_a_id then new.score_a else new.score_b end;
      v_opp := case when p = new.player_a_id then new.score_b else new.score_a end;
      v_kind := case when new.winner_id is null then 'result_draw' when new.winner_id = p then 'result_win' else 'result_loss' end;
      perform _notify(p, t.id, new.id, v_kind,
        jsonb_build_object('opp', _opp_name(new, p), 'score', case when v_me is null then '' else v_me || '-' || v_opp end),
        'res:' || new.id, '/t/' || t.slug);
    end loop;
    if new.stage in ('knockout', 'playoff') and new.winner_id is not null then
      perform _eliminated(case when new.winner_id = new.player_a_id then new.player_b_id else new.player_a_id end, t.id, 'knocked_out');
    end if;

    -- the round is complete?
    if not exists (select 1 from fixtures where tournament_id = t.id and stage = new.stage and round = new.round
                   and status not in ('completed', 'bye', 'cancelled')) then
      if new.stage in ('knockout', 'playoff') then
        select count(*) into v_left from fixtures where tournament_id = t.id and stage = new.stage and round = new.round and winner_id is not null;
        for r in select user_id from tournament_follows where tournament_id = t.id loop
          select lang into v_lang from profiles where id = r.user_id;
          perform _notify(r.user_id, t.id, null, 'round_complete_ko',
            jsonb_build_object('round', _round_name(t.id, new.stage, new.round, v_lang), 'n', v_left),
            'round:' || t.id || ':ko:' || new.round, null, null, true);
        end loop;
      elsif new.stage = 'group' then
        for r in select gt.user_id, gt.rank, gt.points from group_tables(t.id) gt where gt.group_no = new.group_no loop
          perform _notify(r.user_id, t.id, null, 'round_complete_league',
            jsonb_build_object('round', new.round, 'rank', r.rank, 'pts', r.points),
            'round:' || t.id || ':grp:' || new.group_no || ':' || new.round, null, null, true);
        end loop;
      else
        for r in select lt.user_id, lt.rank, lt.points from league_table(t.id) lt loop
          perform _notify(r.user_id, t.id, null, 'round_complete_league',
            jsonb_build_object('round', new.round, 'rank', r.rank, 'pts', r.points),
            'round:' || t.id || ':lg:' || new.round, null, null, true);
        end loop;
        -- league stage over in a league + knockout: tell those who did not qualify
        if t.format = 'league_knockout' and not exists (select 1 from fixtures where tournament_id = t.id and stage = 'league'
                                                        and status not in ('completed', 'cancelled', 'bye')) then
          select array_agg(user_id) into v_top from (select user_id from league_table(t.id) order by rank limit t.league_advance) q;
          for r in select user_id from tournament_entries where tournament_id = t.id and status <> 'withdrawn'
                   and not (user_id = any (coalesce(v_top, '{}'))) loop
            perform _eliminated(r.user_id, t.id, 'not_qualified');
          end loop;
        end if;
      end if;
    end if;

  -- sent to an admin for review
  elsif new.status = 'disputed' and old.status is distinct from 'disputed' then
    foreach p in array array[new.player_a_id, new.player_b_id] loop
      perform _notify(p, t.id, new.id, 'under_review', jsonb_build_object('opp', _opp_name(new, p)), 'review:' || new.id, '/t/' || t.slug);
    end loop;

  -- a new or changed time for an upcoming match
  elsif t.status = 'live' and new.status = 'scheduled' and new.scheduled_at is not null
        and new.scheduled_at is distinct from old.scheduled_at then
    foreach p in array array[new.player_a_id, new.player_b_id] loop
      if old.scheduled_at is null or old.player_a_id is null or old.player_b_id is null then
        select lang into v_lang from profiles where id = p;
        perform _notify(p, t.id, new.id, 'next_match',
          jsonb_build_object('opp', _opp_name(new, p), 'round', _round_name(t.id, new.stage, new.round, v_lang)),
          'next:' || new.id || ':' || extract(epoch from new.scheduled_at)::bigint, '/matchroom.html?f=' || new.id, null, false, new.scheduled_at);
      else
        perform _notify(p, t.id, new.id, 'rescheduled', jsonb_build_object('opp', _opp_name(new, p)),
          'time:' || new.id || ':' || extract(epoch from new.scheduled_at)::bigint, '/matchroom.html?f=' || new.id, null, false, new.scheduled_at);
      end if;
    end loop;
  end if;
  return new;
end $$;

create or replace function public._round_name(p_tid uuid, p_stage text, p_round int, p_lang text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_last int; v_left int; l text := coalesce(p_lang, 'en');
begin
  if p_stage = 'playoff' then
    return case l when 'fr' then 'Barrages' when 'rw' then 'Imikino ya kamarampaka' else 'Play-off round' end;
  end if;
  if p_stage = 'group' then
    return case l when 'fr' then 'phase de groupes, journée ' when 'rw' then 'amatsinda, umunsi wa ' else 'group stage, round ' end || p_round;
  end if;
  if p_stage = 'league' then
    return case l when 'fr' then 'journée ' when 'rw' then 'umunsi wa ' else 'league round ' end || p_round;
  end if;
  select max(round) into v_last from fixtures where tournament_id = p_tid and stage = 'knockout';
  v_left := coalesce(v_last, p_round) - p_round;
  return case
    when v_left = 0 then case l when 'fr' then 'Finale' when 'rw' then 'Umukino wa nyuma' else 'Final' end
    when v_left = 1 then case l when 'fr' then 'Demi-finales' when 'rw' then 'Kimwe cya kabiri' else 'Semi-finals' end
    when v_left = 2 then case l when 'fr' then 'Quarts de finale' when 'rw' then 'Kimwe cya kane' else 'Quarter-finals' end
    when v_left = 3 then case l when 'fr' then 'Huitièmes de finale' when 'rw' then '16 ba nyuma' else 'Round of 16' end
    else case l when 'fr' then 'Tour ' when 'rw' then 'Icyiciro cya ' else 'Round ' end || p_round
  end;
end $$;

-- ---------------------------------------------------------------- recommendation shown to organizers
create or replace function public.recommend_format(p_players int) returns text
language sql immutable as $$
  select case when p_players <= 6 then 'league' when p_players <= 11 then 'league_knockout'
              when p_players <= 31 then 'groups_knockout' else 'league_phase' end
$$;

-- ---------------------------------------------------------------- grants
revoke execute on function public._standings(uuid, text, int), public._generate_groups(uuid, uuid[]),
  public._start_knockout_from_groups(uuid), public._pair_phase_round(uuid, int), public._start_after_phase(uuid),
  public._start_knockout_after_playoff(uuid), public._phase_bracket_size(int), public._have_met(uuid, uuid, uuid),
  public._swiss_match(uuid, uuid[]) from public, anon, authenticated;
grant execute on function public.league_table(uuid), public.group_tables(uuid), public.recommend_format(int) to anon, authenticated;
grant execute on all functions in schema public to service_role;
