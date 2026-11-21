-- WIN ZONE — tests for 0013: reports, suspensions, account deletion, evidence, responsible play, sponsors, demo mode.
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(c, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claim.sub', coalesce(u::text, ''), false) $$;
create or replace function pg_temp.mk(p_name text, p_country text default 'RW') returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into auth.users (email, raw_user_meta_data) values (p_name || '@safety.local', jsonb_build_object('username', p_name, 'country', p_country))
  returning id into v;
  return v;
end $$;

do $$
declare
  adm uuid; a uuid; b uuid; c uuid; d uuid; tid uuid; tid2 uuid; r jsonb; f fixtures; blocked boolean; n int; v_slug text; i int;
begin
  adm := pg_temp.mk('safe_admin'); a := pg_temp.mk('safe_a'); b := pg_temp.mk('safe_b'); c := pg_temp.mk('safe_c'); d := pg_temp.mk('safe_d');
  perform grant_role('safe_admin@safety.local', 'admin');
  -- grant_role needs an existing admin or service context in tests; make sure it took
  if not exists (select 1 from user_roles where user_id = adm and role = 'admin') then insert into user_roles values (adm, 'admin'); end if;

  -- an open tournament to register into
  perform pg_temp.as_user(adm);
  insert into tournaments (slug, name, game_id, format, size, status, created_by)
  values ('safety-cup', 'Safety Cup', (select id from games limit 1), 'knockout', 8, 'open', adm) returning id into tid;
  insert into tournaments (slug, name, game_id, format, size, status, created_by)
  values ('safety-cup-2', 'Safety Cup 2', (select id from games limit 1), 'knockout', 8, 'open', adm) returning id into tid2;

  -- ---------------------------------------------------------- reports
  perform pg_temp.as_user(a);
  r := report_player('safe_b', 'abuse', 'insults in chat');
  perform pg_temp.ok(r ->> 'ok' = 'true', 'a player can report another player');
  r := report_player('safe_b', 'abuse', 'again');
  perform pg_temp.ok((r ->> 'already')::boolean, 'a second open report on the same player is not duplicated');
  r := report_player('safe_a', 'other');
  perform pg_temp.ok(r ->> 'reason' = 'cannot_report_self', 'nobody can report themselves');
  r := report_player('nobody_here', 'other');
  perform pg_temp.ok(r ->> 'reason' = 'player_not_found', 'unknown player is refused');
  r := report_player('safe_c', 'shouting');
  perform pg_temp.ok(r ->> 'reason' = 'bad_reason', 'unknown reason is refused');
  blocked := false;
  begin perform list_reports('open'); exception when others then blocked := true; end;
  perform pg_temp.ok(blocked, 'players cannot list reports');
  perform pg_temp.ok((select count(*) from player_reports) = 1, 'one report stored');

  perform pg_temp.as_user(adm);
  r := list_reports('open');
  perform pg_temp.ok(jsonb_array_length(r) = 1 and r -> 0 ->> 'reported' = 'safe_b' and r -> 0 ->> 'reporter' = 'safe_a', 'admin sees the report with names');

  -- ---------------------------------------------------------- suspensions
  perform pg_temp.as_user(b);
  perform pg_temp.ok(register_for_tournament(tid) ->> 'ok' = 'true', 'b registers before the suspension');
  perform pg_temp.as_user(adm);
  r := ban_player('safe_b', 7, 'abuse');
  perform pg_temp.ok(r ->> 'ok' = 'true' and (r ->> 'left_tournaments')::int = 1, 'suspension removes the player from open tournaments');
  perform pg_temp.ok(ban_player('safe_admin', 7, 'x') ->> 'reason' = 'cannot_ban_self', 'an admin cannot suspend themselves');
  perform review_report((select id from player_reports limit 1), 'actioned');
  perform pg_temp.ok((select status from player_reports limit 1) = 'actioned', 'report marked as actioned');
  perform pg_temp.ok(jsonb_array_length(list_banned()) = 1, 'suspended list shows the player');
  perform pg_temp.as_user(b);
  r := register_for_tournament(tid);
  perform pg_temp.ok(r ->> 'reason' = 'account_suspended', 'a suspended player cannot register');
  perform pg_temp.ok(my_profile() ->> 'banned_until' is not null, 'the player sees the suspension on their page');
  perform pg_temp.ok(exists (select 1 from notifications where user_id = b and kind = 'account'), 'the player is told about the suspension');
  perform pg_temp.as_user(adm);
  perform unban_player('safe_b');
  perform pg_temp.as_user(b);
  perform pg_temp.ok(register_for_tournament(tid) ->> 'ok' = 'true', 'after lifting the suspension the player can register again');

  -- ---------------------------------------------------------- responsible play
  perform pg_temp.as_user(c);
  perform pg_temp.ok(set_play_limit(1) ->> 'ok' = 'true', 'a player can set a limit');
  perform pg_temp.ok(register_for_tournament(tid) ->> 'ok' = 'true', 'first tournament is fine');
  perform pg_temp.ok(register_for_tournament(tid2) ->> 'reason' = 'play_limit_reached', 'the limit stops a second tournament');
  perform set_play_limit(null);
  perform pg_temp.ok(take_break(400) ->> 'reason' = 'bad_days', 'only the offered break lengths are accepted');
  r := take_break(7);
  perform pg_temp.ok(r ->> 'ok' = 'true' and (r ->> 'left_tournaments')::int = 1, 'a break leaves open tournaments');
  perform pg_temp.ok(register_for_tournament(tid2) ->> 'reason' = 'on_break', 'no registration during a break');
  r := take_break(1);
  perform pg_temp.ok((select break_until from profiles where id = c) > now() + interval '6 days', 'a break cannot be shortened');

  perform pg_temp.as_user(a);
  blocked := false;
  begin perform set_country_blocked('RW', true); exception when others then blocked := true; end;
  perform pg_temp.ok(blocked, 'players cannot block countries');
  perform pg_temp.as_user(adm);
  perform set_country_blocked('KE', true);
  perform pg_temp.as_user(d);
  perform pg_temp.ok(set_my_country('KE') ->> 'reason' = 'country_not_available', 'a blocked country cannot be chosen');
  update profiles set country = 'KE' where id = d;   -- signed up before the block
  perform pg_temp.ok(register_for_tournament(tid2) ->> 'reason' = 'country_not_available', 'players from a blocked country cannot register');
  perform pg_temp.as_user(adm);
  perform set_country_blocked('KE', false);
  perform pg_temp.as_user(d);
  perform pg_temp.ok(register_for_tournament(tid2) ->> 'ok' = 'true', 'unblocking lets them register');

  -- ---------------------------------------------------------- dispute evidence
  perform pg_temp.as_user(adm);
  insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, status, completed_at)
  values (tid2, 'knockout', 9, 1, a, d, 'disputed', now()) returning * into f;
  perform pg_temp.as_user(a);
  insert into storage.objects (bucket_id, name) values ('evidence', f.id || '/' || a || '/shot1.png');
  r := add_dispute_evidence(f.id, f.id || '/' || a || '/shot1.png', 'final score screen');
  perform pg_temp.ok(r ->> 'ok' = 'true', 'a participant can attach a screenshot');
  perform pg_temp.ok(exists (select 1 from disputes where fixture_id = f.id and user_id = a and status = 'open'), 'adding evidence opens a dispute');
  r := add_dispute_evidence(f.id, f.id || '/' || d || '/shot1.png');
  perform pg_temp.ok(r ->> 'reason' = 'bad_path', 'files must be in the uploader''s own folder');
  r := add_dispute_evidence(f.id, f.id || '/' || a || '/missing.png');
  perform pg_temp.ok(r ->> 'reason' = 'file_not_uploaded', 'the file must really exist');
  perform pg_temp.as_user(b);
  r := add_dispute_evidence(f.id, f.id || '/' || b || '/x.png');
  perform pg_temp.ok(r ->> 'reason' = 'not_a_participant', 'outsiders cannot add evidence');
  perform pg_temp.ok(exists (select 1 from storage.buckets where id = 'evidence' and not public), 'evidence bucket is private');
  perform pg_temp.ok((select count(*) from pg_policies where schemaname = 'storage' and policyname like 'wz_%') = 5, 'file rules created');

  -- ---------------------------------------------------------- sponsors
  perform pg_temp.as_user(a);
  blocked := false;
  begin perform save_sponsor(null, 'X', null, null); exception when others then blocked := true; end;
  perform pg_temp.ok(blocked, 'players cannot add sponsors');
  perform pg_temp.as_user(adm);
  perform pg_temp.ok(save_sponsor(null, 'Bad', 'http://x', null) ->> 'reason' = 'links_must_start_with_https', 'sponsor links must be https');
  r := save_sponsor(null, 'Acme Mobile', 'https://example.com/logo.png', 'https://example.com', true, true);
  perform pg_temp.ok(r ->> 'ok' = 'true', 'admin adds a sponsor');
  perform set_sponsor_placement(tid, (r ->> 'id')::uuid, 'title', true);
  perform pg_temp.ok(exists (select 1 from sponsor_placements where tournament_id = tid and placement_type = 'title'), 'title sponsor placed');
  perform save_sponsor((r ->> 'id')::uuid, 'Acme Mobile', null, null, false, false);
  perform pg_temp.as_user(null);
  set local role anon;
  perform pg_temp.ok(not exists (select 1 from sponsors where name = 'Acme Mobile'), 'paused sponsors are hidden from visitors');
  reset role;

  -- ---------------------------------------------------------- demo mode
  perform pg_temp.as_user(a);
  blocked := false;
  begin perform create_demo_tournament('Demo', 8); exception when others then blocked := true; end;
  perform pg_temp.ok(blocked, 'players cannot create demos');
  perform pg_temp.as_user(adm);
  r := create_demo_tournament('Demo Knockout', 8, 'knockout');
  perform pg_temp.ok(r ->> 'ok' = 'true', 'admin creates a demo');
  select slug into v_slug from tournaments where id = (r ->> 'id')::uuid;
  perform pg_temp.ok((select status from tournaments where slug = v_slug) = 'live', 'demo goes live straight away');
  perform pg_temp.ok((select count(*) from tournament_entries e join profiles p on p.id = e.user_id where e.tournament_id = (r ->> 'id')::uuid and p.is_bot) = 8, 'demo is filled with 8 bots');
  perform pg_temp.as_user(a);
  perform pg_temp.ok(register_for_tournament((r ->> 'id')::uuid) ->> 'reason' = 'demo_tournament', 'real players cannot join a demo');
  -- play it to the end: bring every match forward and let the bots play
  for i in 1..10 loop
    update fixtures set scheduled_at = now() - interval '1 minute' where tournament_id = (r ->> 'id')::uuid and status = 'scheduled' and player_a_id is not null and player_b_id is not null;
    perform _play_demo();
  end loop;
  perform pg_temp.ok((select status from tournaments where id = (r ->> 'id')::uuid) = 'completed'
                     and (select champion_id from tournaments where id = (r ->> 'id')::uuid) is not null, 'bots play the demo to a champion');
  perform pg_temp.ok(not exists (select 1 from rankings(500, null) x join profiles p on p.id = x.user_id where p.is_bot), 'bots never appear in rankings');
  perform pg_temp.ok(not exists (select 1 from notifications nt join profiles p on p.id = nt.user_id where p.is_bot), 'bots get no notifications');
  perform pg_temp.as_user(adm);
  r := create_demo_tournament('Demo League', 6, 'league');
  for i in 1..12 loop
    update fixtures set scheduled_at = now() - interval '1 minute' where tournament_id = (r ->> 'id')::uuid and status = 'scheduled' and player_a_id is not null and player_b_id is not null;
    perform _play_demo();
  end loop;
  perform pg_temp.ok((select status from tournaments where id = (r ->> 'id')::uuid) = 'completed', 'a demo league also finishes');
  perform pg_temp.as_user(adm);
  perform pg_temp.ok(delete_demo_tournament((r ->> 'id')::uuid) ->> 'ok' = 'true', 'admin deletes a demo');
  perform pg_temp.ok(delete_demo_tournament(tid) ->> 'reason' = 'not_a_demo', 'real tournaments cannot be deleted this way');

  -- ---------------------------------------------------------- account deletion
  perform pg_temp.as_user(d);
  perform pg_temp.ok(delete_my_account('wrong') ->> 'reason' = 'confirm_username', 'deletion needs the username typed');
  r := delete_my_account('safe_d');
  perform pg_temp.ok(r ->> 'ok' = 'true', 'a player can delete their account');
  perform pg_temp.ok(not exists (select 1 from auth.users where id = d), 'the login is gone');
  perform pg_temp.ok((select username like 'deleted_%' and display_name = 'Deleted player' and country is null and deleted_at is not null from profiles where id = d),
                     'a player with match history stays only as an anonymous "Deleted player"');
  perform pg_temp.ok(not exists (select 1 from tournament_entries e join tournaments t on t.id = e.tournament_id where e.user_id = d and t.status = 'open'), 'and leaves open tournaments');
  perform pg_temp.ok((public_player((select username from profiles where id = d)) ->> 'ok') = 'false', 'deleted players have no public page');
  n := (select count(*) from profiles where id = b);
  perform pg_temp.as_user(b);
  update tournament_entries set status = 'withdrawn' where user_id = b;
  perform delete_my_account('SAFE_B');
  perform pg_temp.ok(not exists (select 1 from profiles where id = b) and n = 1, 'a player with no history is removed completely');
  perform pg_temp.as_user(adm);
end $$;

select 'safety tests: all assertions passed' as result;
