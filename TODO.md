# Inmobiliaria24 — TODO Tracker

> **Legend:** `[ ]` pending | `[~]` in progress | `[x]` done | `[!]` blocked
> **Last updated:** 2026-04-09

---

## Phase 1: Production Hardening (Scraper)

### State & Deduplication
- [x] Create `state.py` module with SQLite-backed state store
- [x] Implement lead ID tracking (seen/new detection)
- [x] SQLite WAL mode + busy_timeout for concurrent safety
- [x] File locking via SQLite built-in locking
- [x] Unit tests for state module (6 tests passing)

### Error Recovery
- [x] Add retry logic with exponential backoff (page loads)
- [x] Add retry logic for webhook/API calls (3 retries, exponential backoff)
- [x] Graceful tab-failure handling (continue with other tabs — try/except per lead)
- [x] Session auto-recovery on stale detection
- [x] Screenshot capture on all failures

### Logging & Monitoring
- [x] Switch to structured JSON logging for production
- [x] Implement health heartbeat (Telegram ping after each run)
- [x] Error-only alerts to Telegram (`monitor.py`)
- [x] Log rotation config (10MB, 7 days)

### Scheduling & Deployment
- [x] Create systemd service unit (`inmobiliaria24.service`)
- [x] Create systemd timer unit (every 2h, business hours)
- [x] Add new env vars to config (WEBHOOK_URL, STATE_DB_PATH, TELEGRAM_*)
- [x] `deploy.sh` script

---

## Phase 2: CRM Adapter Layer

### Generic Interface
- [x] Define `CRMAdapter` abstract base class (`crm/base.py`)
- [x] Define `Lead` data model (dataclass with `from_scraped()`)
- [x] Implement `WebhookCRMAdapter` (generic POST with retry)
- [x] HubSpot adapter template (`crm/hubspot.py` — ready for API keys)
- [x] Unit tests for Lead model (3 tests)

### Lead Pipeline
- [x] Build pipeline: scrape → dedup → CRM check → push (`pipeline.py`)
- [x] Track CRM push status per lead in state DB
- [x] Retry failed CRM pushes on next run (`retry_failed_pushes()`)
- [x] Pipeline integration tests (mock CRM)

### CRM-Specific (when keys arrive)
- [!] Activate HubSpot adapter (blocked: waiting for client CRM decision + keys)
- [x] Field mapping: Lead model → HubSpot fields (in hubspot.py)
- [ ] CRM adapter integration tests

---

## Phase 3: WhatsApp Business API Setup

### Account & BSP (manual steps)
- [ ] Select BSP (360dialog vs Twilio — evaluate pricing)
- [!] Register WhatsApp Business Account (blocked: need client's business info)
- [!] Meta Business verification (blocked: need client action)
- [ ] Get dedicated phone number
- [ ] Configure webhook endpoint URL with Meta

### Message Templates
- [x] Draft `lead_greeting` template (Spanish) — in `templates.py`
- [x] Draft `qualification_start` template
- [x] Draft `agent_handoff` template
- [x] Draft `follow_up` template
- [x] Template component builder (`build_template_components()`)
- [!] Submit templates for Meta approval (blocked: need WA account)

### WhatsApp Service Module
- [x] WA Business API client (`whatsapp/client.py`)
- [x] Template message sender
- [x] Free-form text message sender (24h window)
- [x] Interactive buttons + list messages
- [x] Mark-as-read support
- [x] Incoming webhook handler (in `server.py`)
- [x] Message status logging

---

## Phase 4: WhatsApp Qualification Bot

### Conversation State Machine
- [x] Design state machine: NEW → GREETING → INTENT → BUDGET → TIMELINE → ZONE → QUALIFIED → HANDED_OFF
- [x] Implement state machine in `whatsapp/bot.py`
- [x] SQLite-backed conversation store (`conversation_store.py`)
- [x] Timeout handling (24h no-response → follow-up)
- [x] Second timeout → mark as cold + update CRM
- [x] Unit tests for conversation store (5 tests)

### Natural Language Parsing
- [x] Budget parser ("2 millones", "$2M", "500k", ranges)
- [x] Timeline parser ("ahora", "3 meses", button replies)
- [x] Intent parser (comprar/rentar)
- [x] Zone parser (cleanup prefixes)
- [x] Off-script handler (re-prompt on unrecognized input)
- [x] Agent-request detection ("quiero hablar con alguien" → immediate handoff)
- [x] Parser unit tests (15 tests)

### Agent Handoff
- [x] Qualification summary builder
- [x] Send agent WhatsApp notification with lead brief
- [x] Update CRM with qualification data
- [x] Mark conversation as "handed off" (bot stops responding)

---

## Phase 5: Integration & Deployment

### Web Server
- [x] FastAPI app with WhatsApp webhook endpoints (`server.py`)
- [x] Meta webhook verification challenge handler
- [x] Webhook signature verification (HMAC-SHA256)
- [x] Health check endpoint (`GET /health`)
- [x] Interactive button/list reply parsing
- [x] Systemd service for uvicorn (`inmobiliaria24-server.service`)

### Deployment Configs
- [x] `deploy.sh` script (pull, install, restart)
- [x] Nginx reverse proxy config (`nginx-webhook.conf`)
- [x] Systemd service for webhook server
- [ ] SSL certificate setup (Let's Encrypt / certbot) — manual on VPS
- [ ] Firewall rules — manual on VPS
- [ ] Environment setup on VPS — manual

### Testing
- [x] Unit tests: 49 passing (config, state, CRM, parser, conversation store, pipeline, monitor)
- [ ] Integration test: mock scrape → full pipeline → mock CRM
- [ ] WhatsApp bot conversation E2E test
- [ ] End-to-end test on staging

### Monitoring
- [ ] Telegram error channel setup — manual
- [x] Alert: 0 successful runs in 24h
- [ ] Alert: webhook unreachable
- [x] Daily summary: leads scraped / qualified / pushed

---

## Phase 6: Polish & Client Handoff

### Documentation
- [x] README.md with full setup instructions
- [x] Environment variables reference (`.env.example` — complete)
- [ ] Bot conversation flow diagram

### Client Configuration
- [x] Bot messages via templates (configurable without code changes)
- [x] Agent phone + name configurable via env vars
- [x] Business hours configurable via env vars
- [x] Timeout configurable via env vars

### Go-Live Checklist (all manual)
- [ ] Meta Business verification approved
- [ ] WhatsApp templates approved
- [ ] CRM keys configured and tested
- [ ] SSL certificate active and auto-renewing
- [ ] Scraper running on schedule
- [ ] Bot responding to test messages
- [ ] Error alerts verified
- [ ] Client walkthrough / training session

---

## Backlog (Future / Nice-to-Have)

- [ ] Multi-account support (multiple Inmuebles24 accounts)
- [ ] Admin web dashboard (lead stats, bot performance)
- [ ] Property photo sending via WhatsApp
- [ ] Visit scheduling integration (Google Calendar)
- [ ] Lead scoring based on qualification answers
- [ ] Analytics: conversion rate tracking
- [ ] Automatic follow-up sequences (drip campaign)
- [ ] Agent mobile app for lead management

---

## Client Dependencies Tracker

| Item | Owner | Status | Notes |
|------|-------|--------|-------|
| CRM selection + API keys | Client | Pending | Needed to activate CRM adapter |
| WhatsApp Business phone # | Client | Pending | Needed for Meta setup |
| Meta Business Manager access | Client | Pending | Needed for WA templates |
| Business verification docs | Client | Pending | Needed for Meta approval |
| Qualification flow approval | Client | Pending | Templates ready for review |
| Agent phone for handoff | Client | Pending | Env var: BOT_AGENT_PHONE |
| VPS SSH access | Client | Pending | Needed for deployment |
| Go-live date agreement | Client | Pending | — |
