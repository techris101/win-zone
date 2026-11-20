# WIN ZONE

Free 1v1 mobile football tournaments. Players register free, get a fixture, and play on their phone. The Android app reads the match screen and reports the result; the server decides; the public bracket updates live. No entry fee, no stake, no subscription.

- `docs/SPEC.md` the single source of truth
- `docs/SETUP.md` one-time setup (Supabase, GitHub secrets, Cloudflare Pages)
- `supabase/migrations/` database schema, rules and RPCs
- `supabase/tests/` database tests (`run_local.sh`, also run in CI)
- `web/` the static website (deployed as-is by Cloudflare Pages, no build step)
- `.github/workflows/` CI, database deploy, keep-alive

Run the database tests locally against any Postgres 16: `supabase/tests/run_local.sh postgresql://user@localhost:5432/winzone_test`
