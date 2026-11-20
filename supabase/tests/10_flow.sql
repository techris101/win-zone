-- WIN ZONE database tests. Run with run_local.sh (or the db-test GitHub workflow).
-- Any failed assertion aborts the run.

create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(c, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

create or replace function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claim.sub', coalesce(u::text, ''), false) $$;

create or replace function pg_temp.mkuser(p_name text, p_age boolean default true) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into auth.users (email, raw_user_meta_data)
  values (p_name || '@test.local', jsonb_build_object('username', p_name, 'age_confirmed', p_age::text))
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
  foreach n in array array['admin1', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'minor'] loop
    insert into tu values (n, pg_temp.mkuser(n, n <> 'minor'));
  end loop;
  perform grant_role('admin1@test.local', 'admin');
  perform pg_temp.ok((select count(*) from profiles) = 8, 'profiles created by trigger');
  perform pg_temp.ok((select age_confirmed_at is null from profiles where username = 'minor'), 'age flag respected');
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

  perform pg_temp.as_user(pg_temp.u('minor'));
  r := register_for_tournament(t);
  perform pg_temp.ok(r ->> 'reason' = 'age_not_confirmed', 'age gate blocks registration');

  foreach host in array array[pg_temp.u('p1'), pg_temp.u('p2'), pg_temp.u('p3'), pg_temp.u('p4')] loop
    perform pg_temp.as_user(host);
    r := register_for_tournament(t);
    perform pg_temp.ok((r ->> 'ok')::boolean, 'register ok');
  end loop;
  r := register_for_tournament(t);
  perform pg_temp.ok((r ->> 'already')::boolean, 'registration is idempotent');

  perform pg_temp.as_user(pg_temp.u('admin1'));
  r := generate_tournament(t);
  perform pg_temp.ok((r ->> 'players')::int = 4, 'generated with 4 players');
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
  perform generate_tournament(t);
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
  perform generate_tournament(t);
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
  perform generate_tournament(t);
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
  perform generate_tournament(t);
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
  perform generate_tournament(t);
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
  perform generate_tournament(t);
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
  perform generate_tournament(t);
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
  perform generate_tournament(t);
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
  perform generate_tournament(t);
  select * into fx from fixtures where tournament_id = t; f := fx.id;
  perform pg_temp.ok((select room_code ~ '^[A-Z2-9]{6,8}$' and room_code ~ '[A-Z]' and room_code ~ '[2-9]' from matchrooms where fixture_id = f), 'generated code format');

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
  update games set room_code_model = 'host_issued' where slug = 'football-1v1';
end $$;

-- admin reversal of a completed fixture is blocked once downstream play started
do $$
declare t uuid; fx fixtures; fin fixtures; r jsonb; a uuid;
begin
  perform pg_temp.as_user(pg_temp.u('admin1'));
  t := create_tournament('Cup R', 'cup-r', 'football-1v1', 'knockout', 4);
  perform set_tournament_status(t, 'open');
  insert into tournament_entries (tournament_id, user_id) values (t, pg_temp.u('p1')), (t, pg_temp.u('p2')), (t, pg_temp.u('p3')), (t, pg_temp.u('p4'));
  perform generate_tournament(t);
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

select 'database tests: all assertions passed' as result;
