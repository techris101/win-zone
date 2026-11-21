-- WIN ZONE — 0020: automatic cleanup to stay inside the free plan
-- Seven days after a tournament ends (time for late disputes) its bulky match data is deleted: phone readings,
-- match states, codes, app passes and play links, event logs, raw match reports, dispute screenshots and records,
-- notifications and follow settings. The tournament, its players and every final score stay, so rankings, titles,
-- player pages and statistics remain correct. Demo tournaments are deleted completely one day after they finish.
-- Expired play links and passes are removed everywhere after a day. Runs every night.

alter table public.tournaments add column finished_at timestamptz;
alter table public.tournaments add column cleaned_at timestamptz;
update public.tournaments t set finished_at = coalesce((select max(completed_at) from public.fixtures f where f.tournament_id = t.id), now())
where t.status in ('completed', 'cancelled') and t.finished_at is null;

create or replace function public._mark_finished() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('completed', 'cancelled') and old.status is distinct from new.status then new.finished_at := now();
  elsif new.status not in ('completed', 'cancelled') then new.finished_at := null; new.cleaned_at := null;
  end if;
  return new;
end $$;
create trigger tournaments_finished before update of status on public.tournaments
  for each row execute function public._mark_finished();

-- deletes the bulky data of a set of fixtures; returns the screenshot files that the storage service must remove
create or replace function public._purge_fixtures(p_ids uuid[]) returns text[]
language plpgsql security definer set search_path = public as $$
declare v_files text[];
begin
  select coalesce(array_agg(path), '{}') into v_files from dispute_evidence where fixture_id = any(p_ids);
  delete from dispute_evidence where fixture_id = any(p_ids);
  delete from disputes where fixture_id = any(p_ids);
  delete from match_state_log where fixture_id = any(p_ids);
  delete from match_latest_state where fixture_id = any(p_ids);
  delete from matchrooms where fixture_id = any(p_ids);
  delete from app_handoffs where fixture_id = any(p_ids);
  delete from match_passes where fixture_id = any(p_ids);
  delete from match_events where fixture_id = any(p_ids);
  delete from match_reports where fixture_id = any(p_ids);
  return v_files;
end $$;

-- asks the storage service to delete files (through the cleanup-files function, with the push hook secret)
create or replace function public._delete_files(p_paths text[]) returns void
language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text; i int := 1;
begin
  if coalesce(array_length(p_paths, 1), 0) = 0 then return; end if;
  select replace(value, '/send-push', '/cleanup-files') into v_url from app_private_config where key = 'push_url';
  select value into v_secret from app_private_config where key = 'push_secret';
  if v_url is null or v_secret is null then return; end if;
  while i <= array_length(p_paths, 1) loop
    perform net.http_post(url := v_url, body := jsonb_build_object('paths', to_jsonb(p_paths[i:i + 99])),
                          headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', v_secret));
    i := i + 100;
  end loop;
exception when others then
  raise notice 'file cleanup not sent: %', sqlerrm;   -- never block the database cleanup
end $$;

create or replace function public._cleanup() returns jsonb
language plpgsql security definer set search_path = public as $$
declare t tournaments; v_ids uuid[]; v_files text[] := '{}'; v_n int := 0; v_demo int := 0;
begin
  -- demo tournaments: gone completely a day after they finish
  for t in select * from tournaments where is_demo and status in ('completed', 'cancelled') and finished_at < now() - interval '1 day' loop
    select coalesce(array_agg(id), '{}') into v_ids from fixtures where tournament_id = t.id;
    v_files := v_files || _purge_fixtures(v_ids);
    delete from notifications where tournament_id = t.id;
    delete from tournaments where id = t.id;
    v_demo := v_demo + 1;
  end loop;

  -- real tournaments: bulky data gone seven days after they finish, results kept
  for t in select * from tournaments where not is_demo and status in ('completed', 'cancelled') and cleaned_at is null
             and finished_at < now() - interval '7 days' loop
    select coalesce(array_agg(id), '{}') into v_ids from fixtures where tournament_id = t.id;
    v_files := v_files || _purge_fixtures(v_ids);
    delete from notifications where tournament_id = t.id;
    delete from tournament_follows where tournament_id = t.id;
    update tournaments set cleaned_at = now() where id = t.id;
    insert into audit_logs (action, entity, entity_id, details)
    values ('cleanup_tournament', 'tournament', t.id, jsonb_build_object('fixtures', coalesce(array_length(v_ids, 1), 0)));
    v_n := v_n + 1;
  end loop;

  -- everywhere: play links and passes a day after they expired
  delete from app_handoffs where expires_at < now() - interval '1 day';
  delete from match_passes where expires_at < now() - interval '1 day';

  perform _delete_files(v_files);
  return jsonb_build_object('tournaments', v_n, 'demos', v_demo, 'files', coalesce(array_length(v_files, 1), 0));
end $$;

revoke execute on function public._mark_finished(), public._purge_fixtures(uuid[]), public._delete_files(text[]), public._cleanup()
  from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

do $$ begin
  perform cron.schedule('winzone-cleanup', '17 1 * * *', 'select public._cleanup()');
exception when others then raise notice 'pg_cron not available: %', sqlerrm;
end $$;
