# Supabase Setup

Everything you need to know to wire Supabase into n8n correctly.

## Finding your connection string

Go to **Supabase Dashboard → Project Settings → Database → Connection string**.

You'll see three options. Here's what each one means and when to use it:

### 1. Direct connection (port 5432)
```
postgresql://postgres:[password]@db.[project-ref].supabase.co:5432/postgres
```
- IPv6 only on free tier. Won't work from most hosts (including most VPS providers) unless IPv6 is supported.
- Skip this for n8n unless you've confirmed IPv6 connectivity.

### 2. Session pooler (port 5432) ← **use this one for n8n**
```
postgresql://postgres.[project-ref]:[password]@aws-0-[region].pooler.supabase.com:5432/postgres
```
- IPv4. Works from anywhere.
- Supports prepared statements, transactions, LISTEN/NOTIFY — everything n8n's Postgres node uses.
- This is the one that goes in `DATABASE_URL`.

### 3. Transaction pooler (port 6543)
```
postgresql://postgres.[project-ref]:[password]@aws-0-[region].pooler.supabase.com:6543/postgres
```
- Smaller connection footprint, but doesn't support prepared statements.
- n8n's Postgres node uses parameterized queries that *sometimes* fall back to prepared statements; behavior is inconsistent across versions.
- Don't use this for n8n. Stick with the session pooler.

## Creating the n8n credential

In n8n, add a new credential of type **Postgres**:

| Field | Value |
|-------|-------|
| Host | `aws-0-[region].pooler.supabase.com` |
| Database | `postgres` |
| User | `postgres.[project-ref]` (yes, include the dot and project ref) |
| Password | your DB password |
| Port | `5432` |
| SSL | `require` |
| Ignore SSL Issues | `false` (Supabase has valid certs) |

Name it `Supabase Postgres` — the workflow JSONs reference this exact name.

Click "Test" before saving. If it fails, 99% of the time the user field is wrong (missing the `.[project-ref]` suffix).

## Running migrations against Supabase

You have three options:

### Option A — Local psql with the connection string (recommended)

```bash
cp .env.example .env
# Edit .env, paste your session pooler connection string into DATABASE_URL
make migrate
```

### Option B — SQL Editor in the Supabase Dashboard

Paste each migration file's contents into the SQL editor and run. Run them in order:
1. `migrations/0001_init.sql`
2. `migrations/0002_rls.sql`
3. `migrations/0003_seed_dev.sql`

Slower but doesn't require installing psql locally.

### Option C — Supabase CLI

If you already have it installed:
```bash
supabase db push --file migrations/0001_init.sql
# etc.
```

## About RLS (Row-Level Security)

Supabase enables RLS by default on new tables you create via the Dashboard UI, but **not** on tables created via raw SQL. Migration `0002_rls.sql` explicitly enables it on all five tables and leaves them with no policies — meaning:

- The `anon` and `authenticated` Supabase roles **cannot read or write these tables** at all.
- The `postgres` role (which is what your n8n connection uses) **bypasses RLS** entirely.

This is intentional. n8n needs full access as a trusted backend; end-users should never have any access to these tables directly.

If you later build an admin dashboard and want it to read from these tables via the Supabase REST API, you'll need to add explicit policies. Example:

```sql
CREATE POLICY "admins_read_conversations" ON conversations
  FOR SELECT TO authenticated
  USING (auth.jwt() ->> 'role' = 'admin');
```

## Debugging in the SQL Editor

The SQL Editor runs queries as the `postgres` role by default, so you bypass RLS just like n8n. You can query any table directly:

```sql
SELECT * FROM auctions ORDER BY created_at DESC LIMIT 10;
```

If you see "permission denied" somewhere, you're either not logged in as an owner of the project, or you've switched roles mid-session (`SET ROLE authenticated;`). Run `SET ROLE postgres;` to reset.

## IP allowlist (optional, production)

For production, go to **Project Settings → Database → Network Restrictions** and allowlist the public IP of your n8n host. This isn't required — Supabase's pooler is already auth-protected — but it's a good additional layer.

## Keeping costs down

On the free tier:
- 500 MB database — ample for this use case unless `messages` grows huge. Add a retention policy later if needed (e.g., archive messages older than 90 days).
- Project pauses after 7 days of inactivity. Not a problem for an active agent pipeline, but worth knowing during development.
- 2 GB egress/month — watch this if the LLM workflow pulls `messages` history frequently.
