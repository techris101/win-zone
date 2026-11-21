-- WIN ZONE — tests for 0016: live score for visitors.
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(c, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
do $$
declare a uuid; b uuid; tid uuid; f uuid; r record; blocked boolean := false;
begin
  insert into auth.users (email, raw_user_meta_data) values ('live_a@x.local', '{"username":"live_a","country":"RW"}') returning id into a;
  insert into auth.users (email, raw_user_meta_data) values ('live_b@x.local', '{"username":"live_b","country":"RW"}') returning id into b;
  insert into tournaments (slug, name, game_id, format, size, status) values ('live-cup', 'Live Cup', (select id from games limit 1), 'knockout', 2, 'live') returning id into tid;
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, scheduled_at, kickoff_at)
  values (tid, 'knockout', 1, 1, a, b, 'active', now() - interval '20 minutes', now() - interval '15 minutes') returning id into f;
  insert into match_latest_state (fixture_id, user_id, layout, score_me, score_opp, clock_seconds, client_seq, updated_at)
  values (f, a, 'in_play', 1, 0, 600, 9, now() - interval '5 seconds'), (f, b, 'in_play', 0, 1, 610, 9, now());
  select * into r from live_scores(tid);
  perform pg_temp.ok(r.fixture_id = f and r.score_a = 1 and r.score_b = 0 and r.minute = 11, 'live score shown as A 1-0 B in minute 11 (from the newest phone, turned to sides)');
  set local role anon;
  begin perform 1 from live_scores(tid); exception when insufficient_privilege then blocked := true; end;
  reset role;
  perform pg_temp.ok(not blocked, 'visitors can read the live score');
  update match_latest_state set updated_at = now() - interval '5 minutes' where fixture_id = f;
  perform pg_temp.ok(not exists (select 1 from live_scores(tid)), 'old readings are not shown as live');
end $$;
do $$
declare a uuid; b uuid; tid uuid; f uuid; pass text; r jsonb;
begin
  select id into a from profiles where username = 'live_a'; select id into b from profiles where username = 'live_b';
  insert into tournaments (slug, name, game_id, format, size, status) values ('quiet-cup', 'Quiet Cup', (select id from games limit 1), 'league', 2, 'live') returning id into tid;
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, scheduled_at)
  values (tid, 'league', 1, 1, a, b, 'active', now() - interval '40 minutes') returning id into f;
  -- unrecognised screens are only logged
  pass := 'p' || md5(random()::text);
  insert into match_passes (token_hash, user_id, fixture_id, expires_at) values (_hash(pass), a, f, now() + interval '1 hour');
  r := submit_screen_state_pass(pass, 'unknown', null, null, null, null, null, 1, '{"lines":["SOMETHING"]}');
  perform pg_temp.ok((r ->> 'logged')::boolean and not exists (select 1 from match_latest_state where fixture_id = f), 'unknown screens are logged, the match state is untouched');
  perform pg_temp.ok(exists (select 1 from match_state_log where fixture_id = f and layout = 'unknown' and raw ->> 'lines' like '%SOMETHING%'), 'with their text');
  -- quiet for 15 minutes without kick-off: to the admins
  insert into match_latest_state (fixture_id, user_id, layout, client_seq, updated_at) values (f, a, 'in_play', 2, now() - interval '20 minutes');
  perform sweep_fixtures();
  perform pg_temp.ok((select status from fixtures where id = f) = 'disputed', 'a quiet match without kick-off goes to the admins');
  -- the after-match screen
  r := match_status_pass(pass);
  perform pg_temp.ok(r ->> 'opponent' = 'live_b' and r ->> 'tournament' = 'Quiet Cup' and r ? 'stats' and r ->> 'username' = 'live_a', 'the app gets the result screen data and the player''s statistics');
end $$;

select 'live score tests: all assertions passed' as result;
