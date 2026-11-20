# Setup (one time, about 15 minutes, no card needed)

Everything is free and done in your browser. Never paste passwords or secret tokens into chat; only into the GitHub secrets page below. Your Supabase project is `jfniylmbogodgozcczln`. The website is already configured to use it.

## A. Supabase (your existing project)
1. Open the project at supabase.com.
2. **Authentication, then Sign In / Providers, then Email:** turn **off** "Confirm email" (demo only; turn it back on when you own a domain).
3. **Wipe the old staking app (permanent).** Open **SQL Editor, then New query**. Paste the whole of `supabase/reset/legacy_reset.sql` from this repo and press **Run**.
   - It deletes the old app's tables, views, functions and custom types in the `public` schema (old wallets, matches, profiles and so on). Login accounts and installed extensions (such as `pg_net`) are kept.
   - It refuses to run if the new WIN ZONE tables already exist, so it can never erase live data.
   - It runs as one block: if it fails, nothing is deleted.
   - Success looks like "Success. No rows returned".
4. Look for leftovers from the old app that I cannot see: **Database, then Cron jobs** (extension pg_cron), **Edge Functions**, and **Storage** buckets. Delete what the old app used.
5. Make sure you know the database password. If not: **Project Settings, then Database, then Reset database password**, and save it.
6. Account menu, **Access Tokens**, generate a token named `github`. Keep it private.

## B. GitHub secrets (two only)
Repository, then **Settings, then Secrets and variables, then Actions, then New repository secret**:

| Name | Value |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | the token from step A6 |
| `SUPABASE_DB_PASSWORD` | the database password from A5 |

Then open the **Actions** tab, choose **Deploy database**, and click **Run workflow**. A green tick means the new database is built. Do this after step A3.

## C. Cloudflare Pages (the website)
1. Sign up free at dash.cloudflare.com (no card).
2. **Workers & Pages, then Create, then Pages, then Connect to Git.** Allow access to the `win-zone` repository.
3. Project name: `win-zone`. Production branch: `main`. Framework preset: **None**. Build command: leave empty. Build output directory: `web`. Click **Save and Deploy**.
4. Your site is at `https://win-zone.pages.dev`. Every pull request also gets a preview link you can open before merging.

Merge the pull request **after** the Deploy database run is green. Until the database is built, the site shows "The live service is being set up".

## D. Make yourself the admin
1. On the live site, register an account (or sign in with an existing one).
2. In Supabase **SQL Editor**, run (with your email):
   `select public.grant_role('you@example.com', 'admin');`
3. Reload the site. An **Admin** button appears.

Old accounts still log in, get a new WIN ZONE profile automatically, and are asked to confirm their age when they first register for a tournament. Nobody is an admin until you grant it.
