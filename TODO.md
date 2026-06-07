# Inmobiliaria24 — TODO Tracker

> **Legend:** `[ ]` pending | `[~]` in progress | `[x]` done | `[!]` blocked
> **Last updated:** 2026-06-07

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

- [x] 9 migrations applied (0001-0010, sin 0003 dev seed ni 9999 rollback)
- [x] 11 tables with RLS enabled
- [x] Critical indexes + partial unique en auctions.short_code (open only)
- [x] 15 functions: classify_sender, is_daytime, current_shift, get_on_shift_agents, find_returning_lead, save_month_schedule, generate_tomo_code, evolution_phone, update_updated_at_column, lead_status_log_change, update_lead_stage, mark_assigned, mark_first_response, record_sla_breach, get_sla_breaches
- [x] 2 views: agent_metrics, sla_breaches
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

## Deployment Checklist (partial client data received 2026-05-20)

| # | Item | Owner | Status |
|---|------|-------|--------|
| 1 | WhatsApp numbers for 6 agents | BYG | [x] Received |
| 1b | WhatsApp managers (Sandy ✓, Marusa ✓) | BYG | [x] Received |
| 2 | Gmail per agent (5/6) | BYG | [~] Falta email Gina |
| 2b | Confirm gmail = EasyBroker email | BYG | [!] Pending |
| 2c | Email Marusa (Marusabobadilla@gmail.com) | BYG | [x] Received |
| 3 | Shifts (Sandy L-V 8:30-18:00, Marusa L-V 18-22 + Sáb/Dom) | BYG | [x] Received |
| 4 | First month guard calendar (6 agentes) | BYG | [!] Pending |
| 5 | Bot WhatsApp number (5215529814996) | BYG | [x] Received — en `.env` |
| 6 | Inmuebles24 credentials (citas.bygrealestate@gmail.com) | BYG | [x] Received — en `.env` |
| 7 | Schema migration: support 2 managers with time-based routing | Dev | [!] Decision needed |

Datos recibidos guardados en `whatsapp-agent/scripts/01_update_agents_real.sql`.

Once remaining items received: execute GO_LIVE_CHECKLIST.md stages 1-10 (~4 days).

---

## Phase 8: Supabase CRM (replaces EasyBroker routing) — IN PROGRESS

Backend complete. Frontend pending next session.

- [x] Migration 0009 — `lead_status`, `lead_status_history`, `agent_metrics`, `sla_breaches` views, `update_lead_stage` RPC, trigger-based audit log (applied 2026-05-21)
- [x] Migration 0010 — `mark_assigned`, `mark_first_response`, `record_sla_breach`, `get_sla_breaches` RPCs (applied 2026-05-21)
- [x] Integration doc — `whatsapp-agent/docs/crm-integration.md` (WF1/WF3a/b/c/WF11 hook points + EasyBroker degradation plan)
- [ ] WF1 patch — add `mark_first_response` call on outbound human branch
- [ ] WF3a/b patch — add `mark_assigned` call at claim and escalation points
- [ ] WF11 build — new SLA monitor workflow (cron 5m, get_sla_breaches → record_sla_breach + manager nudge with 30-min dedupe)
- [ ] Dashboard: lead detail page with stage history timeline
- [ ] Dashboard: Kanban pipeline view (`/leads/pipeline`)
- [ ] Dashboard: SLA breach widget on overview
- [ ] Dashboard: agent_metrics tab

---

## Phase 9: Migración a Proyecto Supabase Nuevo (2026-06-07) — IN PROGRESS

Proyecto nuevo: `wkaeutndwawkdhswisqe` (https://wkaeutndwawkdhswisqe.supabase.co).
Proyecto viejo: `eazzsvekwmkwmlylirja` (a retirar tras cutover).

### Hecho (lado Claude/MCP)
- [x] Schema completo replicado vía MCP: 9 migrations (0001-0010) aplicadas en orden
- [x] 11 tablas con RLS, 15 funciones, 2 vistas, triggers, índices, extensión pgcrypto
- [x] 7 agentes seed (placeholders `5215500000001`...099) — Lupita, Paty, Yol, Gina, Carol, Moni, Manager
- [x] 2 políticas RLS (lead_status_read, lead_status_history_read)
- [x] `dashboard/.env.local` → URL + anon key nuevos
- [x] Verificado: list_tables, list_migrations, advisors (findings heredados del schema original, no regresiones)

### Pendiente (lado usuario — atacar próxima sesión)
- [ ] **n8n**: actualizar credencial Postgres → host `db.wkaeutndwawkdhswisqe.supabase.co` + database password del proyecto nuevo (Settings → Database)
- [ ] **service_role key real**: agarrar de Dashboard → Settings → API → `service_role secret`; reemplazar en `dashboard/.env.local` y Vercel env. (Ahora usa anon key — funciona por SECURITY DEFINER pero no es prod-grade)
- [ ] **Vercel**: actualizar `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` env vars → redeploy dashboard
- [ ] Smoke test: dashboard lee tablas nuevas, RPC `save_month_schedule` escribe OK
- [ ] Verificar `.mcp.json` ya apunta a `wkaeutndwawkdhswisqe` (hecho sesión previa)
- [ ] Tras cutover validado: retirar/archivar proyecto viejo `eazzsvekwmkwmlylirja`

### Opcional (hardening advisors — diferido, igual al schema viejo)
- [ ] `search_path` fijo en funciones (function_search_path_mutable WARN)
- [ ] Vistas a `security_invoker` (security_definer_view ERROR en agent_metrics/sla_breaches)
- [ ] Revisar grant de `get_sla_breaches` a anon (intencional en 0010)

---

## Backlog (Future / Nice-to-Have)

- [ ] Multi-account support (multiple Inmuebles24 accounts)
- [ ] Property photo sending via WhatsApp
- [ ] Visit scheduling integration (Google Calendar)
- [ ] Lead scoring based on qualification answers
- [ ] Analytics: conversion rate tracking
- [ ] Automatic follow-up sequences (drip campaign)
