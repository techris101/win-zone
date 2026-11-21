-- WIN ZONE — 0016 strict kick-off, full-time rules, live score
-- 1. Kick-off = both phones show the match running at 0-0 with the clock at 00:01-02:00. No kick-off, no automatic result:
--    the admin decides. (This replaces the softer rule from 0015.)
-- 2. Screen rules: "FULL TIME" under the clock and "opponent disconnected" are recognised by the app.
-- 3. Live score: visitors see the score and minute of matches being played.

-- ---------------------------------------------------------------- live score (public, read-only)
-- Each phone reports "me"/"opponent"; here they become side A/side B. When both phones are current the most recent
-- report is shown: it is only a live indication, the official result is decided as before.
create or replace function public.live_scores(p_tid uuid)
returns table (fixture_id uuid, score_a int, score_b int, minute int, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  with cur as (
    select f.id, f.player_a_id, s.user_id, s.score_me, s.score_opp, s.clock_seconds, s.updated_at
    from fixtures f
    join tournaments t on t.id = f.tournament_id and t.status = 'live'
    join match_latest_state s on s.fixture_id = f.id
    where f.tournament_id = p_tid and f.status = 'active' and s.layout = 'in_play'
      and s.updated_at > now() - interval '90 seconds' and s.score_me is not null and s.score_opp is not null
  ), pick as (
    select distinct on (id) id,
      case when user_id = player_a_id then score_me else score_opp end as a,
      case when user_id = player_a_id then score_opp else score_me end as b,
      clock_seconds, updated_at
    from cur order by id, updated_at desc
  )
  select id, a, b, case when clock_seconds is null then null else least(120, clock_seconds / 60 + 1) end, updated_at from pick
$$;

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

    -- Kick-off: both phones show the match running at 0-0 with the clock just started (00:01 to 02:00),
    -- both within the last 15 seconds. Without this, no result is ever accepted automatically.
    if f.kickoff_at is null then
      select * into sa from match_latest_state where fixture_id = f.id and user_id = f.player_a_id;
      select * into sb from match_latest_state where fixture_id = f.id and user_id = f.player_b_id;
      if sa.layout = 'in_play' and sb.layout = 'in_play'
         and sa.last_in_play_at > now() - interval '15 seconds' and sb.last_in_play_at > now() - interval '15 seconds'
         and sa.clock_seconds between 1 and 120 and sb.clock_seconds between 1 and 120
         and sa.score_me = 0 and sa.score_opp = 0 and sb.score_me = 0 and sb.score_opp = 0 then
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

  -- No kick-off seen by both phones: never decided automatically (an admin decides, see sweep_fixtures).
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

create or replace function public.sweep_fixtures() returns int
language plpgsql security definer set search_path = public as $$
declare
  f fixtures; g games; mr matchrooms; v_n int := 0; v_deadline timestamptz; v_stale boolean;
  v_host_blocked boolean;
begin
  for f in select fx.* from fixtures fx join tournaments tt on tt.id = fx.tournament_id
           where tt.status = 'live' and not tt.is_demo and fx.status in ('scheduled', 'active', 'stalled') and fx.scheduled_at is not null loop
    select gm.* into g from tournaments t join games gm on gm.id = t.game_id where t.id = f.tournament_id;
    select * into mr from matchrooms where fixture_id = f.id;
    v_deadline := f.scheduled_at + make_interval(secs => g.checkin_seconds);

    -- 1. decided fixtures: settle even if both apps were closed
    if f.kickoff_at is not null then
      if _finalize(f.id, null) ->> 'ok' = 'true' and (select status from fixtures where id = f.id) in ('completed', 'disputed') then
        v_n := v_n + 1;
        continue;
      end if;
    end if;

    -- 1b. played without a confirmed kick-off: the phones reported an end but kick-off (0-0 at 00:01 on both phones)
    --     was never seen. After 20 minutes an admin decides (it appears in "Needs attention").
    if f.kickoff_at is null and f.scheduled_at < now() - interval '20 minutes'
       and exists (select 1 from match_latest_state where fixture_id = f.id and terminal_kind is not null) then
      update fixtures set status = 'disputed' where id = f.id;
      perform _event(f.id, 'disputed', null, '{"reason":"no_kickoff_confirmed"}');
      v_n := v_n + 1;
      continue;
    end if;
    if f.kickoff_at is null and f.status = 'active' and f.scheduled_at < now() - interval '3 hours' then
      update fixtures set status = 'stalled' where id = f.id;
      perform _event(f.id, 'stalled', null, '{"reason":"no_result"}');
      v_n := v_n + 1;
      continue;
    end if;

    -- 2. check-in deadline
    if f.kickoff_at is null and now() > v_deadline then
      if g.room_code_model = 'host_issued' then
        if mr.room_code is null then
          select exists (select 1 from match_events where fixture_id = f.id and event_type = 'host_blocked') into v_host_blocked;
          if v_host_blocked then
            update fixtures set status = 'disputed' where id = f.id;
            perform _event(f.id, 'disputed', null, '{"reason":"host_blocked"}');
          elsif (case when f.host_player_id = f.player_a_id then mr.player_b_joined_at else mr.player_a_joined_at end) is null then
            update fixtures set status = 'cancelled' where id = f.id;
            perform _event(f.id, 'cancelled', null, '{"reason":"no_show_both"}');
          else
            perform _forfeit(f.id, f.host_player_id, 'forfeit', 'host_failed_to_create_room');
          end if;
          v_n := v_n + 1;
        elsif (case when f.host_player_id = f.player_a_id then mr.player_b_joined_at else mr.player_a_joined_at end) is null then
          perform _forfeit(f.id, case when f.host_player_id = f.player_a_id then f.player_b_id else f.player_a_id end,
                           'forfeit', 'opponent_never_joined');
          v_n := v_n + 1;
        end if;
      else
        if mr.player_a_joined_at is null and mr.player_b_joined_at is null then
          update fixtures set status = 'cancelled' where id = f.id;
          perform _event(f.id, 'cancelled', null, '{"reason":"no_show_both"}');
          v_n := v_n + 1;
        elsif mr.player_a_joined_at is null or mr.player_b_joined_at is null then
          perform _forfeit(f.id, case when mr.player_a_joined_at is null then f.player_a_id else f.player_b_id end,
                           'forfeit', 'did_not_check_in');
          v_n := v_n + 1;
        end if;
      end if;
      continue;
    end if;

    -- 3. stalls: never auto-forfeit mid-match, flag for an admin after 10 minutes of silence
    if f.status = 'active' and f.kickoff_at is not null then
      select coalesce(min(updated_at), '-infinity') < now() - interval '10 minutes'
             or (select count(*) from match_latest_state where fixture_id = f.id) < 2
        into v_stale from match_latest_state where fixture_id = f.id;
      if v_stale and f.kickoff_at < now() - interval '10 minutes' then
        update fixtures set status = 'stalled' where id = f.id;
        perform _event(f.id, 'stalled', null, '{}');
        v_n := v_n + 1;
      end if;
    end if;
  end loop;
  return v_n;
end $$;

update public.game_profiles set profile = profile || jsonb_build_object(
  'quit_keywords', '["OPPONENT QUIT", "FORFEITS THE MATCH", "DISCONNECTED", "OPPONENT LEFT", "LEFT THE MATCH"]'::jsonb,
  'full_time_keywords', '["FULL TIME", "FULL-TIME", "FULLTIME"]'::jsonb,
  'kickoff_max_clock', 120,
  'version', 3);

revoke execute on function public.live_scores(uuid) from public;
grant execute on function public.live_scores(uuid) to anon, authenticated;
revoke execute on function public._submit_screen_state(uuid, uuid, text, int, int, int, int, int, bigint, jsonb), public._evaluate_fixture(uuid) from public, anon, authenticated;
grant execute on all functions in schema public to service_role;
