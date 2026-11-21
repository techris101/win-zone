-- WIN ZONE — 0017 after-match screen data, unrecognised screens, quiet matches
-- 1. The app's "match ended" screen: result, opponent, tournament and the player's statistics from the match pass.
-- 2. Screens the app cannot recognise are logged with their text (to tune the rules) and never change a match.
-- 3. A match without a confirmed kick-off whose phones went quiet for 15 minutes goes to the admins.

create or replace function public.match_status_pass(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p match_passes; f fixtures; v_a boolean; t tournaments; v_opp uuid; me match_latest_state;
begin
  p := _pass(p_pass);
  if p.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_pass'); end if;
  select * into f from fixtures where id = p.fixture_id;
  select * into t from tournaments where id = f.tournament_id;
  select * into me from match_latest_state where fixture_id = f.id and user_id = p.user_id;
  v_a := (p.user_id = f.player_a_id);
  v_opp := case when v_a then f.player_b_id else f.player_a_id end;
  return jsonb_build_object('ok', true, 'status', f.status, 'kickoff', f.kickoff_at is not null,
    'outcome', f.outcome, 'winner_is_me', case when f.winner_id is null then null else f.winner_id = p.user_id end,
    'score_me', case when v_a then f.score_a else f.score_b end, 'score_opp', case when v_a then f.score_b else f.score_a end,
    'pen_me', case when v_a then f.pen_a else f.pen_b end, 'pen_opp', case when v_a then f.pen_b else f.pen_a end,
    -- for the app's "match ended" screen
    'my_result_sent', me.terminal_kind is not null,
    'opponent', (select coalesce(display_name, username) from profiles where id = v_opp),
    'tournament', t.name, 'slug', t.slug,
    'username', (select username from profiles where id = p.user_id),
    'stats', career_stats(p.user_id));
end $$;

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

  -- A screen the app could not recognise: kept in the log only (its text helps tune the screen rules),
  -- it never changes the match state.
  if p_layout = 'unknown' then
    insert into match_state_log (fixture_id, user_id, client_seq, layout, raw) values (f.id, v_uid, p_client_seq, 'unknown', p_raw);
    return jsonb_build_object('ok', true, 'logged', true);
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
    --     was never seen, or the phones went quiet for 15 minutes without kick-off. After 20 minutes an admin decides
    --     (it appears in "Needs attention").
    if f.kickoff_at is null and f.scheduled_at < now() - interval '20 minutes'
       and (exists (select 1 from match_latest_state where fixture_id = f.id and terminal_kind is not null)
            or (exists (select 1 from match_latest_state where fixture_id = f.id)
                and not exists (select 1 from match_latest_state where fixture_id = f.id and updated_at > now() - interval '15 minutes'))) then
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

revoke execute on function public._submit_screen_state(uuid, uuid, text, int, int, int, int, int, bigint, jsonb) from public, anon, authenticated;
revoke execute on function public.match_status_pass(text) from public;
grant execute on function public.match_status_pass(text) to anon, authenticated;
grant execute on all functions in schema public to service_role;
