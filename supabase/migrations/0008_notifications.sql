-- WIN ZONE — 0008 notifications
-- Every notification is stored (site inbox, always works) and, if the player turned it on, pushed to their phone.
-- While a player is in a tournament they get everything about it. When they are knocked out they get one last
-- notification asking whether to keep following. No answer = no more tournament-wide updates.

-- ---------------------------------------------------------------- tables
alter table public.profiles add column lang text not null default 'en' check (lang in ('en', 'fr', 'rw'));

create table public.tournament_follows (
  user_id       uuid not null,
  tournament_id uuid not null references public.tournaments (id) on delete cascade,
  state         text not null check (state in ('playing', 'asked', 'following', 'stopped')),
  updated_at    timestamptz not null default now(),
  primary key (user_id, tournament_id)
);

create table public.notifications (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null,
  tournament_id uuid references public.tournaments (id) on delete cascade,
  fixture_id    uuid references public.fixtures (id) on delete set null,
  kind          text not null,
  title         text not null,
  body          text not null,
  url           text,
  actions       jsonb,
  dedupe_key    text not null,
  created_at    timestamptz not null default now(),
  read_at       timestamptz,
  pushed_at     timestamptz,
  unique (user_id, dedupe_key)
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);

create table public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  user_agent text,
  created_at timestamptz not null default now()
);
create index push_subscriptions_user_idx on public.push_subscriptions (user_id);

-- private settings for the push sender (function URL, shared secret). Never readable from the API.
create table public.app_private_config (key text primary key, value text not null);

alter table public.tournament_follows enable row level security;
alter table public.notifications enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.app_private_config enable row level security;
revoke all on public.tournament_follows, public.notifications, public.push_subscriptions, public.app_private_config from anon, authenticated;

grant select on public.notifications, public.tournament_follows to authenticated;
create policy notifications_own on public.notifications for select to authenticated using (user_id = auth.uid());
create policy follows_own on public.tournament_follows for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------- message templates (en / fr / rw)
-- NOTE: Kinyarwanda needs review by a native speaker before launch.
create or replace function public._msg(p_lang text, p_kind text, p jsonb) returns jsonb
language plpgsql immutable as $$
declare
  tpl constant jsonb := $j${
  "en": {
    "registered": ["You're in: {t}", "Registration confirmed. We'll notify you when the fixtures are published."],
    "published": ["Fixtures are out: {t}", "Your first match: vs {opp}, {when} (your time)."],
    "published_bye": ["Fixtures are out: {t}", "You go straight through round 1. We'll tell you your next match."],
    "next_match": ["Next match: vs {opp}", "{t}, {round}: {when} (your time)."],
    "rescheduled": ["Match time changed", "{t}: vs {opp} is now {when} (your time)."],
    "reminder": ["Match in 1 hour", "{t}: vs {opp} at {when}. Be ready."],
    "room_open": ["Your match code is ready", "vs {opp}. Open the matchroom, copy the code and tap Play game."],
    "result_win": ["You won {score}", "{t}: you beat {opp}."],
    "result_loss": ["You lost {score}", "{t}: {opp} won this one."],
    "result_draw": ["Draw {score}", "{t}: draw with {opp}."],
    "under_review": ["Match under review", "{t}: your match vs {opp} is being checked by an admin."],
    "knocked_out": ["You're out of {t}", "Thanks for playing. Do you want to keep getting updates about this tournament?"],
    "not_qualified": ["You didn't qualify: {t}", "The league stage is over. Do you want to keep getting updates about the knockout stage?"],
    "round_complete_ko": ["{round} finished", "{t}: {n} players left."],
    "round_complete_league": ["League round {round} finished", "{t}: you are #{rank} with {pts} points."],
    "champion_you": ["You won {t}!", "Champion. Well played."],
    "champion": ["{champ} wins {t}", "The tournament is over. Thanks for following."]
  },
  "fr": {
    "registered": ["Inscription confirmée : {t}", "Nous vous préviendrons dès que le calendrier sera publié."],
    "published": ["Calendrier publié : {t}", "Votre premier match : contre {opp}, {when} (votre heure)."],
    "published_bye": ["Calendrier publié : {t}", "Vous passez directement le 1er tour. Nous vous indiquerons votre prochain match."],
    "next_match": ["Prochain match : contre {opp}", "{t}, {round} : {when} (votre heure)."],
    "rescheduled": ["Horaire modifié", "{t} : le match contre {opp} est désormais {when} (votre heure)."],
    "reminder": ["Match dans 1 heure", "{t} : contre {opp} à {when}. Soyez prêt."],
    "room_open": ["Votre code de match est prêt", "Contre {opp}. Ouvrez la salle, copiez le code et touchez Jouer."],
    "result_win": ["Victoire {score}", "{t} : vous avez battu {opp}."],
    "result_loss": ["Défaite {score}", "{t} : {opp} a gagné ce match."],
    "result_draw": ["Match nul {score}", "{t} : match nul contre {opp}."],
    "under_review": ["Match en examen", "{t} : votre match contre {opp} est vérifié par un administrateur."],
    "knocked_out": ["Vous êtes éliminé : {t}", "Merci d'avoir joué. Voulez-vous continuer à recevoir les nouvelles de ce tournoi ?"],
    "not_qualified": ["Non qualifié : {t}", "La phase de championnat est terminée. Voulez-vous suivre la phase à élimination ?"],
    "round_complete_ko": ["{round} terminé", "{t} : il reste {n} joueurs."],
    "round_complete_league": ["Journée {round} terminée", "{t} : vous êtes {rank}e avec {pts} points."],
    "champion_you": ["Vous avez gagné {t} !", "Champion. Bravo."],
    "champion": ["{champ} remporte {t}", "Le tournoi est terminé. Merci de l'avoir suivi."]
  },
  "rw": {
    "registered": ["Wiyandikishije: {t}", "Tuzakumenyesha igihe imikino izashyirwa ahagaragara."],
    "published": ["Imikino yasohotse: {t}", "Umukino wawe wa mbere: na {opp}, {when} (isaha yawe)."],
    "published_bye": ["Imikino yasohotse: {t}", "Wakomeje mu cyiciro gikurikira utakinnye. Tuzakubwira umukino wawe ukurikira."],
    "next_match": ["Umukino ukurikira: na {opp}", "{t}, {round}: {when} (isaha yawe)."],
    "rescheduled": ["Isaha y'umukino yahindutse", "{t}: umukino na {opp} ubu ni {when} (isaha yawe)."],
    "reminder": ["Umukino mu isaha 1", "{t}: na {opp} saa {when}. Itegure."],
    "room_open": ["Kode y'umukino iriteguye", "Na {opp}. Fungura icyumba, koporora kode ukande Kina."],
    "result_win": ["Watsinze {score}", "{t}: watsinze {opp}."],
    "result_loss": ["Watsinzwe {score}", "{t}: {opp} ni we watsinze."],
    "result_draw": ["Mwanganyije {score}", "{t}: wanganyije na {opp}."],
    "under_review": ["Umukino uri gusuzumwa", "{t}: umukino wawe na {opp} uri gusuzumwa n'umuyobozi."],
    "knocked_out": ["Wasezerewe muri {t}", "Murakoze gukina. Urashaka gukomeza kubona amakuru y'iri rushanwa?"],
    "not_qualified": ["Ntiwabonye itike: {t}", "Icyiciro cya shampiyona cyarangiye. Urashaka gukurikira icyiciro cyo gusezerera?"],
    "round_complete_ko": ["{round} cyarangiye", "{t}: hasigaye abakinnyi {n}."],
    "round_complete_league": ["Umunsi wa {round} wa shampiyona urangiye", "{t}: uri ku mwanya wa {rank} n'amanota {pts}."],
    "champion_you": ["Wegukanye {t}!", "Uri uwa mbere. Wakoze neza."],
    "champion": ["{champ} yegukanye {t}", "Irushanwa rirangiye. Murakoze kurikurikira."]
  }
  }$j$::jsonb;
  pair jsonb; v_title text; v_body text; k text;
begin
  pair := coalesce(tpl -> coalesce(p_lang, 'en') -> p_kind, tpl -> 'en' -> p_kind);
  if pair is null then return jsonb_build_object('title', p_kind, 'body', ''); end if;
  v_title := pair ->> 0; v_body := pair ->> 1;
  for k in select jsonb_object_keys(coalesce(p, '{}'::jsonb)) loop
    v_title := replace(v_title, '{' || k || '}', coalesce(p ->> k, ''));
    v_body := replace(v_body, '{' || k || '}', coalesce(p ->> k, ''));
  end loop;
  return jsonb_build_object('title', v_title, 'body', v_body);
end $$;

create or replace function public._round_name(p_tid uuid, p_stage text, p_round int, p_lang text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_last int; v_left int; l text := coalesce(p_lang, 'en');
begin
  if p_stage = 'league' then
    return case l when 'fr' then 'journée ' when 'rw' then 'umunsi wa ' else 'league round ' end || p_round;
  end if;
  select max(round) into v_last from fixtures where tournament_id = p_tid and stage = 'knockout';
  v_left := coalesce(v_last, p_round) - p_round;
  return case
    when v_left = 0 then case l when 'fr' then 'Finale' when 'rw' then 'Umukino wa nyuma' else 'Final' end
    when v_left = 1 then case l when 'fr' then 'Demi-finales' when 'rw' then 'Kimwe cya kabiri' else 'Semi-finals' end
    when v_left = 2 then case l when 'fr' then 'Quarts de finale' when 'rw' then 'Kimwe cya kane' else 'Quarter-finals' end
    when v_left = 3 then case l when 'fr' then 'Huitièmes de finale' when 'rw' then '16 ba nyuma' else 'Round of 16' end
    else case l when 'fr' then 'Tour ' when 'rw' then 'Icyiciro cya ' else 'Round ' end || p_round
  end;
end $$;

-- ---------------------------------------------------------------- the one place notifications are created
-- p_wide: a tournament-wide update, only for people still playing or who chose to keep following.
create or replace function public._notify(
  p_user uuid, p_tid uuid, p_fixture uuid, p_kind text, p_params jsonb, p_dedupe text,
  p_url text default null, p_actions jsonb default null, p_wide boolean default false, p_at timestamptz default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_lang text; v_tz text; v_params jsonb := coalesce(p_params, '{}'::jsonb); v_msg jsonb; v_name text; v_slug text;
begin
  if p_user is null then return; end if;
  if p_wide and not exists (select 1 from tournament_follows where user_id = p_user and tournament_id = p_tid and state in ('playing', 'following')) then
    return;
  end if;
  select pr.lang, c.tz into v_lang, v_tz from profiles pr left join countries c on c.code = pr.country where pr.id = p_user;
  select name, slug into v_name, v_slug from tournaments where id = p_tid;
  v_params := v_params || jsonb_build_object('t', coalesce(v_name, ''));
  if p_at is not null then
    v_params := v_params || jsonb_build_object('when', to_char(p_at at time zone coalesce(v_tz, 'Africa/Kigali'), 'DD/MM HH24:MI'));
  end if;
  v_msg := _msg(v_lang, p_kind, v_params);
  insert into notifications (user_id, tournament_id, fixture_id, kind, title, body, url, actions, dedupe_key)
  values (p_user, p_tid, p_fixture, p_kind, v_msg ->> 'title', v_msg ->> 'body',
          coalesce(p_url, case when v_slug is not null then '/t/' || v_slug end), p_actions, p_dedupe)
  on conflict (user_id, dedupe_key) do nothing;
end $$;

create or replace function public._opp_name(p_fixture fixtures, p_me uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(display_name, username) from profiles
  where id = case when p_fixture.player_a_id = p_me then p_fixture.player_b_id else p_fixture.player_a_id end
$$;

-- knocked out / not qualified: one last notification with a choice
create or replace function public._eliminated(p_user uuid, p_tid uuid, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into tournament_follows (user_id, tournament_id, state) values (p_user, p_tid, 'asked')
  on conflict (user_id, tournament_id) do update set state = 'asked', updated_at = now()
  where tournament_follows.state = 'playing';
  perform _notify(p_user, p_tid, null, p_kind, '{}', 'out:' || p_tid,
    '/me.html?t=' || p_tid || '#notifications',
    '[{"action":"follow","title":"Keep following"},{"action":"stop","title":"Stop"}]'::jsonb);
end $$;

-- ---------------------------------------------------------------- registration
create or replace function public._entry_notify() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'withdrawn' then
    update tournament_follows set state = 'stopped', updated_at = now() where user_id = new.user_id and tournament_id = new.tournament_id;
    return new;
  end if;
  if tg_op = 'INSERT' or old.status = 'withdrawn' then
    insert into tournament_follows (user_id, tournament_id, state) values (new.user_id, new.tournament_id, 'playing')
    on conflict (user_id, tournament_id) do update set state = 'playing', updated_at = now();
    perform _notify(new.user_id, new.tournament_id, null, 'registered', '{}', 'reg:' || new.tournament_id);
  end if;
  return new;
end $$;
create trigger tournament_entries_notify after insert or update of status on public.tournament_entries
  for each row execute function public._entry_notify();

-- ---------------------------------------------------------------- publish and champion
create or replace function public._tournament_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare e record; f fixtures; v_champ text; r record;
begin
  if old.status = 'planning' and new.status = 'live' then
    for e in select user_id from tournament_entries where tournament_id = new.id and status <> 'withdrawn' loop
      select * into f from fixtures
      where tournament_id = new.id and e.user_id in (player_a_id, player_b_id) and player_a_id is not null and player_b_id is not null
        and status = 'scheduled' order by scheduled_at nulls last limit 1;
      if f.id is not null then
        perform _notify(e.user_id, new.id, f.id, 'published', jsonb_build_object('opp', _opp_name(f, e.user_id)), 'pub:' || new.id,
                        '/matchroom.html?f=' || f.id, null, false, f.scheduled_at);
      else
        perform _notify(e.user_id, new.id, null, 'published_bye', '{}', 'pub:' || new.id);
      end if;
    end loop;
  elsif new.status = 'completed' and old.status is distinct from 'completed' and new.champion_id is not null then
    select coalesce(display_name, username) into v_champ from profiles where id = new.champion_id;
    perform _notify(new.champion_id, new.id, null, 'champion_you', '{}', 'champ:' || new.id);
    for r in select user_id from tournament_follows where tournament_id = new.id and user_id <> new.champion_id loop
      perform _notify(r.user_id, new.id, null, 'champion', jsonb_build_object('champ', v_champ), 'champ:' || new.id, null, null, true);
    end loop;
  end if;
  return new;
end $$;
create trigger tournaments_notify after update of status on public.tournaments
  for each row execute function public._tournament_notify();

-- ---------------------------------------------------------------- results, reviews, times, rounds
create or replace function public._fixture_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  t tournaments; p uuid; v_me int; v_opp int; v_kind text; v_left int; v_lang text; r record; v_top uuid[];
begin
  select * into t from tournaments where id = new.tournament_id;
  if t.status not in ('live', 'completed') or new.player_a_id is null or new.player_b_id is null then return new; end if;

  -- a match result
  if new.status = 'completed' and old.status is distinct from 'completed' then
    foreach p in array array[new.player_a_id, new.player_b_id] loop
      v_me := case when p = new.player_a_id then new.score_a else new.score_b end;
      v_opp := case when p = new.player_a_id then new.score_b else new.score_a end;
      v_kind := case when new.winner_id is null then 'result_draw' when new.winner_id = p then 'result_win' else 'result_loss' end;
      perform _notify(p, t.id, new.id, v_kind,
        jsonb_build_object('opp', _opp_name(new, p), 'score', case when v_me is null then '' else v_me || '-' || v_opp end),
        'res:' || new.id, '/t/' || t.slug);
    end loop;
    if new.stage = 'knockout' and new.winner_id is not null then
      perform _eliminated(case when new.winner_id = new.player_a_id then new.player_b_id else new.player_a_id end, t.id, 'knocked_out');
    end if;

    -- the round is complete?
    if not exists (select 1 from fixtures where tournament_id = t.id and stage = new.stage and round = new.round
                   and status not in ('completed', 'bye', 'cancelled')) then
      if new.stage = 'knockout' then
        select count(*) into v_left from fixtures where tournament_id = t.id and stage = 'knockout' and round = new.round and winner_id is not null;
        for r in select user_id from tournament_follows where tournament_id = t.id loop
          select lang into v_lang from profiles where id = r.user_id;
          perform _notify(r.user_id, t.id, null, 'round_complete_ko',
            jsonb_build_object('round', _round_name(t.id, 'knockout', new.round, v_lang), 'n', v_left),
            'round:' || t.id || ':ko:' || new.round, null, null, true);
        end loop;
      else
        for r in select lt.user_id, lt.rank, lt.points from league_table(t.id) lt loop
          perform _notify(r.user_id, t.id, null, 'round_complete_league',
            jsonb_build_object('round', new.round, 'rank', r.rank, 'pts', r.points),
            'round:' || t.id || ':lg:' || new.round, null, null, true);
        end loop;
        -- league stage over in a league + knockout: tell those who did not qualify
        if t.format = 'league_knockout' and not exists (select 1 from fixtures where tournament_id = t.id and stage = 'league'
                                                        and status not in ('completed', 'cancelled', 'bye')) then
          select array_agg(user_id) into v_top from (select user_id from league_table(t.id) order by rank limit t.league_advance) q;
          for r in select user_id from tournament_entries where tournament_id = t.id and status <> 'withdrawn'
                   and not (user_id = any (coalesce(v_top, '{}'))) loop
            perform _eliminated(r.user_id, t.id, 'not_qualified');
          end loop;
        end if;
      end if;
    end if;

  -- sent to an admin for review
  elsif new.status = 'disputed' and old.status is distinct from 'disputed' then
    foreach p in array array[new.player_a_id, new.player_b_id] loop
      perform _notify(p, t.id, new.id, 'under_review', jsonb_build_object('opp', _opp_name(new, p)), 'review:' || new.id, '/t/' || t.slug);
    end loop;

  -- a new or changed time for an upcoming match
  elsif t.status = 'live' and new.status = 'scheduled' and new.scheduled_at is not null
        and new.scheduled_at is distinct from old.scheduled_at then
    foreach p in array array[new.player_a_id, new.player_b_id] loop
      if old.scheduled_at is null or old.player_a_id is null or old.player_b_id is null then
        select lang into v_lang from profiles where id = p;
        perform _notify(p, t.id, new.id, 'next_match',
          jsonb_build_object('opp', _opp_name(new, p), 'round', _round_name(t.id, new.stage, new.round, v_lang)),
          'next:' || new.id || ':' || extract(epoch from new.scheduled_at)::bigint, '/matchroom.html?f=' || new.id, null, false, new.scheduled_at);
      else
        perform _notify(p, t.id, new.id, 'rescheduled', jsonb_build_object('opp', _opp_name(new, p)),
          'time:' || new.id || ':' || extract(epoch from new.scheduled_at)::bigint, '/matchroom.html?f=' || new.id, null, false, new.scheduled_at);
      end if;
    end loop;
  end if;
  return new;
end $$;
create trigger fixtures_notify after update on public.fixtures
  for each row execute function public._fixture_notify();

-- ---------------------------------------------------------------- reminders (every minute)
create or replace function public._notify_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare f record; p uuid; v_n int := 0; v_key text;
begin
  for f in
    select fx.*, g.reveal_buffer_seconds from fixtures fx
    join tournaments t on t.id = fx.tournament_id join games g on g.id = t.game_id
    where t.status = 'live' and fx.status in ('scheduled', 'active') and fx.kickoff_at is null
      and fx.player_a_id is not null and fx.player_b_id is not null
      and fx.scheduled_at between now() - interval '5 minutes' and now() + interval '60 minutes'
  loop
    v_key := f.id || ':' || extract(epoch from f.scheduled_at)::bigint;
    foreach p in array array[f.player_a_id, f.player_b_id] loop
      if now() >= f.scheduled_at - make_interval(secs => f.reveal_buffer_seconds) then
        perform _notify(p, f.tournament_id, f.id, 'room_open', jsonb_build_object('opp', (select coalesce(display_name, username) from profiles where id = case when p = f.player_a_id then f.player_b_id else f.player_a_id end)),
                        'room:' || v_key, '/matchroom.html?f=' || f.id);
      elsif f.scheduled_at - now() > interval '15 minutes' then
        perform _notify(p, f.tournament_id, f.id, 'reminder', jsonb_build_object('opp', (select coalesce(display_name, username) from profiles where id = case when p = f.player_a_id then f.player_b_id else f.player_a_id end)),
                        'rem:' || v_key, '/matchroom.html?f=' || f.id, null, false, f.scheduled_at);
      end if;
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end $$;

do $$ begin
  perform cron.schedule('winzone-notify', '* * * * *', 'select public._notify_reminders()');
exception when others then raise notice 'pg_cron not available: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------- phone push: hand each new notification to the sender
create or replace function public._push_notification() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text;
begin
  if not exists (select 1 from push_subscriptions where user_id = new.user_id) then return new; end if;
  select value into v_url from app_private_config where key = 'push_url';
  select value into v_secret from app_private_config where key = 'push_secret';
  if v_url is null or v_secret is null then return new; end if;
  perform net.http_post(url := v_url, body := jsonb_build_object('notification_id', new.id),
                        headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', v_secret));
  return new;
exception when others then
  return new;   -- a push problem must never block a result, a registration or a schedule
end $$;
create trigger notifications_push after insert on public.notifications
  for each row execute function public._push_notification();

-- ---------------------------------------------------------------- player RPCs
create or replace function public.set_follow(p_tid uuid, p_follow boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  if not exists (select 1 from tournaments where id = p_tid and status <> 'draft') then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if exists (select 1 from tournament_follows where user_id = auth.uid() and tournament_id = p_tid and state = 'playing') then
    return jsonb_build_object('ok', true, 'state', 'playing');   -- still in the tournament: always informed
  end if;
  insert into tournament_follows (user_id, tournament_id, state)
  values (auth.uid(), p_tid, case when p_follow then 'following' else 'stopped' end)
  on conflict (user_id, tournament_id) do update set state = excluded.state, updated_at = now();
  return jsonb_build_object('ok', true, 'state', case when p_follow then 'following' else 'stopped' end);
end $$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null) returns int
language plpgsql security definer set search_path = public as $$
declare v int;
begin
  update notifications set read_at = now()
  where user_id = auth.uid() and read_at is null and (p_ids is null or id = any (p_ids));
  get diagnostics v = row_count;
  return v;
end $$;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', 'not_signed_in'); end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'bad_subscription');
  end if;
  insert into push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_ua, 300))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.delete_push_subscription(p_endpoint text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.set_my_lang(p_lang text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_lang not in ('en', 'fr', 'rw') then return jsonb_build_object('ok', false); end if;
  update profiles set lang = p_lang where id = auth.uid();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.my_profile() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name,
                              'country', p.country, 'country_name', c.name, 'tz', c.tz, 'lang', p.lang)
    from profiles p left join countries c on c.code = p.country where p.id = auth.uid()
  ), '{}'::jsonb)
$$;

-- sign-up stores the chosen language too
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_name text; v_try int := 0; v_country text; v_lang text;
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
  v_lang := coalesce(new.raw_user_meta_data ->> 'lang', 'en');
  if v_lang not in ('en', 'fr', 'rw') then v_lang := 'en'; end if;
  insert into profiles (id, username, display_name, country, lang)
  values (new.id, v_name, coalesce(new.raw_user_meta_data ->> 'display_name', v_name), v_country, v_lang);
  return new;
end $$;

-- live bell on the site
do $$ begin
  alter publication supabase_realtime add table public.notifications;
exception when others then raise notice 'realtime publication not available: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function public._msg(text, text, jsonb), public._round_name(uuid, text, int, text),
  public._notify(uuid, uuid, uuid, text, jsonb, text, text, jsonb, boolean, timestamptz), public._opp_name(fixtures, uuid),
  public._eliminated(uuid, uuid, text), public._entry_notify(), public._tournament_notify(), public._fixture_notify(),
  public._notify_reminders(), public._push_notification() from public, anon, authenticated;
revoke execute on function public.set_follow(uuid, boolean), public.mark_notifications_read(uuid[]),
  public.save_push_subscription(text, text, text, text), public.delete_push_subscription(text), public.set_my_lang(text) from public, anon;
grant execute on function public.set_follow(uuid, boolean), public.mark_notifications_read(uuid[]),
  public.save_push_subscription(text, text, text, text), public.delete_push_subscription(text), public.set_my_lang(text) to authenticated;
