# Inmobiliaria24 — TODO Tracker

> **Legend:** `[ ]` pending | `[~]` in progress | `[x]` done | `[!]` blocked
> **Last updated:** 2026-05-10

---

## System Status: CODE COMPLETE, PRODUCTION BLOCKED

All code, workflows, schema, and dashboard are built and audited. Deployment is blocked on client (BYG) providing agent data. See [GO_LIVE_CHECKLIST.md](GO_LIVE_CHECKLIST.md) for the full deployment plan.

---

## Phase 1: Scraper (Python/Playwright) — DONE

- [x] Playwright scraper for Inmuebles24 "Interesados" (3 tabs: messages, phone, WhatsApp)
- [x] SQLite state store with dedup (WAL mode, concurrent-safe)
- [x] Retry logic with exponential backoff (page loads + webhooks)
- [x] Session auto-recovery on stale detection
- [x] Screenshot capture on all failures
- [x] Structured JSON logging, log rotation (10MB, 7 days)
- [x] Telegram monitoring (errors, heartbeats, daily summary)
- [x] Systemd service + timer (every 2h, 8AM-10PM)
- [x] Deploy script (`deploy/deploy.sh`)
- [x] 112 tests passing

---

## Phase 2: CRM Adapter Layer — DONE

- [x] `CRMAdapter` abstract base class + `Lead` data model
- [x] `WebhookCRMAdapter` (generic POST with retry)
- [x] HubSpot adapter template (ready for API keys)
- [x] Pipeline: scrape -> dedup -> CRM check -> push
- [x] Retry failed CRM pushes on next run
- [!] Activate HubSpot adapter (blocked: waiting for client CRM decision)

---

## Phase 3: n8n Workflow Engine (v5 Architecture) — DONE

11 workflows built, audited, and bug-fixed:

| # | Workflow | Status | Notes |
|---|----------|--------|-------|
| WF1 | Inbound Router | [x] Done | classify_sender fixed (C1), night_queued mode added (C4) |
| WF2 | Lead Intake | [x] Done | Property search narrowed (M5) |
| WF3a | Auction Launcher | [x] Done | TOMO code collision fix (M2), error tracking added (M3) |
| WF3b | Claim Handler | [x] Done | Atomic claim via Postgres |
| WF3c | Expiry Sweeper | [x] Done | Every 1 min, escalates to manager |
| WF4 | AI Conversation | [x] Done | OpenRouter/Claude integration |
| WF5 | Human Handoff | [x] Done | AI -> human transition |
| WF6 | Guard Schedule | [x] Done | DST fix (C2), Google Sheets removed, 3-node design |
| WF7 | Morning Report | [x] Done | 8AM summary + 8:05 auto-TOMO |
| WF8 | EasyBroker Polling | [x] Done | Every 15 min |
| WF10 | Scraper Intake | [x] Done | Webhook from Raspberry Pi |

### Bugs Fixed (Validation Audit, May 9)

**6 Critical:**
- [x] C1: classify_sender() LATERAL join (returns 1 row, most recent)
- [x] C2: WF6 DST timezone fix (America/Mexico_City)
- [x] C3: Message linking for returning leads
- [x] C4: WF1 night_queued mode handler
- [x] C5: Atomic calendar save RPC (save_month_schedule)
- [x] C6: SECURITY DEFINER on DB functions

**4 Medium:**
- [x] M1: Fixed by C3 (message conversation_id linking)
- [x] M2: TOMO code collision — generate_tomo_code() with retry
- [x] M3: WF3a Evolution API error tracking
- [x] M5: WF2 property search narrowed (exact match priority)

**Deferred:**
- [ ] M4: find_returning_lead() email/phone priority — low risk, monitor post-go-live
- [ ] M6: Scraper 30s wait per tab — performance only, not blocking

---

## Phase 4: Database (Supabase) — DONE

- [x] 6 migrations applied (0001-0006)
- [x] 9 tables with RLS enabled
- [x] 5 critical indexes
- [x] Functions: classify_sender, is_daytime, current_shift, get_on_shift_agents, find_returning_lead, save_month_schedule, generate_tomo_code
- [x] Test data present (will be cleaned at go-live via 00_cleanup_test_data.sql)

---

## Phase 5: Dashboard (Next.js) — DONE

- [x] Next.js 16 with route groups: `(dashboard)/` has sidebar, `/login` is standalone
- [x] Pages: overview, leads, agentes, subastas, calendario, nocturno
- [x] Password auth via middleware (SHA-256 token cookie)
- [x] Interactive guard calendar editor with Supabase persistence
- [x] Auto-refresh every 30 seconds
- [x] Deployed on Vercel
- [ ] Set DASHBOARD_PASSWORD env var in Vercel (at go-live)
- [ ] Supabase Magic Link auth (future — needs client SMTP credentials)

---

## Phase 6: Security — DONE

- [x] Hardcoded secrets removed from codebase
- [x] .gitignore covers: .env, .env.local, .env.production, .mcp.json
- [x] n8n JWT rotated after exposure (May 9)
- [x] RLS enabled on all tables
- [x] SECURITY DEFINER on DB functions
- [x] Dashboard uses anon key (read-only)

---

## Phase 7: Client Onboarding Tools — DONE

- [x] `formulario_datos_cliente.html` — 8-section data collection form
- [x] `calendario_guardias.html` — interactive monthly guard schedule tool
- [x] `flowchart_sistema_v5.html` — system flowchart for client review

---

## Deployment Checklist (blocked on client)

| # | Item | Owner | Status |
|---|------|-------|--------|
| 1 | WhatsApp numbers for 6 agents + manager | BYG | [!] Pending |
| 2 | EasyBroker emails per agent | BYG | [!] Pending |
| 3 | Shift schedule confirmation | BYG | [!] Pending |
| 4 | First month guard calendar | BYG | [!] Pending |
| 5 | Bot WhatsApp number | BYG | [!] Pending |
| 6 | Inmuebles24 credentials | BYG | [!] Pending |

Once received: execute GO_LIVE_CHECKLIST.md stages 1-10 (~4 days).

---

## Backlog (Future / Nice-to-Have)

- [ ] Multi-account support (multiple Inmuebles24 accounts)
- [ ] Property photo sending via WhatsApp
- [ ] Visit scheduling integration (Google Calendar)
- [ ] Lead scoring based on qualification answers
- [ ] Analytics: conversion rate tracking
- [ ] Automatic follow-up sequences (drip campaign)
