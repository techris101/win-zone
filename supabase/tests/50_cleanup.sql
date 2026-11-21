-- WIN ZONE — tests for 0020: automatic cleanup keeps results, removes the bulky match data.
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(c, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
do $$
declare a uuid; b uuid; tid uuid; t2 uuid; did uuid; f uuid; f2 uuid; r jsonb;
begin
  insert into auth.users (email, raw_user_meta_data) values ('cl_a@x.local', '{"username":"cl_a","country":"RW"}') returning id into a;
  insert into auth.users (email, raw_user_meta_data) values ('cl_b@x.local', '{"username":"cl_b","country":"RW"}') returning id into b;
  insert into tournaments (slug, name, game_id, format, size, status) values ('old-cup', 'Old Cup', (select id from games limit 1), 'knockout', 2, 'live') returning id into tid;
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, score_a, score_b, winner_id, outcome, completed_at)
  values (tid, 'knockout', 1, 1, a, b, 'completed', 2, 1, a, 'win_by_score', now()) returning id into f;
  insert into match_state_log (fixture_id, user_id, client_seq, layout) select f, a, g, 'in_play' from generate_series(1, 50) g;
  insert into match_latest_state (fixture_id, user_id, layout, client_seq) values (f, a, 'result', 50);
  insert into match_events (fixture_id, event_type) values (f, 'kickoff');
  insert into dispute_evidence (fixture_id, user_id, path) values (f, a, f || '/' || a || '/x.png');
  insert into notifications (user_id, tournament_id, kind, title, body, dedupe_key) values (a, tid, 'result_win', 'Won', 'Won', 'cl1');
  update tournaments set status = 'completed', champion_id = a where id = tid;
  perform pg_temp.ok((select finished_at is not null from tournaments where id = tid), 'the end time is recorded');

  r := _cleanup();
  perform pg_temp.ok(exists (select 1 from match_state_log where fixture_id = f), 'nothing is removed during the 7 days for late disputes');

  update tournaments set finished_at = now() - interval '8 days' where id = tid;
  r := _cleanup();
  perform pg_temp.ok((r ->> 'tournaments')::int = 1 and (r ->> 'files')::int = 1, 'one tournament cleaned, its screenshot sent for deletion');
  perform pg_temp.ok(not exists (select 1 from match_state_log where fixture_id = f) and not exists (select 1 from match_latest_state where fixture_id = f)
                     and not exists (select 1 from match_events where fixture_id = f) and not exists (select 1 from dispute_evidence where fixture_id = f)
                     and not exists (select 1 from notifications where tournament_id = tid), 'the bulky match data is gone');
  perform pg_temp.ok((select score_a = 2 and score_b = 1 and winner_id = a from fixtures where id = f)
                     and (select champion_id = a from tournaments where id = tid), 'the result and the champion stay');
  perform pg_temp.ok(exists (select 1 from rankings(500, null) x where x.user_id = a and x.titles = 1 and x.won = 1), 'rankings still count the title and the win');
  r := _cleanup();
  perform pg_temp.ok((r ->> 'tournaments')::int = 0, 'a cleaned tournament is not cleaned twice');

  -- demo: removed completely a day after it ends
  insert into tournaments (slug, name, game_id, format, size, status, is_demo) values ('old-demo', 'Old Demo', (select id from games limit 1), 'knockout', 2, 'live', true) returning id into did;
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status) values (did, 'knockout', 1, 1, a, b, 'completed') returning id into f2;
  insert into match_state_log (fixture_id, user_id, client_seq, layout) values (f2, a, 1, 'in_play');
  update tournaments set status = 'completed' where id = did;
  update tournaments set finished_at = now() - interval '2 days' where id = did;
  r := _cleanup();
  perform pg_temp.ok(not exists (select 1 from tournaments where id = did) and not exists (select 1 from match_state_log where fixture_id = f2), 'an old demo is removed completely');

  -- reopening a finished tournament clears its end time
  insert into tournaments (slug, name, game_id, format, size, status) values ('re-cup', 'Re Cup', (select id from games limit 1), 'league', 2, 'completed') returning id into t2;
  update tournaments set status = 'live' where id = t2;
  perform pg_temp.ok((select finished_at is null from tournaments where id = t2), 'a reopened tournament is not cleaned');
end $$;
select 'cleanup tests: all assertions passed' as result;
