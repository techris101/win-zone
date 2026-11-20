-- WIN ZONE — 0003 match logic
-- Room codes, screen-state ingestion, the end-of-match decision, sweeps, admin overrides.
-- The server decides. Clients only report what the game screen shows.

-- ---------------------------------------------------------------- event helper
create or replace function public._event(p_fixture uuid, p_type text, p_actor uuid, p_details jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into match_events (fixture_id, event_type, actor, details) values (p_fixture, p_type, p_actor, p_details)
$$;

-- ---------------------------------------------------------------- clock classification
-- 'regulation' = full time at the regulation clock, 'extra' = knockout extra time end,
-- 'early' = result screen before full time (a forfeit), 'anomaly' = impossible clock.
create or replace function public._clock_class(p_stage text, p_clock int, p_reg int, p_ext int)
returns text language sql immutable as $$
  select case
    when p_clock is null then 'anomaly'
    when p_clock < p_reg - 5 then 'early'
    when p_clock <= p_reg + 5 then 'regulation'
    when p_stage = 'league' then 'anomaly'
    when p_clock < p_ext - 5 then 'early'
    else 'extra'
  end
$$;

-- ---------------------------------------------------------------- the decision
-- status: wait | win | draw | dispute
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
    if f.stage = 'league' then
      return jsonb_build_object('status', 'draw', 'outcome', 'draw',
        'score_a', v_a_me, 'score_b', v_a_opp, 'pen_a', v_pa, 'pen_b', v_pb);
    end if;
    return jsonb_build_object('status', 'dispute', 'reason', 'knockout_level_no_winner');
  end if;
  -- A knockout cannot end level at regulation; a draw here means the screen was misread.
  if f.stage = 'knockout' and ca = 'regulation' and v_a_me = v_a_opp then
    return jsonb_build_object('status', 'dispute', 'reason', 'knockout_level_at_regulation');
  end if;

  return jsonb_build_object('status', 'win', 'outcome', 'win_by_score', 'winner_id', v_winner,
    'score_a', v_a_me, 'score_b', v_a_opp, 'pen_a', v_pa, 'pen_b', v_pb);
end $$;

-- ---------------------------------------------------------------- finalize (internal + public)
create or replace function public._finalize(p_fixture_id uuid, p_actor uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f fixtures; ev jsonb;
begin
  select * into f from fixtures where id = p_fixture_id for update;
  if f.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if f.status in ('completed', 'disputed', 'cancelled', 'bye') then
    return jsonb_build_object('ok', true, 'already_finalized', true, 'status', f.status, 'winner_id', f.winner_id);
  end if;

  ev := _evaluate_fixture(p_fixture_id);
  if ev ->> 'status' = 'wait' then
    return jsonb_build_object('ok', false, 'reason', 'not_ready', 'detail', ev ->> 'reason');
  end if;

  if ev ->> 'status' = 'dispute' then
    update fixtures set status = 'disputed' where id = f.id;
    perform _event(f.id, 'disputed', p_actor, jsonb_build_object('reason', ev ->> 'reason'));
    return jsonb_build_object('ok', true, 'status', 'disputed', 'reason', ev ->> 'reason');
  end if;

  update fixtures
  set status = 'completed',
      winner_id = nullif(ev ->> 'winner_id', '')::uuid,
      outcome = ev ->> 'outcome',
      score_a = (ev ->> 'score_a')::int, score_b = (ev ->> 'score_b')::int,
      pen_a = (ev ->> 'pen_a')::int,     pen_b = (ev ->> 'pen_b')::int,
      completed_at = now()
  where id = f.id;
  perform _event(f.id, 'finalized', p_actor, ev - 'status');
  perform _after_final(f.id);
  return jsonb_build_object('ok', true, 'status', 'completed',
    'winner_id', nullif(ev ->> 'winner_id', '')::uuid, 'outcome', ev ->> 'outcome');
end $$;

create or replace function public.finalize_fixture(p_fixture_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f fixtures;
begin
  select * into f from fixtures where id = p_fixture_id;
  if f.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if auth.uid() is null or auth.uid() not in (f.player_a_id, f.player_b_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_a_participant');
  end if;
  return _finalize(p_fixture_id, auth.uid());
end $$;

-- ---------------------------------------------------------------- submit_screen_state
create or replace function public.submit_screen_state(
  p_fixture_id uuid, p_layout text,
  p_score_me int, p_score_opp int, p_pen_me int, p_pen_opp int,
  p_clock_seconds int, p_client_seq bigint, p_raw jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); f fixtures; cur match_latest_state; ev jsonb; v_kick boolean;
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
         and coalesce(sa.clock_seconds, 99999) <= 300 and coalesce(sb.clock_seconds, 99999) <= 300 then
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

-- ---------------------------------------------------------------- matchroom access
create or replace function public.app_join_fixture(p_fixture_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); f fixtures; g games; mr matchrooms; v_reveal timestamptz; v_side text;
  v_opp uuid; v_opp_name text; v_is_host boolean; v_deadline timestamptz;
begin
  select * into f from fixtures where id = p_fixture_id;
  if f.id is null or v_uid is null or v_uid not in (f.player_a_id, f.player_b_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_a_participant');
  end if;
  if f.status in ('completed', 'cancelled', 'disputed', 'bye') then
    return jsonb_build_object('ok', false, 'reason', 'fixture_closed', 'status', f.status);
  end if;
  if f.scheduled_at is null then
    return jsonb_build_object('ok', false, 'reason', 'not_scheduled');
  end if;

  select gm.* into g from tournaments t join games gm on gm.id = t.game_id where t.id = f.tournament_id;
  v_reveal := f.scheduled_at - make_interval(secs => g.reveal_buffer_seconds);
  v_deadline := f.scheduled_at + make_interval(secs => g.checkin_seconds);
  if now() < v_reveal then
    return jsonb_build_object('ok', false, 'reason', 'too_early', 'reveal_at', v_reveal, 'scheduled_at', f.scheduled_at);
  end if;

  v_side := case when v_uid = f.player_a_id then 'A' else 'B' end;
  v_is_host := (v_uid = f.host_player_id);
  v_opp := case when v_side = 'A' then f.player_b_id else f.player_a_id end;
  select coalesce(display_name, username) into v_opp_name from profiles where id = v_opp;

  select * into mr from matchrooms where fixture_id = f.id for update;
  if mr.id is null then
    perform _ensure_matchroom(f.id);
    select * into mr from matchrooms where fixture_id = f.id for update;
  end if;

  -- Opening the matchroom is the check-in.
  update matchrooms
  set player_a_joined_at = case when v_side = 'A' then coalesce(player_a_joined_at, now()) else player_a_joined_at end,
      player_b_joined_at = case when v_side = 'B' then coalesce(player_b_joined_at, now()) else player_b_joined_at end
  where id = mr.id
  returning * into mr;

  if g.room_code_model = 'platform_issued' and mr.player_a_joined_at is not null
     and mr.player_b_joined_at is not null and f.status = 'scheduled' then
    update fixtures set status = 'active' where id = f.id returning * into f;
  end if;

  if mr.room_code is null then
    return jsonb_build_object('ok', false, 'reason', 'waiting_for_host_code', 'is_host', v_is_host,
      'my_side', v_side, 'opponent', v_opp_name, 'scheduled_at', f.scheduled_at, 'checkin_deadline', v_deadline);
  end if;

  return jsonb_build_object('ok', true, 'fixture_id', f.id, 'matchroom_id', mr.id, 'room_code', mr.room_code,
    'my_side', v_side, 'is_host', v_is_host, 'opponent_id', v_opp, 'opponent', v_opp_name,
    'scheduled_at', f.scheduled_at, 'checkin_deadline', v_deadline, 'status', f.status,
    'stage', f.stage, 'game', g.name);
end $$;

create or replace function public.submit_room_code(p_fixture_id uuid, p_room_code text, p_capture_method text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare f fixtures; g games; mr matchrooms; v_uid uuid := auth.uid();
begin
  if p_capture_method not in ('ocr', 'manual') then return jsonb_build_object('ok', false, 'reason', 'bad_method'); end if;
  select * into f from fixtures where id = p_fixture_id;
  if f.id is null or f.host_player_id is distinct from v_uid then
    return jsonb_build_object('ok', false, 'reason', 'not_host');
  end if;
  if f.status not in ('scheduled', 'active') or f.scheduled_at is null then
    return jsonb_build_object('ok', false, 'reason', 'fixture_closed');
  end if;
  select gm.* into g from tournaments t join games gm on gm.id = t.game_id where t.id = f.tournament_id;
  if g.room_code_model <> 'host_issued' then return jsonb_build_object('ok', false, 'reason', 'not_host_issued'); end if;
  if now() < f.scheduled_at - make_interval(secs => g.reveal_buffer_seconds)
     or now() > f.scheduled_at + make_interval(secs => g.checkin_seconds) then
    return jsonb_build_object('ok', false, 'reason', 'outside_submission_window');
  end if;
  if p_room_code !~ g.room_code_pattern then return jsonb_build_object('ok', false, 'reason', 'invalid_format'); end if;

  perform _ensure_matchroom(f.id);
  update matchrooms
  set room_code = upper(p_room_code), room_code_source = 'host', room_code_submitted_at = now(),
      room_code_capture_method = p_capture_method
  where fixture_id = f.id and (room_code is null or room_code = upper(p_room_code))
  returning * into mr;
  if mr.id is null then return jsonb_build_object('ok', false, 'reason', 'already_set_differently'); end if;

  update fixtures set status = 'active' where id = f.id and status = 'scheduled';
  perform _event(f.id, 'room_code_set', v_uid, jsonb_build_object('method', p_capture_method));  -- never the code itself
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.report_host_blocked(p_fixture_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f fixtures;
begin
  select * into f from fixtures where id = p_fixture_id;
  if f.id is null or f.host_player_id is distinct from auth.uid() then
    return jsonb_build_object('ok', false, 'reason', 'not_host');
  end if;
  perform _event(f.id, 'host_blocked', auth.uid(), jsonb_build_object('client_reason', left(coalesce(p_reason, ''), 200)));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.open_dispute(p_fixture_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f fixtures;
begin
  select * into f from fixtures where id = p_fixture_id;
  if f.id is null or auth.uid() is null or auth.uid() not in (f.player_a_id, f.player_b_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_a_participant');
  end if;
  insert into disputes (fixture_id, user_id, note) values (f.id, auth.uid(), left(coalesce(p_note, ''), 1000))
  on conflict (fixture_id, user_id) do update set note = excluded.note, status = 'open';
  perform _event(f.id, 'dispute_opened', auth.uid());
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- forfeits and sweep
create or replace function public._forfeit(p_fixture_id uuid, p_loser uuid, p_event text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare f fixtures; v_winner uuid;
begin
  select * into f from fixtures where id = p_fixture_id for update;
  if f.status in ('completed', 'cancelled', 'disputed', 'bye') then return; end if;
  v_winner := case when p_loser = f.player_a_id then f.player_b_id else f.player_a_id end;
  update fixtures set status = 'completed', winner_id = v_winner, outcome = 'win_by_noshow', completed_at = now()
  where id = f.id;
  perform _event(f.id, p_event, p_loser, jsonb_build_object('reason', p_reason));
  perform _after_final(f.id);
end $$;

-- Runs every minute (pg_cron). Finalizes decided fixtures, applies check-in rules, flags stalls.
create or replace function public.sweep_fixtures() returns int
language plpgsql security definer set search_path = public as $$
declare
  f fixtures; g games; mr matchrooms; v_n int := 0; v_deadline timestamptz; v_stale boolean;
  v_host_blocked boolean;
begin
  for f in select * from fixtures where status in ('scheduled', 'active', 'stalled') and scheduled_at is not null loop
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

-- ---------------------------------------------------------------- admin overrides (audited)
-- The only way to change a live result.
create or replace function public.resolve_fixture(p_fixture_id uuid, p_outcome text, p_notes text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f fixtures; v_winner uuid; nxt fixtures;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  select * into f from fixtures where id = p_fixture_id for update;
  if f.id is null then raise exception 'not_found'; end if;
  if p_outcome not in ('win_player_a', 'win_player_b', 'forfeit_player_a', 'forfeit_player_b', 'replay', 'cancel') then
    raise exception 'bad outcome';
  end if;

  -- Reversing a finished fixture is only allowed while nothing downstream has started.
  if f.status = 'completed' then
    if f.stage = 'league' and exists (select 1 from fixtures where tournament_id = f.tournament_id and stage = 'knockout') then
      raise exception 'knockout already generated';
    end if;
    if f.next_fixture_id is not null then
      select * into nxt from fixtures where id = f.next_fixture_id;
      if nxt.status <> 'scheduled' or nxt.kickoff_at is not null then raise exception 'downstream_started'; end if;
      update fixtures
      set player_a_id = case when f.next_side = 'A' then null else player_a_id end,
          player_b_id = case when f.next_side = 'B' then null else player_b_id end,
          host_player_id = null, scheduled_at = null
      where id = nxt.id;
      delete from matchrooms where fixture_id = nxt.id;
    end if;
    update tournaments set status = 'live', champion_id = null where id = f.tournament_id and status = 'completed';
  end if;

  if p_outcome = 'cancel' then
    update fixtures set status = 'cancelled' where id = f.id;
  elsif p_outcome = 'replay' then
    delete from match_latest_state where fixture_id = f.id;
    update fixtures set status = 'scheduled', kickoff_at = null, winner_id = null, outcome = null,
           score_a = null, score_b = null, pen_a = null, pen_b = null, completed_at = null,
           replay_count = replay_count + 1, scheduled_at = now() + interval '15 minutes'
    where id = f.id;
    delete from matchrooms where fixture_id = f.id;
    perform _ensure_matchroom(f.id);
  else
    v_winner := case p_outcome
      when 'win_player_a' then f.player_a_id when 'forfeit_player_b' then f.player_a_id
      else f.player_b_id end;
    update fixtures set status = 'completed', winner_id = v_winner, outcome = 'admin_' || p_outcome,
           completed_at = now() where id = f.id;
    perform _after_final(f.id);
  end if;

  update disputes set status = 'resolved' where fixture_id = f.id;
  perform _event(f.id, 'admin_resolved', auth.uid(), jsonb_build_object('outcome', p_outcome, 'notes', p_notes));
  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'resolve_fixture', 'fixture', f.id, jsonb_build_object('outcome', p_outcome, 'notes', p_notes));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.regenerate_room_code(p_fixture_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_model text;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  select g.room_code_model into v_model from fixtures f join tournaments t on t.id = f.tournament_id
    join games g on g.id = t.game_id where f.id = p_fixture_id;
  if v_model <> 'platform_issued' then raise exception 'host-issued codes come from the host'; end if;
  update matchrooms set room_code = _gen_room_code(), room_code_source = 'platform', room_code_submitted_at = now()
  where fixture_id = p_fixture_id;
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'regenerate_room_code', 'fixture', p_fixture_id);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.submit_room_code_as_admin(p_fixture_id uuid, p_code text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  perform _ensure_matchroom(p_fixture_id);
  update matchrooms set room_code = upper(p_code), room_code_source = 'admin', room_code_capture_method = 'admin',
         room_code_submitted_at = now() where fixture_id = p_fixture_id;
  update fixtures set status = 'active' where id = p_fixture_id and status = 'scheduled';
  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'submit_room_code_as_admin', 'fixture', p_fixture_id, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true);
end $$;
