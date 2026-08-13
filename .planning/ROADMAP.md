---
title: Roadmap - Inmobiliaria24 Lead Monitor
date: 2026-07-31
tags:
  - roadmap
  - sprint
  - inmobiliaria24
  - architecture
aliases:
  - Project Roadmap
  - Sprint Plan
status: active
---

# Roadmap: Inmobiliaria24 Lead Monitor

> [!info] Project Overview
> Build a scheduled Python + Playwright automation that logs into Inmuebles24, extracts leads across active listings, deduplicates against persisted state, and delivers structured notifications & WhatsApp auctions via n8n + Supabase + Next.js Dashboard.

## Phases

- [x] **Phase 1: Foundation** — Config, authenticated Playwright session, stealth, and bot-detection hardening (completed 2026-03-11)
- [x] **Phase 2: Extraction** — Scrape active listings and per-listing leads into structured data (`[[src/inmobiliaria24/scraper.py]]`)
- [x] **Phase 3: State and Deduplication** — Persist seen lead IDs, compute new-only diff, guard against concurrent runs (`[[src/inmobiliaria24/state.py]]`)
- [x] **Phase 4: Notification** — Format and deliver Telegram/Webhook messages (`[[src/inmobiliaria24/crm/webhook.py]]`, `[[src/inmobiliaria24/monitor.py]]`)
- [x] **Phase 5: WhatsApp Agent & Auction System** — n8n 11-workflow engine, Meta Cloud API / Twilio, Supabase RLS, TOMO auction engine
- [x] **Phase 6: Next.js Dashboard & Role Management** — Live lead monitor, guard schedule calendar, owner/manager role badges (`[[dashboard/src/lib/queries.ts]]`)
- [x] **Phase 7: Real Production Deployment & E2E Verification** — Pi scraper with MX mobile proxy relay, Supabase cutover, 113/113 passing unit tests

---

## Phase Details

### Phase 1: Foundation
**Goal**: A stealth-capable, authenticated Playwright session that can access Inmuebles24 reliably across repeated runs without being blocked.
**Depends on**: Nothing (first phase)
**Requirements**: AUTH-01, AUTH-02

Plans:
- [x] [[01-01-PLAN.md]] — Project scaffold, dependency manifest, and credential-safe config loader
- [x] [[01-02-PLAN.md]] — Authenticated Playwright session with stealth, `storage_state` caching, and CLI entrypoint

### Phase 2: Extraction
**Goal**: Scraper returning structured lead data linked to source property for active listings.
- [x] Scrape Playwright inbox (`messages`, `phone`, `WhatsApp` tabs)
- [x] Selector fallbacks & SPA navigation wait

### Phase 3: State & Deduplication
**Goal**: Durable lead deduplication & concurrency control.
- [x] SQLite `StateStore` with WAL mode & atomic lock
- [x] Unpushed lead tracking & retry pipeline

### Phase 4 & 5: Notifications & WhatsApp Agent
**Goal**: Multi-channel lead dispatching and automated WhatsApp auctions.
- [x] Telegram error alerts & heartbeats (`[[src/inmobiliaria24/monitor.py]]`)
- [x] 11 n8n workflows (`WF1`-`WF10`) for inbound routing, TOMO auctions, AI conversation, and human handoff

### Phase 6 & 7: Dashboard, Metrics & SLA Monitoring
**Goal**: Real-time SLA tracking, response metrics, and role-based agent management.
- [x] SLA breach detection view & RPCs in Supabase
- [x] Next.js dashboard KPI cards with real `avgResponseMin`, `conversionRate`, and `slaBreachesCount`

---

## Sprint Execution Log

> [!success] Completed Sprint Items (2026-07-31)
> 1. **Graphify Architecture Mapping**: Mapped 220+ codebase symbols, database schema, Next.js dashboard, and `inmobiliaria24` scraper modules.
> 2. **SLA & Dashboard Metrics Implementation**:
>    - Updated `[[dashboard/src/lib/types.ts]]` with `SLABreach` interface & `slaBreachesCount` field in `KPIs`.
>    - Updated `[[dashboard/src/lib/queries.ts]]` `getKPIs()` to query `agent_metrics` & `conversations` dynamically for real response times and conversion rates.
>    - Added `getSLABreaches()` query function for real-time SLA breach monitoring.
> 3. **Monitor Clean-up**:
>    - Enhanced `[[src/inmobiliaria24/monitor.py]]` `raise_for_status()` to support both sync and async mock callers seamlessly.
> 4. **Verification**:
>    - All 113 pytest tests passing (`113 passed in 0.59s`).
>    - Next.js production build (`npm run build`) completed cleanly with zero errors.
>    - Knowledge graph updated via `graphify update .`.

| Phase | Status | Completion Date |
|---|---|---|
| 1. Foundation | Complete | 2026-03-11 |
| 2. Extraction | Complete | 2026-06-14 |
| 3. State & Deduplication | Complete | 2026-06-14 |
| 4. Notification | Complete | 2026-06-14 |
| 5. WhatsApp Agent | Complete | 2026-06-20 |
| 6. Dashboard & SLA Metrics | Complete | 2026-07-31 |
| 7. Production Readiness | Complete | 2026-07-31 |
