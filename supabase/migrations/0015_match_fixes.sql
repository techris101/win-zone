-- WIN ZONE — 0015 match fixes and the 5-minute reminder
-- 1. A result is accepted when both phones reported the end of the match, even if kick-off was not seen.
-- 2. A match that was played but has only one phone's result goes to the admins after 20 minutes;
--    a match with no result 3 hours after its time is flagged as stalled. Demo matches are left to the demo player.
-- 3. Players get "Kick-off in 5 minutes" (in their language) besides the 1-hour reminder and "code ready".
-- 4. Screen rules: the game clock may be anywhere at the top during play.

create or replace function public._evaluate_fixture(p_fixture_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  f fixtures; g games; sa match_latest_state; sb match_latest_state;
  ca text; cb text; a_claim boolean; b_claim boolean;
  v_a_me int; v_a_opp int; v_winner uuid; v_pa int; v_pb int;
begin
  select * into f from fixtures where id = p_fixture_id;
  select gm.* into g from tournaments t join games gm on gm.id = t.game_id where t.id = f.tournament_id;
  select * into sa from match_latest_state where fixture_id = f.id and user_id = f.player_a_id;
  select * into sb from match_latest_state where fixture_id = f.id and user_id = f.player_b_id;

  -- Kick-off is normally seen by both phones. If it was missed (for example the app was started late) but both
  -- phones reported the end of the match, those two reports are enough. One report alone still waits.
  if f.kickoff_at is null and (sa.terminal_kind is null or sb.terminal_kind is null) then
    return jsonb_build_object('status', 'wait', 'reason', 'no_kickoff');
  end if;
  if sa.terminal_kind is null and sb.terminal_kind is null then
    return jsonb_build_object('status', 'wait', 'reason', 'no_terminal');
  end if;

  ca := case when sa.terminal_kind is null then null
             when sa.terminal_kind = 'opponent_quit' then 'quit'
             else _clock_class(f.stage, sa.t_clock, g.regulation_seconds, g.extra_time_seconds) end;
  cb := case when sb.terminal_kind is null then null
             when sb.terminal_kind = 'opponent_quit' then 'quit'
             else _clock_class(f.stage, sb.t_clock, g.regulation_seconds, g.extra_time_seconds) end;
  a_claim := ca in ('quit', 'early');
  b_claim := cb in ('quit', 'early');

  -- Forfeit paths: the phone that still shows a result wins, whatever the score.
  if a_claim and b_claim then
    return jsonb_build_object('status', 'dispute', 'reason', 'both_claim_forfeit');
  elsif a_claim or b_claim then
    declare
      w match_latest_state := case when a_claim then sa else sb end;
      o match_latest_state := case when a_claim then sb else sa end;
    begin
      if o.terminal_kind is not null then
        return jsonb_build_object('status', 'dispute', 'reason', 'conflicting_terminals');
      end if;
      if now() - w.terminal_at < interval '20 seconds' then
        return jsonb_build_object('status', 'wait', 'reason', 'grace');
      end if;
      if o.last_in_play_at is not null and o.last_in_play_at > w.terminal_at + interval '2 seconds' then
        return jsonb_build_object('status', 'dispute', 'reason', 'opponent_still_playing');
      end if;
      return jsonb_build_object(
        'status', 'win', 'outcome', 'win_by_forfeit', 'winner_id', w.user_id,
        'score_a', case when a_claim then w.t_score_me else w.t_score_opp end,
        'score_b', case when a_claim then w.t_score_opp else w.t_score_me end,
        'pen_a',   case when a_claim then w.t_pen_me else w.t_pen_opp end,
        'pen_b',   case when a_claim then w.t_pen_opp else w.t_pen_me end);
    end;
  end if;

  -- Normal full time: both phones must have reported a result.
  if sa.terminal_kind is null or sb.terminal_kind is null then
    return jsonb_build_object('status', 'wait', 'reason', 'waiting_for_other_phone');
  end if;
  if ca = 'anomaly' or cb = 'anomaly' then
    return jsonb_build_object('status', 'dispute', 'reason', 'clock_anomaly');
  end if;
  if ca <> cb then
    return jsonb_build_object('status', 'dispute', 'reason', 'clock_mismatch');
  end if;
  -- Mirror check: my goals on one phone must equal opponent goals on the other.
  if sa.t_score_me is distinct from sb.t_score_opp or sa.t_score_opp is distinct from sb.t_score_me
     or coalesce(sa.t_pen_me, -1) <> coalesce(sb.t_pen_opp, -1)
     or coalesce(sa.t_pen_opp, -1) <> coalesce(sb.t_pen_me, -1) then
    return jsonb_build_object('status', 'dispute', 'reason', 'score_mismatch');
  end if;

  v_a_me := sa.t_score_me; v_a_opp := sa.t_score_opp;
  v_pa := sa.t_pen_me;     v_pb := sa.t_pen_opp;
  if v_a_me > v_a_opp then v_winner := f.player_a_id;
  elsif v_a_me < v_a_opp then v_winner := f.player_b_id;
  elsif v_pa is not null and v_pb is not null and v_pa <> v_pb then
    v_winner := case when v_pa > v_pb then f.player_a_id else f.player_b_id end;
  end if;

  if v_winner is null then
    if f.stage in ('league', 'group') then
      return jsonb_build_object('status', 'draw', 'outcome', 'draw',
        'score_a', v_a_me, 'score_b', v_a_opp, 'pen_a', v_pa, 'pen_b', v_pb);
    end if;
    return jsonb_build_object('status', 'dispute', 'reason', 'knockout_level_no_winner');
  end if;
  -- A knockout cannot end level at regulation; a draw here means the screen was misread.
  if f.stage in ('knockout', 'playoff') and ca = 'regulation' and v_a_me = v_a_opp then
    return jsonb_build_object('status', 'dispute', 'reason', 'knockout_level_at_regulation');
  end if;

  return jsonb_build_object('status', 'win', 'outcome', 'win_by_score', 'winner_id', v_winner,
    'score_a', v_a_me, 'score_b', v_a_opp, 'pen_a', v_pa, 'pen_b', v_pb);
end $$;

create or replace function public.sweep_fixtures() returns int
language plpgsql security definer set search_path = public as $$
declare
  f fixtures; g games; mr matchrooms; v_n int := 0; v_deadline timestamptz; v_stale boolean;
  v_host_blocked boolean;
begin
  for f in select fx.* from fixtures fx join tournaments tt on tt.id = fx.tournament_id
           where tt.status = 'live' and not tt.is_demo and fx.status in ('scheduled', 'active', 'stalled') and fx.scheduled_at is not null loop
    select gm.* into g from tournaments t join games gm on gm.id = t.game_id where t.id = f.tournament_id;
    select * into mr from matchrooms where fixture_id = f.id;
    v_deadline := f.scheduled_at + make_interval(secs => g.checkin_seconds);

    -- 1. decided fixtures: settle even if both apps were closed (also when kick-off was missed but both phones reported the end)
    if f.kickoff_at is not null or (select count(*) from match_latest_state where fixture_id = f.id and terminal_kind is not null) = 2 then
      if _finalize(f.id, null) ->> 'ok' = 'true' and (select status from fixtures where id = f.id) in ('completed', 'disputed') then
        v_n := v_n + 1;
        continue;
      end if;
    end if;

    -- 1b. played but never settled: the phones were used but kick-off was missed and one end report is missing.
    --     After 20 minutes an admin decides (it appears in "Needs attention").
    if f.kickoff_at is null and f.scheduled_at < now() - interval '20 minutes'
       and exists (select 1 from match_latest_state where fixture_id = f.id and terminal_kind is not null) then
      update fixtures set status = 'disputed' where id = f.id;
      perform _event(f.id, 'disputed', null, '{"reason":"result_from_one_phone"}');
      v_n := v_n + 1;
      continue;
    end if;
    if f.kickoff_at is null and f.status = 'active' and f.scheduled_at < now() - interval '3 hours' then
      update fixtures set status = 'stalled' where id = f.id;
      perform _event(f.id, 'stalled', null, '{"reason":"no_result"}');
      v_n := v_n + 1;
      continue;
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
    "soon": ["Kick-off in 5 minutes", "{t}: vs {opp}. Open the match room now; the code appears 2 minutes before kick-off."],
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
    "soon": ["Coup d'envoi dans 5 minutes", "{t} : contre {opp}. Ouvrez la salle du match ; le code apparaît 2 minutes avant."],
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
    "soon": ["Umukino utangira mu minota 5", "{t}: na {opp}. Fungura icyumba cy'umukino; kode igaragara iminota 2 mbere."],
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
      elsif f.scheduled_at - now() <= interval '6 minutes' then
        perform _notify(p, f.tournament_id, f.id, 'soon', jsonb_build_object('opp', (select coalesce(display_name, username) from profiles where id = case when p = f.player_a_id then f.player_b_id else f.player_a_id end)),
                        'soon:' || v_key, '/matchroom.html?f=' || f.id);
      elsif f.scheduled_at - now() > interval '15 minutes' then
        perform _notify(p, f.tournament_id, f.id, 'reminder', jsonb_build_object('opp', (select coalesce(display_name, username) from profiles where id = case when p = f.player_a_id then f.player_b_id else f.player_a_id end)),
                        'rem:' || v_key, '/matchroom.html?f=' || f.id, null, false, f.scheduled_at);
      end if;
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end $$;

update public.game_profiles set profile = profile || '{"inplay_clock_anywhere": true, "inplay_top_band": [0, 0.3], "version": 2}'::jsonb;

revoke execute on function public._evaluate_fixture(uuid), public._msg(text, text, jsonb), public._notify_reminders() from public, anon, authenticated;
grant execute on all functions in schema public to service_role;
