-- WIN ZONE — 0006 private-match codes, no age gate, one-tap app handoff
-- 1. Room codes match the game's Private Match: both players type the SAME code and press Search.
--    The server generates it: letters a-z and digits 0-9, always both, length 3-5 (default 5).
-- 2. The 18+ confirmation is removed.
-- 3. Web -> app handoff: the website gives a player a one-time 60-second code; the app swaps it for a
--    pass that works for ONE match and ONE player and can only report screen state. No second login,
--    and never a login token in a link.

-- ---------------------------------------------------------------- 1. room codes
alter table public.games add column if not exists room_code_length int not null default 5
  check (room_code_length between 3 and 5);
update public.games set room_code_model = 'platform_issued' where slug = 'football-1v1';

create or replace function public._gen_room_code(p_len int default 5) returns text
language plpgsql volatile as $$
declare
  c_all constant text := 'abcdefghjkmnpqrstuvwxyz23456789';   -- no i, l, o, 0, 1 (look-alikes)
  v_len int := least(5, greatest(3, coalesce(p_len, 5)));
  v_code text; v_try int := 0; v_bytes bytea; i int;
begin
  loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_code := '';
    for i in 0..(v_len - 1) loop
      v_code := v_code || substr(c_all, 1 + (get_byte(v_bytes, i) % length(c_all)), 1);
    end loop;
    if v_code ~ '[a-z]' and v_code ~ '[2-9]'
       and not exists (select 1 from matchrooms where room_code = v_code) then
      return v_code;
    end if;
    v_try := v_try + 1;
    if v_try > 50 then raise exception 'could not generate a unique room code'; end if;
  end loop;
end $$;

create or replace function public._ensure_matchroom(p_fixture_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_model text; v_len int;
begin
  select g.room_code_model, g.room_code_length into v_model, v_len
  from fixtures f join tournaments t on t.id = f.tournament_id join games g on g.id = t.game_id
  where f.id = p_fixture_id;

  insert into matchrooms (fixture_id, room_code, room_code_source)
  values (p_fixture_id,
          case when v_model = 'platform_issued' then _gen_room_code(v_len) end,
          case when v_model = 'platform_issued' then 'platform' end)
  on conflict (fixture_id) do nothing;
end $$;

create or replace function public.regenerate_room_code(p_fixture_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_model text; v_len int;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  select g.room_code_model, g.room_code_length into v_model, v_len
  from fixtures f join tournaments t on t.id = f.tournament_id join games g on g.id = t.game_id
  where f.id = p_fixture_id;
  if v_model <> 'platform_issued' then raise exception 'host-issued codes come from the host'; end if;
  update matchrooms set room_code = _gen_room_code(v_len), room_code_source = 'platform', room_code_submitted_at = now()
  where fixture_id = p_fixture_id;
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'regenerate_room_code', 'fixture', p_fixture_id);
  return jsonb_build_object('ok', true);
end $$;

drop function if exists public._gen_room_code();

-- ---------------------------------------------------------------- 2. no age gate
create or replace function public.register_for_tournament(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments; v_uid uuid := auth.uid(); v_count int;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  select * into t from tournaments where id = p_tid;
  if t.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if t.status <> 'open' then return jsonb_build_object('ok', false, 'reason', 'registration_closed'); end if;
  if t.registration_closes_at is not null and now() > t.registration_closes_at then
    return jsonb_build_object('ok', false, 'reason', 'registration_closed');
  end if;

  if exists (select 1 from tournament_entries where tournament_id = p_tid and user_id = v_uid and status <> 'withdrawn') then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  select count(*) into v_count from tournament_entries where tournament_id = p_tid and status <> 'withdrawn';
  if v_count >= t.size then return jsonb_build_object('ok', false, 'reason', 'tournament_full'); end if;

  insert into tournament_entries (tournament_id, user_id) values (p_tid, v_uid)
  on conflict (tournament_id, user_id) do update set status = 'registered';
  return jsonb_build_object('ok', true);
end $$;

drop function if exists public.confirm_age();

-- ---------------------------------------------------------------- 3. web -> app handoff
create table public.app_handoffs (
  id          uuid primary key default gen_random_uuid(),
  code_hash   text not null unique,
  user_id     uuid not null,
  fixture_id  uuid not null references public.fixtures (id) on delete cascade,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);
create table public.match_passes (
  id           uuid primary key default gen_random_uuid(),
  token_hash   text not null unique,
  user_id      uuid not null,
  fixture_id   uuid not null references public.fixtures (id) on delete cascade,
  expires_at   timestamptz not null,
  last_seen_at timestamptz,
  created_at   timestamptz not null default now()
);
create index app_handoffs_user_idx on public.app_handoffs (user_id, fixture_id);
create index match_passes_fixture_idx on public.match_passes (fixture_id, user_id);
alter table public.app_handoffs enable row level security;
alter table public.match_passes enable row level security;
revoke all on public.app_handoffs, public.match_passes from anon, authenticated;

create or replace function public._hash(p_text text) returns text
language sql immutable as $$ select encode(sha256(convert_to(p_text, 'UTF8')), 'hex') $$;

create or replace function public._random_token(p_bytes int default 16) returns text
language sql volatile as $$
  select substr(replace(gen_random_uuid()::text || gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 1, p_bytes * 2)
$$;

-- Called by the website (signed-in player) when they press "Play game".
create or replace function public.create_app_handoff(p_fixture_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); f fixtures; g games; v_code text; mr matchrooms;
begin
  select * into f from fixtures where id = p_fixture_id;
  if f.id is null or v_uid is null or v_uid not in (f.player_a_id, f.player_b_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_a_participant');
  end if;
  if f.status not in ('scheduled', 'active', 'stalled') then
    return jsonb_build_object('ok', false, 'reason', 'fixture_closed');
  end if;
  if f.scheduled_at is null then return jsonb_build_object('ok', false, 'reason', 'not_scheduled'); end if;
  select gm.* into g from tournaments t join games gm on gm.id = t.game_id where t.id = f.tournament_id;
  if now() < f.scheduled_at - make_interval(secs => g.reveal_buffer_seconds) then
    return jsonb_build_object('ok', false, 'reason', 'too_early');
  end if;
  select * into mr from matchrooms where fixture_id = f.id;
  if mr.room_code is null then return jsonb_build_object('ok', false, 'reason', 'waiting_for_code'); end if;

  delete from app_handoffs where user_id = v_uid and fixture_id = f.id and used_at is null;
  delete from app_handoffs where expires_at < now() - interval '1 day';
  v_code := _random_token(12);   -- 24 hex characters
  insert into app_handoffs (code_hash, user_id, fixture_id, expires_at)
  values (_hash(v_code), v_uid, f.id, now() + interval '60 seconds');
  return jsonb_build_object('ok', true, 'code', v_code, 'fixture_id', f.id, 'expires_in', 60);
end $$;

-- Called by the app (no login). Swaps a one-time code for a pass for this one match.
create or replace function public.redeem_app_handoff(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h app_handoffs; f fixtures; g games; v_pass text; v_opp uuid; v_opp_name text;
begin
  select * into h from app_handoffs
  where code_hash = _hash(coalesce(p_code, '')) and used_at is null and expires_at > now() for update;
  if h.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_or_expired'); end if;
  update app_handoffs set used_at = now() where id = h.id;

  select * into f from fixtures where id = h.fixture_id;
  if f.status in ('completed', 'cancelled', 'disputed', 'bye') then
    return jsonb_build_object('ok', false, 'reason', 'fixture_closed');
  end if;
  select gm.* into g from tournaments t join games gm on gm.id = t.game_id where t.id = f.tournament_id;

  delete from match_passes where user_id = h.user_id and fixture_id = h.fixture_id;
  v_pass := _random_token(32);   -- 64 hex characters
  insert into match_passes (token_hash, user_id, fixture_id, expires_at)
  values (_hash(v_pass), h.user_id, h.fixture_id, now() + interval '8 hours');

  v_opp := case when h.user_id = f.player_a_id then f.player_b_id else f.player_a_id end;
  select coalesce(display_name, username) into v_opp_name from profiles where id = v_opp;
  return jsonb_build_object('ok', true, 'pass', v_pass, 'fixture_id', f.id,
    'my_side', case when h.user_id = f.player_a_id then 'A' else 'B' end,
    'opponent', v_opp_name, 'stage', f.stage, 'scheduled_at', f.scheduled_at, 'status', f.status,
    'regulation_seconds', g.regulation_seconds, 'extra_time_seconds', g.extra_time_seconds);
end $$;

create or replace function public._pass(p_pass text) returns match_passes
language plpgsql security definer set search_path = public as $$
declare p match_passes;
begin
  select * into p from match_passes where token_hash = _hash(coalesce(p_pass, '')) and expires_at > now();
  if p.id is not null then update match_passes set last_seen_at = now() where id = p.id; end if;
  return p;
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

-- The signed-in version keeps working exactly as before.
create or replace function public.submit_screen_state(
  p_fixture_id uuid, p_layout text,
  p_score_me int, p_score_opp int, p_pen_me int, p_pen_opp int,
  p_clock_seconds int, p_client_seq bigint, p_raw jsonb default null)
returns jsonb
language sql security definer set search_path = public as $$
  select public._submit_screen_state(auth.uid(), p_fixture_id, p_layout, p_score_me, p_score_opp,
                                     p_pen_me, p_pen_opp, p_clock_seconds, p_client_seq, p_raw)
$$;

-- The app version: identified by the match pass instead of a login.
create or replace function public.submit_screen_state_pass(
  p_pass text, p_layout text,
  p_score_me int, p_score_opp int, p_pen_me int, p_pen_opp int,
  p_clock_seconds int, p_client_seq bigint, p_raw jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare p match_passes;
begin
  p := _pass(p_pass);
  if p.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_pass'); end if;
  return _submit_screen_state(p.user_id, p.fixture_id, p_layout, p_score_me, p_score_opp,
                              p_pen_me, p_pen_opp, p_clock_seconds, p_client_seq, p_raw);
end $$;

create or replace function public.finalize_fixture_pass(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p match_passes;
begin
  p := _pass(p_pass);
  if p.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_pass'); end if;
  return _finalize(p.fixture_id, p.user_id);
end $$;

-- What the app shows: match state and result from this player's point of view.
create or replace function public.match_status_pass(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p match_passes; f fixtures; v_a boolean;
begin
  p := _pass(p_pass);
  if p.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid_pass'); end if;
  select * into f from fixtures where id = p.fixture_id;
  v_a := (p.user_id = f.player_a_id);
  return jsonb_build_object('ok', true, 'status', f.status, 'kickoff', f.kickoff_at is not null,
    'outcome', f.outcome, 'winner_is_me', case when f.winner_id is null then null else f.winner_id = p.user_id end,
    'score_me', case when v_a then f.score_a else f.score_b end, 'score_opp', case when v_a then f.score_b else f.score_a end,
    'pen_me', case when v_a then f.pen_a else f.pen_b end, 'pen_opp', case when v_a then f.pen_b else f.pen_a end);
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function public._hash(text), public._random_token(int), public._pass(text),
  public._gen_room_code(int), public._submit_screen_state(uuid, uuid, text, int, int, int, int, int, bigint, jsonb)
  from public, anon, authenticated;
revoke execute on function public.create_app_handoff(uuid) from public, anon;
grant execute on function public.create_app_handoff(uuid) to authenticated;
revoke execute on function public.redeem_app_handoff(text), public.submit_screen_state_pass(text, text, int, int, int, int, int, bigint, jsonb),
  public.finalize_fixture_pass(text), public.match_status_pass(text) from public;
grant execute on function public.redeem_app_handoff(text), public.submit_screen_state_pass(text, text, int, int, int, int, int, bigint, jsonb),
  public.finalize_fixture_pass(text), public.match_status_pass(text) to anon, authenticated;
