-- WIN ZONE — 0019: the live score also says where each match is
-- phase: 'waiting' (no confirmed kick-off yet), 'live' (kick-off confirmed), 'checking' (a phone reported the end,
-- the result is being confirmed). The score and minute come from the newest phone reading of the last 90 seconds.
drop function if exists public.live_scores(uuid);
create function public.live_scores(p_tid uuid)
returns table (fixture_id uuid, score_a int, score_b int, minute int, updated_at timestamptz, phase text)
language sql stable security definer set search_path = public as $$
  with act as (
    select f.* from fixtures f join tournaments t on t.id = f.tournament_id and t.status = 'live'
    where f.tournament_id = p_tid and f.status = 'active'
  ), pick as (
    select distinct on (s.fixture_id) s.fixture_id,
      case when s.user_id = a.player_a_id then s.score_me else s.score_opp end as a,
      case when s.user_id = a.player_a_id then s.score_opp else s.score_me end as b,
      s.clock_seconds, s.updated_at
    from act a join match_latest_state s on s.fixture_id = a.id
    where s.layout = 'in_play' and s.updated_at > now() - interval '90 seconds' and s.score_me is not null and s.score_opp is not null
    order by s.fixture_id, s.updated_at desc
  )
  select a.id, p.a, p.b,
         case when p.clock_seconds is null then null else least(120, p.clock_seconds / 60 + 1) end,
         p.updated_at,
         case when exists (select 1 from match_latest_state s where s.fixture_id = a.id and s.terminal_kind is not null) then 'checking'
              when a.kickoff_at is not null then 'live' else 'waiting' end
  from act a left join pick p on p.fixture_id = a.id
$$;
revoke execute on function public.live_scores(uuid) from public;
grant execute on function public.live_scores(uuid) to anon, authenticated, service_role;
update public.game_profiles set profile = profile || '{"min_app": "0.4.1"}'::jsonb;
