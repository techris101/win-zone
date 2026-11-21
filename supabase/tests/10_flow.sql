-- WIN ZONE database tests. Run with run_local.sh (or the db-test GitHub workflow).
-- Any failed assertion aborts the run.

create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(c, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

create or replace function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claim.sub', coalesce(u::text, ''), false) $$;

create or replace function pg_temp.mkuser(p_name text, p_country text default 'RW') returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into auth.users (email, raw_user_meta_data)
  values (p_name || '@test.local', jsonb_strip_nulls(jsonb_build_object('username', p_name, 'country', p_country)))
  returning id into v;
  return v;
end $$;

-- Directly writes latched terminal states (what two phones would have reported), as the server would hold them.
create or replace function pg_temp.terminal(p_fixture uuid, p_user uuid, p_kind text, p_me int, p_opp int,
                                            p_pme int, p_popp int, p_clock int, p_age_seconds int default 60)
returns void language sql as $$
  insert into match_latest_state (fixture_id, user_id, layout, score_me, score_opp, pen_me, pen_opp, clock_seconds,
      client_seq, terminal_kind, terminal_at, t_score_me, t_score_opp, t_pen_me, t_pen_opp, t_clock)
  values (p_fixture, p_user, p_kind, p_me, p_opp, p_pme, p_popp, p_clock, 99, p_kind,
      now() - make_interval(secs => p_age_seconds), p_me, p_opp, p_pme, p_popp, p_clock)
  on conflict (fixture_id, user_id) do update set layout = excluded.layout, terminal_kind = excluded.terminal_kind,
      terminal_at = excluded.terminal_at, t_score_me = excluded.t_score_me, t_score_opp = excluded.t_score_opp,
      t_pen_me = excluded.t_pen_me, t_pen_opp = excluded.t_pen_opp, t_clock = excluded.t_clock
$$;

-- ============================================================ people
create temp table tu (name text primary key, id uuid);
grant all on tu to public;
do $$
declare n text;
begin
  foreach n in array array['admin1', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'minor', 'nocountry', 'admin2'] loop
    insert into tu values (n, pg_temp.mkuser(n, case when n = 'nocountry' then null else 'RW' end));
  end loop;
  perform grant_role('admin1@test.local', 'admin');
  perform pg_temp.ok((select count(*) from profiles) = 10, 'profiles created by trigger');
  perform pg_temp.ok((select country from profiles where id = (select id from tu where name = 'p1')) = 'RW' and (select country from profiles where id = (select id from tu where name = 'nocountry')) is null, 'country saved from sign-up');
end $$;

create or replace function pg_temp.u(p_name text) returns uuid language sql as $$ select id from tu where name = p_name $$;

-- ============================================================ access rules
do $$
declare v_blocked boolean := false;
begin
  -- room codes are unreachable directly
  set local role authenticated;
  begin
    perform 1 from matchrooms limit 1;
  exception when insufficient_privilege then v_blocked := true;
  end;
  reset role;
  perform pg_temp.ok(v_blocked, 'authenticated cannot read matchrooms');

  v_blocked := false;
  set local role anon;
  begin
    perform public._finalize(gen_random_uuid(), null);
  exception when insufficient_privilege then v_blocked := true;
  end;
  reset role;
  perform pg_temp.ok(v_blocked, 'internal functions are not callable by API roles');

  v_blocked := false;
  set local role authenticated;
  begin
    insert into fixtures (tournament_id, stage, round, slot) values (gen_random_uuid(), 'league', 1, 1);
  exception when insufficient_privilege then v_blocked := true;
  end;
  reset role;
  perform pg_temp.ok(v_blocked, 'clients cannot write fixtures');
end $$;

-- ============================================================ knockout, 4 players, host-issued room codes
create temp table ctx (k text primary key, v text);
grant all on ctx to public;

do $$
declare t uuid; r jsonb; v_fix record; host uuid; guest uuid; code text;
begin
  update games set room_code_model = 'host_issued' where slug = 'football-1v1';   -- both models stay supported
  perform pg_temp.as_user(pg_temp.u('p1'));
  begin
    perform create_tournament('x', 'x-cup', 'football-1v1', 'knockout', 8);
    raise exception 'ASSERT FAILED: non-organizer created tournament';
  exception when others then
    if sqlerrm not like '%not_allowed%' then raise; end if;
  end;

  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup A', 'cup-a', 'football-1v1', 'knockout', 8);
  insert into ctx values ('cup', t::text);
  perform set_tournament_status(t, 'open');


  foreach host in array array[pg_temp.u('p1'), pg_temp.u('p2'), pg_temp.u('p3'), pg_temp.u('p4')] loop
    perform pg_temp.as_user(host);
    r := register_for_tournament(t);
    perform pg_temp.ok((r ->> 'ok')::boolean, 'register ok');
  end loop;
  r := register_for_tournament(t);
  perform pg_temp.ok((r ->> 'already')::boolean, 'registration is idempotent');

  perform pg_temp.as_user(pg_temp.u('admin1'));
  r := generate_tournament(t);
  perform pg_temp.ok((r ->> 'players')::int = 4 and (select status from tournaments where id = t) = 'planning', 'fixtures are prepared as a draft');
  perform publish_tournament(t);
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t) = 3, '4-player bracket has 3 fixtures');
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and round = 1 and player_a_id is not null and player_b_id is not null) = 2, 'round 1 populated');
  perform pg_temp.ok((select count(*) from matchrooms) = 2, 'matchrooms created for playable fixtures');
  perform pg_temp.ok((select count(*) from matchrooms where room_code is not null) = 0, 'host-issued: no code yet');

  perform pg_temp.ok(schedule_fixtures(t, 'knockout', 1, now() + interval '30 seconds', 30) = 2, 'round 1 scheduled');

  -- Fixture 1: host flow
  select * into v_fix from fixtures where tournament_id = t and round = 1 and slot = 1;
  insert into ctx values ('f1', v_fix.id::text);
  host := v_fix.host_player_id;
  guest := case when host = v_fix.player_a_id then v_fix.player_b_id else v_fix.player_a_id end;

  perform pg_temp.as_user(pg_temp.u('p5'));
  r := app_join_fixture(v_fix.id);
  perform pg_temp.ok(r ->> 'reason' = 'not_a_participant', 'outsider cannot join');

  perform pg_temp.as_user(guest);
  r := app_join_fixture(v_fix.id);
  perform pg_temp.ok(r ->> 'reason' = 'waiting_for_host_code', 'guest waits for host code');
  perform pg_temp.ok(not r::text like '%room_code%', 'no code leaked while waiting');
  r := submit_room_code(v_fix.id, 'ABCD23', 'manual');
  perform pg_temp.ok(r ->> 'reason' = 'not_host', 'guest cannot submit a code');

  perform pg_temp.as_user(host);
  r := submit_room_code(v_fix.id, '!!', 'manual');
  perform pg_temp.ok(r ->> 'reason' = 'invalid_format', 'bad code format rejected');
  r := submit_room_code(v_fix.id, 'abcd23', 'ocr');
  perform pg_temp.ok((r ->> 'ok')::boolean, 'host submits code');
  r := submit_room_code(v_fix.id, 'ZZZZ99', 'ocr');
  perform pg_temp.ok(r ->> 'reason' = 'already_set_differently', 'code is immutable once set');

  perform pg_temp.as_user(guest);
  r := app_join_fixture(v_fix.id);
  code := r ->> 'room_code';
  perform pg_temp.ok(code = 'ABCD23', 'guest receives the host''s code');
  perform pg_temp.as_user(host);
  perform pg_temp.ok(app_join_fixture(v_fix.id) ->> 'room_code' = code, 'both players read the same code');
  perform pg_temp.ok((select count(*) from match_events where details::text like '%ABCD23%') = 0, 'code never written to events');
end $$;

-- ============================================================ live states -> kickoff -> finalize (normal result)
do $$
declare f uuid := (select v::uuid from ctx where k = 'f1'); fx fixtures; a uuid; b uuid; r jsonb;
begin
  select * into fx from fixtures where id = f; a := fx.player_a_id; b := fx.player_b_id;

  perform pg_temp.as_user(a);
  r := submit_screen_state(f, 'in_play', 0, 0, null, null, 5, 1);
  perform pg_temp.ok(not (r ->> 'kickoff_ready')::boolean, 'no kickoff after one phone');
  perform pg_temp.as_user(b);
  r := submit_screen_state(f, 'in_play', 0, 0, null, null, 6, 1);
  perform pg_temp.ok(not (r ->> 'kickoff_ready')::boolean, 'no kickoff before 5 s of play');

  update match_latest_state set in_play_since = now() - interval '8 seconds' where fixture_id = f;
  r := submit_screen_state(f, 'in_play', 0, 0, null, null, 12, 2);
  perform pg_temp.ok((r ->> 'kickoff_ready')::boolean, 'kickoff after 5 s on both phones');
  perform pg_temp.as_user(a);
  r := submit_screen_state(f, 'in_play', 0, 0, null, null, 14, 2);
  perform pg_temp.ok((r ->> 'kickoff_ready')::boolean, 'kickoff stays set');

  -- stale sequence numbers are ignored
  r := submit_screen_state(f, 'menu', null, null, null, null, null, 1);
  perform pg_temp.ok((select layout from match_latest_state where fixture_id = f and user_id = a) = 'in_play', 'stale seq ignored');

  -- finalize before anyone reports a result
  r := finalize_fixture(f);
  perform pg_temp.ok(r ->> 'reason' = 'not_ready', 'cannot finalize without a result');

  -- A reports a result (2-1 to A), then taps Continue: the report must survive
  r := submit_screen_state(f, 'result', 2, 1, null, null, 5400, 3);
  r := submit_screen_state(f, 'menu', null, null, null, null, null, 4);
  perform pg_temp.ok((select terminal_kind from match_latest_state where fixture_id = f and user_id = a) = 'result', 'terminal report is latched');
  r := finalize_fixture(f);
  perform pg_temp.ok(r ->> 'detail' = 'waiting_for_other_phone', 'waits for the second phone');

  perform pg_temp.as_user(b);
  r := submit_screen_state(f, 'result', 1, 2, null, null, 5401, 3);   -- mirrored view
  perform pg_temp.ok((r ->> 'finalize_ready')::boolean, 'finalize ready after both phones agree');
  r := finalize_fixture(f);
  perform pg_temp.ok(r ->> 'status' = 'completed' and (r ->> 'winner_id')::uuid = a, 'A wins 2-1 (mirrored perspectives)');
  r := finalize_fixture(f);
  perform pg_temp.ok((r ->> 'already_finalized')::boolean, 'finalize is idempotent');
  perform pg_temp.ok((select score_a || '-' || score_b from fixtures where id = f) = '2-1', 'score stored from A''s view');
  perform pg_temp.ok((select player_a_id from fixtures where id = (select next_fixture_id from fixtures where id = f)) = a
                     or (select player_b_id from fixtures where id = (select next_fixture_id from fixtures where id = f)) = a,
                     'winner advanced to the final');
end $$;

-- ============================================================ forfeit via early end / opponent quit
do $$
declare t uuid := (select v::uuid from ctx where k = 'cup'); fx fixtures; a uuid; b uuid; f uuid; r jsonb;
begin
  select * into fx from fixtures where tournament_id = t and round = 1 and slot = 2;
  f := fx.id; a := fx.player_a_id; b := fx.player_b_id;
  insert into ctx values ('f2', f::text);
  update fixtures set kickoff_at = now() - interval '10 minutes', status = 'active' where id = f;

  -- B's phone shows an early result screen (opponent quit) at 48:59 while A's phone is silent
  perform pg_temp.terminal(f, b, 'result', 3, 0, null, null, 2939, 5);
  perform pg_temp.as_user(b);
  r := finalize_fixture(f);
  perform pg_temp.ok(r ->> 'detail' = 'grace', 'forfeit waits 20 s grace for the other phone');

  -- A is still playing after B's claim => dispute, not a win
  update match_latest_state set terminal_at = now() - interval '60 seconds' where fixture_id = f and user_id = b;
  insert into match_latest_state (fixture_id, user_id, layout, client_seq, last_in_play_at)
  values (f, a, 'in_play', 5, now());
  r := finalize_fixture(f);
  perform pg_temp.ok(r ->> 'status' = 'disputed' and r ->> 'reason' = 'opponent_still_playing', 'a faked quit while opponent plays is a dispute');

  -- admin resolves, bracket advances
  perform pg_temp.as_user(pg_temp.u('p1'));
  begin
    perform resolve_fixture(f, 'win_player_b', 'x');
    raise exception 'ASSERT FAILED: player resolved a fixture';
  exception when others then
    if sqlerrm not like '%not_allowed%' then raise; end if;
  end;
  perform pg_temp.as_user(pg_temp.u('admin1'));
  r := resolve_fixture(f, 'win_player_b', 'admin ruling');
  perform pg_temp.ok((r ->> 'ok')::boolean and (select winner_id from fixtures where id = f) = b, 'admin override sets the winner');
  perform pg_temp.ok((select count(*) from audit_logs where action = 'resolve_fixture') = 1, 'override is audited');
  perform pg_temp.ok((select status from fixtures where tournament_id = t and round = 2) = 'scheduled'
                     and (select player_a_id is not null and player_b_id is not null from fixtures where tournament_id = t and round = 2),
                     'final now has both players');
end $$;

-- clean forfeit (opponent silent) on a fresh knockout
do $$
declare t uuid; f uuid; a uuid; b uuid; r jsonb; fx fixtures;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup F', 'cup-f', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2'));
  perform generate_tournament(t); perform publish_tournament(t);
  select * into fx from fixtures where tournament_id = t; f := fx.id; a := fx.player_a_id; b := fx.player_b_id;
  perform pg_temp.ok(fx.next_fixture_id is null, 'two players -> a single final');
  update fixtures set kickoff_at = now() - interval '5 minutes', status = 'active' where id = f;
  -- A shows OPPONENT QUIT popup at 48:59 while ahead 3-0; B's phone stopped reporting
  perform pg_temp.terminal(f, a, 'opponent_quit', 3, 0, null, null, 2939, 40);
  insert into match_latest_state (fixture_id, user_id, layout, client_seq, last_in_play_at)
  values (f, b, 'menu', 3, now() - interval '3 minutes');
  perform pg_temp.as_user(a);
  r := finalize_fixture(f);
  perform pg_temp.ok(r ->> 'status' = 'completed' and (r ->> 'winner_id')::uuid = a, 'phone showing the quit popup wins');
  perform pg_temp.ok((select outcome from fixtures where id = f) = 'win_by_forfeit', 'outcome is forfeit');
  perform pg_temp.ok((select status from tournaments where id = t) = 'completed' and (select champion_id from tournaments where id = t) = a, 'tournament completes with a champion');
end $$;

-- ============================================================ knockout extra time + penalties, then champion
do $$
declare t uuid := (select v::uuid from ctx where k = 'cup'); fx fixtures; a uuid; b uuid; f uuid; r jsonb;
begin
  select * into fx from fixtures where tournament_id = t and round = 2; f := fx.id; a := fx.player_a_id; b := fx.player_b_id;
  update fixtures set kickoff_at = now() - interval '20 minutes', status = 'active', scheduled_at = now() where id = f;
  -- 1-1 after 120:00, penalties: A 0, B 2 (A's phone view and B's mirrored view)
  perform pg_temp.terminal(f, a, 'result', 1, 1, 0, 2, 7200, 60);
  perform pg_temp.terminal(f, b, 'result', 1, 1, 2, 0, 7200, 60);
  perform pg_temp.as_user(a);
  r := finalize_fixture(f);
  perform pg_temp.ok(r ->> 'status' = 'completed' and (r ->> 'winner_id')::uuid = b, 'penalties decide the knockout');
  perform pg_temp.ok((select pen_a || '-' || pen_b from fixtures where id = f) = '0-2', 'penalties stored');
  perform pg_temp.ok((select champion_id from tournaments where id = t) = b and (select status from tournaments where id = t) = 'completed', 'champion crowned');
end $$;

-- ============================================================ disputes: mismatch, level at regulation
do $$
declare t uuid; fx fixtures; r jsonb; f uuid;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup D', 'cup-d', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2'));
  perform generate_tournament(t); perform publish_tournament(t);
  select * into fx from fixtures where tournament_id = t; f := fx.id;
  update fixtures set kickoff_at = now(), status = 'active' where id = f;

  perform pg_temp.terminal(f, fx.player_a_id, 'result', 2, 1, null, null, 5400);
  perform pg_temp.terminal(f, fx.player_b_id, 'result', 2, 1, null, null, 5400);   -- not mirrored
  r := _finalize(f, null);
  perform pg_temp.ok(r ->> 'reason' = 'score_mismatch', 'non-mirrored scores -> dispute');

  update fixtures set status = 'active' where id = f;
  perform pg_temp.terminal(f, fx.player_a_id, 'result', 1, 1, null, null, 5400);
  perform pg_temp.terminal(f, fx.player_b_id, 'result', 1, 1, null, null, 5400);
  r := _finalize(f, null);
  perform pg_temp.ok(r ->> 'reason' = 'knockout_level_no_winner', 'level knockout with no penalties -> dispute');

  update fixtures set status = 'active' where id = f;
  perform pg_temp.terminal(f, fx.player_a_id, 'opponent_quit', 1, 0, null, null, 3000);
  perform pg_temp.terminal(f, fx.player_b_id, 'opponent_quit', 0, 1, null, null, 3000);
  r := _finalize(f, null);
  perform pg_temp.ok(r ->> 'reason' = 'both_claim_forfeit', 'both phones claiming forfeit -> dispute');

  -- replay resets the fixture
  perform pg_temp.as_user(pg_temp.u('admin1'));
  perform resolve_fixture(f, 'replay', 'rerun');
  perform pg_temp.ok((select status = 'scheduled' and replay_count = 1 and kickoff_at is null from fixtures where id = f), 'replay resets fixture');
  perform pg_temp.ok((select count(*) from match_latest_state where fixture_id = f) = 0, 'replay clears old states');
end $$;

-- ============================================================ league: table, ties, draws, completion
do $$
declare t uuid; fx record; r jsonb; a_pts int;
  p1 uuid := pg_temp.u('p1'); p2 uuid := pg_temp.u('p2'); p3 uuid := pg_temp.u('p3'); p4 uuid := pg_temp.u('p4');
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('League L', 'league-l', 'football-1v1', 'league', 8);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, p1), (t, p2), (t, p3), (t, p4);
  perform generate_tournament(t); perform publish_tournament(t);
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t) = 6, '4-player league has 6 fixtures');
  perform pg_temp.ok((select count(*) from (select least(player_a_id, player_b_id), greatest(player_a_id, player_b_id) from fixtures where tournament_id = t group by 1, 2) q) = 6, 'every pairing exactly once');

  -- p1 beats everyone 1-0; p2 beats p3 and p4 1-0; p3 v p4 draws 1-1
  for fx in select * from fixtures where tournament_id = t loop
    update fixtures set kickoff_at = now(), status = 'active' where id = fx.id;
    declare ga int; gb int; pa uuid := fx.player_a_id; pb uuid := fx.player_b_id;
    begin
      if pa = p1 then ga := 1; gb := 0; elsif pb = p1 then ga := 0; gb := 1;
      elsif pa = p2 then ga := 1; gb := 0; elsif pb = p2 then ga := 0; gb := 1;
      else ga := 1; gb := 1; end if;
      perform pg_temp.terminal(fx.id, pa, 'result', ga, gb, null, null, 5400);
      perform pg_temp.terminal(fx.id, pb, 'result', gb, ga, null, null, 5400);
      r := _finalize(fx.id, null);
      perform pg_temp.ok(r ->> 'status' = 'completed', 'league fixture completes');
    end;
  end loop;

  perform pg_temp.ok((select outcome from fixtures where tournament_id = t and ((player_a_id = p3 and player_b_id = p4) or (player_a_id = p4 and player_b_id = p3))) = 'draw', 'draw recorded');
  perform pg_temp.ok((select user_id from league_table(t) where rank = 1) = p1, 'p1 tops the table');
  perform pg_temp.ok((select points from league_table(t) where user_id = p1) = 9, 'p1 has 9 points');
  perform pg_temp.ok((select points from league_table(t) where user_id = p3) = 1, 'draw gives 1 point');
  perform pg_temp.ok((select rank from league_table(t) where user_id = p3) < (select rank from league_table(t) where user_id = p4)
                     or (select username from profiles where id = p3) < (select username from profiles where id = p4), 'username is the last tie-break');
  perform pg_temp.ok((select status from tournaments where id = t) = 'completed' and (select champion_id from tournaments where id = t) = p1, 'league completes with champion');
end $$;

-- head-to-head tie-break: A and B level on points/GD/GF, B beat A
do $$
declare t uuid; p1 uuid := pg_temp.u('p1'); p2 uuid := pg_temp.u('p2'); p3 uuid := pg_temp.u('p3'); fx record; ga int; gb int;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('League H', 'league-h', 'football-1v1', 'league', 8);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, p1), (t, p2), (t, p3);
  perform generate_tournament(t); perform publish_tournament(t);
  -- p1 beats p3 2-0, p2 beats p3 2-0, p2 beats p1 1-0 would break level; make p1 and p2 level via draw:
  -- Results: p1 bt p3 1-0, p2 bt p3 1-0, p1 v p2 0-0  => p1,p2: 4 pts, GD +1, GF 1. Level. h2h level (draw). Falls to username.
  for fx in select * from fixtures where tournament_id = t loop
    update fixtures set kickoff_at = now(), status = 'active' where id = fx.id;
    if p3 in (fx.player_a_id, fx.player_b_id) then
      ga := case when fx.player_a_id = p3 then 0 else 1 end; gb := case when fx.player_a_id = p3 then 1 else 0 end;
    else ga := 0; gb := 0; end if;
    perform pg_temp.terminal(fx.id, fx.player_a_id, 'result', ga, gb, null, null, 5400);
    perform pg_temp.terminal(fx.id, fx.player_b_id, 'result', gb, ga, null, null, 5400);
    perform _finalize(fx.id, null);
  end loop;
  perform pg_temp.ok((select count(distinct rank) from league_table(t)) = 3, 'ranks are unique even with level teams');
  perform pg_temp.ok((select h2h from league_table(t) where user_id = p1) = 1, 'head-to-head points counted among level teams');
end $$;

-- ============================================================ league -> knockout
do $$
declare t uuid; fx record; r jsonb; p uuid[] := array[pg_temp.u('p1'), pg_temp.u('p2'), pg_temp.u('p3'), pg_temp.u('p4')]; i int;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('League K', 'league-k', 'football-1v1', 'league_knockout', 8, null, null, 2);
  perform set_tournament_status(t, 'open');
  for i in 1..4 loop insert into tournament_entries (tournament_id, user_id) values (t, p[i]); end loop;
  perform generate_tournament(t); perform publish_tournament(t);
  for fx in select * from fixtures where tournament_id = t and stage = 'league' order by round, slot loop
    update fixtures set kickoff_at = now(), status = 'active' where id = fx.id;
    perform pg_temp.terminal(fx.id, fx.player_a_id, 'result', 2, 0, null, null, 5400);   -- host always wins 2-0
    perform pg_temp.terminal(fx.id, fx.player_b_id, 'result', 0, 2, null, null, 5400);
    perform _finalize(fx.id, null);
  end loop;
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'knockout') = 1, 'top 2 advance to a knockout final');
  perform pg_temp.ok((select status from tournaments where id = t) = 'live', 'tournament still live during knockout');
  perform pg_temp.ok((select count(*) from matchrooms m join fixtures f on f.id = m.fixture_id where f.tournament_id = t and f.stage = 'knockout') = 1, 'knockout final has a matchroom');
end $$;

-- ============================================================ byes: 5 players
do $$
declare t uuid; i int; p uuid[] := array[pg_temp.u('p1'), pg_temp.u('p2'), pg_temp.u('p3'), pg_temp.u('p4'), pg_temp.u('p5')];
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup B', 'cup-b', 'football-1v1', 'knockout', 8);
  perform set_tournament_status(t, 'open');
  for i in 1..5 loop insert into tournament_entries (tournament_id, user_id) values (t, p[i]); end loop;
  perform generate_tournament(t); perform publish_tournament(t);
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t) = 7, '8-slot bracket has 7 fixtures');
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and status = 'bye') = 3, '5 players get 3 byes');
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and round = 2 and player_a_id is not null and player_b_id is not null) = 1
                  and (select count(*) from fixtures where tournament_id = t and round = 2 and (player_a_id is not null or player_b_id is not null)) = 2,
                  'bye winners already advanced to round 2');
end $$;

-- ============================================================ sweep: check-in deadlines
do $$
declare t uuid; fx fixtures; f uuid; n int;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup S', 'cup-s', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2'));
  perform generate_tournament(t); perform publish_tournament(t);
  select * into fx from fixtures where tournament_id = t; f := fx.id;

  -- nobody showed up, deadline passed
  update fixtures set scheduled_at = now() - interval '10 minutes' where id = f;
  n := sweep_fixtures();
  perform pg_temp.ok((select status from fixtures where id = f) = 'cancelled', 'no-show by both cancels');

  -- host created the room, opponent never joined -> opponent forfeits
  update fixtures set status = 'scheduled', scheduled_at = now() - interval '10 minutes' where id = f;
  update matchrooms set room_code = 'QWER45', room_code_source = 'host', player_a_joined_at = now() - interval '12 minutes',
         player_b_joined_at = null where fixture_id = f;
  update matchrooms set player_a_joined_at = null, player_b_joined_at = null where fixture_id = f;
  update matchrooms set player_a_joined_at = case when fx.host_player_id = fx.player_a_id then now() - interval '12 minutes' end,
                        player_b_joined_at = case when fx.host_player_id = fx.player_b_id then now() - interval '12 minutes' end
  where fixture_id = f;
  update fixtures set status = 'active' where id = f;
  n := sweep_fixtures();
  perform pg_temp.ok((select winner_id from fixtures where id = f) = fx.host_player_id and (select outcome from fixtures where id = f) = 'win_by_noshow', 'absent opponent forfeits');
end $$;

-- host_blocked evidence turns a missing code into a dispute instead of a forfeit
do $$
declare t uuid; fx fixtures; f uuid; r jsonb;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup H', 'cup-hb', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2'));
  perform generate_tournament(t); perform publish_tournament(t);
  select * into fx from fixtures where tournament_id = t; f := fx.id;
  perform pg_temp.as_user(fx.host_player_id);
  r := report_host_blocked(f, 'game crashed');
  perform pg_temp.ok((r ->> 'ok')::boolean, 'host can report being blocked');
  update fixtures set scheduled_at = now() - interval '10 minutes' where id = f;
  update matchrooms set player_a_joined_at = now(), player_b_joined_at = now() where fixture_id = f;
  perform sweep_fixtures();
  perform pg_temp.ok((select status from fixtures where id = f) = 'disputed', 'blocked host -> disputed, not forfeited');
end $$;

-- platform-issued model: both players get the same generated code, reveal window enforced
do $$
declare t uuid; fx fixtures; f uuid; r1 jsonb; r2 jsonb;
begin
  update games set room_code_model = 'platform_issued' where slug = 'football-1v1';
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup P', 'cup-p', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2'));
  perform generate_tournament(t); perform publish_tournament(t);
  select * into fx from fixtures where tournament_id = t; f := fx.id;
  perform pg_temp.ok((select room_code ~ '^[a-hj-km-np-z2-9]{5}$' and room_code ~ '[a-z]' and room_code ~ '[2-9]' from matchrooms where fixture_id = f), 'generated code: 5 chars, lowercase letters and digits, both present');

  perform schedule_fixtures(t, 'knockout', 1, now() + interval '1 hour', 30);
  perform pg_temp.as_user(fx.player_a_id);
  r1 := app_join_fixture(f);
  perform pg_temp.ok(r1 ->> 'reason' = 'too_early' and not r1::text like '%room_code%', 'code hidden before the reveal window');

  update fixtures set scheduled_at = now() + interval '90 seconds' where id = f;
  r1 := app_join_fixture(f);
  perform pg_temp.as_user(fx.player_b_id);
  r2 := app_join_fixture(f);
  perform pg_temp.ok(r1 ->> 'room_code' = r2 ->> 'room_code' and r1 ->> 'room_code' is not null, 'both players get the same platform code');
  perform pg_temp.ok((select status from fixtures where id = f) = 'active', 'fixture active once both checked in');

  perform pg_temp.as_user(pg_temp.u('admin1'));
  perform regenerate_room_code(f);
  perform pg_temp.ok((select room_code from matchrooms where fixture_id = f) <> r1 ->> 'room_code', 'admin regeneration changes the code');
end $$;   -- the game stays platform-issued from here on (the shipped default)

-- admin reversal of a completed fixture is blocked once downstream play started
do $$
declare t uuid; fx fixtures; fin fixtures; r jsonb; a uuid;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup R', 'cup-r', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2')), (t, pg_temp.u('p3')), (t, pg_temp.u('p4'));
  perform generate_tournament(t); perform publish_tournament(t);
  select * into fx from fixtures where tournament_id = t and round = 1 and slot = 1;
  update fixtures set kickoff_at = now(), status = 'active' where id = fx.id;
  perform pg_temp.terminal(fx.id, fx.player_a_id, 'result', 1, 0, null, null, 5400);
  perform pg_temp.terminal(fx.id, fx.player_b_id, 'result', 0, 1, null, null, 5400);
  perform _finalize(fx.id, null);
  -- reversal while the final is still unplayed works and clears the slot
  r := resolve_fixture(fx.id, 'win_player_b', 'wrong winner reported');
  perform pg_temp.ok((select (player_a_id = fx.player_b_id) or (player_b_id = fx.player_b_id) from fixtures where id = fx.next_fixture_id), 'reversal re-advances the other player');
  perform pg_temp.ok(not exists (select 1 from fixtures where id = fx.next_fixture_id and fx.player_a_id in (player_a_id, player_b_id)), 'old winner removed from next round');
end $$;


-- ============================================================ country, local time and the draft -> publish flow
do $$
declare t uuid; r jsonb; v_fixture record; v_times timestamptz[]; blocked boolean; n int; v_tz text;
begin
  -- country is required to register, and can be set afterwards
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup Life', 'cup-life', 'football-1v1', 'knockout', 4, now() + interval '3 days');
  perform set_tournament_status(t, 'open');
  perform pg_temp.as_user(pg_temp.u('nocountry'));
  perform pg_temp.ok(register_for_tournament(t) ->> 'reason' = 'country_required', 'registration needs a country');
  perform pg_temp.ok(set_my_country('zz') ->> 'reason' = 'unknown_country', 'unknown country rejected');
  r := set_my_country('ke');
  perform pg_temp.ok((r ->> 'ok')::boolean and r ->> 'tz' = 'Africa/Nairobi', 'country saved, time zone returned');
  perform pg_temp.ok(my_profile() ->> 'tz' = 'Africa/Nairobi' and my_profile() ->> 'country_name' = 'Kenya', 'my_profile returns the local time zone');
  perform pg_temp.ok((register_for_tournament(t) ->> 'ok')::boolean, 'registration works once a country is set');

  -- three more players fill the tournament: registration closes and a hidden draft is prepared automatically
  perform pg_temp.as_user(pg_temp.u('p1')); perform register_for_tournament(t);
  perform pg_temp.as_user(pg_temp.u('p2')); perform register_for_tournament(t);
  perform pg_temp.ok((select status from tournaments where id = t) = 'open', 'still open with 3 of 4 players');
  perform pg_temp.as_user(pg_temp.u('p3')); r := register_for_tournament(t);
  perform pg_temp.ok((r ->> 'ok')::boolean and (select status from tournaments where id = t) = 'planning', 'when full: registration closes and the draft is prepared');
  perform pg_temp.as_user(pg_temp.u('p4'));
  perform pg_temp.ok(register_for_tournament(t) ->> 'reason' = 'registration_closed', 'no entrance once full');
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t) = 3, 'draft has all fixtures');
  select schedule_tz into v_tz from tournaments where id = t;
  perform pg_temp.ok(v_tz = 'Africa/Kigali', 'time zone = the most common one among players (3 Rwanda, 1 Kenya)');

  -- automatic times: local slot hour, after the tournament start, never sooner than 12 hours away
  for v_fixture in select * from fixtures where tournament_id = t and round = 1 loop
    perform pg_temp.ok(v_fixture.scheduled_at is not null, 'round 1 has an automatic time');
    perform pg_temp.ok(extract(hour from v_fixture.scheduled_at at time zone 'Africa/Kigali') = 18 and extract(minute from v_fixture.scheduled_at) = 0, 'time is 18:00 local');
    perform pg_temp.ok(v_fixture.scheduled_at >= now() + interval '12 hours', 'at least 12 hours away');
  end loop;

  -- hidden from the public while it is a draft; visible to the organizer
  blocked := false;
  perform pg_temp.as_user(null);
  set local role anon;
  select count(*) into n from fixtures where tournament_id = t;
  reset role;
  perform pg_temp.ok(n = 0, 'public cannot see draft fixtures');
  perform pg_temp.as_user(pg_temp.u('admin1'));
  set local role authenticated;
  select count(*) into n from fixtures where tournament_id = t;
  reset role;
  perform pg_temp.ok(n = 3, 'organizer can see the draft');

  -- not playable while a draft
  select * into v_fixture from fixtures where tournament_id = t and round = 1 and slot = 1;
  perform pg_temp.as_user(v_fixture.player_a_id);
  update fixtures set scheduled_at = now() + interval '30 seconds' where id = v_fixture.id;
  perform pg_temp.ok(app_join_fixture(v_fixture.id) ->> 'reason' = 'not_live', 'matchroom closed while a draft');
  perform pg_temp.ok(create_app_handoff(v_fixture.id) ->> 'reason' = 'not_live', 'no app handoff while a draft');
  -- the sweep leaves drafts alone (no forfeits or cancellations)
  update fixtures set scheduled_at = now() - interval '1 hour' where id = v_fixture.id;
  perform sweep_fixtures();
  perform pg_temp.ok((select status from fixtures where id = v_fixture.id) = 'scheduled', 'sweep ignores draft fixtures');

  -- admin edits one time, players cannot
  perform pg_temp.as_user(v_fixture.player_a_id);
  begin perform reschedule_fixture(v_fixture.id, now() + interval '5 days'); raise exception 'ASSERT FAILED: player rescheduled';
  exception when others then if sqlerrm not like '%not_allowed%' then raise; end if; end;
  perform pg_temp.as_user(pg_temp.u('admin1'));
  r := reschedule_fixture(v_fixture.id, now() + interval '5 days');
  perform pg_temp.ok((r ->> 'ok')::boolean and (select scheduled_at from fixtures where id = v_fixture.id) > now() + interval '4 days', 'admin changes a time');
  perform pg_temp.ok((select count(*) from audit_logs where action = 'reschedule_fixture') = 1, 'time change is audited');

  -- only the owner/admin publishes
  perform pg_temp.as_user(pg_temp.u('p1'));
  begin perform publish_tournament(t); raise exception 'ASSERT FAILED: player published';
  exception when others then if sqlerrm not like '%not_allowed%' then raise; end if; end;
  perform pg_temp.as_user(pg_temp.u('admin1'));
  r := publish_tournament(t);
  perform pg_temp.ok((r ->> 'ok')::boolean and (select status from tournaments where id = t) = 'live', 'admin publishes');
  perform pg_temp.ok(publish_tournament(t) ->> 'reason' = 'not_in_planning', 'publishing twice is refused');
  perform pg_temp.as_user(null);
  set local role anon;
  select count(*) into n from fixtures where tournament_id = t;
  reset role;
  perform pg_temp.ok(n = 3, 'fixtures are public once published');
end $$;

-- ============================================================ later rounds get automatic times; league rounds follow the gap
do $$
declare t uuid; fx record; r jsonb; fin fixtures; v_r1 timestamptz; v_r2 timestamptz; v_gap numeric;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('League Gap', 'league-gap', 'football-1v1', 'league', 8, now() + interval '2 days');
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2')), (t, pg_temp.u('p3')), (t, pg_temp.u('p4'));
  perform generate_tournament(t);
  select min(scheduled_at) into v_r1 from fixtures where tournament_id = t and round = 1;
  select min(scheduled_at) into v_r2 from fixtures where tournament_id = t and round = 2;
  v_gap := extract(epoch from (v_r2 - v_r1)) / 3600;
  perform pg_temp.ok(v_gap = 48, 'league rounds are 48 hours apart (got ' || v_gap || ')');
  perform pg_temp.ok((select count(distinct scheduled_at) from fixtures where tournament_id = t and round = 1) = 1, 'all matches of a round share one time');
  perform publish_tournament(t);

  -- change the schedule policy, then a fresh tournament follows it
  r := update_tournament(t, '{"slot_hour":20,"round_gap_hours":24,"schedule_tz":"Europe/Paris"}'::jsonb);
  perform pg_temp.ok((r ->> 'ok')::boolean, 'schedule policy can be changed');
  perform pg_temp.ok(update_tournament(t, '{"schedule_tz":"Mars/Base"}'::jsonb) ->> 'reason' = 'unknown_time_zone', 'unknown time zone rejected');
  perform pg_temp.ok(update_tournament(t, '{"size":2}'::jsonb) ->> 'reason' = 'size_locked', 'size is locked after the draft');

  -- knockout: after round 1 finishes, the final gets an automatic time
  t := create_tournament('Cup Auto', 'cup-auto', 'football-1v1', 'knockout', 4, now() + interval '2 days');
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2')), (t, pg_temp.u('p3')), (t, pg_temp.u('p4'));
  perform generate_tournament(t); perform publish_tournament(t);
  for fx in select * from fixtures where tournament_id = t and round = 1 loop
    update fixtures set kickoff_at = now(), status = 'active' where id = fx.id;
    perform pg_temp.terminal(fx.id, fx.player_a_id, 'result', 1, 0, null, null, 5400);
    perform pg_temp.terminal(fx.id, fx.player_b_id, 'result', 0, 1, null, null, 5400);
    perform _finalize(fx.id, null);
  end loop;
  select * into fin from fixtures where tournament_id = t and round = 2;
  perform pg_temp.ok(fin.scheduled_at is not null and fin.scheduled_at >= now() + interval '12 hours', 'the final is scheduled automatically');
  perform pg_temp.ok(extract(hour from fin.scheduled_at at time zone 'Africa/Kigali') = 18, 'the final is at the local slot hour');
end $$;

-- ============================================================ going back to registration
do $$
declare t uuid; r jsonb;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup Back', 'cup-back', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2'));
  perform generate_tournament(t);   -- admin closes early with 2 players
  perform pg_temp.ok((select status from tournaments where id = t) = 'planning', 'admin can close registration early');
  r := reopen_registration(t);
  perform pg_temp.ok((r ->> 'ok')::boolean and (select status from tournaments where id = t) = 'open' and (select count(*) from fixtures where tournament_id = t) = 0, 'reopen removes the draft');
  r := update_tournament(t, '{"size":6}'::jsonb);
  perform pg_temp.ok((r ->> 'ok')::boolean and (select size from tournaments where id = t) = 6, 'size can grow while open');
  perform pg_temp.ok(update_tournament(t, '{"size":1}'::jsonb) ->> 'reason' = 'size_below_players', 'size cannot drop below the players');
end $$;

-- ============================================================ adding and removing admins
do $$
declare r jsonb; n int; blocked boolean := false;
begin
  perform pg_temp.as_user(pg_temp.u('p1'));
  begin perform add_role('p2', 'admin'); raise exception 'ASSERT FAILED: player added an admin';
  exception when others then if sqlerrm not like '%not_allowed%' then raise; end if; end;
  begin perform list_admins(); raise exception 'ASSERT FAILED: player listed admins';
  exception when others then if sqlerrm not like '%not_allowed%' then raise; end if; end;

  perform pg_temp.as_user(pg_temp.u('admin1'));
  perform pg_temp.ok(add_role('nobody@nowhere.test', 'admin') ->> 'reason' = 'no_such_account', 'unknown account rejected');
  perform pg_temp.ok(add_role('p2', 'owner') ->> 'reason' = 'bad_role', 'only known roles accepted');
  r := add_role('admin2@test.local', 'admin');
  perform pg_temp.ok((r ->> 'ok')::boolean, 'admin added by email');
  perform pg_temp.ok((add_role('PlayerP2', 'organizer') ->> 'ok')::boolean, 'organizer added by username (case-insensitive)');
  select count(*) into n from list_admins();
  perform pg_temp.ok(n >= 3, 'admins can be listed');

  -- the new admin has real powers
  perform pg_temp.as_user(pg_temp.u('admin2'));
  perform pg_temp.ok(is_admin(), 'the new admin is an admin');
  perform pg_temp.ok((add_role('PlayerP3', 'organizer') ->> 'ok')::boolean, 'the new admin can add people too');

  -- protections
  perform pg_temp.ok(remove_role(pg_temp.u('admin2'), 'admin') ->> 'reason' = 'cannot_remove_yourself', 'cannot remove yourself');
  perform pg_temp.as_user(pg_temp.u('admin1'));
  perform pg_temp.ok((remove_role(pg_temp.u('admin2'), 'admin') ->> 'ok')::boolean, 'an admin can be removed');
  perform pg_temp.as_user(pg_temp.u('p2'));
  perform pg_temp.ok(not is_admin() and is_organizer(), 'organizer is not an admin');
  -- a removed admin loses every power immediately
  perform pg_temp.as_user(pg_temp.u('admin2'));
  begin perform add_role('PlayerP5', 'admin'); raise exception 'ASSERT FAILED: removed admin still acts';
  exception when others then if sqlerrm not like '%not_allowed%' then raise; end if; end;
  perform pg_temp.ok((select count(*) from audit_logs where action in ('add_role', 'remove_role')) >= 4, 'role changes are audited');
end $$;


-- ============================================================ notifications
do $$
declare
  t uuid; r jsonb; n int; fx record; s1 fixtures; s2 fixtures; fin fixtures; i int;
  u uuid[] := array[]::uuid[]; w1 uuid; l1 uuid; w2 uuid; l2 uuid; blocked boolean;
begin
  for i in 1..4 loop
    insert into tu values ('n' || i, pg_temp.mkuser('nplayer' || i));
    u := u || pg_temp.u('n' || i);
  end loop;
  update profiles set lang = 'fr' where id = u[2];

  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Notify Cup', 'notify-cup', 'football-1v1', 'knockout', 4, now() + interval '2 days');
  perform set_tournament_status(t, 'open');
  for i in 1..4 loop perform pg_temp.as_user(u[i]); perform register_for_tournament(t); end loop;

  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'registered') = 4, 'every player is told they are in');
  perform pg_temp.ok((select title from notifications where user_id = u[2] and kind = 'registered') like 'Inscription confirmée%', 'French player gets French text');
  perform pg_temp.ok((select count(*) from tournament_follows where tournament_id = t and state = 'playing') = 4, 'all players follow while playing');
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind like 'published%') = 0, 'nothing about fixtures while it is a draft');

  perform pg_temp.as_user(pg_temp.u('admin1'));
  perform publish_tournament(t);
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'published') = 4, 'publishing tells every player their first match');
  perform pg_temp.ok((select url from notifications where user_id = u[1] and kind = 'published') like '/matchroom.html?f=%', 'it links to the matchroom');
  perform pg_temp.ok((select body from notifications where user_id = u[1] and kind = 'published') ~ '\d\d/\d\d \d\d:\d\d', 'it shows the time in the player''s zone');

  select * into s1 from fixtures where tournament_id = t and round = 1 and slot = 1;
  select * into s2 from fixtures where tournament_id = t and round = 1 and slot = 2;

  -- the admin moves a match: both players are told
  r := reschedule_fixture(s1.id, now() + interval '3 days');
  perform pg_temp.ok((select count(*) from notifications where fixture_id = s1.id and kind = 'rescheduled') = 2, 'time change reaches both players');

  -- reminders: 1 hour before, then when the room opens; never twice
  update fixtures set scheduled_at = now() + interval '40 minutes' where id = s1.id;
  perform _notify_reminders(); perform _notify_reminders();
  perform pg_temp.ok((select count(*) from notifications where fixture_id = s1.id and kind = 'reminder') = 2, 'one reminder each, no duplicates');
  update fixtures set scheduled_at = now() + interval '60 seconds' where id = s1.id;
  perform _notify_reminders(); perform _notify_reminders();
  perform pg_temp.ok((select count(*) from notifications where fixture_id = s1.id and kind = 'room_open') = 2, 'code-ready notice when the room opens');

  -- semi-final 1: A wins. Results for both, the loser gets the last notification with a choice
  w1 := s1.player_a_id; l1 := s1.player_b_id;
  update fixtures set kickoff_at = now(), status = 'active' where id = s1.id;
  perform pg_temp.terminal(s1.id, w1, 'result', 2, 0, null, null, 5400);
  perform pg_temp.terminal(s1.id, l1, 'result', 0, 2, null, null, 5400);
  perform _finalize(s1.id, null);
  perform pg_temp.ok((select kind from notifications where user_id = w1 and fixture_id = s1.id and kind like 'result%') = 'result_win', 'winner told they won');
  perform pg_temp.ok((select title from notifications where user_id = l1 and fixture_id = s1.id and kind = 'result_loss') like '%0-2', 'loser sees their own score first (0-2)');
  perform pg_temp.ok((select actions from notifications where user_id = l1 and kind = 'knocked_out') -> 0 ->> 'action' = 'follow', 'knocked-out notice carries Keep following / Stop');
  perform pg_temp.ok((select state from tournament_follows where user_id = l1 and tournament_id = t) = 'asked', 'loser is asked, not auto-followed');
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'round_complete_ko') = 0, 'round not complete yet');

  -- the first loser keeps following
  perform pg_temp.as_user(l1);
  perform pg_temp.ok(set_follow(t, true) ->> 'state' = 'following', 'loser chooses to keep following');

  -- semi-final 2: the second loser does not answer
  w2 := s2.player_a_id; l2 := s2.player_b_id;
  update fixtures set kickoff_at = now(), status = 'active' where id = s2.id;
  perform pg_temp.terminal(s2.id, w2, 'result', 1, 0, null, null, 5400);
  perform pg_temp.terminal(s2.id, l2, 'result', 0, 1, null, null, 5400);
  perform _finalize(s2.id, null);
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'round_complete_ko') = 3, 'round update to the 2 still playing + 1 follower');
  perform pg_temp.ok(not exists (select 1 from notifications where user_id = l2 and kind = 'round_complete_ko'), 'no answer = no more updates');
  select * into fin from fixtures where tournament_id = t and round = 2;
  perform pg_temp.ok((select count(*) from notifications where fixture_id = fin.id and kind = 'next_match') = 2, 'finalists get their next match');
  perform pg_temp.ok((select body from notifications where user_id = w1 and kind = 'next_match') like '%Final%'
                  or (select body from notifications where user_id = w1 and kind = 'next_match') like '%Finale%', 'next match names the round');

  -- second loser now says stop explicitly
  perform pg_temp.as_user(l2);
  perform pg_temp.ok(set_follow(t, false) ->> 'state' = 'stopped', 'loser can stop');

  -- final
  update fixtures set kickoff_at = now(), status = 'active' where id = fin.id;
  perform pg_temp.terminal(fin.id, fin.player_a_id, 'result', 3, 1, null, null, 5400);
  perform pg_temp.terminal(fin.id, fin.player_b_id, 'result', 1, 3, null, null, 5400);
  perform _finalize(fin.id, null);
  perform pg_temp.ok(exists (select 1 from notifications where user_id = fin.player_a_id and kind = 'champion_you'), 'the champion is told');
  perform pg_temp.ok(exists (select 1 from notifications where user_id = l1 and kind = 'champion'), 'the follower hears who won');
  perform pg_temp.ok(not exists (select 1 from notifications where user_id = l2 and kind = 'champion'), 'the one who stopped hears nothing');

  -- privacy and permissions
  perform pg_temp.as_user(u[1]);
  set local role authenticated;
  select count(*) into n from notifications;
  reset role;
  perform pg_temp.ok(n = (select count(*) from notifications where user_id = u[1]) and n > 0, 'players read only their own notifications');
  blocked := false; set local role authenticated;
  begin insert into notifications (user_id, kind, title, body, dedupe_key) values (u[1], 'x', 'x', 'x', 'x'); exception when insufficient_privilege then blocked := true; end;
  reset role;
  perform pg_temp.ok(blocked, 'clients cannot create notifications');
  perform pg_temp.ok(mark_notifications_read(null) = n, 'mark all as read');
  perform pg_temp.ok(not exists (select 1 from notifications where user_id = u[1] and read_at is null), 'all read');

  perform pg_temp.ok(save_push_subscription('http://insecure', 'k', 'a') ->> 'reason' = 'bad_subscription', 'only https push endpoints');
  perform pg_temp.ok((save_push_subscription('https://push.example/abc', 'key', 'auth', 'test') ->> 'ok')::boolean, 'phone subscription saved');
  perform pg_temp.as_user(u[2]);
  perform delete_push_subscription('https://push.example/abc');
  perform pg_temp.ok((select count(*) from push_subscriptions where endpoint = 'https://push.example/abc') = 1, 'someone else cannot remove my phone');
  blocked := false; set local role authenticated;
  begin perform 1 from push_subscriptions limit 1; exception when insufficient_privilege then blocked := true; end;
  reset role;
  perform pg_temp.ok(blocked, 'push subscriptions are unreachable from the API');
  -- a new notification for a user with a phone must not fail without a push sender configured
  perform _notify(u[1], t, null, 'registered', '{}', 'test:push');
  perform pg_temp.ok(exists (select 1 from notifications where user_id = u[1] and dedupe_key = 'test:push'), 'notification stored even when push is not configured');
  perform pg_temp.as_user(u[1]);
  perform delete_push_subscription('https://push.example/abc');
  perform pg_temp.ok((select count(*) from push_subscriptions where endpoint = 'https://push.example/abc') = 0, 'I can remove my phone');
  perform pg_temp.ok((set_my_lang('rw') ->> 'ok')::boolean, 'language accepted');
  perform pg_temp.ok((select lang from profiles where id = u[1]) = 'rw', 'language saved');
  perform pg_temp.ok(set_my_lang('de') ->> 'ok' = 'false', 'unknown language rejected');
end $$;

-- league + knockout: those who miss the cut are told, with the same choice
do $$
declare t uuid; fx record; i int; u uuid[] := array[pg_temp.u('n1'), pg_temp.u('n2'), pg_temp.u('n3'), pg_temp.u('n4')];
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Notify League', 'notify-league', 'football-1v1', 'league_knockout', 8, now() + interval '2 days', null, 2);
  perform set_tournament_status(t, 'open');
  for i in 1..4 loop perform pg_temp.as_user(u[i]); perform register_for_tournament(t); end loop;
  perform pg_temp.as_user(pg_temp.u('admin1'));
  perform generate_tournament(t); perform publish_tournament(t);
  for fx in select * from fixtures where tournament_id = t and stage = 'league' order by round, slot loop
    update fixtures set kickoff_at = now(), status = 'active' where id = fx.id;
    perform pg_temp.terminal(fx.id, fx.player_a_id, 'result', 2, 0, null, null, 5400);
    perform pg_temp.terminal(fx.id, fx.player_b_id, 'result', 0, 2, null, null, 5400);
    perform _finalize(fx.id, null);
  end loop;
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'not_qualified') = 2, 'the two who missed the cut are told');
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'round_complete_league') >= 4, 'league round updates with position');
  perform pg_temp.ok(exists (select 1 from notifications where tournament_id = t and kind = 'round_complete_league' and (body like '%#1 with%' or body like '%1e avec%' or body like '%mwanya wa 1 %')), 'position is in the update (any language)');
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'next_match') = 2, 'the two qualifiers get their knockout match');
end $$;


-- ============================================================ formats, tie-breaks and speeds (0010)
-- helper: play every open fixture of a stage/round with the host (player A) winning 1-0
create or replace function pg_temp.play_round(p_tid uuid, p_stage text, p_round int) returns int language plpgsql as $$
declare fx record; n int := 0;
begin
  for fx in select * from fixtures where tournament_id = p_tid and stage = p_stage and round = p_round
            and status in ('scheduled', 'active') and player_a_id is not null and player_b_id is not null order by slot loop
    update fixtures set kickoff_at = now(), status = 'active' where id = fx.id;
    perform pg_temp.terminal(fx.id, fx.player_a_id, 'result', 1, 0, null, null, case when p_stage in ('knockout', 'playoff') then 5400 else 5400 end);
    perform pg_temp.terminal(fx.id, fx.player_b_id, 'result', 0, 1, null, null, 5400);
    perform _finalize(fx.id, null);
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
declare i int;
begin
  for i in 1..20 loop insert into tu values ('g' || i, pg_temp.mkuser('gplayer' || i)); end loop;
end $$;

-- the recommendation
do $$ begin
  perform pg_temp.ok(recommend_format(4) = 'league' and recommend_format(10) = 'league_knockout'
                     and recommend_format(20) = 'groups_knockout' and recommend_format(40) = 'league_phase', 'format recommended by player count');
end $$;

-- tie-break order: wins, strength of opponents, forfeits, then earlier registration
do $$
declare t uuid; x uuid := pg_temp.u('g1'); y uuid := pg_temp.u('g2'); z uuid := pg_temp.u('g3'); w uuid := pg_temp.u('g4');
        v uuid := pg_temp.u('g5'); a uuid := pg_temp.u('g6'); b uuid := pg_temp.u('g7');
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Tie League', 'tie-league', 'football-1v1', 'league', 16);
  update tournaments set status = 'live' where id = t;
  insert into tournament_entries (tournament_id, user_id, created_at) values
    (t, x, now() - interval '9 hours'), (t, y, now() - interval '8 hours'), (t, z, now() - interval '7 hours'), (t, w, now() - interval '6 hours'),
    (t, v, now() - interval '5 hours'), (t, a, now() - interval '4 hours'), (t, b, now() - interval '3 hours');
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, score_a, score_b, winner_id, outcome) values
    (t, 'league', 1, 1, x, z, 'completed', 1, 0, x, 'win_by_score'),    -- X: 1 win, 1 loss: 3 pts, GD 0, GF 1
    (t, 'league', 2, 1, w, x, 'completed', 1, 0, w, 'win_by_score'),
    (t, 'league', 1, 2, y, z, 'completed', 0, 0, null, 'draw'),         -- Y: 3 draws: 3 pts, GD 0, GF 1
    (t, 'league', 2, 2, y, w, 'completed', 0, 0, null, 'draw'),
    (t, 'league', 3, 1, y, v, 'completed', 1, 1, null, 'draw'),
    (t, 'league', 3, 2, w, v, 'completed', null, null, w, 'win_by_noshow');   -- V did not show: a forfeit loss
  perform pg_temp.ok((select rank from league_table(t) where user_id = x) < (select rank from league_table(t) where user_id = y), 'more wins ranks higher when points, GD, GF and head-to-head are level');
  perform pg_temp.ok((select forfeits from league_table(t) where user_id = v) = 1, 'forfeit losses are counted');
  perform pg_temp.ok((select sos from league_table(t) where user_id = x) =
                     (select sum(points) from league_table(t) where user_id in (z, w)), 'strength of opponents = their total points');
  perform pg_temp.ok((select rank from league_table(t) where user_id = a) < (select rank from league_table(t) where user_id = b), 'all else equal: earlier registration ranks higher');
end $$;

-- groups + knockout: 12 players = 3 groups of 4; top 2 + 2 best third-placed make a bracket of 8
do $$
declare t uuid; i int; n int;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Group Cup', 'group-cup', 'football-1v1', 'groups_knockout', 12, now() + interval '2 days');
  perform set_tournament_status(t, 'open');
  for i in 1..12 loop insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('g' || i)); end loop;
  perform pg_temp.ok((select status from tournaments where id = t) = 'planning', 'full: draft prepared');
  perform publish_tournament(t);
  perform pg_temp.ok((select count(distinct group_no) from tournament_entries where tournament_id = t) = 3, '3 groups');
  perform pg_temp.ok((select bool_and(c = 4) from (select count(*) c from tournament_entries where tournament_id = t group by group_no) q), 'groups of 4');
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'group') = 18, '6 matches per group');
  perform pg_temp.ok((select count(*) from fixtures f where f.tournament_id = t and f.stage = 'group' and
        (select group_no from tournament_entries where tournament_id = t and user_id = f.player_a_id) <> f.group_no) = 0, 'players only meet their own group');
  for i in 1..3 loop perform pg_temp.play_round(t, 'group', i); end loop;
  perform pg_temp.ok((select count(*) from group_tables(t)) = 12, 'group tables cover everyone');
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'knockout') = 7, 'bracket of 8 created after the groups');
  perform pg_temp.ok((select count(distinct x) from fixtures, unnest(array[player_a_id, player_b_id]) x where tournament_id = t and stage = 'knockout' and round = 1) = 8, '8 different qualifiers');
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'not_qualified') = 4, 'the 4 who did not qualify are told');
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'knockout' and round = 1 and scheduled_at is not null) = 4, 'knockout round 1 is timed automatically');
  -- group winners all go through
  perform pg_temp.ok((select bool_and(exists (select 1 from fixtures f where f.tournament_id = t and f.stage = 'knockout' and f.round = 1 and gt.user_id in (f.player_a_id, f.player_b_id)))
                      from group_tables(t) gt where gt.rank = 1), 'every group winner qualifies');
end $$;

-- 9 players: 3 groups of 3 (everyone plays 2 group matches); 20 players: 5 groups -> winners + 3 best runners-up
do $$
declare t uuid; i int;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Group Nine', 'group-nine', 'football-1v1', 'groups_knockout', 9);
  perform set_tournament_status(t, 'open');
  for i in 1..9 loop insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('g' || i)); end loop;
  perform publish_tournament(t);
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'group') = 9, '3 groups of 3 = 9 matches');
  for i in 1..3 loop perform pg_temp.play_round(t, 'group', i); end loop;
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'knockout') = 7, '3 groups: 6 + 2 best thirds = bracket of 8');

  t := create_tournament('Group Twenty', 'group-twenty', 'football-1v1', 'groups_knockout', 20);
  perform set_tournament_status(t, 'open');
  for i in 1..20 loop insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('g' || i)); end loop;
  perform publish_tournament(t);
  perform pg_temp.ok((select count(distinct group_no) from tournament_entries where tournament_id = t) = 5, '20 players: 5 groups');
  for i in 1..3 loop perform pg_temp.play_round(t, 'group', i); end loop;
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'knockout') = 7, '5 groups: winners + 3 best runners-up = bracket of 8');
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'not_qualified') = 12, 'the other 12 are told');
end $$;

-- league phase (Swiss): 10 players, 6 rounds, then play-offs (3v6, 4v5), then semi-finals with 1 and 2
do $$
declare t uuid; i int; r int; rep int;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Phase Cup', 'phase-cup', 'football-1v1', 'league_phase', 10, now() + interval '2 days');
  perform set_tournament_status(t, 'open');
  for i in 1..10 loop insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('g' || i)); end loop;
  perform publish_tournament(t);
  perform pg_temp.ok((select phase_rounds from tournaments where id = t) = 6, '10 players: 6 league-phase rounds');
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'league') = 5, 'only round 1 is paired at first');
  for r in 1..6 loop
    perform pg_temp.ok((select count(distinct x) from fixtures, unnest(array[player_a_id, player_b_id]) x where tournament_id = t and stage = 'league' and round = r) = 10, 'round ' || r || ': everyone plays once');
    perform pg_temp.play_round(t, 'league', r);
  end loop;
  select count(*) into rep from (select least(player_a_id, player_b_id), greatest(player_a_id, player_b_id) from fixtures
     where tournament_id = t and stage = 'league' group by 1, 2 having count(*) > 1) q;
  perform pg_temp.ok(rep = 0, 'no rematches in the league phase (got ' || rep || ')');
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'playoff') = 2, 'play-off round: ranks 3-6');
  perform pg_temp.ok((select player_a_id from fixtures where tournament_id = t and stage = 'playoff' and slot = 1) = (select user_id from league_table(t) where rank = 3)
                 and (select player_b_id from fixtures where tournament_id = t and stage = 'playoff' and slot = 1) = (select user_id from league_table(t) where rank = 6), '3rd plays 6th');
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'not_qualified') = 4, 'ranks 7-10 are told they are out');
  perform pg_temp.play_round(t, 'playoff', 1);
  perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'knockout') = 3, 'semi-finals and final created after the play-offs');
  perform pg_temp.ok((select count(*) from fixtures f where f.tournament_id = t and f.stage = 'knockout' and f.round = 1
                      and ((select user_id from league_table(t) where rank = 1) in (f.player_a_id, f.player_b_id)
                        or (select user_id from league_table(t) where rank = 2) in (f.player_a_id, f.player_b_id))) = 2, 'the top 2 qualified directly, in different semi-finals');
  perform pg_temp.ok((select count(*) from notifications where tournament_id = t and kind = 'knocked_out') = 2, 'play-off losers are knocked out');
  perform pg_temp.play_round(t, 'knockout', 1);
  perform pg_temp.play_round(t, 'knockout', 2);
  perform pg_temp.ok((select status from tournaments where id = t) = 'completed', 'league-phase tournament completes');
end $$;

-- league phase with an odd number of players: one bye per round, never twice for the same player
do $$
declare t uuid; i int; r int;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Phase Nine', 'phase-nine', 'football-1v1', 'league_phase', 9);
  perform set_tournament_status(t, 'open');
  for i in 1..9 loop insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('g' || i)); end loop;
  perform publish_tournament(t);
  for r in 1..(select phase_rounds from tournaments where id = t) loop
    perform pg_temp.ok((select count(*) from fixtures where tournament_id = t and stage = 'league' and round = r and status = 'bye') = 1, 'round ' || r || ': one bye');
    perform pg_temp.play_round(t, 'league', r);
  end loop;
  perform pg_temp.ok((select max(c) from (select count(*) c from fixtures where tournament_id = t and status = 'bye' group by player_a_id) q) = 1, 'nobody gets two byes');
  perform pg_temp.ok((select won from league_table(t) lt join fixtures f on f.player_a_id = lt.user_id and f.status = 'bye' and f.tournament_id = t limit 1) >= 1, 'a bye counts as a win');
end $$;

-- schedule speeds
do $$
declare t uuid; i int; r1 timestamptz; r2 timestamptz; fin timestamptz;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Fast League', 'fast-league', 'football-1v1', 'league', 8, now() + interval '2 days');
  perform pg_temp.ok((update_tournament(t, '{"schedule_speed":"fast"}'::jsonb) ->> 'ok')::boolean, 'speed set to fast');
  perform pg_temp.ok((select round_gap_hours from tournaments where id = t) = 24, 'fast = 24 hours between rounds');
  perform pg_temp.ok(update_tournament(t, '{"schedule_speed":"turbo"}'::jsonb) ->> 'reason' = 'unknown_speed', 'unknown speed rejected');
  perform set_tournament_status(t, 'open');
  for i in 1..4 loop insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('g' || i)); end loop;
  perform generate_tournament(t);
  select min(scheduled_at) into r1 from fixtures where tournament_id = t and round = 1;
  select min(scheduled_at) into r2 from fixtures where tournament_id = t and round = 2;
  perform pg_temp.ok(r2 - r1 = interval '24 hours', 'rounds 24 hours apart');

  t := create_tournament('One Day Cup', 'one-day-cup', 'football-1v1', 'knockout', 4, now() + interval '2 hours');
  perform update_tournament(t, '{"schedule_speed":"oneday"}'::jsonb);
  perform set_tournament_status(t, 'open');
  for i in 1..4 loop insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('g' || i)); end loop;
  perform publish_tournament(t);
  select min(scheduled_at) into r1 from fixtures where tournament_id = t and round = 1;
  perform pg_temp.ok(abs(extract(epoch from r1 - (select starts_at from tournaments where id = t))) < 1, 'one-day: round 1 at the start time (not moved to 18:00)');
  perform pg_temp.play_round(t, 'knockout', 1);
  select scheduled_at into fin from fixtures where tournament_id = t and round = 2;
  perform pg_temp.ok(fin - r1 = interval '45 minutes', 'one-day: next round 45 minutes later');
end $$;

-- match rules per stage: group draws are results; a level play-off needs penalties
do $$
declare t uuid; f fixtures; i int; r jsonb;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Rule Groups', 'rule-groups', 'football-1v1', 'groups_knockout', 8);
  perform set_tournament_status(t, 'open');
  for i in 1..8 loop insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('g' || i)); end loop;
  perform publish_tournament(t);
  select * into f from fixtures where tournament_id = t and stage = 'group' limit 1;
  update fixtures set kickoff_at = now(), status = 'active' where id = f.id;
  perform pg_temp.terminal(f.id, f.player_a_id, 'result', 1, 1, null, null, 5400);
  perform pg_temp.terminal(f.id, f.player_b_id, 'result', 1, 1, null, null, 5400);
  r := _finalize(f.id, null);
  perform pg_temp.ok(r ->> 'outcome' = 'draw', 'a group-stage draw is a result');
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, kickoff_at)
  values (t, 'playoff', 1, 1, f.player_a_id, f.player_b_id, 'active', now()) returning * into f;
  perform pg_temp.terminal(f.id, f.player_a_id, 'result', 1, 1, null, null, 5400);
  perform pg_temp.terminal(f.id, f.player_b_id, 'result', 1, 1, null, null, 5400);
  perform pg_temp.ok(_finalize(f.id, null) ->> 'status' = 'disputed', 'a level play-off without penalties goes to review');
end $$;


-- ============================================================ statistics (0011)
do $$
declare t uuid; a uuid := pg_temp.u('g11'); b uuid := pg_temp.u('g12'); c uuid := pg_temp.u('g13'); d uuid := pg_temp.u('g14');
begin
  -- league + knockout, top 2 advance, 3 rounds; after 2 rounds A and B have 6 points, C and D none
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Race Cup', 'race-cup', 'football-1v1', 'league_knockout', 8, null, null, 2);
  update tournaments set status = 'live' where id = t;
  insert into tournament_entries (tournament_id, user_id) values (t, a), (t, b), (t, c), (t, d);
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, score_a, score_b, winner_id, outcome, completed_at) values
    (t, 'league', 1, 1, a, c, 'completed', 1, 0, a, 'win_by_score', now() - interval '2 days'),
    (t, 'league', 1, 2, b, d, 'completed', 2, 0, b, 'win_by_score', now() - interval '2 days'),
    (t, 'league', 2, 1, a, d, 'completed', 3, 1, a, 'win_by_score', now() - interval '1 day'),
    (t, 'league', 2, 2, b, c, 'completed', 1, 0, b, 'win_by_score', now() - interval '1 day');
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, scheduled_at) values
    (t, 'league', 3, 1, a, b, 'scheduled', now() + interval '1 day'), (t, 'league', 3, 2, c, d, 'scheduled', now() + interval '1 day');
  perform pg_temp.ok((select status from player_stats(t) where user_id = a) = 'qualified', 'A is mathematically through (only B can still catch A)');
  perform pg_temp.ok((select status from player_stats(t) where user_id = c) = 'eliminated', 'C cannot reach the top 2 any more');
  perform pg_temp.ok((select remaining || '/' || max_points || '/' || form from player_stats(t) where user_id = a) = '1/9/WW', 'matches left, best possible points, form');
  perform pg_temp.ok((select next_opponent from player_stats(t) where user_id = a) is not null, 'next opponent shown');

  -- the title race of a plain league: nothing is "certain" too early
  t := create_tournament('Title Race', 'title-race', 'football-1v1', 'league', 8);
  update tournaments set status = 'live' where id = t;
  insert into tournament_entries (tournament_id, user_id) values (t, a), (t, b), (t, c), (t, d);
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, score_a, score_b, winner_id, outcome, completed_at) values
    (t, 'league', 1, 1, a, b, 'completed', 1, 0, a, 'win_by_score', now() - interval '2 days'),
    (t, 'league', 1, 2, c, d, 'completed', 1, 0, c, 'win_by_score', now() - interval '2 days'),
    (t, 'league', 2, 1, a, c, 'completed', 2, 0, a, 'win_by_score', now() - interval '1 day'),
    (t, 'league', 2, 2, b, d, 'completed', 1, 0, b, 'win_by_score', now() - interval '1 day');
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, scheduled_at) values
    (t, 'league', 3, 1, a, d, 'scheduled', now() + interval '1 day'), (t, 'league', 3, 2, b, c, 'scheduled', now() + interval '1 day');
  -- A 6, B 3, C 3, D 0 with one match each left: A needs 1 point to be sure of the title
  perform pg_temp.ok((select status from player_stats(t) where user_id = a) = 'in_race', 'A not yet certain');
  perform pg_temp.ok((select needs from player_stats(t) where user_id = a) = 1 and (select can_secure from player_stats(t) where user_id = a), 'A needs 1 point and can do it alone');
  perform pg_temp.ok((select status from player_stats(t) where user_id = d) = 'eliminated', 'D cannot win the league');
  perform pg_temp.ok((select status from player_stats(t) where user_id = b) = 'in_race' and not (select can_secure from player_stats(t) where user_id = b), 'B can still win, but needs help');
end $$;

-- knockout statuses and the finished tournament
do $$
declare t uuid; r record; champ uuid;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Stat Cup', 'stat-cup', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('g11')), (t, pg_temp.u('g12')), (t, pg_temp.u('g13')), (t, pg_temp.u('g14'));
  perform publish_tournament(t);
  perform pg_temp.ok((select count(*) from player_stats(t) where status = 'in') = 4, 'everyone is "still in" at the start of a knockout');
  perform pg_temp.play_round(t, 'knockout', 1);
  perform pg_temp.ok((select count(*) from player_stats(t) where status = 'eliminated') = 2 and (select count(*) from player_stats(t) where status = 'in') = 2, 'semi-final losers are out');
  perform pg_temp.play_round(t, 'knockout', 2);
  select champion_id into champ from tournaments where id = t;
  perform pg_temp.ok((select status from player_stats(t) where user_id = champ) = 'champion', 'champion status');
  perform pg_temp.ok((select count(*) from player_stats(t) where status = 'finished') = 3, 'everyone else finished');
  perform pg_temp.ok(((career_stats(champ)) ->> 'titles')::int >= 1 and ((career_stats(champ)) ->> 'won')::int >= 2, 'career numbers count titles and wins');
end $$;

-- footballer leaderboards: cross-checked goals, the same star for two teams, misreads ignored
do $$
declare t uuid; f1 fixtures; f2 fixtures; a uuid := pg_temp.u('g15'); b uuid := pg_temp.u('g16'); r jsonb; blocked boolean := false;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Scorer Cup', 'scorer-cup', 'football-1v1', 'league', 8);
  update tournaments set status = 'live' where id = t;
  insert into tournament_entries (tournament_id, user_id) values (t, a), (t, b);
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, kickoff_at) values
    (t, 'league', 1, 1, a, b, 'active', now()) returning * into f1;
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, kickoff_at) values
    (t, 'league', 2, 1, b, a, 'active', now()) returning * into f2;

  -- match 1, A wins 2-1. Reports arrive before the result is settled.
  perform pg_temp.as_user(a);
  r := submit_match_report(f1.id, '{"my_team":"DREAM FC","opp_team":"HARMOU",
    "goals":[{"player":"Messi","minute":12,"team":"me"},{"player":"Messi","minute":70,"team":"me","pen":true},{"player":"Haaland","minute":40,"team":"opp"}],
    "assists":[{"player":"Pedri","minute":12,"team":"me"}],
    "potm":{"player":"Messi","team":"me","rating":"8.9"}}'::jsonb);
  perform pg_temp.ok((r ->> 'ok')::boolean, 'report stored');
  -- B's phone misread one of A's goals: its list for DREAM FC does not match the official score
  perform pg_temp.as_user(b);
  perform submit_match_report(f1.id, '{"my_team":"HARMOU","opp_team":"DREAM FC",
    "goals":[{"player":"Messl","minute":12,"team":"opp"},{"player":"Haaland","minute":40,"team":"me"}],
    "potm":{"player":"Messi","team":"opp","rating":"8.9"}}'::jsonb);
  perform pg_temp.terminal(f1.id, a, 'result', 2, 1, null, null, 5400);
  perform pg_temp.terminal(f1.id, b, 'result', 1, 2, null, null, 5400);
  perform _finalize(f1.id, null);
  perform pg_temp.ok((select team_a || ' v ' || team_b from fixtures where id = f1.id) = 'DREAM FC v HARMOU', 'team names recorded');
  perform pg_temp.ok((select total from footballer_leaders(t, 'goal') where footballer = 'Messi' and team_name = 'DREAM FC') = 2, 'Messi (DREAM FC): 2 goals, taken from the report that matches the score');
  perform pg_temp.ok((select pens from footballer_leaders(t, 'goal') where team_name = 'DREAM FC') = 1, 'penalty goals counted');
  perform pg_temp.ok(not exists (select 1 from footballer_leaders(t, 'goal') where footballer = 'Messl'), 'the misread name is not counted');
  perform pg_temp.ok((select total from footballer_leaders(t, 'assist') where footballer = 'Pedri') = 1, 'assists counted');
  perform pg_temp.ok((select avg_rating from footballer_leaders(t, 'potm') where footballer = 'Messi') = 8.9, 'player of the match with rating');

  -- match 2: B (HARMOU) also fields Messi. He must appear separately: "Messi (HARMOU)"
  perform pg_temp.as_user(b);
  perform submit_match_report(f2.id, '{"my_team":"HARMOU","opp_team":"DREAM FC","goals":[{"player":"Messi","minute":30,"team":"me"}]}'::jsonb);
  perform pg_temp.terminal(f2.id, b, 'result', 1, 0, null, null, 5400);
  perform pg_temp.terminal(f2.id, a, 'result', 0, 1, null, null, 5400);
  perform _finalize(f2.id, null);
  perform pg_temp.ok((select count(*) from footballer_leaders(t, 'goal') where footballer = 'Messi') = 2, 'same footballer, two teams, two separate rows');
  perform pg_temp.ok((select total from footballer_leaders(t, 'goal') where footballer = 'Messi' and team_name = 'HARMOU') = 1, 'Messi (HARMOU): 1 goal');

  -- a report arriving after the result is processed too, through the app's match pass
  -- and a report cannot be rewritten later
  perform pg_temp.as_user(a);
  r := submit_match_report(f2.id, '{"my_team":"DREAM FC","opp_team":"HARMOU","goals":[{"player":"Messi","minute":30,"team":"opp"}]}'::jsonb);
  perform pg_temp.ok((r ->> 'ok')::boolean, 'late report accepted');
  perform submit_match_report(f2.id, '{"my_team":"DREAM FC","opp_team":"HARMOU","goals":[{"player":"Fake","minute":1,"team":"opp"}]}'::jsonb);
  perform pg_temp.ok(not exists (select 1 from footballer_leaders(t, 'goal') where footballer = 'Fake'), 'a second report from the same phone is ignored');
  perform pg_temp.ok(submit_match_report(f2.id, '"not an object"'::jsonb) ->> 'reason' = 'bad_report', 'malformed report rejected');
  perform pg_temp.as_user(pg_temp.u('p5'));
  perform pg_temp.ok(submit_match_report(f2.id, '{}'::jsonb) ->> 'reason' = 'not_a_participant', 'outsiders cannot report');
  perform pg_temp.ok(submit_match_report_pass('nope', '{}'::jsonb) ->> 'reason' = 'invalid_pass', 'app reports need a valid pass');
  perform pg_temp.ok((career_stats(a) ->> 'goals')::int = 2, 'career goals count the footballers of my team');

  set local role authenticated;
  begin perform 1 from match_reports limit 1; exception when insufficient_privilege then blocked := true; end;
  reset role;
  perform pg_temp.ok(blocked, 'raw reports are private');
end $$;


-- ============================================================ 0012: team names, app support, rankings, player pages
do $$
declare t uuid; fx fixtures; r jsonb; code text; pass text; a uuid := pg_temp.u('g17'); b uuid := pg_temp.u('g18'); v timestamptz;
begin
  -- team names (the app uses them to know which side of the screen is yours)
  perform pg_temp.as_user(a);
  perform pg_temp.ok(set_my_team_name('x') ->> 'reason' = 'bad_name', 'team name too short rejected');
  perform pg_temp.ok(set_my_team_name('  dream   fc ') ->> 'team_name' = 'DREAM FC', 'team name cleaned and saved');
  perform pg_temp.ok(my_profile() ->> 'team_name' = 'DREAM FC', 'my profile shows the team name');

  -- the app's handoff now carries the tournament, both team names; the profile rules are available with the pass
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('App Cup', 'app-cup', 'football-1v1', 'knockout', 2);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, a), (t, b);
  perform publish_tournament(t);
  select * into fx from fixtures where tournament_id = t;
  update fixtures set scheduled_at = now() + interval '60 seconds' where id = fx.id;
  perform pg_temp.as_user(a);
  code := create_app_handoff(fx.id) ->> 'code';
  perform pg_temp.as_user(null);
  r := redeem_app_handoff(code);
  pass := r ->> 'pass';
  perform pg_temp.ok((r ->> 'tournament_id')::uuid = t and r ->> 'my_team' = 'DREAM FC' and r ? 'opp_team', 'handoff carries tournament and team names');
  perform pg_temp.ok((set_team_name_pass(pass, 'harmou fc') ->> 'ok')::boolean, 'app can set the team name with its pass');
  perform pg_temp.ok((select team_name from profiles where id = a) = 'HARMOU FC', 'team name saved from the app');
  perform pg_temp.ok((game_profile_pass(pass) -> 'profile' ->> 'version')::int >= 1, 'screen-reading rules come from the server');
  perform pg_temp.ok(game_profile_pass('nope') ->> 'reason' = 'invalid_pass', 'rules need a valid pass');

  -- kickoff works even if the clock cannot be read
  perform pg_temp.as_user(a); perform submit_screen_state(fx.id, 'in_play', 0, 0, null, null, null, 1);
  perform pg_temp.as_user(b); perform submit_screen_state(fx.id, 'in_play', 0, 0, null, null, null, 1);
  update match_latest_state set in_play_since = now() - interval '8 seconds' where fixture_id = fx.id;
  r := submit_screen_state(fx.id, 'in_play', 0, 0, null, null, null, 2);
  perform pg_temp.ok((r ->> 'kickoff_ready')::boolean, 'kickoff without a readable clock');

end $$;

-- rankings and public player pages
do $$
declare r jsonb; top uuid;
begin
  perform pg_temp.ok((select count(*) from rankings(500, null)) > 0, 'rankings list players with matches');
  select user_id into top from rankings(1, null);
  perform pg_temp.ok((select titles from rankings(500, null) where user_id = top) >= (select max(titles) from rankings(500, null)), 'most titles ranks first');
  perform pg_temp.ok((select count(*) from rankings(500, 'gplayer1')) >= 1 and (select bool_and(username ilike '%gplayer1%') from rankings(500, 'gplayer1')), 'search by name');
  r := public_player((select username from profiles where id = top));
  perform pg_temp.ok((r ->> 'ok')::boolean and r ? 'career' and jsonb_array_length(r -> 'recent') > 0 and (r ->> 'rank')::int = 1, 'player page: career, recent results, rank');
  perform pg_temp.ok(public_player('nobody_here') ->> 'reason' = 'not_found', 'unknown player');
end $$;

-- ============================================================ existing accounts, no age gate
do $$
declare t uuid; r jsonb; v int;
begin
  -- an account that predates the schema gets a profile
  delete from profiles where id = pg_temp.u('p6');
  v := _backfill_profiles();
  perform pg_temp.ok(v = 1, 'backfill creates the missing profile');
  perform pg_temp.ok((select username from profiles where id = pg_temp.u('p6')) = 'playerp6', 'backfilled profile gets a valid username');
  perform pg_temp.ok(_backfill_profiles() = 0, 'backfill is idempotent');

  -- there is no age confirmation any more
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup Age', 'cup-age', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  perform pg_temp.as_user(pg_temp.u('minor'));
  r := register_for_tournament(t);
  perform pg_temp.ok((r ->> 'ok')::boolean, 'registration needs no age confirmation');
  perform pg_temp.ok(to_regprocedure('public.confirm_age()') is null, 'confirm_age no longer exists');
end $$;

-- ============================================================ room code format (3-5, letters and digits)
do $$
declare i int; c text; n int;
begin
  for n in 3..5 loop
    for i in 1..300 loop
      c := _gen_room_code(n);
      perform pg_temp.ok(length(c) = n, 'code length is ' || n);
      perform pg_temp.ok(c ~ '^[a-z2-9]+$' and c ~ '[a-z]' and c ~ '[2-9]', 'code has letters and digits only, both present: ' || c);
    end loop;
  end loop;
  perform pg_temp.ok(length(_gen_room_code(9)) = 5 and length(_gen_room_code(1)) = 3, 'requested length is clamped to 3..5');
  perform pg_temp.ok((select room_code_model from games where slug = 'football-1v1') = 'platform_issued', 'game ships as platform-issued');
end $$;

-- ============================================================ web -> app handoff and match pass
do $$
declare
  t uuid; fx fixtures; a uuid; b uuid; f uuid; r jsonb; ca text; cb text; pass_a text; pass_b text; blocked boolean;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup Handoff', 'cup-handoff', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2'));
  perform generate_tournament(t); perform publish_tournament(t);
  select * into fx from fixtures where tournament_id = t; f := fx.id; a := fx.player_a_id; b := fx.player_b_id;
  perform schedule_fixtures(t, 'knockout', 1, now() + interval '1 hour', 30);

  perform pg_temp.as_user(a);
  perform pg_temp.ok(create_app_handoff(f) ->> 'reason' = 'too_early', 'no handoff before the room opens');
  update fixtures set scheduled_at = now() + interval '90 seconds' where id = f;

  perform pg_temp.as_user(pg_temp.u('p5'));
  perform pg_temp.ok(create_app_handoff(f) ->> 'reason' = 'not_a_participant', 'outsider cannot get a handoff');
  perform pg_temp.as_user(null);
  perform pg_temp.ok(create_app_handoff(f) ->> 'reason' = 'not_a_participant', 'signed-out visitor cannot get a handoff');

  perform pg_temp.as_user(a);  r := create_app_handoff(f);  ca := r ->> 'code';
  perform pg_temp.ok((r ->> 'ok')::boolean and length(ca) = 24 and (r ->> 'expires_in')::int = 60, 'handoff code issued: 24 chars, 60 s');
  perform pg_temp.as_user(b);  r := create_app_handoff(f);  cb := r ->> 'code';
  perform pg_temp.ok((select count(*) from app_handoffs where code_hash = ca or code_hash = cb) = 0, 'plain codes are never stored');

  -- the app has no login: redeem as anonymous
  perform pg_temp.as_user(null);
  r := redeem_app_handoff('not-a-real-code');
  perform pg_temp.ok(r ->> 'reason' = 'invalid_or_expired', 'unknown code rejected');
  r := redeem_app_handoff(ca);
  perform pg_temp.ok((r ->> 'ok')::boolean and r ->> 'my_side' = 'A' and length(r ->> 'pass') = 64, 'code redeemed for a pass');
  pass_a := r ->> 'pass';
  perform pg_temp.ok((r ->> 'regulation_seconds')::int = 5400, 'app learns the match clock settings');
  perform pg_temp.ok(redeem_app_handoff(ca) ->> 'reason' = 'invalid_or_expired', 'a code works only once');
  pass_b := redeem_app_handoff(cb) ->> 'pass';
  perform pg_temp.ok(pass_b is not null and pass_b <> pass_a, 'second player gets their own pass');

  -- expired code
  perform pg_temp.as_user(a);  r := create_app_handoff(f);
  update app_handoffs set expires_at = now() - interval '1 second' where used_at is null;
  perform pg_temp.as_user(null);
  perform pg_temp.ok(redeem_app_handoff(r ->> 'code') ->> 'reason' = 'invalid_or_expired', 'expired code rejected');

  -- the pass reports state for its own player and fixture only
  perform pg_temp.ok(submit_screen_state_pass('bad', 'in_play', 0, 0, null, null, 3, 1) ->> 'reason' = 'invalid_pass', 'bad pass rejected');
  r := submit_screen_state_pass(pass_a, 'in_play', 0, 0, null, null, 5, 1);
  perform pg_temp.ok((r ->> 'ok')::boolean, 'pass can report state');
  perform pg_temp.ok((select layout from match_latest_state where fixture_id = f and user_id = a) = 'in_play', 'state stored for the pass holder');
  perform submit_screen_state_pass(pass_b, 'in_play', 0, 0, null, null, 6, 1);
  update match_latest_state set in_play_since = now() - interval '9 seconds' where fixture_id = f;
  r := submit_screen_state_pass(pass_a, 'in_play', 0, 0, null, null, 12, 2);
  perform pg_temp.ok((r ->> 'kickoff_ready')::boolean, 'kickoff works through passes');

  -- finish the match through passes only (A wins 2-1), then each sees their own view
  perform submit_screen_state_pass(pass_a, 'result', 2, 1, null, null, 5400, 3);
  perform submit_screen_state_pass(pass_b, 'result', 1, 2, null, null, 5400, 3);
  r := finalize_fixture_pass(pass_b);
  perform pg_temp.ok(r ->> 'status' = 'completed' and (r ->> 'winner_id')::uuid = a, 'result finalized through a pass');
  r := match_status_pass(pass_a);
  perform pg_temp.ok((r ->> 'winner_is_me')::boolean and (r ->> 'score_me')::int = 2 and (r ->> 'score_opp')::int = 1, 'winner sees 2-1 and "winner"');
  r := match_status_pass(pass_b);
  perform pg_temp.ok(not (r ->> 'winner_is_me')::boolean and (r ->> 'score_me')::int = 1 and (r ->> 'score_opp')::int = 2, 'loser sees 1-2 and "not winner"');

  -- a pass only reaches its own fixture's state
  perform pg_temp.ok(not exists (select 1 from match_latest_state where fixture_id <> f and user_id in (a, b) and client_seq = 3 and layout = 'result' and t_score_me = 2), 'pass cannot write to other fixtures');

  -- permissions
  blocked := false; set local role anon;
  begin perform public._pass('x'); exception when insufficient_privilege then blocked := true; end;
  reset role;
  perform pg_temp.ok(blocked, 'internal pass lookup is not callable by API roles');
  blocked := false; set local role authenticated;
  begin perform 1 from app_handoffs limit 1; exception when insufficient_privilege then blocked := true; end;
  reset role;
  perform pg_temp.ok(blocked, 'handoff table is unreachable by API roles');
  blocked := false; set local role anon;
  begin perform public.create_app_handoff(f); exception when insufficient_privilege then blocked := true; end;
  reset role;
  perform pg_temp.ok(blocked, 'only signed-in players can create a handoff');
  blocked := false; set local role anon;
  begin perform public._submit_screen_state(a, f, 'in_play', 0, 0, null, null, 1, 99, null); exception when insufficient_privilege then blocked := true; end;
  reset role;
  perform pg_temp.ok(blocked, 'the internal submit function cannot be called with a chosen user id');
end $$;

do $$ begin
  perform pg_temp.ok(has_table_privilege('service_role', 'public.notifications', 'SELECT')
                 and has_table_privilege('service_role', 'public.push_subscriptions', 'DELETE'), 'server functions can read notifications and remove dead phones');
  perform pg_temp.ok(not has_table_privilege('anon', 'public.push_subscriptions', 'SELECT'), 'visitors still cannot');
end $$;

select 'database tests: all assertions passed' as result;
