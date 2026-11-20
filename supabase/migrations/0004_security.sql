-- WIN ZONE — 0004 security
-- Default posture: nothing is readable or writable by API roles unless granted below.
-- Writes happen only through SECURITY DEFINER RPCs. Room codes are never directly readable.

-- ---------------------------------------------------------------- auth triggers
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
create trigger on_auth_user_deleted after delete on auth.users
  for each row execute function public.handle_deleted_user();

-- ---------------------------------------------------------------- start from zero
alter table public.profiles           enable row level security;
alter table public.user_roles         enable row level security;
alter table public.games              enable row level security;
alter table public.game_profiles      enable row level security;
alter table public.tournaments        enable row level security;
alter table public.tournament_entries enable row level security;
alter table public.fixtures           enable row level security;
alter table public.matchrooms         enable row level security;
alter table public.match_latest_state enable row level security;
alter table public.match_state_log    enable row level security;
alter table public.match_events       enable row level security;
alter table public.disputes           enable row level security;
alter table public.sponsors           enable row level security;
alter table public.sponsor_private    enable row level security;
alter table public.sponsor_placements enable row level security;
alter table public.organizer_tenants  enable row level security;
alter table public.audit_logs         enable row level security;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

-- ---------------------------------------------------------------- public reads (shareable pages)
grant select on public.games, public.tournaments, public.tournament_entries, public.fixtures,
                public.profiles, public.sponsors, public.sponsor_placements to anon, authenticated;
-- Column-limited: nothing private on profiles besides age_confirmed_at.
revoke select on public.profiles from anon, authenticated;
grant select (id, username, display_name, avatar_url, is_bot, created_at) on public.profiles to anon, authenticated;

create policy games_public          on public.games              for select using (active);
create policy profiles_public       on public.profiles           for select using (true);
create policy tournaments_public    on public.tournaments        for select using (status <> 'draft');
create policy tournaments_owner     on public.tournaments        for select to authenticated
  using (created_by = auth.uid() or public.is_admin());
create policy entries_public        on public.tournament_entries for select
  using (exists (select 1 from public.tournaments t where t.id = tournament_id and t.status <> 'draft'));
create policy fixtures_public       on public.fixtures           for select
  using (exists (select 1 from public.tournaments t where t.id = tournament_id and t.status <> 'draft'));
create policy sponsors_public       on public.sponsors           for select using (true);
create policy placements_public     on public.sponsor_placements for select using (true);

-- ---------------------------------------------------------------- own data
grant update (display_name, avatar_url) on public.profiles to authenticated;
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

grant select on public.user_roles to authenticated;
create policy roles_own on public.user_roles for select to authenticated using (user_id = auth.uid());

-- A participant may read BOTH rows of their fixture (needed for the agreement gate UI).
grant select on public.match_latest_state to authenticated;
create policy state_participants on public.match_latest_state for select to authenticated
  using (exists (select 1 from public.fixtures f
                 where f.id = fixture_id and auth.uid() in (f.player_a_id, f.player_b_id)));

grant select on public.disputes to authenticated;
create policy disputes_own on public.disputes for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- ---------------------------------------------------------------- admin reads
grant select on public.match_events, public.audit_logs, public.sponsor_private, public.organizer_tenants to authenticated;
create policy events_admin   on public.match_events      for select to authenticated using (public.is_admin());
create policy audit_admin    on public.audit_logs        for select to authenticated using (public.is_admin());
create policy sponsorp_admin on public.sponsor_private   for select to authenticated using (public.is_admin());
create policy tenants_admin  on public.organizer_tenants for select to authenticated
  using (public.is_admin() or owner_user_id = auth.uid());

-- Admin sponsor management (direct writes, admin only).
grant insert, update, delete on public.sponsors, public.sponsor_placements to authenticated;
create policy sponsors_admin_w   on public.sponsors           for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy placements_admin_w on public.sponsor_placements for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- matchrooms, game_profiles, match_state_log: no grants, no policies => unreachable from the API.

-- ---------------------------------------------------------------- RPC grants
grant execute on function
  public.register_for_tournament(uuid), public.withdraw_from_tournament(uuid),
  public.app_join_fixture(uuid), public.submit_room_code(uuid, text, text),
  public.report_host_blocked(uuid, text),
  public.submit_screen_state(uuid, text, int, int, int, int, int, bigint, jsonb),
  public.finalize_fixture(uuid), public.open_dispute(uuid, text),
  public.create_tournament(text, text, text, text, int, timestamptz, text, int),
  public.set_tournament_status(uuid, text), public.generate_tournament(uuid),
  public.schedule_fixtures(uuid, text, int, timestamptz, int),
  public.resolve_fixture(uuid, text, text), public.regenerate_room_code(uuid),
  public.submit_room_code_as_admin(uuid, text, text),
  public.is_admin(), public.is_organizer()
to authenticated;
grant execute on function public.league_table(uuid) to anon, authenticated;
-- internal helpers (_x), grant_role and sweep_fixtures stay unreachable from the API.

-- ---------------------------------------------------------------- live updates
do $$ begin
  alter publication supabase_realtime add table public.fixtures, public.tournaments,
    public.tournament_entries, public.match_latest_state;
exception when others then raise notice 'realtime publication not available: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------- scheduled sweep (every minute)
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('winzone-sweep', '* * * * *', 'select public.sweep_fixtures()');
exception when others then raise notice 'pg_cron not available: %', sqlerrm;
end $$;
