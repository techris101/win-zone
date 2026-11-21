-- WIN ZONE — 0007 lifecycle: country and local time, automatic draft schedule, admin publish, admin management
-- Players choose a country; every match time is shown in their local time.
-- When a tournament fills up, registration closes and the system prepares fixtures with automatic times as a
-- DRAFT that only organizers/admins can see. An admin reviews, edits times, and publishes. Admins can add admins.

-- ---------------------------------------------------------------- countries and time zones
create table public.countries (
  code text primary key check (code ~ '^[A-Z]{2}$'),
  name text not null,
  tz   text not null
);
insert into public.countries (code, name, tz) values
('DZ','Algeria','Africa/Algiers'),('AO','Angola','Africa/Luanda'),('BJ','Benin','Africa/Porto-Novo'),('BW','Botswana','Africa/Gaborone'),
('BF','Burkina Faso','Africa/Ouagadougou'),('BI','Burundi','Africa/Bujumbura'),('CV','Cabo Verde','Atlantic/Cape_Verde'),('CM','Cameroon','Africa/Douala'),
('CF','Central African Republic','Africa/Bangui'),('TD','Chad','Africa/Ndjamena'),('KM','Comoros','Indian/Comoro'),('CG','Congo','Africa/Brazzaville'),
('CD','DR Congo','Africa/Kinshasa'),('CI','Côte d''Ivoire','Africa/Abidjan'),('DJ','Djibouti','Africa/Djibouti'),('EG','Egypt','Africa/Cairo'),
('GQ','Equatorial Guinea','Africa/Malabo'),('ER','Eritrea','Africa/Asmara'),('SZ','Eswatini','Africa/Mbabane'),('ET','Ethiopia','Africa/Addis_Ababa'),
('GA','Gabon','Africa/Libreville'),('GM','Gambia','Africa/Banjul'),('GH','Ghana','Africa/Accra'),('GN','Guinea','Africa/Conakry'),
('GW','Guinea-Bissau','Africa/Bissau'),('KE','Kenya','Africa/Nairobi'),('LS','Lesotho','Africa/Maseru'),('LR','Liberia','Africa/Monrovia'),
('LY','Libya','Africa/Tripoli'),('MG','Madagascar','Indian/Antananarivo'),('MW','Malawi','Africa/Blantyre'),('ML','Mali','Africa/Bamako'),
('MR','Mauritania','Africa/Nouakchott'),('MU','Mauritius','Indian/Mauritius'),('MA','Morocco','Africa/Casablanca'),('MZ','Mozambique','Africa/Maputo'),
('NA','Namibia','Africa/Windhoek'),('NE','Niger','Africa/Niamey'),('NG','Nigeria','Africa/Lagos'),('RW','Rwanda','Africa/Kigali'),
('ST','São Tomé and Príncipe','Africa/Sao_Tome'),('SN','Senegal','Africa/Dakar'),('SC','Seychelles','Indian/Mahe'),('SL','Sierra Leone','Africa/Freetown'),
('SO','Somalia','Africa/Mogadishu'),('ZA','South Africa','Africa/Johannesburg'),('SS','South Sudan','Africa/Juba'),('SD','Sudan','Africa/Khartoum'),
('TZ','Tanzania','Africa/Dar_es_Salaam'),('TG','Togo','Africa/Lome'),('TN','Tunisia','Africa/Tunis'),('UG','Uganda','Africa/Kampala'),
('ZM','Zambia','Africa/Lusaka'),('ZW','Zimbabwe','Africa/Harare'),
('US','United States','America/New_York'),('CA','Canada','America/Toronto'),('MX','Mexico','America/Mexico_City'),('BR','Brazil','America/Sao_Paulo'),
('AR','Argentina','America/Argentina/Buenos_Aires'),('CO','Colombia','America/Bogota'),('GB','United Kingdom','Europe/London'),('IE','Ireland','Europe/Dublin'),
('FR','France','Europe/Paris'),('DE','Germany','Europe/Berlin'),('ES','Spain','Europe/Madrid'),('IT','Italy','Europe/Rome'),('PT','Portugal','Europe/Lisbon'),
('NL','Netherlands','Europe/Amsterdam'),('BE','Belgium','Europe/Brussels'),('CH','Switzerland','Europe/Zurich'),('SE','Sweden','Europe/Stockholm'),
('PL','Poland','Europe/Warsaw'),('TR','Türkiye','Europe/Istanbul'),('RU','Russia','Europe/Moscow'),('UA','Ukraine','Europe/Kyiv'),
('SA','Saudi Arabia','Asia/Riyadh'),('AE','United Arab Emirates','Asia/Dubai'),('QA','Qatar','Asia/Qatar'),('IN','India','Asia/Kolkata'),
('PK','Pakistan','Asia/Karachi'),('BD','Bangladesh','Asia/Dhaka'),('CN','China','Asia/Shanghai'),('JP','Japan','Asia/Tokyo'),('KR','South Korea','Asia/Seoul'),
('ID','Indonesia','Asia/Jakarta'),('PH','Philippines','Asia/Manila'),('AU','Australia','Australia/Sydney');
alter table public.countries enable row level security;
create policy countries_public on public.countries for select using (true);
grant select on public.countries to anon, authenticated;

alter table public.profiles add column country text references public.countries (code);

-- sign-up stores the chosen country
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_name text; v_try int := 0; v_country text;
begin
  v_name := regexp_replace(coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1)), '[^A-Za-z0-9_]', '', 'g');
  if length(v_name) < 3 then v_name := 'player' || v_name; end if;
  v_name := left(v_name, 20);
  while exists (select 1 from profiles where lower(username) = lower(v_name)) and v_try < 20 loop
    v_name := left(v_name, 15) || substr(md5(random()::text), 1, 4);
    v_try := v_try + 1;
  end loop;
  v_country := upper(coalesce(new.raw_user_meta_data ->> 'country', ''));
  if not exists (select 1 from countries where code = v_country) then v_country := null; end if;
  insert into profiles (id, username, display_name, country)
  values (new.id, v_name, coalesce(new.raw_user_meta_data ->> 'display_name', v_name), v_country);
  return new;
end $$;

create or replace function public.my_profile() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name,
                              'country', p.country, 'country_name', c.name, 'tz', c.tz)
    from profiles p left join countries c on c.code = p.country where p.id = auth.uid()
  ), '{}'::jsonb)
$$;

create or replace function public.set_my_country(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text := upper(coalesce(p_code, ''));
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  if not exists (select 1 from countries where code = v) then return jsonb_build_object('ok', false, 'reason', 'unknown_country'); end if;
  update profiles set country = v where id = auth.uid();
  return jsonb_build_object('ok', true, 'tz', (select tz from countries where code = v));
end $$;

-- registration needs a country (so times can be shown in the player's local time)
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
  if pr.country is null then return jsonb_build_object('ok', false, 'reason', 'country_required'); end if;

  if exists (select 1 from tournament_entries where tournament_id = p_tid and user_id = v_uid and status <> 'withdrawn') then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  select count(*) into v_count from tournament_entries where tournament_id = p_tid and status <> 'withdrawn';
  if v_count >= t.size then return jsonb_build_object('ok', false, 'reason', 'tournament_full'); end if;

  insert into tournament_entries (tournament_id, user_id) values (p_tid, v_uid)
  on conflict (tournament_id, user_id) do update set status = 'registered';
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- schedule policy
alter table public.tournaments add column schedule_tz text;                       -- null = decided when fixtures are prepared
alter table public.tournaments add column slot_hour int not null default 18 check (slot_hour between 0 and 23);
alter table public.tournaments add column round_gap_hours int not null default 48 check (round_gap_hours between 1 and 720);
alter table public.tournaments drop constraint tournaments_status_check;
alter table public.tournaments add constraint tournaments_status_check
  check (status in ('draft', 'open', 'planning', 'live', 'completed', 'cancelled'));

-- the next local "slot" (for example 18:00 in that time zone) at or after a moment
create or replace function public._next_slot(p_tz text, p_hour int, p_after timestamptz) returns timestamptz
language plpgsql stable as $$
declare v_day timestamp; v_slot timestamptz;
begin
  v_day := date_trunc('day', p_after at time zone p_tz);
  v_slot := (v_day + make_interval(hours => p_hour)) at time zone p_tz;
  if v_slot < p_after then
    v_slot := (v_day + interval '1 day' + make_interval(hours => p_hour)) at time zone p_tz;
  end if;
  return v_slot;
end $$;

-- the automatic time for a round: rounds follow each other every round_gap_hours at the slot hour,
-- never sooner than 12 hours from now. League rounds come first, then knockout rounds.
create or replace function public._auto_time(p_tid uuid, p_stage text, p_round int) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare t tournaments; v_offset int; v_league_rounds int;
begin
  select * into t from tournaments where id = p_tid;
  if p_stage = 'league' then
    v_offset := p_round - 1;
  else
    select coalesce(max(round), 0) into v_league_rounds from fixtures where tournament_id = p_tid and stage = 'league';
    v_offset := v_league_rounds + p_round - 1;
  end if;
  return _next_slot(coalesce(t.schedule_tz, 'Africa/Kigali'), t.slot_hour,
                    greatest(now() + interval '12 hours',
                             coalesce(t.starts_at, now() + interval '24 hours') + make_interval(hours => v_offset * t.round_gap_hours)));
end $$;

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
      update fixtures set scheduled_at = _auto_time(p_tid, 'knockout', 1) where id = fid;
    elsif pa is not null or pb is not null then
      update fixtures set status = 'bye', winner_id = coalesce(pa, pb), outcome = 'bye', completed_at = now()
      where id = fid;
      perform _after_final(fid);
    end if;
  end loop;
end $$;

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
        update fixtures set scheduled_at = _auto_time(p_tid, 'league', r) where id = fid;
      end if;
    end loop;
    arr := arr[1:1] || arr[m:m] || arr[2:m - 1];
  end loop;
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
        update fixtures set scheduled_at = _auto_time(f.tournament_id, 'knockout', nxt.round) where id = nxt.id;
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

-- ---------------------------------------------------------------- prepare fixtures (draft) and publish
create or replace function public._plan_tournament(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments; v_players uuid[]; n int; v_adv int; v_tz text;
begin
  select * into t from tournaments where id = p_tid for update;
  if t.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if t.status not in ('draft', 'open') then return jsonb_build_object('ok', false, 'reason', 'already_planned'); end if;

  select array_agg(user_id order by random()) into v_players
  from tournament_entries where tournament_id = p_tid and status <> 'withdrawn';
  n := coalesce(array_length(v_players, 1), 0);
  if n < 2 then return jsonb_build_object('ok', false, 'reason', 'need_two_players'); end if;
  update tournaments set status = 'planning' where id = p_tid;   -- claim it first: no re-entry, no double planning

  update tournament_entries e set seed = q.rn
  from (select user_id, row_number() over () as rn from unnest(v_players) as user_id) q
  where e.tournament_id = p_tid and e.user_id = q.user_id;

  -- time zone: the most common one among the players, unless the admin already chose one
  if t.schedule_tz is null then
    select c.tz into v_tz
    from tournament_entries e join profiles p on p.id = e.user_id join countries c on c.code = p.country
    where e.tournament_id = p_tid and e.status <> 'withdrawn'
    group by c.tz order by count(*) desc, c.tz limit 1;
    update tournaments set schedule_tz = coalesce(v_tz, 'Africa/Kigali') where id = p_tid;
  end if;

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

  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'plan_tournament', 'tournament', p_tid, jsonb_build_object('players', n));
  return jsonb_build_object('ok', true, 'players', n);
end $$;

-- an organizer can close registration early and prepare the draft
create or replace function public.generate_tournament(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments;
begin
  select * into t from tournaments where id = p_tid;
  if t.id is null then raise exception 'not_found'; end if;
  if not (is_admin() or t.created_by = auth.uid()) then raise exception 'not_allowed'; end if;
  return _plan_tournament(p_tid);
end $$;

-- when the last place is taken, registration closes and the draft is prepared
create or replace function public._entry_changed() returns trigger
language plpgsql security definer set search_path = public as $$
declare t tournaments; n int;
begin
  select * into t from tournaments where id = new.tournament_id;
  if t.status = 'open' then
    select count(*) into n from tournament_entries where tournament_id = t.id and status <> 'withdrawn';
    if n >= t.size then perform _plan_tournament(t.id); end if;
  end if;
  return new;
end $$;
create trigger tournament_entries_full after insert or update of status on public.tournament_entries
  for each row execute function public._entry_changed();

create or replace function public.publish_tournament(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments;
begin
  select * into t from tournaments where id = p_tid for update;
  if t.id is null then raise exception 'not_found'; end if;
  if not (is_admin() or t.created_by = auth.uid()) then raise exception 'not_allowed'; end if;
  if t.status <> 'planning' then return jsonb_build_object('ok', false, 'reason', 'not_in_planning'); end if;
  update tournaments set status = 'live' where id = p_tid;
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'publish_tournament', 'tournament', p_tid);
  return jsonb_build_object('ok', true);
end $$;

-- back to registration (for example to add places): deletes the draft fixtures
create or replace function public.reopen_registration(p_tid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments;
begin
  select * into t from tournaments where id = p_tid for update;
  if t.id is null then raise exception 'not_found'; end if;
  if not (is_admin() or t.created_by = auth.uid()) then raise exception 'not_allowed'; end if;
  if t.status <> 'planning' then return jsonb_build_object('ok', false, 'reason', 'not_in_planning'); end if;
  delete from fixtures where tournament_id = p_tid;
  update tournament_entries set seed = null where tournament_id = p_tid;
  update tournaments set status = 'open', schedule_tz = null where id = p_tid;
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'reopen_registration', 'tournament', p_tid);
  return jsonb_build_object('ok', true);
end $$;

-- change a tournament's details or schedule policy (whitelisted fields only)
create or replace function public.update_tournament(p_tid uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments; v_active int;
begin
  select * into t from tournaments where id = p_tid for update;
  if t.id is null then raise exception 'not_found'; end if;
  if not (is_admin() or t.created_by = auth.uid()) then raise exception 'not_allowed'; end if;
  if t.status in ('completed', 'cancelled') then return jsonb_build_object('ok', false, 'reason', 'tournament_finished'); end if;

  if p_patch ? 'size' then
    if t.status not in ('draft', 'open') then return jsonb_build_object('ok', false, 'reason', 'size_locked'); end if;
    select count(*) into v_active from tournament_entries where tournament_id = p_tid and status <> 'withdrawn';
    if (p_patch ->> 'size')::int < greatest(v_active, 2) then return jsonb_build_object('ok', false, 'reason', 'size_below_players'); end if;
  end if;
  if p_patch ? 'schedule_tz' and not exists (select 1 from pg_timezone_names where name = p_patch ->> 'schedule_tz') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_time_zone');
  end if;

  update tournaments set
    name = coalesce(nullif(p_patch ->> 'name', ''), name),
    prize_description = case when p_patch ? 'prize_description' then nullif(p_patch ->> 'prize_description', '') else prize_description end,
    starts_at = case when p_patch ? 'starts_at' then nullif(p_patch ->> 'starts_at', '')::timestamptz else starts_at end,
    size = coalesce((p_patch ->> 'size')::int, size),
    league_advance = coalesce((p_patch ->> 'league_advance')::int, league_advance),
    schedule_tz = coalesce(nullif(p_patch ->> 'schedule_tz', ''), schedule_tz),
    slot_hour = coalesce((p_patch ->> 'slot_hour')::int, slot_hour),
    round_gap_hours = coalesce((p_patch ->> 'round_gap_hours')::int, round_gap_hours)
  where id = p_tid;
  insert into audit_logs (actor, action, entity, entity_id, details) values (auth.uid(), 'update_tournament', 'tournament', p_tid, p_patch);
  return jsonb_build_object('ok', true);
end $$;

-- the system sets times automatically; an organizer or admin can change any of them
create or replace function public.reschedule_fixture(p_fixture_id uuid, p_at timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f fixtures; t tournaments;
begin
  select * into f from fixtures where id = p_fixture_id for update;
  if f.id is null then raise exception 'not_found'; end if;
  select * into t from tournaments where id = f.tournament_id;
  if not (is_admin() or t.created_by = auth.uid()) then raise exception 'not_allowed'; end if;
  if f.status <> 'scheduled' or f.kickoff_at is not null then return jsonb_build_object('ok', false, 'reason', 'fixture_already_started'); end if;
  if p_at is null then return jsonb_build_object('ok', false, 'reason', 'time_required'); end if;
  update fixtures set scheduled_at = p_at where id = f.id;
  perform _event(f.id, 'rescheduled', auth.uid(), jsonb_build_object('from', f.scheduled_at, 'to', p_at));
  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'reschedule_fixture', 'fixture', f.id, jsonb_build_object('from', f.scheduled_at, 'to', p_at));
  return jsonb_build_object('ok', true);
end $$;

-- only live tournaments are playable
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
  if not exists (select 1 from tournaments where id = f.tournament_id and status = 'live') then
    return jsonb_build_object('ok', false, 'reason', 'not_live');
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

create or replace function public.sweep_fixtures() returns int
language plpgsql security definer set search_path = public as $$
declare
  f fixtures; g games; mr matchrooms; v_n int := 0; v_deadline timestamptz; v_stale boolean;
  v_host_blocked boolean;
begin
  for f in select fx.* from fixtures fx join tournaments tt on tt.id = fx.tournament_id
           where tt.status = 'live' and fx.status in ('scheduled', 'active', 'stalled') and fx.scheduled_at is not null loop
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
  if not exists (select 1 from tournaments where id = f.tournament_id and status = 'live') then
    return jsonb_build_object('ok', false, 'reason', 'not_live');
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

-- fixtures stay hidden from the public until the admin publishes
drop policy if exists fixtures_public on public.fixtures;
create policy fixtures_public on public.fixtures for select
  using (exists (select 1 from public.tournaments t where t.id = tournament_id and t.status in ('live', 'completed', 'cancelled')));
create policy fixtures_owner on public.fixtures for select to authenticated
  using (exists (select 1 from public.tournaments t where t.id = tournament_id and (t.created_by = auth.uid() or public.is_admin())));

-- ---------------------------------------------------------------- admin management
create or replace function public.list_admins() returns table (user_id uuid, role text, username text, email text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  return query
    select r.user_id, r.role, p.username, u.email::text
    from user_roles r left join profiles p on p.id = r.user_id left join auth.users u on u.id = r.user_id
    order by r.role, p.username;
end $$;

-- add a person (by email or username) as admin or organizer; they must already have an account
create or replace function public.add_role(p_identifier text, p_role text default 'admin') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_key text := lower(trim(coalesce(p_identifier, '')));
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if p_role not in ('admin', 'organizer') then return jsonb_build_object('ok', false, 'reason', 'bad_role'); end if;
  select id into v_id from auth.users where lower(email) = v_key;
  if v_id is null then select id into v_id from profiles where lower(username) = v_key; end if;
  if v_id is null then return jsonb_build_object('ok', false, 'reason', 'no_such_account'); end if;
  insert into user_roles (user_id, role) values (v_id, p_role) on conflict do nothing;
  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'add_role', 'user', v_id, jsonb_build_object('role', p_role));
  return jsonb_build_object('ok', true, 'user_id', v_id);
end $$;

create or replace function public.remove_role(p_user_id uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if p_user_id = auth.uid() then return jsonb_build_object('ok', false, 'reason', 'cannot_remove_yourself'); end if;
  if p_role = 'admin' and (select count(*) from user_roles where role = 'admin') <= 1 then
    return jsonb_build_object('ok', false, 'reason', 'last_admin');
  end if;
  delete from user_roles where user_id = p_user_id and role = p_role;
  insert into audit_logs (actor, action, entity, entity_id, details)
  values (auth.uid(), 'remove_role', 'user', p_user_id, jsonb_build_object('role', p_role));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function public._next_slot(text, int, timestamptz), public._auto_time(uuid, text, int),
  public._plan_tournament(uuid), public._entry_changed() from public, anon, authenticated;
revoke execute on function public.my_profile(), public.set_my_country(text), public.publish_tournament(uuid),
  public.reopen_registration(uuid), public.update_tournament(uuid, jsonb), public.reschedule_fixture(uuid, timestamptz),
  public.list_admins(), public.add_role(text, text), public.remove_role(uuid, text) from public, anon;
grant execute on function public.my_profile(), public.set_my_country(text), public.publish_tournament(uuid),
  public.reopen_registration(uuid), public.update_tournament(uuid, jsonb), public.reschedule_fixture(uuid, timestamptz),
  public.list_admins(), public.add_role(text, text), public.remove_role(uuid, text) to authenticated;
