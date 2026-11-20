-- WIN ZONE — 0001 schema
-- One schema, no money tables. Logic lives in RPCs (0002, 0003). Access rules in 0004.

-- ---------------------------------------------------------------- identity
create table public.profiles (
  id               uuid primary key,
  username         text not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  display_name     text,
  avatar_url       text,
  is_bot           boolean not null default false,
  age_confirmed_at timestamptz,
  created_at       timestamptz not null default now()
);
create unique index profiles_username_ci on public.profiles (lower(username));

create table public.user_roles (
  user_id uuid not null,
  role    text not null check (role in ('admin', 'organizer')),
  primary key (user_id, role)
);

-- ---------------------------------------------------------------- games
-- Public name is generic on purpose. Technical details live in game_profiles (never public).
create table public.games (
  id                    uuid primary key default gen_random_uuid(),
  slug                  text not null unique,
  name                  text not null,
  room_code_model       text not null check (room_code_model in ('platform_issued', 'host_issued')),
  regulation_seconds    int  not null default 5400,   -- 90:00
  extra_time_seconds    int  not null default 7200,   -- 120:00
  reveal_buffer_seconds int  not null default 120,
  checkin_seconds       int  not null default 300,
  room_code_pattern     text not null default '^[A-Za-z0-9]{4,12}$',
  active                boolean not null default true
);

create table public.game_profiles (
  game_id     uuid primary key references public.games (id) on delete cascade,
  profile     jsonb not null default '{}'::jsonb,
  flag_secure boolean,
  verified_at timestamptz
);

-- ---------------------------------------------------------------- tournaments
create table public.tournaments (
  id                      uuid primary key default gen_random_uuid(),
  slug                    text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name                    text not null,
  game_id                 uuid not null references public.games (id),
  format                  text not null check (format in ('knockout', 'league', 'league_knockout')),
  size                    int  not null check (size between 2 and 128),   -- max players
  league_advance          int  not null default 4 check (league_advance in (2, 4, 8, 16)),
  status                  text not null default 'draft'
                          check (status in ('draft', 'open', 'live', 'completed', 'cancelled')),
  starts_at               timestamptz,
  registration_closes_at  timestamptz,
  prize_description       text,
  champion_id             uuid,
  created_by              uuid,
  created_at              timestamptz not null default now()
);

create table public.tournament_entries (
  tournament_id uuid not null references public.tournaments (id) on delete cascade,
  user_id       uuid not null,
  seed          int,
  status        text not null default 'registered'
                check (status in ('registered', 'checked_in', 'eliminated', 'withdrawn')),
  created_at    timestamptz not null default now(),
  primary key (tournament_id, user_id)
);

-- ---------------------------------------------------------------- fixtures
create table public.fixtures (
  id              uuid primary key default gen_random_uuid(),
  tournament_id   uuid not null references public.tournaments (id) on delete cascade,
  stage           text not null check (stage in ('league', 'knockout')),
  round           int  not null,
  slot            int  not null,
  player_a_id     uuid,
  player_b_id     uuid,
  host_player_id  uuid,
  scheduled_at    timestamptz,
  status          text not null default 'scheduled'
                  check (status in ('scheduled', 'active', 'completed', 'disputed', 'cancelled', 'bye', 'stalled')),
  kickoff_at      timestamptz,
  winner_id       uuid,
  outcome         text,
  score_a         int,
  score_b         int,
  pen_a           int,
  pen_b           int,
  replay_count    int  not null default 0,
  completed_at    timestamptz,
  next_fixture_id uuid references public.fixtures (id),
  next_side       text check (next_side in ('A', 'B')),
  created_at      timestamptz not null default now(),
  unique (tournament_id, stage, round, slot)
);
create index fixtures_tournament_idx on public.fixtures (tournament_id);
create index fixtures_players_idx on public.fixtures (player_a_id, player_b_id);

-- Room codes. Never readable by clients directly (see 0004). Only app_join_fixture returns them.
create table public.matchrooms (
  id                       uuid primary key default gen_random_uuid(),
  fixture_id               uuid not null unique references public.fixtures (id) on delete cascade,
  room_code                text unique,
  room_code_source         text check (room_code_source in ('platform', 'host', 'admin')),
  room_code_submitted_at   timestamptz,
  room_code_capture_method text check (room_code_capture_method in ('ocr', 'manual', 'admin')),
  status                   text not null default 'pending',
  player_a_joined_at       timestamptz,
  player_b_joined_at       timestamptz,
  opened_at                timestamptz,
  closed_at                timestamptz
);

-- ---------------------------------------------------------------- match state
-- One row per player per fixture. Perspective is "me" and "opponent" (the game screen
-- can show the player on either side). Terminal reports are latched and never overwritten.
create table public.match_latest_state (
  fixture_id      uuid not null references public.fixtures (id) on delete cascade,
  user_id         uuid not null,
  layout          text not null check (layout in ('in_play', 'result', 'opponent_quit', 'menu', 'unknown')),
  score_me        int,
  score_opp       int,
  pen_me          int,
  pen_opp         int,
  clock_seconds   int,
  client_seq      bigint not null default 0,
  in_play_since   timestamptz,
  last_in_play_at timestamptz,
  terminal_kind   text check (terminal_kind in ('result', 'opponent_quit')),
  terminal_at     timestamptz,
  t_score_me      int,
  t_score_opp     int,
  t_pen_me        int,
  t_pen_opp       int,
  t_clock         int,
  updated_at      timestamptz not null default now(),
  primary key (fixture_id, user_id)
);

create table public.match_state_log (
  id            bigserial primary key,
  fixture_id    uuid not null,
  user_id       uuid not null,
  client_seq    bigint not null,
  layout        text not null,
  score_me      int,
  score_opp     int,
  pen_me        int,
  pen_opp       int,
  clock_seconds int,
  raw           jsonb,
  server_ts     timestamptz not null default now()
);
create index match_state_log_fixture_idx on public.match_state_log (fixture_id, server_ts);

create table public.match_events (
  id         bigserial primary key,
  fixture_id uuid not null,
  event_type text not null,
  actor      uuid,
  details    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index match_events_fixture_idx on public.match_events (fixture_id, created_at);

-- ---------------------------------------------------------------- disputes, sponsors, audit
create table public.disputes (
  id            uuid primary key default gen_random_uuid(),
  fixture_id    uuid not null references public.fixtures (id) on delete cascade,
  user_id       uuid not null,
  status        text not null default 'open' check (status in ('open', 'resolved')),
  note          text,
  evidence_path text,
  created_at    timestamptz not null default now(),
  unique (fixture_id, user_id)
);

create table public.sponsors (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  logo_url   text,
  website    text,
  created_at timestamptz not null default now()
);

create table public.sponsor_private (
  sponsor_id uuid primary key references public.sponsors (id) on delete cascade,
  contact    text,
  contract   jsonb not null default '{}'::jsonb
);

create table public.sponsor_placements (
  id             uuid primary key default gen_random_uuid(),
  tournament_id  uuid not null references public.tournaments (id) on delete cascade,
  sponsor_id     uuid not null references public.sponsors (id) on delete cascade,
  placement_type text not null check (placement_type in ('title', 'bracket_logo', 'round', 'prize')),
  display_order  int  not null default 0
);

create table public.organizer_tenants (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  owner_user_id uuid not null,
  branding      jsonb not null default '{}'::jsonb,
  plan          text not null default 'demo',
  created_at    timestamptz not null default now()
);

create table public.audit_logs (
  id         bigserial primary key,
  actor      uuid,
  action     text not null,
  entity     text,
  entity_id  uuid,
  details    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- seed: the v1 game
-- Public name is generic. Room-code model is provisional until verified on a real phone.
insert into public.games (slug, name, room_code_model)
values ('football-1v1', 'Football 1v1', 'host_issued');
insert into public.game_profiles (game_id, profile)
select id, '{}'::jsonb from public.games where slug = 'football-1v1';
