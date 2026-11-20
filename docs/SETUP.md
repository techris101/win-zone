# Setup (one time, about 15 minutes, no card needed)

Everything is free. You do these steps in your browser. Never paste passwords or secret tokens into chat; only into the GitHub secrets page described below.

## A. Supabase (database and login)
1. Go to supabase.com and sign in with GitHub. Click **New project**.
2. Name: `win-zone`. Pick a strong database password and save it somewhere safe. Region: the closest to Rwanda (South Africa if listed, otherwise Frankfurt). Plan: Free.
3. When the project is ready, go to **Authentication, then Sign In / Providers, then Email** and turn **off** "Confirm email" (demo only; turn it back on when you own a domain and set up email).
4. Go to **Project Settings, then API**. Copy two values: **Project URL** and the **anon public** key. These two are safe to share with me in chat; they are public by design. Do not share the `service_role` key.
5. Go to your account menu, **Access Tokens**, and generate a token named `github`. Keep it private.

## B. GitHub secrets (so GitHub can build the database for you)
Repository, then **Settings, then Secrets and variables, then Actions, then New repository secret**. Add:

| Name | Value |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | the token from step A5 |
| `SUPABASE_DB_PASSWORD` | the database password from A2 |
| `SUPABASE_PROJECT_REF` | the letters in your Project URL: `https://<THIS-PART>.supabase.co` |
| `SUPABASE_URL` | the Project URL |
| `SUPABASE_ANON_KEY` | the anon public key |

Then open the **Actions** tab, choose **Deploy database**, and click **Run workflow**. A green tick means the database is built.

## C. Cloudflare Pages (the website)
1. Sign up free at dash.cloudflare.com (no card).
2. **Workers & Pages, then Create, then Pages, then Connect to Git.** Allow access to the `win-zone` repository.
3. Project name: `win-zone`. Production branch: `main`. Framework preset: **None**. Build command: leave empty. Build output directory: `web`. Click **Save and Deploy**.
4. Your site is at `https://win-zone.pages.dev`. Every pull request also gets its own preview link.

## D. Connect the site to the database
Send me the Project URL and the anon public key. I put them in `web/js/config.js`. Until then the site shows clearly labelled sample data.

## E. Make yourself the admin
1. On the live site, register an account.
2. In Supabase, open **SQL Editor** and run (with your email):
   `select public.grant_role('you@example.com', 'admin');`
3. Reload the site. An **Admin** button appears.
