-- WIN ZONE — 0014: demo tournaments show no prize line (the Demo label already explains them)
create or replace function public.create_demo_tournament(p_name text, p_size int default 8, p_format text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tid uuid; v_slug text; v_bots uuid[]; v_fmt text; b uuid; g uuid;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if p_size is null or p_size < 4 or p_size > 64 then return jsonb_build_object('ok', false, 'reason', 'size_4_to_64'); end if;
  v_fmt := coalesce(nullif(p_format, ''), recommend_format(p_size));
  if v_fmt not in ('knockout', 'league', 'league_knockout', 'groups_knockout', 'league_phase') then
    return jsonb_build_object('ok', false, 'reason', 'bad_format');
  end if;
  select id into g from games where active order by slug limit 1;
  v_slug := 'demo-' || substr(md5(random()::text), 1, 6);
  insert into tournaments (slug, name, game_id, format, size, status, is_demo, created_by, starts_at, prize_description, schedule_speed)
  values (v_slug, left(coalesce(nullif(trim(p_name), ''), 'Demo Cup'), 60), g, v_fmt, p_size, 'open', true, auth.uid(),
          now() + interval '5 minutes', null, 'oneday')
  returning id into v_tid;
  v_bots := _ensure_bots(p_size);
  foreach b in array v_bots loop
    insert into tournament_entries (tournament_id, user_id) values (v_tid, b);   -- the last one fills it and plans it
  end loop;
  update tournaments set status = 'live' where id = v_tid and status = 'planning';
  perform _play_demo();
  insert into audit_logs (actor, action, entity, entity_id) values (auth.uid(), 'create_demo_tournament', 'tournament', v_tid);
  return jsonb_build_object('ok', true, 'id', v_tid, 'slug', v_slug);
end $$;
update public.tournaments set prize_description = null where is_demo and prize_description = 'Demo: played by bots, no prize';
