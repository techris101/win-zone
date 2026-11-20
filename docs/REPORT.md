# WIN ZONE — status report (20 Nov 2026)

## Done
- **Backend (Supabase, live):** accounts, countries/time zones, tournaments in 5 formats, automatic scheduling, admin control (draft → publish, change times, add admins), match codes, match logic (kickoff, result agreement, Opponent Quit, disputes, sweep every minute), notifications (inbox + phone push), statistics, rankings. Migrations 0001–0012 applied. No money features anywhere.
- **Website (code ready):** home, tournaments, brackets/tables, match room with code + copy + "Play game", player pages, rankings, admin panel with "describe the tournament" box, EN/FR/RW, light/dark.
- **Android app (first test version):** opens from "Play game" (no second login), asks for team name once, screen-capture with a visible notification, reads the screen on the phone (score, clock, result screen, Opponent Quit, scorers, player of the match), sends results by itself, retries when offline, shows the confirmed result.
- **Checks:** all database tests, reset test, 16 reader tests, code checks and game-name check pass. GitHub builds the app file on every change ("Android app" workflow) and publishes it as the `app-latest` download.

## Needs you (only you can do these — they need your accounts)
1. **Put the website online (5 min, free):** Cloudflare dashboard → Workers & Pages → Create → Pages → Connect to Git → `techris101/win-zone` → project name `win-zone`, branch `claude/amazing-johnson-txwx9s` (or `main` after merging), build command empty, output folder `web`. Address: https://win-zone.pages.dev
2. **Merge the pull request** when happy.
3. **Revoke the Supabase access token** you gave me (Supabase → Account → Access tokens). Delete/rotate the old MTN keys at MTN.
4. **Test the app on 2 phones** in one real match, then send me: screenshots of in-play, penalty shootout and the "searching" screen, plus your Android versions. The screen-reading rules can be tuned on the server without a new app.
5. Later: set the game's package name in `game_profiles` (so the app opens the game directly), app signing key for a store release, contact email, domain.

## Deferred at your request
Sponsors, dispute evidence upload, demo mode with bots, responsible-play / country blocking.

## Honest limits of the test app
- The screen reader is built from your result screenshots only; in-play and penalty screens need real screenshots to tune.
- It is a debug (test) build: Android will warn "unknown source" when installing. Normal for testing.
