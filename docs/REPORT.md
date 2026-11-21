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

## Update — website online (20 Nov 2026)
- Live at **https://win-zone.pages.dev** (Cloudflare Pages project `win-zone`, direct upload).
- Deploy again after changes: `python3 tools/build_worker.py` packs `web/` into `dist/_worker.js`, then upload it to the Pages project (see `tools/build_worker.py`). Connecting the GitHub repo in Cloudflare later makes this automatic.
- Sign-in emails now link to the live site (Supabase site address updated).
- Revoke the Cloudflare token when you no longer need me to deploy.

## Update — 21 Nov 2026: skipped features, new logo, full check
**Done and live**
- Trust and safety: player reports (player page and match room), admin review, suspensions (7 days to permanent), delete my account (results kept as "Deleted player").
- Dispute evidence: result screenshots attached in the match room, private to the uploader and admins, shown in the admin "Needs attention" list.
- Responsible play: take a break (cannot be shortened), limit on tournaments at once, blocked countries (admin), new Responsible play page.
- Sponsors: admin adds sponsors (link or uploaded logo), places them on tournaments (title, bracket, round, prize) and optionally the home page.
- Demo mode: admin creates a demo tournament filled with bots that play a match every few minutes; labelled "Demo", real players cannot join, kept out of rankings and notifications. One demo ("WIN ZONE Demo Cup") is running now; delete it from the admin page whenever you like.
- Also: change password, add match to calendar, robots.txt + sitemap, terms/privacy updated.
- New logo: football pitch seen from above + plain wordmark, on the site, favicon, app icon and notification icon.
- Android app 0.2.0: new icon, 23 MB (was 46 MB). Public download: https://jfniylmbogodgozcczln.supabase.co/storage/v1/object/public/downloads/winzone.apk (linked from the site footer and My matches).
- Fixed during the check: Terms, Privacy, Organizers and 404 pages had no header/footer; a match status label read "ST.SCHEDULED"; the Admin button wrapped on phones.

**Checked**: 2 test suites (all pass, 40 new checks), reset test, reader tests, code checks, game-name check, every live page (200), real browser on desktop and phone with no errors, signed-in pages with stand-in data, live account deletion rehearsal (undone), live demo bots playing.

**Not done (needs you)**
1. Email service (Brevo, free): sign-up and reset emails are limited to 2 per hour until this is connected.
2. Bot protection on sign-up (Cloudflare Turnstile): possible with the saved Cloudflare key, but switching it on blocks every sign-in if anything is wrong, and it cannot be fully tested from here. Say the word and I will set it up with you testing on your phone.
3. Daily database backup: a safety check stopped me from copying player data out automatically. If you want it, approve it and add a `SUPABASE_ACCESS_TOKEN` secret in GitHub.
4. Public contact email: not shown yet; tell me if bigmin00001@gmail.com should appear on the Contact page.
5. Download limit: the free database plan allows about 5 GB of downloads a month (~200 app downloads). Fine for testing.

## Update — 21 Nov 2026 (evening): state at hand-over
**Live and checked**
- Website https://win-zone.pages.dev — all 20 pages load, no errors on phone and computer (real browser check).
- App 0.5.0 (Android 5+): https://jfniylmbogodgozcczln.supabase.co/storage/v1/object/public/downloads/winzone.apk
  - the whole site inside the app; Play game opens the match screen directly; sign in once
  - records the entire screen (Android 14+), follows rotation, ignores the phone's own clock, shows what it reads
    in its notification, reports a blank picture to the server
  - strict kick-off (0-0 at 00:01 on both phones); recording stops on a final full time, the result screen or an
    opponent disconnecting; "Match ended" screen with the result and statistics; text-reading model checked inside
- Database: migrations 0001–0022 live; 4 automatic jobs (results every minute, alerts, demo, nightly cleanup) with no
  failures; phone alerts delivered (15 in the last 6 hours); 17 MB of 500 MB.
- Tests: 5 database suites, reset test, 16 describe-box tests, 11 app reader tests, Android version checker — all pass;
  GitHub checks green.

**Not yet proven:** a full match read by both phones with 0.5.0. Next test: both phones on 0.5.0 → Play game → Start →
"Entire screen" → play; pull down the notification during the match (it should say "Match on" with the minute).
The test match KIGALI GOATS is "Under review": replay it from the admin page for the test.

**Waiting for the owner:** in-play screenshots (one with FULL TIME), phone models and Android versions; Firebase for
alerts when the app is closed; Brevo email; contact email decision; daily backup approval; bot protection; "Watch live"
streaming; revoke the Supabase and Cloudflare keys when building is done; change the old MTN keys.
