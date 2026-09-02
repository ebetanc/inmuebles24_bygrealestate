# Inmobiliaria24 — Production Plan

> **Status:** Planning
> **Last updated:** 2026-04-09
> **Client:** BYG Real Estate
> **Target:** Production-grade lead capture + WhatsApp qualification bot

---

## Executive Summary

Transform the demo scraper into a production system with three pillars:
1. **Reliable scraping** with deduplication and error recovery
2. **CRM integration** via generic adapter (CRM TBD by client)
3. **WhatsApp Business bot** that auto-responds and qualifies leads

All running on the existing Hostinger VPS alongside n8n.

---

## Architecture Overview

```
Inmuebles24.com
      |
      v
[Scraper] ──> [State DB] ──> [CRM Adapter] ──> [Client's CRM]
      |                             |
      |                             v
      |                    [WhatsApp Business API]
      |                        |           ^
      |                        v           |
      |                   [Lead gets       [Lead replies]
      |                    greeting]            |
      v                                        v
[Error Alerts] ──────────> [Telegram]   [Qualification Bot]
                          (errors only)   (budget/timeline/zone)
                                               |
                                               v
                                      [Qualified Lead ──> CRM + Agent WA]
```

---

## Phase Breakdown

### Phase 1: Production Hardening (Scraper)
**Goal:** Make the existing scraper reliable enough for unattended production runs.

**Tasks:**
1. **State & Deduplication**
   - Create `state.json` (or SQLite) to persist seen lead IDs
   - On each run: extract → diff against state → process only NEW leads
   - Atomic writes (write to temp file, then rename) to prevent corruption
   - File locking (`flock`) to prevent concurrent runs

2. **Error Recovery & Resilience**
   - Retry logic with exponential backoff for page loads and webhook calls
   - Screenshot capture on any failure for debugging
   - Graceful degradation: if one tab fails, continue with others
   - Session auto-recovery: detect stale session → clear → re-login

3. **Logging & Monitoring**
   - Structured JSON logging for production (loguru → JSON sink)
   - Health heartbeat: send "alive" signal every N hours
   - Error alerts to Telegram (keep Telegram ONLY for system errors)
   - Log rotation: max 10MB per file, keep 7 days

4. **Scheduling**
   - Systemd timer (preferred over cron for logging/restart)
   - Run every 2 hours during business hours (8am–10pm CST)
   - Configurable schedule via environment variable

**Deliverables:**
- `src/inmobiliaria24/state.py` — State management module
- `src/inmobiliaria24/monitor.py` — Health/error alerting
- `deploy/inmobiliaria24.service` — Systemd service unit
- `deploy/inmobiliaria24.timer` — Systemd timer unit
- Updated `config.py` with new env vars

**Estimated effort:** 2-3 days

---

### Phase 2: CRM Adapter Layer
**Goal:** Build a pluggable CRM integration that works with any CRM the client chooses.

**Tasks:**
1. **Generic CRM Interface**
   - Define abstract `CRMAdapter` base class:
     ```python
     class CRMAdapter(ABC):
         async def push_lead(self, lead: Lead) -> str:  # returns CRM lead ID
         async def update_lead(self, crm_id: str, data: dict) -> None:
         async def check_duplicate(self, email: str, phone: str) -> Optional[str]:
         async def health_check(self) -> bool:
     ```
   - Lead data model with all fields from scraper + qualification data

2. **Webhook Adapter (Interim)**
   - Implement `WebhookCRMAdapter` that POSTs to any URL
   - This replaces the current hardcoded n8n webhook
   - Works as fallback until client provides CRM keys
   - Supports configurable payload mapping (JSON template)

3. **CRM-Specific Adapters (when client decides)**
   - `HubSpotAdapter` — most likely for real estate
   - `SalesforceAdapter` — enterprise option
   - Each adapter maps Lead fields → CRM fields
   - Handle rate limits, auth token refresh, error codes

4. **Lead Pipeline**
   - Scraper → Dedup check → CRM duplicate check → Push to CRM
   - Track CRM push status per lead in state DB
   - Retry failed pushes on next run
   - Conflict resolution: CRM is source of truth for existing leads

**Deliverables:**
- `src/inmobiliaria24/crm/base.py` — Abstract adapter + Lead model
- `src/inmobiliaria24/crm/webhook.py` — Generic webhook adapter
- `src/inmobiliaria24/crm/hubspot.py` — HubSpot adapter (template, activated when keys arrive)
- `src/inmobiliaria24/pipeline.py` — Lead processing pipeline
- Updated `.env.example` with CRM config vars

**Estimated effort:** 3-4 days

---

### Phase 3: WhatsApp Business API Setup
**Goal:** Set up WhatsApp Business API via a BSP and build the message infrastructure.

**Tasks:**
1. **BSP Selection & Account Setup**
   - Recommended BSP: **360dialog** (good for LatAm, cost-effective) or **Twilio**
   - Register WhatsApp Business Account with Meta
   - Business verification process (~1-2 weeks for Meta approval)
   - Get dedicated phone number for the bot
   - Set up webhook endpoint for incoming messages

2. **Message Templates (Meta-approved)**
   - Templates need Meta approval before sending (24h+ review):
     - `lead_greeting`: "Hola {{name}}, gracias por tu interés en {{property}}. Soy el asistente de BYG Real Estate..."
     - `qualification_start`: "Para atenderte mejor, me gustaría hacerte unas preguntas rápidas..."
     - `agent_handoff`: "Te comunico con {{agent_name}} quien te ayudará personalmente..."
     - `follow_up`: "Hola {{name}}, ¿sigues interesado en {{property}}?"
   - Submit templates early — approval can take 24-48h

3. **WhatsApp Service Module**
   - Incoming webhook handler (receives lead replies)
   - Outgoing message sender (uses approved templates + free-form in 24h window)
   - Media support: send property photos/PDFs
   - Message status tracking (sent/delivered/read)

4. **n8n Integration**
   - New n8n workflow: WhatsApp webhook → Bot logic → Response
   - OR: Direct Python handler (more control, less dependency on n8n)
   - **Recommended: Python handler** — keeps all logic in one codebase

**Deliverables:**
- BSP account setup documentation
- Message template drafts for Meta approval
- `src/inmobiliaria24/whatsapp/client.py` — WA Business API client
- `src/inmobiliaria24/whatsapp/templates.py` — Template management
- `src/inmobiliaria24/whatsapp/webhook.py` — Incoming message handler
- Webhook endpoint (FastAPI or similar lightweight server)

**Estimated effort:** 5-7 days (including Meta approval wait time)

---

### Phase 4: WhatsApp Qualification Bot
**Goal:** Automated conversation flow that qualifies leads before agent handoff.

**Tasks:**
1. **Conversation State Machine**
   ```
   [NEW_LEAD]
       → Send greeting + property context
       → "¿Estás interesado en comprar o rentar?"

   [AWAITING_INTENT]
       → Capture: comprar/rentar
       → "¿Cuál es tu presupuesto aproximado?"

   [AWAITING_BUDGET]
       → Capture: budget range
       → "¿En qué periodo estás buscando? (inmediato / 1-3 meses / 3-6 meses / solo explorando)"

   [AWAITING_TIMELINE]
       → Capture: timeline
       → "¿Qué zona prefieres?"

   [AWAITING_ZONE]
       → Capture: zone preference
       → "Perfecto, te comunico con nuestro asesor {{agent}}. ¡Gracias!"

   [QUALIFIED]
       → Push qualification data to CRM
       → Notify agent via WhatsApp with full lead brief
       → Agent takes over conversation

   [TIMEOUT] (no response in 24h)
       → Send follow-up template
       → After 2nd timeout → mark as cold in CRM
   ```

2. **Conversation Persistence**
   - Store conversation state per lead (phone number as key)
   - SQLite or JSON file for state (SQLite preferred for concurrent access)
   - Track: current step, collected answers, timestamps, retry count

3. **Natural Language Handling**
   - Parse free-text budget responses ("como 2 millones", "$2M", "2,000,000")
   - Parse timeline ("ahora", "en 3 meses", "el próximo año")
   - Handle off-script messages: "No entendí tu respuesta, ¿podrías elegir una opción?"
   - Detect agent-request: "quiero hablar con alguien" → immediate handoff

4. **Agent Handoff**
   - When qualification completes:
     - Update CRM with qualification data
     - Send agent a WhatsApp summary: lead name, property, budget, timeline, zone
     - Mark conversation as "handed off" — bot stops responding
   - Agent can trigger bot to re-engage via command (future)

**Deliverables:**
- `src/inmobiliaria24/whatsapp/bot.py` — Conversation state machine
- `src/inmobiliaria24/whatsapp/parser.py` — NL response parser (budget, timeline, etc.)
- `src/inmobiliaria24/whatsapp/handoff.py` — Agent notification & handoff logic
- `src/inmobiliaria24/conversation_store.py` — SQLite-backed conversation state
- Qualification flow diagram (for client approval)

**Estimated effort:** 4-5 days

---

### Phase 5: Integration & Deployment
**Goal:** Wire everything together, deploy to VPS, test end-to-end.

**Tasks:**
1. **End-to-End Pipeline**
   ```
   Cron triggers scraper
       → New leads extracted
       → Dedup against state DB
       → Push to CRM (adapter)
       → Send WhatsApp greeting to lead
       → Bot qualifies lead
       → Qualification data → CRM update
       → Agent notified via WhatsApp
   ```

2. **Web Server for Webhooks**
   - Lightweight FastAPI app to receive WhatsApp webhooks
   - Endpoints:
     - `POST /webhook/whatsapp` — Incoming messages
     - `GET /webhook/whatsapp` — Meta verification challenge
     - `GET /health` — Health check endpoint
   - Run via systemd + uvicorn
   - Reverse proxy via existing n8n's nginx (or Caddy)

3. **Deployment Automation**
   - `deploy.sh` script: pull, install deps, restart services
   - Environment setup documentation
   - SSL certificate for webhook endpoint (Let's Encrypt)
   - Firewall rules for webhook port

4. **Testing**
   - Unit tests for each module
   - Integration test: mock Inmuebles24 → full pipeline → mock CRM
   - WhatsApp bot conversation test with test number
   - Load test: simulate 50 leads in one batch

5. **Monitoring & Alerting**
   - Telegram channel for system errors only
   - Scraper: alert if 0 runs succeed in 24h
   - Bot: alert if webhook is unreachable
   - CRM: alert if push failures exceed threshold
   - Daily summary: X leads scraped, Y qualified, Z pushed to CRM

**Deliverables:**
- `src/inmobiliaria24/server.py` — FastAPI webhook server
- `deploy/` — All deployment configs (systemd, nginx, deploy.sh)
- `tests/` — Full test suite
- `docs/DEPLOY.md` — Deployment guide
- `docs/RUNBOOK.md` — Operations runbook (common issues & fixes)

**Estimated effort:** 3-4 days

---

### Phase 6: Polish & Client Handoff
**Goal:** Documentation, client training, go-live support.

**Tasks:**
1. **Documentation**
   - README.md with setup instructions
   - API documentation for CRM adapter
   - WhatsApp bot conversation flow diagram
   - Environment variables reference

2. **Client Configuration**
   - Admin panel or config file for:
     - Bot greeting messages (editable without code)
     - Qualification questions (configurable)
     - Business hours (when bot responds)
     - Agent phone number for handoff

3. **Go-Live Checklist**
   - [ ] Meta Business verification approved
   - [ ] WhatsApp templates approved
   - [ ] CRM keys configured
   - [ ] SSL certificate active
   - [ ] Scraper running on schedule
   - [ ] Bot responding to test messages
   - [ ] Error alerts working
   - [ ] Client trained on monitoring

**Estimated effort:** 2-3 days

---

## Technology Stack (Production)

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| Scraper | Python 3.13 + Playwright/CDP | Already built, proven |
| Web server | FastAPI + Uvicorn | Lightweight, async, handles webhooks |
| WhatsApp API | 360dialog or Twilio | Official BSP, LatAm support |
| CRM adapter | Abstract Python class | Pluggable, client hasn't decided |
| State DB | SQLite | Single-file, concurrent-safe, zero config |
| Scheduling | Systemd timer | Better than cron: logging, restart on failure |
| Deployment | Systemd + Nginx reverse proxy | Uses existing VPS infra |
| Monitoring | Telegram bot (errors only) | Already have the integration |
| Config | .env + python-dotenv | Simple, secure, already in place |

---

## Environment Variables (Production)

```bash
# Existing
INMUEBLES24_EMAIL=...
INMUEBLES24_PASSWORD=...

# New — Scraper
SCRAPE_INTERVAL_HOURS=2
SCRAPE_BUSINESS_HOURS_START=8
SCRAPE_BUSINESS_HOURS_END=22
STATE_DB_PATH=./data/state.db

# New — CRM
CRM_ADAPTER=webhook  # webhook | hubspot | salesforce
CRM_WEBHOOK_URL=https://...
CRM_API_KEY=...
CRM_API_SECRET=...

# New — WhatsApp
WA_BSP=360dialog  # 360dialog | twilio
WA_API_KEY=...
WA_PHONE_NUMBER_ID=...
WA_WEBHOOK_VERIFY_TOKEN=...
WA_WEBHOOK_SECRET=...

# New — Bot
BOT_AGENT_PHONE=+52...
BOT_BUSINESS_HOURS_START=8
BOT_BUSINESS_HOURS_END=22
BOT_TIMEOUT_HOURS=24

# New — Monitoring
TELEGRAM_BOT_TOKEN=...
TELEGRAM_ALERT_CHAT_ID=...
```

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| Meta WA approval delays | Blocks Phase 3-4 | Submit templates ASAP, start Phase 1-2 in parallel |
| Inmuebles24 changes HTML | Breaks scraper | Screenshot-on-error, alerting, CSS selector fallbacks |
| CRM keys delayed | Blocks Phase 2 integration | Webhook adapter works as interim, pipeline is ready |
| VPS resource limits | Performance issues | Monitor RAM/CPU, Chrome is the heaviest component |
| Bot sends spam-like messages | WA account ban | Use approved templates, respect 24h window, rate limit |
| Concurrent scraper runs | Duplicate leads | File locking + state DB dedup |

---

## Timeline (Estimated)

```
Week 1:  Phase 1 (Scraper hardening) + Phase 3 start (BSP setup, template submission)
Week 2:  Phase 2 (CRM adapter) + Phase 3 continue (WA API client)
Week 3:  Phase 4 (Qualification bot)
Week 4:  Phase 5 (Integration & deployment) + Phase 6 (Polish)
```

**Total estimated effort: 19-26 days**
**Calendar time: ~4 weeks** (accounting for Meta approval wait)

---

## Dependencies on Client

| Item | Needed by | Status |
|------|-----------|--------|
| CRM selection + API keys | Phase 2 | Pending |
| WhatsApp Business phone number | Phase 3 | Pending |
| Meta Business Manager access | Phase 3 | Pending |
| Qualification questions approval | Phase 4 | Pending |
| Agent phone for handoff | Phase 4 | Pending |
| VPS access/credentials | Phase 5 | Pending |
| Go-live date | Phase 6 | Pending |
