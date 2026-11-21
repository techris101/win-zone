-- WIN ZONE — tests for 0015: results without a seen kick-off, stuck matches, the 5-minute reminder.
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(c, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.mk(p_name text) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into auth.users (email, raw_user_meta_data) values (p_name || '@fix.local', jsonb_build_object('username', p_name, 'country', 'RW')) returning id into v;
  return v;
end $$;
create or replace function pg_temp.term(p_f uuid, p_u uuid, p_kind text, p_me int, p_opp int, p_clock int) returns void language sql as $$
  insert into match_latest_state (fixture_id, user_id, layout, score_me, score_opp, clock_seconds, client_seq, terminal_kind, terminal_at, t_score_me, t_score_opp, t_clock)
  values (p_f, p_u, p_kind, p_me, p_opp, p_clock, 5, p_kind, now() - interval '1 minute', p_me, p_opp, p_clock)
  on conflict (fixture_id, user_id) do update set layout = excluded.layout, terminal_kind = excluded.terminal_kind, terminal_at = excluded.terminal_at,
    t_score_me = excluded.t_score_me, t_score_opp = excluded.t_score_opp, t_clock = excluded.t_clock
$$;

do $$
declare a uuid; b uuid; c uuid; d uuid; tid uuid; f1 uuid; f2 uuid; f3 uuid; r jsonb;
begin
  a := pg_temp.mk('fix_a'); b := pg_temp.mk('fix_b'); c := pg_temp.mk('fix_c'); d := pg_temp.mk('fix_d');
  insert into tournaments (slug, name, game_id, format, size, status) values ('fix-cup', 'Fix Cup', (select id from games limit 1), 'league', 4, 'live') returning id into tid;
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, scheduled_at)
  values (tid, 'league', 1, 1, a, b, 'active', now() - interval '10 minutes') returning id into f1;
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, scheduled_at)
  values (tid, 'league', 1, 2, c, d, 'active', now() - interval '30 minutes') returning id into f2;
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, scheduled_at)
  values (tid, 'league', 2, 1, a, c, 'scheduled', now() + interval '5 minutes') returning id into f3;

  -- kick-off missed, both phones reported 2-1 for A: accepted
  perform pg_temp.term(f1, a, 'result', 2, 1, 5400);
  r := _finalize(f1, null);
  perform pg_temp.ok((select status from fixtures where id = f1) <> 'completed', 'one phone without kick-off is not enough');
  perform pg_temp.term(f1, b, 'result', 1, 2, 5400);
  r := _finalize(f1, null);
  perform pg_temp.ok((select status from fixtures where id = f1) not in ('completed'),
                     'strict kick-off: even two agreeing phones are not enough without a confirmed kick-off');

  -- kick-off missed, only one phone reported, 30 minutes on: goes to the admins
  perform pg_temp.term(f2, c, 'result', 0, 3, 843);
  perform sweep_fixtures();
  perform pg_temp.ok((select status from fixtures where id = f2) = 'disputed', 'a match played without a confirmed kick-off goes to the admins');
  perform pg_temp.ok(exists (select 1 from match_events where fixture_id = f2 and details ->> 'reason' = 'no_kickoff_confirmed'), 'with a clear reason');

  -- the 5-minute reminder
  perform _notify_reminders();
  perform pg_temp.ok(exists (select 1 from notifications where user_id = a and fixture_id = f3 and kind = 'soon' and title = 'Kick-off in 5 minutes'), 'players get the 5-minute reminder');
  perform _notify_reminders();
  perform pg_temp.ok((select count(*) from notifications where user_id = a and fixture_id = f3 and kind = 'soon') = 1, 'only once');
  update profiles set lang = 'rw' where id = c;
  delete from notifications where user_id = c and fixture_id = f3;
  perform _notify_reminders();
  perform pg_temp.ok((select title from notifications where user_id = c and fixture_id = f3 and kind = 'soon') = 'Umukino utangira mu minota 5', 'in the player''s language');
  perform pg_temp.ok((select profile ->> 'inplay_clock_anywhere' from game_profiles limit 1) = 'true', 'screen rules updated for the app');
end $$;

select 'match fix tests: all assertions passed' as result;
