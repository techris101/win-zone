# WIN ZONE — Canonical Specification (v3)

Single source of truth. Supersedes every earlier WIN ZONE document. Where this file is silent, nothing is decided.
Corrections against the v2 draft are listed in section 14. The v1 game is never named in public files, in the app, or in this repo; its technical details live only in the backend (`game_profiles`).

## 1. What WIN ZONE is
A tournament operating system for 1v1 mobile football. Organizers create tournaments, players register free, the system builds the bracket or league, schedules fixtures, and opens a matchroom per fixture. Players tap Play in the Android app, which reads the match screen on the phone (OCR, every 2 s) and reports state. The server reconciles both phones and decides the result. There is no entry fee, no stake and no subscription. Revenue comes from sponsorship, advertising (after a domain is bought), media/data and B2B licensing of the engine.

## 2. Surfaces
| Surface | Job | Never does |
|---|---|---|
| Android app | login, register, next fixture, matchroom, Play, capture + OCR, report state, show own result | money, public brackets, deciding results |
| Web | public tournament pages, registration, matchroom fallback, organizer/admin panel, legal pages | match experience, business logic |
| Backend (Supabase) | auth, tables, RLS, all rules as RPCs | UI |

Logic lives once, in the backend. If a rule appears in two places it is a bug.

## 3. Formats and match rules
- **Formats** (research in `docs/RESEARCH.md`; recommended automatically by player count, admin can override):
  - `league` (2-6): everyone plays everyone once.
  - `league_knockout` (7-11): league, then the top N (2/4/8/16) in a knockout seeded by table rank.
  - `groups_knockout` (12-31): groups of 3-4 (snake seeding); top 2 + best third-placed players fill the next bracket size (World Cup 2026 / AFCON). If there are not enough third-placed players the bracket shrinks to group winners + best runners-up. Cross-group comparisons are per match played.
  - `league_phase` (32+): Swiss pairing, 6 rounds by default (at least log2 of the players, max 12), no rematches (backtracking), one bye per round with an odd number (a win, no goals). Then knockout size 16 (32+ players), 8 (16+) or 4: the top half qualify directly, the next ranks play a single play-off round (9th v 24th ...), the rest are out (Champions League).
  - `knockout`: any size.
- **Tie-break order (every table):** points, goal difference, goals scored, head-to-head points among the tied, wins, strength of opponents (their total points), fewer forfeit/no-show losses, earlier registration.
- **Speeds:** standard (a round every 48 h at the slot hour), fast (24 h), one-day (every 45 minutes from the start time).
- **League:** single round robin. Points 3/1/0. A forfeit or no-show win counts 3-0 in the table. A fixture that is `disputed` blocks completion of the league until an admin resolves it.
- **Knockout:** standard seeding, byes to top seeds, winner advances through `next_fixture_id`. A slot fills once; a second fill raises an error.
- **Clocks:** regulation 90:00, knockout extra time 120:00, with 5 s of tolerance. Penalty scores appear in brackets beside the score on the result screen.

### Tournament lifecycle (admin stays in control)
`draft` -> `open` -> `planning` -> `live` -> `completed` (or `cancelled`).
1. **Open:** players register. A country is required (it decides the time zone they see). Registration closes by itself when the last place is taken, or an admin can close it early.
2. **Planning (draft):** the system seeds players at random, builds all fixtures and proposes **automatic times**. The draft is visible only to the organizer and admins; the public sees "Preparing fixtures". Matchrooms are closed and the sweep ignores drafts.
3. **Admin reviews:** any single time can be changed (`reschedule_fixture`), schedule rules can be edited (`update_tournament`), or the admin can go back to registration (deletes the draft).
4. **Publish:** only an admin or the tournament's organizer publishes. Fixtures become public and matchrooms open at their times. Nothing goes live on its own.

### Time and time zones
All times are stored in UTC. Each player picks a **country** at sign-up (or later); every match time is shown in the time zone of that country, otherwise the browser's. A match has one moment in time, shown to each player in their own zone.
**Automatic times (provisional defaults, to be refined by the format research):** rounds start at 18:00 in the tournament's schedule time zone (default: the most common zone among its players, else Rwanda), `round_gap_hours` apart (default 48), never sooner than 12 hours from now. League rounds come first, then knockout rounds; all matches of a round share one time. Later knockout rounds are scheduled automatically as soon as both players are known.

### Admins
Admins can add or remove other admins and organizers (by email or username; the person needs an account). Rules: you cannot remove yourself, and one admin must always remain. Every change is audited. Organizers manage only the tournaments they created.

### Notifications
Every notification is stored (site inbox on "My matches", always works) and, if the player turned it on, pushed to their phone (free web push; works with the site closed on Android; on iPhone after "Add to Home Screen"). Text follows the player's language (en / fr / rw) and times follow their country's time zone.

| While still in the tournament | When |
|---|---|
| You're in | registration |
| Fixtures are out + first match | admin publishes |
| Next match (opponent, round, time) | both players known |
| Match time changed | admin or system changes a time |
| Match in 1 hour | 60 minutes before |
| Your match code is ready | room opens (2 minutes before) |
| Result (win / loss / draw, own score first) | match settled |
| Match under review | sent to admin review |
| Round finished (players left, or your league position) | round complete |
| Champion | tournament completed |

**Knocked out / not qualified:** one last notification with **Keep following** / **Stop**. No answer means stop. Followers keep getting tournament-wide updates (round finished, champion); personal ones end with their last match. Players can change their choice and turn phone notifications on or off at any time.
Plumbing: database triggers create notifications; a database hook calls the `send-push` server function, which signs and encrypts the push (VAPID keys stored only as Supabase secrets) and removes phones that no longer exist. A 1-minute job sends reminders. A push failure never blocks a result or a registration.

### Statistics
- **Player standing** (`player_stats`, public): position, points, matches left, best possible points, form (last 5), next match, and a status: `qualified` / `playoff_sure` / `in_race` (with "needs N more points to be sure", or "needs other results") / `eliminated`, then `in` / `eliminated` in knockouts and `champion` / `finished` at the end. "Qualified" and "eliminated" are shown only when mathematically certain (fewer than K players can still reach your points; K players are already out of your reach).
- **Career** (`career_stats`): tournaments, titles, played, won, drawn, lost, goals for/against, goals by your footballers.
- **Footballer leaderboards** (`footballer_leaders`: goals, assists, player of the match), always shown as **Footballer (Team)** plus the WIN ZONE player, because the same footballer can play for many teams. Built from the result screens both phones read; a team's goals are counted only from a report whose goal count matches the official score (both phones agreeing, else the team owner's phone, else the opponent's). Reports are stored once per phone and cannot be rewritten. Statistics never affect results.

**Result-screen report the app sends** (`submit_match_report_pass(pass, report)`), `team` is relative to the reporting phone:
```json
{ "my_team": "DREAM FC", "opp_team": "HARMOU",
  "goals":   [{ "player": "Messi", "minute": 12, "team": "me", "pen": false }],
  "assists": [{ "player": "Pedri", "minute": 12, "team": "me" }],
  "cards":   [{ "player": "Rivaldo", "minute": 65, "team": "opp", "type": "red" }],
  "potm":    { "player": "Messi", "team": "me", "rating": "8.9" } }
```

### Players and rankings
- **Players page** (`/players.html`, `rankings`): every player with at least one finished match, ranked by titles, then points (3/1/0 from all matches), win rate, goal difference. Search by name or team.
- **Player page** (`/p/<username>`, `public_player`): name, in-game team name, world rank, career numbers, tournaments (with titles marked) and the last 10 results. Country stays private. Names in tables link to player pages.
- **Team name:** each player saves their in-game team name (My matches page, or the app). The app uses it to know which side of the result screen is theirs; it is public on leaderboards.

### Admin "describe the tournament" box
The admin writes the tournament in plain words (English, French or Kinyarwanda), for example *"Kigali Cup" knockout for 16 players on 5 December at 18:00, fast. Prize: headphones*. A free, rule-based reader (`web/js/describe.js`, tested in CI) fills the creation form: name (in quotes), players, format, players who advance, matches per player, start date and time, speed and prize. Anything not found is filled from the recommendation and marked "assumed, please check". The admin reviews and creates; "Open registration right away" publishes the tournament page at once.

## 4. Verification pipeline
Foreground service (`mediaProjection`), persistent notification, ML Kit OCR on device, frame every 2 s, no frames uploaded. Only extracted fields are sent.

Layouts the phone reports: `in_play`, `result` (the game's end-of-match screen), `opponent_quit` (the "Opponent Quit" popup, which may already be dismissed), `menu`, `unknown`.
Scores are reported from the phone's own perspective (`score_me`, `score_opp`), because the player can be on either side of the screen. A phone latches a result only after reading the same values twice in a row.

### Server rules (implemented in `0003_match_logic.sql`)
1. **Kickoff:** both phones `in_play` for 5 consecutive seconds with match clock at most 5:00. Sets `kickoff_at`. A fixture cannot finalize before kickoff.
2. **Terminal reports are latched.** The first `result` / `opponent_quit` a phone sends is stored in its own columns and never overwritten (tapping Continue must not erase it).
3. **Normal result:** both phones latched `result` with a normal clock class and mirrored scores (A's `me` equals B's `opp` and vice versa, penalties too). Higher score wins; if level, higher penalties win.
4. **Early end = forfeit:** a result screen whose clock is before full time, or an `opponent_quit` popup, means the opponent left. The phone showing it wins, whatever the score. Conditions: 20 s grace, the other phone has no terminal report, and the other phone sent no `in_play` after the claim. Otherwise the fixture is disputed.
5. **Disputes (never auto-decided):** both phones claim a forfeit, one claims a forfeit while the other shows a result, scores not mirrored, clocks disagree, impossible clock, knockout level with no penalty winner, knockout level at 90:00.
6. **League draws** are valid results (1 point each). Knockout draws cannot occur in the game; if one is reported it is a dispute.
7. **Idempotent finalize.** `finalize_fixture` re-checks everything server-side; it never trusts the caller. A 1-minute sweep finalizes decided fixtures even if both apps are closed.
8. **Silence:** never auto-forfeit mid-match. After 10 minutes of silence the fixture is flagged `stalled` for an admin.
9. **Overrides:** only `resolve_fixture` (admin): win A/B, forfeit A/B, replay, cancel. Audited. Reversal of a finished fixture is refused once downstream play has started.
10. **No manual result entry** exists anywhere. Screenshots are dispute evidence only.

## 5. Room codes
The v1 game's Private Match screen has one box, "Match Code". Both players type the **same code** and press **Search**; the game pairs them. So the server generates the code and shows it to both players.

- **Format:** lowercase letters `a-z` and digits `0-9`, **always both**, length 3-5 (per-game setting `room_code_length`, default 5, because a longer code is safer against a stranger typing the same code). Look-alike characters (`i`, `l`, `o`, `0`, `1`) are left out. Generated when the fixture is created and never changes, except an audited admin regeneration.
- **One row per fixture.** Both players read the same value through `app_join_fixture`, the only read path. Codes are never in Realtime, logs, events or public pages. Clients have no direct access to `matchrooms`.
- **Copy button** on the matchroom page (and in the app) so players paste the code instead of typing it.
- **Reveal:** 2 minutes before `scheduled_at` (per-game setting). The matchroom stays open until the fixture ends so a crashed app can re-enter.
- **Check-in:** opening the matchroom is the check-in. Deadline is `scheduled_at` + 5 minutes. One player checked in, the other not: the present player wins by forfeit. Neither: cancelled, organizer re-seeds.
- **Host-issued model** (the game creates the code) remains supported for other games via `room_code_model = host_issued`; it is not used by the v1 game.

### Web to app handoff (no second login)
1. Both players open the matchroom page on their phone (signed in on the website) and see the code.
2. **Play game** calls `create_app_handoff`: a random 24-character code, valid **60 seconds**, **single use**, stored only as a hash.
3. The page opens the app with the match id and that code. The link never carries a login or session token.
4. The app calls `redeem_app_handoff` (no login needed). The server returns a **match pass**: random 64 characters, stored only as a hash, valid for **one player in one match**, 8 hours at most.
5. The app reports with the pass (`submit_screen_state_pass`, `finalize_fixture_pass`, `match_status_pass`). A pass cannot read the account, other matches or any other data, and cannot be used on another fixture.
6. The app then requests screen-recording permission. On Android 14 and newer the system lets the player share a single app (the game); on Android 7 to 13 only the whole screen is offered, and the app reads only game screens on the phone. Nothing is uploaded either way except extracted fields.

## 6. Data model
Tables: `profiles`, `user_roles`, `games`, `game_profiles` (private), `tournaments`, `tournament_entries`, `fixtures`, `matchrooms` (private), `match_latest_state`, `match_state_log` (private), `match_events`, `disputes`, `sponsors`, `sponsor_private`, `sponsor_placements`, `organizer_tenants`, `audit_logs`.

**No money anywhere:** WIN ZONE has no payments, fees, stakes, wallets or payment providers, and none are planned.

RLS summary: public (anon) reads published tournaments, entries, fixtures, usernames and sponsors. A participant reads both `match_latest_state` rows of their fixture. All writes go through SECURITY DEFINER RPCs; admin checks read `user_roles` server-side. Internal helpers and the sweep are not callable by API roles.

## 7. Stack and cost (zero spend)
| Need | Service | Limit to watch |
|---|---|---|
| Web hosting | Cloudflare Pages (free), `win-zone.pages.dev`, static files, no build | none relevant |
| Database, auth, realtime | Supabase free | pauses after ~1 week idle; 500 MB; 200 realtime connections |
| Keep-alive | scheduled GitHub Action (daily ping) | needs the two public repo secrets |
| Migrations | GitHub Action `Deploy database` | needs three repo secrets |
| Image storage (later) | Supabase Storage (1 GB) | free tier only |
| App build and releases | GitHub Actions + GitHub Releases | APK is sideloaded |

Existing Supabase project: the old staking tables are removed once, by hand, with `supabase/reset/legacy_reset.sql` (it removes only the old app's objects, leaves extensions such as `pg_net` alone, and refuses to run on a live WIN ZONE database). Login accounts are kept and get profiles through migration `0005`.

Not used in v1: Cloudflare R2, Workers, D1, Durable Objects. Ads wait for a real domain (ad networks reject `pages.dev`). Supabase's built-in email is rate-limited, so the demo runs without email confirmation.

## 8. Android app (Phase 2) requirements
Min SDK 24 (Android 7.0 and above). `foregroundServiceType="mediaProjection"` and `FOREGROUND_SERVICE_MEDIA_PROJECTION`; FGS started from a foreground Activity. `REQUEST_INSTALL_PACKAGES`. Room database offline queue; exponential backoff with jitter; honor 429 Retry-After; one in-flight submission per match. Fail-closed certificate pinning with a backup pin. Ed25519-signed `version.json`. Block rotation and picture-in-picture during capture. Android 14+ single-app capture where offered; a foreground-app check where permitted. Regions read by percentage of the frame, not pixels (tested at 1280x576 and 1080x486). English, French and Kinyarwanda strings. No login in the app: it receives a one-time handoff code from the website and exchanges it for a single-match pass (section 5). Deep link carries the match id and that code only. Capture does not start if notifications are denied.

## 9. Compliance posture
Free to enter, no money features. Required: Terms, Privacy, responsible-play baseline, data protection, geo-fence, tax disclosure. Prize-eligible players need identity verification before any prize of material value. Spectator prediction and tipping are out of scope. Open legal items before launch: per-market skill opinion for the specific game, prize structure (non-cash is safer), geo-fence map, B2B contract. This document is an engineering spec, not legal advice; every legal question needs a qualified advisor.

## 10. Monetization
Sponsorship, advertising (after a domain), media and data, B2B licensing, optional cosmetics that never buy advantage. Out of scope: entry fees, subscriptions, paid priority, spectator wagers.

## 11. Decisions
1 Tournament OS. 2 No money features of any kind. 3 One backend, two surfaces. 4 Live OCR primary, screenshots dispute-only. 5 Supabase + Cloudflare Pages + GitHub, zero spend. 6 Kickoff rule (5 s in play, first 5 minutes). 7 Forfeit rule in 4.4 above. 8 No manual result entry. 9 Deep link carries the match id and a single-use 60-second code, never a login or token (the app has no login; see section 5). 10 Both room-code models supported, per game; the v1 game is platform-issued. 11 Room codes only through `app_join_fixture`. 12 Reveal 2 minutes before. 13 Check-in deadline 5 minutes. 18 Codes: letters and digits, both required, 3-5 long (default 5), with a copy button. 19 No age confirmation in the product (owner decision, see section 9). 20 Country chosen by each player decides the time zone they see. 21 The system sets match times automatically; admins can change any of them. 22 Full tournament: registration closes, a hidden draft is prepared, an admin reviews and publishes. 23 Admins can add and remove admins. 25 Formats, tie-breaks and speeds as in section 3 (owner approved the recommended options). 24 Notifications: inbox always, phone push when turned on; full information while playing; one last notification with a keep/stop choice when eliminated; no answer = stop. 14 League draws valid, knockout draws disputed. 15 Never auto-forfeit mid-match. 16 League points 3/1/0 with the tie-breaks in section 3. 17 Brand: black `#0B0D0C`, bone `#F2EFE8`, volt `#C8F43A`. The site is white by default with a light/dark switch (saved per visitor); in light mode the black bands and lime highlights keep the identity.

## 12. Open items
| # | Item | Blocks |
|---|---|---|
| O1 | Confirm the v1 game's room-code model and verify capture works in the real app | Phase 2 |
| O2 | Prize structure (non-cash prizes only) | legal |
| O3 | Per-market skill opinion | public launch |
| O4 | Geo-fence map | launch scope |
| O5 | B2B contract template | B2B sales |
| O6 | Keep-alive secrets set and monitored | free-tier viability |
| O7 | Kinyarwanda strings reviewed by a native speaker | launch |
| O8 | Real contact email and APK link in `web/js/config.js` | launch |
| O9 | Research done and proposals A, B, C approved and built (migration 0010) | done |
| O10 | Admin brief box: describe a tournament in words, review a draft summary, publish | done |
| O12 | Old app's leftovers removed from the live project (2026-11-20); nothing money-related remains | done |
| O13 | Sponsor placements UI (tables exist, unused) | later, owner decision |
| O14 | Dispute evidence upload (the text dispute form exists) | later, owner decision |
| O15 | Demo mode with bot players | later, owner decision |
| O16 | Responsible play (self-pause) and country blocking | later, owner decision |
| O11 | Player statistics: website done (migration 0011); app screens in Phase 2 | partly done |

## 13. Build order
- **Phase 1 (done):** schema, rules, bracket and league logic, tests, public site, organizer panel, CI, deploy workflows.
- **Phase 2:** Android app (handoff, no login screen, matchroom summary, capture, OCR of the end screens, agreement, personal tournament statistics), then in-play and penalty readers.
- **Phase 3:** demo simulator (replays recorded screens for a clearly labelled demo tournament only), sponsor placements UI, dispute evidence upload (Supabase Storage), legal review, language review.

## 14. Corrections made to the v2 draft
1. `determine_winner_from_full_time` compared one phone's `score_a` with the other phone's `score_a`, so every agreed match read as a draw. Replaced by a mirrored-perspective comparison.
2. `match_latest_state` was overwritten on every submission, so tapping Continue erased the result. Terminal reports are now latched.
3. Fixed A/B sides replaced by `me`/`opp` perspective (the player can be on either side of the screen).
4. Separate "disconnected" and "conceded" layouts replaced by one `opponent_quit` popup plus the early-clock rule, because the popup may be dismissed before capture.
5. A disconnect claim was accepted while the opponent still reported `in_play`, which let a modified app fake a win. It now needs the opponent's play reports to have stopped.
6. `format` lives on tournaments, not fixtures; the draft's SQL read it from the wrong table. `submit_room_code` used an undeclared variable and `app_join_fixture` had no host-issued branch.
7. The matchroom no longer closes 30 minutes after kickoff.
8. R2, Workers and the Worker bracket cache removed (card required, zero-spend rule). Keep-alive moved to GitHub Actions; storage to Supabase Storage.
9. League and league-then-knockout formats, stage-specific clock rules and tie-breaks added.
