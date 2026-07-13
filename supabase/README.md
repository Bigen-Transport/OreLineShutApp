# Supabase backend — setup & ops

This app is backed by a Supabase project (Postgres + Auth + Storage). One-time setup:

## 1. Create the project
1. [supabase.com](https://supabase.com) → New Project.
2. Once provisioned, go to **Project Settings → API** and copy the **Project URL** and **anon public** key.
3. Paste those into `ore-line-shutdown.html` (and `weather.html` is unaffected — it doesn't need a login), replacing the two placeholder constants near the top of the last `<script>` block:
   ```js
   const SUPABASE_URL = 'YOUR_SUPABASE_URL';
   const SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY';
   ```

## 2. Run the schema
Open **SQL Editor → New query**, paste the contents of `schema.sql`, and run it. This creates all tables, Row Level Security policies, the `kpi-photos` storage bucket, and seeds the demo dataset (same data the app used to ship with locally).

Safe to re-run — seed data only inserts once, everything else uses `create or replace` / `drop policy if exists`.

## 3. Invite editors
There's no self-service sign-up flow in the app. To add someone:
1. **Authentication → Users → Add user** (or send an invite email) — set their email + a temporary password, and tell them to change it after first login (Supabase doesn't have a built-in "change password" UI in this app yet — for now, resetting a password means re-inviting or using **Authentication → Users → ... → Send password recovery**).
2. A `profiles` row is created for them automatically (default role `cust`, view-only).
3. Go to **Table Editor → profiles**, find their row, and set `role` to one of: `admin`, `trim`, `te`, `tpt`, `exec`, `cust`.
   - `admin` — edit everything + Setup (add/remove KPIs, disciplines, change targets).
   - `trim` / `te` / `tpt` — edit actuals/deviations/photos for that division only (enforced server-side via RLS, not just hidden in the UI).
   - `exec` / `cust` — view only.

That's it — the person signs in via the "Sign in" button in the app bar and their role takes effect immediately.

## What's enforced where
- **Read access** is public (no login needed) — matches the original "view-only roles" behaviour for execs/customers.
- **Write access** is enforced in Postgres via Row Level Security, keyed off the signed-in user's `profiles.role` — not just hidden buttons in the UI. A TRIM editor's requests to write TE or TPT data are rejected by the database itself.
- **Setup** (adding/removing KPIs and disciplines, editing targets, changing report metadata) is `admin`-only, same as before.
