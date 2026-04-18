# whatsapp-agent

WhatsApp lead-assignment agent for the `inmuebles24_bygrealestate` project. Handles inbound WhatsApp leads, runs a first-reply-wins auction across the agent pool, and answers property questions using EasyBroker data.

**Stack:** n8n (self-hosted) · Supabase Postgres · Twilio WhatsApp · EasyBroker API · Claude/OpenAI (WF4)

This subfolder is independent of the rest of the repo — it has its own migrations, workflows, `.env`, and Makefile. It doesn't share state or code with the scraping pipeline.

## Current status

**Built:** WF3 (the auction subsystem) — WF3a launcher, WF3b claim handler, WF3c expiry sweeper.

**Not yet built:** WF1 (inbound router), WF2 (lead intake), WF4 (AI conversation), WF5 (human handoff). See `docs/architecture.md` for where they fit.

WF3 is built first because it's the only race-critical piece. Every other workflow is linear and stateless — easy to get right. Doing those first on top of a shaky auction would mean debugging the wrong layer.

## Layout

```
whatsapp-agent/
├── README.md              ← you are here
├── Makefile               ← `make help` for commands
├── .env.example           ← copy to .env and fill in
├── .vscode/               ← recommended extensions
│
├── migrations/            ← SQL files applied in order
│   ├── 0001_init.sql
│   ├── 0002_rls.sql
│   ├── 0003_seed_dev.sql
│   └── 9999_rollback.sql
│
├── workflows/             ← n8n workflow JSONs (import into n8n)
│   ├── WF3a_auction_launcher.json
│   ├── WF3b_claim_handler.json
│   └── WF3c_expiry_sweeper.json
│
├── scripts/
│   ├── migrate.sh         ← run migrations against $DATABASE_URL
│   └── check.sh           ← inspect current DB state
│
└── docs/
    ├── architecture.md    ← full system design
    ├── supabase-setup.md  ← connection string gotchas
    └── wf3-testing.md     ← test scenarios + race-safety proof
```

## Quick start

**All commands below assume you are `cd`'d into `whatsapp-agent/`.** The Makefile uses relative paths.

### 1. Configure environment

```bash
cd whatsapp-agent
cp .env.example .env
```

Edit `.env` and fill in:

- `DATABASE_URL` — from Supabase → Project Settings → Database → Session pooler URI. **Read `docs/supabase-setup.md` first** — there are three pooler options and only one works cleanly with n8n.
- `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` — Twilio Console → Account Dashboard
- `TWILIO_WHATSAPP_FROM` — the sandbox or production sender, **including the `whatsapp:` prefix**
- `MANAGER_WHATSAPP_TO` — your phone for auction-expiry escalations, **including the `whatsapp:` prefix**
- `EASYBROKER_API_KEY` — EasyBroker → Settings → API

### 2. Verify setup

```bash
make env-check
```

Five green checkmarks → ready. Any red → check `.env` and fix before continuing.

### 3. Apply migrations

```bash
make migrate
```

This runs `0001_init.sql`, `0002_rls.sql`, and `0003_seed_dev.sql` in order. Safe to re-run.

Verify tables + seed data:

```bash
make check
```

You should see three seeded agents (Yolanda, Marusa, Gina) and one test conversation.

### 4. Import workflows into n8n

In n8n: **Workflows → Import from File**. Import each of the three files in `workflows/`.

Each imported workflow will show warnings about missing credentials. Open the Postgres and Twilio nodes and re-select your real credentials. Name them exactly:
- Postgres → **Supabase Postgres**
- Twilio → **Twilio**

### 5. Activate only what should run on a schedule

- **WF3a** → leave inactive (called by WF2 via "Execute Workflow")
- **WF3b** → leave inactive for now (will be called by WF1 once built)
- **WF3c** → **activate** (runs every minute)

### 6. Run the manual tests

Follow `docs/wf3-testing.md`. Test 5 — the two-psql-session race proof — is the most important one. It's what demonstrates the system actually honours the first-reply-wins guarantee.

## Common commands

```bash
make help             # list all commands
make migrate          # apply migrations + dev seed
make migrate-no-seed  # migrations only, no seed data
make rollback         # drop all tables (asks for confirmation)
make check            # print current DB state
make psql             # open psql shell against $DATABASE_URL
make env-check        # verify .env has all required vars
```

## About `.env` and this subfolder

`.env` lives inside `whatsapp-agent/`, not at the repo root. The repo's top-level `.gitignore` should already ignore `.env` and `.env.*`, but if it doesn't, add these lines:

```
whatsapp-agent/.env
whatsapp-agent/.env.*.local
```

The rationale: WhatsApp agent secrets (Twilio, EasyBroker API key) have nothing to do with scraper secrets (Inmuebles24 credentials, proxies). Keeping them in separate `.env` files means you can rotate one without touching the other, and a developer working only on the scraper never sees the WhatsApp tokens.

If you later consolidate to a single top-level `.env`, adjust `scripts/migrate.sh` to source `../env` instead — it's a one-line change.

## What's next

Once WF3 is stable (race-safety test 5 passes), the build order is:

1. **WF1 — Inbound Router.** Parses Twilio webhooks, classifies sender, routes. Everything downstream depends on this.
2. **WF2 — Lead Intake.** Extracts property ID from first message, fetches property from EasyBroker, creates `conversations` row, calls WF3a.
3. **WF4 — AI Conversation.** Property-scoped Q&A. Guardrails for price negotiation, visit scheduling, handoff triggers.
4. **WF5 — Human Handoff.** Flips `conversations.mode = 'human'`, shares agent contact with the lead, notifies the agent with conversation summary.

Each new workflow adds one or two files to `workflows/` and occasionally a migration to `migrations/`. Nothing from WF3 gets edited.
