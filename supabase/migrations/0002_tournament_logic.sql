-- WIN ZONE — 0002 tournament logic
-- Helpers, profile trigger, room codes, bracket + league generation, league table.

-- ---------------------------------------------------------------- role helpers
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_roles where user_id = auth.uid() and role = 'admin')
$$;

create or replace function public.is_organizer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_roles where user_id = auth.uid() and role in ('admin', 'organizer'))
$$;

-- Run from the Supabase SQL editor only (not granted to any API role).
create or replace function public.grant_role(p_email text, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where lower(email) = lower(p_email);
  if v_id is null then raise exception 'no user with email %', p_email; end if;
  insert into user_roles (user_id, role) values (v_id, p_role) on conflict do nothing;
end $$;

-- ---------------------------------------------------------------- profile on signup
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_name text; v_try int := 0;
begin
  v_name := regexp_replace(coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1)), '[^A-Za-z0-9_]', '', 'g');
  if length(v_name) < 3 then v_name := 'player' || v_name; end if;
  v_name := left(v_name, 20);
  while exists (select 1 from profiles where lower(username) = lower(v_name)) and v_try < 20 loop
    v_name := left(v_name, 15) || substr(md5(random()::text), 1, 4);
    v_try := v_try + 1;
  end loop;
  insert into profiles (id, username, display_name, age_confirmed_at)
  values (new.id, v_name, coalesce(new.raw_user_meta_data ->> 'display_name', v_name),
          case when (new.raw_user_meta_data ->> 'age_confirmed') = 'true' then now() end);
  return new;
end $$;

create or replace function public.handle_deleted_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from profiles where id = old.id;
  delete from user_roles where user_id = old.id;
  return old;
end $$;

-- ---------------------------------------------------------------- room codes
create or replace function public._gen_room_code() returns text
language plpgsql volatile as $$
declare
  c_alpha constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ';
  c_digit constant text := '23456789';
  c_all   constant text := c_alpha || c_digit;
  v_len int; v_code text; v_try int := 0; v_bytes bytea; i int;
begin
  loop
    v_bytes := decode(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'hex');
    v_len := 6 + (get_byte(v_bytes, 0) % 3);
    v_code := '';
    for i in 1..v_len loop
      v_code := v_code || substr(c_all, 1 + (get_byte(v_bytes, i) % length(c_all)), 1);
    end loop;
    -- at least one letter and one digit
    if v_code ~ '[A-Z]' and v_code ~ '[2-9]'
       and not exists (select 1 from matchrooms where room_code = v_code) then
      return v_code;
    end if;
    v_try := v_try + 1;
    if v_try > 10 then raise exception 'could not generate a unique room code'; end if;
  end loop;
end $$;

create or replace function public._ensure_matchroom(p_fixture_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_model text;
begin
  select g.room_code_model into v_model
  from fixtures f join tournaments t on t.id = f.tournament_id join games g on g.id = t.game_id
  where f.id = p_fixture_id;

  insert into matchrooms (fixture_id, room_code, room_code_source)
  values (p_fixture_id,
          case when v_model = 'platform_issued' then _gen_room_code() end,
          case when v_model = 'platform_issued' then 'platform' end)
  on conflict (fixture_id) do nothing;
end $$;

-- ---------------------------------------------------------------- bracket helpers
-- Standard seeding order for a bracket of size p (power of two). Adjacent pairs meet in round 1.
create or replace function public._bracket_order(p int) returns int[]
language plpgsql immutable as $$
declare o int[] := array[1, 2]; n int := 2; nxt int[]; s int;
begin
  while n < p loop
    nxt := '{}';
    foreach s in array o loop
      nxt := nxt || s || (2 * n + 1 - s);
    end loop;
    o := nxt;
    n := n * 2;
  end loop;
  return o;
end $$;

-- Knockout bracket from players listed in seed order. Byes go to the top seeds.
create or replace function public._generate_knockout(p_tid uuid, p_players uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare
  n int := coalesce(array_length(p_players, 1), 0);
  p int := 1; rounds int := 0; r int; s int;
  v_order int[]; seed_a int; seed_b int; pa uuid; pb uuid; fid uuid;
begin
  if n < 2 then raise exception 'knockout needs at least 2 players'; end if;
  while p < n loop p := p * 2; rounds := rounds + 1; end loop;
  v_order := _bracket_order(p);

  for r in 1..rounds loop
    for s in 1..(p / (2 ^ r)::int) loop
      insert into fixtures (tournament_id, stage, round, slot) values (p_tid, 'knockout', r, s);
    end loop;
  end loop;

  update fixtures f
  set next_fixture_id = nx.id,
      next_side = case when f.slot % 2 = 1 then 'A' else 'B' end
  from fixtures nx
  where f.tournament_id = p_tid and f.stage = 'knockout'
    and nx.tournament_id = p_tid and nx.stage = 'knockout'
    and nx.round = f.round + 1 and nx.slot = (f.slot + 1) / 2;

  for s in 1..(p / 2) loop
    seed_a := v_order[2 * s - 1];
    seed_b := v_order[2 * s];
    pa := case when seed_a <= n then p_players[seed_a] end;
    pb := case when seed_b <= n then p_players[seed_b] end;
    update fixtures set player_a_id = pa, player_b_id = pb, host_player_id = pa
    where tournament_id = p_tid and stage = 'knockout' and round = 1 and slot = s
    returning id into fid;

    if pa is not null and pb is not null then
      perform _ensure_matchroom(fid);
    elsif pa is not null or pb is not null then
      update fixtures set status = 'bye', winner_id = coalesce(pa, pb), outcome = 'bye', completed_at = now()
      where id = fid;
      perform _after_final(fid);
    end if;
  end loop;
end $$;

-- Single round robin (circle method).
create or replace function public._generate_league(p_tid uuid, p_players uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare
  arr uuid[] := p_players; m int; r int; i int; a uuid; b uuid; fid uuid;
begin
  if coalesce(array_length(arr, 1), 0) < 2 then raise exception 'league needs at least 2 players'; end if;
  if array_length(arr, 1) % 2 = 1 then arr := arr || null::uuid; end if;
  m := array_length(arr, 1);

  for r in 1..(m - 1) loop
    for i in 1..(m / 2) loop
      a := arr[i]; b := arr[m + 1 - i];
      if a is not null and b is not null then
        if (r + i) % 2 = 1 then
          insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, host_player_id)
          values (p_tid, 'league', r, i, a, b, a) returning id into fid;
        else
          insert into fixtures (tournament_id, stage, round, slot, player_a_id, player_b_id, host_player_id)
          values (p_tid, 'league', r, i, b, a, b) returning id into fid;
        end if;
        perform _ensure_matchroom(fid);
      end if;
    end loop;
    arr := arr[1:1] || arr[m:m] || arr[2:m - 1];
  end loop;
end $$;

-- ---------------------------------------------------------------- league table
-- Points 3/1/0 (per tournament-wide rule). Ties: goal difference, goals for, head-to-head, username.
-- A forfeit or no-show win counts as 3-0 in the table.
create or replace function public.league_table(p_tid uuid)
returns table (user_id uuid, played int, won int, drawn int, lost int, gf int, ga int, gd int,
               points int, h2h int, rank int)
language sql stable set search_path = public as $$
  with res as (
    select f.id, f.player_a_id as pa, f.player_b_id as pb,
           case when f.outcome in ('win_by_forfeit', 'win_by_noshow')
                then case when f.winner_id = f.player_a_id then 3 else 0 end
                else coalesce(f.score_a, 0) end as sa,
           case when f.outcome in ('win_by_forfeit', 'win_by_noshow')
                then case when f.winner_id = f.player_b_id then 3 else 0 end
                else coalesce(f.score_b, 0) end as sb
    from fixtures f
    where f.tournament_id = p_tid and f.stage = 'league' and f.status = 'completed'
  ),
  rows as (
    select pa as uid, pb as oid, sa as gf, sb as ga, id from res
    union all
    select pb, pa, sb, sa, id from res
  ),
  base as (
    select e.user_id as uid,
           count(r.id)::int as played,
           count(*) filter (where r.gf > r.ga)::int as won,
           count(*) filter (where r.gf = r.ga)::int as drawn,
           count(*) filter (where r.gf < r.ga)::int as lost,
           coalesce(sum(r.gf), 0)::int as gf,
           coalesce(sum(r.ga), 0)::int as ga
    from tournament_entries e
    left join rows r on r.uid = e.user_id
    where e.tournament_id = p_tid and e.status <> 'withdrawn'
    group by e.user_id
  ),
  scored as (
    select b.*, (b.gf - b.ga) as gd, (b.won * 3 + b.drawn)::int as points from base b
  ),
  h2h as (
    select s1.uid,
           coalesce((
             select sum(case when r.gf > r.ga then 3 when r.gf = r.ga then 1 else 0 end)
             from rows r join scored s2 on s2.uid = r.oid
             where r.uid = s1.uid and s2.points = s1.points and s2.gd = s1.gd and s2.gf = s1.gf
           ), 0)::int as h2h
    from scored s1
  )
  select s.uid, s.played, s.won, s.drawn, s.lost, s.gf, s.ga, s.gd, s.points, h.h2h,
         (row_number() over (order by s.points desc, s.gd desc, s.gf desc, h.h2h desc,
                             (select lower(username) from profiles where id = s.uid)))::int
  from scored s join h2h h on h.uid = s.uid
  order by 11
$$;

-- ---------------------------------------------------------------- after a fixture is final
create or replace function public._start_knockout(p_tid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_adv int; v_top uuid[];
begin
  select league_advance into v_adv from tournaments where id = p_tid;
  select array_agg(user_id order by rank) into v_top
  from (select user_id, rank from league_table(p_tid) order by rank limit v_adv) q;
  perform _generate_knockout(p_tid, v_top);
end $$;

create or replace function public._after_final(p_fixture_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  f fixtures; t tournaments; nxt fixtures; v_remaining int; v_champ uuid;
begin
  select * into f from fixtures where id = p_fixture_id;
  select * into t from tournaments where id = f.tournament_id;

  if f.stage = 'knockout' then
    if f.winner_id is null then raise exception 'knockout fixture % has no winner', f.id; end if;
    if f.next_fixture_id is null then
      update tournaments set status = 'completed', champion_id = f.winner_id where id = f.tournament_id;
    else
      update fixtures
      set player_a_id = case when f.next_side = 'A' then f.winner_id else player_a_id end,
          player_b_id = case when f.next_side = 'B' then f.winner_id else player_b_id end
      where id = f.next_fixture_id
        and (case f.next_side when 'A' then player_a_id else player_b_id end) is null
      returning * into nxt;
      if not found then
        raise exception 'bracket slot already filled for fixture %', f.next_fixture_id;
      end if;
      if nxt.player_a_id is not null and nxt.player_b_id is not null then
        update fixtures set host_player_id = player_a_id where id = nxt.id;
        perform _ensure_matchroom(nxt.id);
      end if;
    end if;

  elsif f.stage = 'league' then
    select count(*) into v_remaining from fixtures
    where tournament_id = f.tournament_id and stage = 'league'
      and status not in ('completed', 'cancelled', 'bye');
    if v_remaining = 0 then
      if t.format = 'league' then
        select user_id into v_champ from league_table(t.id) where rank = 1;
        update tournaments set status = 'completed', champion_id = v_champ where id = t.id;
      elsif t.format = 'league_knockout'
            and not exists (select 1 from fixtures where tournament_id = t.id and stage = 'knockout') then
        perform _start_knockout(t.id);
      end if;
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------- organizer RPCs
create or replace function public.create_tournament(
  p_name text, p_slug text, p_game_slug text, p_format text, p_size int,
  p_starts_at timestamptz default null, p_prize text default null, p_league_advance int default 4)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_game uuid; v_id uuid;
begin
  if not is_organizer() then raise exception 'not_allowed'; end if;
  select id into v_game from games where slug = p_game_slug and active;
  if v_game is null then raise exception 'unknown game'; end if;
  insert into tournaments (name, slug, game_id, format, size, starts_at, prize_description, league_advance, created_by)
  values (p_name, p_slug, v_game, p_format, p_size, p_starts_at, p_prize, p_league_advance, auth.uid())
  returning id into v_id;
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'create_tournament', 'tournament', v_id);
  return v_id;
end $$;

create or replace function public.set_tournament_status(p_tid uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare t tournaments;
begin
  select * into t from tournaments where id = p_tid;
  if t.id is null then raise exception 'not_found'; end if;
  if not (is_admin() or t.created_by = auth.uid()) then raise exception 'not_allowed'; end if;
  if p_status not in ('draft', 'open', 'cancelled') then raise exception 'use generate_tournament to go live'; end if;
  if t.status in ('live', 'completed') then raise exception 'tournament already started'; end if;
  update tournaments set status = p_status where id = p_tid;
  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'set_tournament_status', 'tournament', p_tid, jsonb_build_object('status', p_status));
end $$;

create or replace function public.generate_tournament(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments; v_players uuid[]; n int; v_adv int;
begin
  select * into t from tournaments where id = p_tid for update;
  if t.id is null then raise exception 'not_found'; end if;
  if not (is_admin() or t.created_by = auth.uid()) then raise exception 'not_allowed'; end if;
  if t.status not in ('draft', 'open') then raise exception 'already generated'; end if;

  select array_agg(user_id order by random()) into v_players
  from tournament_entries where tournament_id = p_tid and status <> 'withdrawn';
  n := coalesce(array_length(v_players, 1), 0);
  if n < 2 then raise exception 'need at least 2 registered players'; end if;

  update tournament_entries e set seed = q.rn
  from (select user_id, row_number() over () as rn from unnest(v_players) as user_id) q
  where e.tournament_id = p_tid and e.user_id = q.user_id;

  if t.format = 'knockout' then
    perform _generate_knockout(p_tid, v_players);
  else
    if t.format = 'league_knockout' then
      v_adv := t.league_advance;
      while v_adv > n loop v_adv := v_adv / 2; end loop;
      if v_adv < 2 then v_adv := 2; end if;
      update tournaments set league_advance = v_adv where id = p_tid;
    end if;
    perform _generate_league(p_tid, v_players);
  end if;

  update tournaments set status = 'live' where id = p_tid;
  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'generate_tournament', 'tournament', p_tid, jsonb_build_object('players', n));
  return jsonb_build_object('ok', true, 'players', n);
end $$;

create or replace function public.schedule_fixtures(
  p_tid uuid, p_stage text, p_round int, p_start timestamptz, p_spacing_minutes int default 30)
returns int
language plpgsql security definer set search_path = public as $$
declare t tournaments; v_count int;
begin
  select * into t from tournaments where id = p_tid;
  if t.id is null then raise exception 'not_found'; end if;
  if not (is_admin() or t.created_by = auth.uid()) then raise exception 'not_allowed'; end if;
  update fixtures
  set scheduled_at = p_start + ((slot - 1) * p_spacing_minutes) * interval '1 minute'
  where tournament_id = p_tid and stage = p_stage and round = p_round
    and status = 'scheduled' and player_a_id is not null and player_b_id is not null;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- ---------------------------------------------------------------- player RPCs
create or replace function public.register_for_tournament(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments; v_uid uuid := auth.uid(); v_count int; pr profiles;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  select * into t from tournaments where id = p_tid;
  if t.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if t.status <> 'open' then return jsonb_build_object('ok', false, 'reason', 'registration_closed'); end if;
  if t.registration_closes_at is not null and now() > t.registration_closes_at then
    return jsonb_build_object('ok', false, 'reason', 'registration_closed');
  end if;
  select * into pr from profiles where id = v_uid;
  if pr.age_confirmed_at is null then return jsonb_build_object('ok', false, 'reason', 'age_not_confirmed'); end if;

  if exists (select 1 from tournament_entries where tournament_id = p_tid and user_id = v_uid and status <> 'withdrawn') then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  select count(*) into v_count from tournament_entries where tournament_id = p_tid and status <> 'withdrawn';
  if v_count >= t.size then return jsonb_build_object('ok', false, 'reason', 'tournament_full'); end if;

  insert into tournament_entries (tournament_id, user_id) values (p_tid, v_uid)
  on conflict (tournament_id, user_id) do update set status = 'registered';
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.withdraw_from_tournament(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments;
begin
  select * into t from tournaments where id = p_tid;
  if t.status <> 'open' then return jsonb_build_object('ok', false, 'reason', 'locked'); end if;
  update tournament_entries set status = 'withdrawn' where tournament_id = p_tid and user_id = auth.uid();
  return jsonb_build_object('ok', true);
end $$;
