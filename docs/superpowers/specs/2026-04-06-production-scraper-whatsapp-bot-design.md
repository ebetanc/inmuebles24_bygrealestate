# Production Scraper + WhatsApp Bot — Design Spec

**Date:** 2026-04-06
**Status:** Approved
**Client:** Single real estate agency (BYG Real Estate)

---

## 1. System Overview

Upgrade the Inmuebles24 lead scraper from demo to production-grade, deploy on a Raspberry Pi 5 (16GB), store leads in a database via n8n, integrate with a pluggable CRM, and provide a WhatsApp customer service bot that answers listing questions with conversation memory.

### Architecture

```
┌──────────────────────────┐
│     Raspberry Pi 5       │
│                          │
│  systemd timer           │
│  every 15min 7am-18pm    │
│  ┌──────────────────┐    │
│  │ Python scraper    │    │
│  │ Playwright/Chrome │    │       ┌─────────────────────────────────┐
│  │ Bright Data proxy │────│──────▶│  Hostinger VPS                  │
│  │ (Mexico IPs)      │    │ POST  │                                 │
│  │ Dedup state file  │    │       │  n8n Workflows:                 │
│  └──────────────────┘    │       │  ├─ WF1: Lead Ingestion         │
│                          │       │  ├─ WF2: Heartbeat Monitor       │
└──────────────────────────┘       │  └─ WF3: WhatsApp Bot            │
                                   │                                  │
                                   │  Postgres/Supabase DB:           │
                                   │  ├─ leads                        │
                                   │  └─ conversations                │
                                   └─────────────────────────────────┘
                                            ▲
                                            │ WhatsApp Cloud API
                                            ▼
                                      ┌───────────┐
                                      │  End users │
                                      │ (WhatsApp) │
                                      └───────────┘
```

---

## 2. Scraper Upgrades (Raspberry Pi)

### 2.1 Proxy Integration

- Provider: Bright Data residential proxy
- Country targeting: Mexico (`country-mx` in proxy username)
- Configuration via environment variables:
  - `PROXY_HOST`, `PROXY_PORT`, `PROXY_USER`, `PROXY_PASS`
- Passed to Playwright browser launch as `proxy` option
- Fallback policy: if proxy fails, skip run and report error via heartbeat. Never fall back to direct IP.

### 2.2 Scheduling

- systemd timer + service (not cron)
- Fires every 15 minutes between 07:00-18:00 America/Mexico_City
- `Persistent=true` — catches up on missed runs after Pi reboot
- Prevents overlapping runs via systemd's default behavior
- ~44 runs per day

### 2.3 Deduplication

- Local JSON state file: `~/.inmuebles24/seen_leads.json`
- Tracks lead IDs already sent to n8n
- Only new leads get pushed per run
- Atomic writes: write to `.tmp`, then `os.replace()` to prevent corruption

### 2.4 Standardized Lead Schema

```json
{
  "lead_id": "string",
  "name": "string",
  "email": "string | null",
  "phone": "string | null",
  "message": "string | null",
  "listing_id": "string",
  "address": "string",
  "price": "string",
  "listing_type": "venta | renta",
  "property_type": "string",
  "source_tab": "mensajes | telefono | whatsapp",
  "scraped_at": "ISO 8601 timestamp"
}
```

### 2.5 Health Monitoring

- Each run sends a heartbeat to n8n: `{ "status": "ok|auth_failed|proxy_error|scrape_error", "leads_found": N, "new_leads": N, "timestamp": "..." }`
- n8n Workflow 2 tracks heartbeats and alerts on failure

### 2.6 Failure Handling

| Failure | Action |
|---------|--------|
| Auth failure | Heartbeat reports `auth_failed`, n8n alerts operator |
| Proxy connection failure | Skip run, heartbeat reports `proxy_error` |
| Scrape error mid-run | Send partial results, heartbeat reports error count |
| n8n webhook unreachable | Retry 3x with exponential backoff, save leads locally for next run |

---

## 3. n8n Workflows (Hostinger VPS)

### 3.1 Workflow 1: Lead Ingestion

- **Trigger:** Webhook POST from Pi scraper
- **Steps:**
  1. Validate incoming payload schema
  2. Store leads in Postgres/Supabase `leads` table
  3. Push to CRM via HTTP node (disabled placeholder until client provides CRM)
  4. Log success/failure per lead

### 3.2 Workflow 2: Heartbeat Monitor

- **Trigger:** Webhook POST from Pi heartbeat
- **Steps:**
  1. Track last-seen timestamp
  2. Alert if no heartbeat for 30+ minutes during operating hours (7am-18pm CDMX)
  3. Daily summary at 18:00 — total leads, new vs duplicates, errors

### 3.3 Workflow 3: WhatsApp Bot

- **Trigger:** Incoming WhatsApp message via Meta Cloud API webhook
- **Steps:**
  1. Receive user message
  2. Fetch conversation history (last 50 messages or 7 days, whichever fewer) from `conversations` table
  3. Save user message to `conversations` table
  4. Query `leads` table for matching listings (location, bedrooms, price, sale/rental)
  5. Pass to n8n AI Agent node: system prompt + conversation history + matching listings
  6. AI generates response in Spanish
  7. Save assistant response to `conversations` table
  8. Send response via WhatsApp Cloud API
  9. If out-of-scope request (visit scheduling, negotiations): reply with handoff message, notify human agent

---

## 4. Database Schema (Postgres/Supabase)

### 4.1 Leads Table

```sql
CREATE TABLE leads (
  id              SERIAL PRIMARY KEY,
  lead_id         TEXT UNIQUE NOT NULL,
  name            TEXT,
  email           TEXT,
  phone           TEXT,
  message         TEXT,
  listing_id      TEXT,
  address         TEXT,
  price           TEXT,
  listing_type    TEXT,
  property_type   TEXT,
  source_tab      TEXT,
  scraped_at      TIMESTAMPTZ,
  synced_to_crm   BOOLEAN DEFAULT FALSE,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);
```

### 4.2 Conversations Table

```sql
CREATE TABLE conversations (
  id              SERIAL PRIMARY KEY,
  phone_number    TEXT NOT NULL,
  role            TEXT NOT NULL,  -- 'user' or 'assistant'
  message         TEXT NOT NULL,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_conversations_phone ON conversations(phone_number, created_at DESC);
```

---

## 5. WhatsApp Bot Detail

### 5.1 Meta Cloud API Setup

- Meta Business account + WhatsApp Business Platform app
- Webhook URL pointing to n8n Workflow 3
- Subscribe to `messages` webhook event
- Required env vars: `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_ACCESS_TOKEN`, `META_VERIFY_TOKEN`

### 5.2 Conversation Memory

- All messages (user + assistant) persisted in `conversations` table keyed by phone number
- AI receives last 50 messages or 7 days of history per user
- Users can return days/weeks later and continue where they left off

### 5.3 AI Agent Configuration

- System prompt: professional, friendly, real estate focused, always responds in Spanish
- Context: user message + conversation history + up to 10 matching listings from DB
- Guardrails: only answer about available listings, no price negotiations, no legal advice
- Out-of-scope detection: visit scheduling, negotiations, legal questions trigger human handoff

### 5.4 Example Flow

```
Monday:
  User: "Tienen departamentos en renta en Polanco?"
  Bot: "Hola! Si, tenemos 2 opciones: 1) Depto 2 rec en Av. Masaryk..."

Friday:
  User: "La primera que me mostraste, tiene estacionamiento?"
  Bot: "Si, la casa en Av. Masaryk cuenta con 2 lugares de estacionamiento."
```

---

## 6. CRM Integration (Pluggable)

- Disabled HTTP Request node in n8n WF1 with placeholder config
- `synced_to_crm` flag in leads table tracks sync status
- When client provides CRM details:
  1. Map lead schema to CRM fields
  2. Configure/swap in native n8n node (HubSpot, Pipedrive, Salesforce, etc.)
  3. Enable the node
  4. Backfill all `synced_to_crm = FALSE` leads
- Retry workflow picks up failed syncs every hour

---

## 7. Raspberry Pi Deployment

### 7.1 System

- Raspberry Pi 5, 16GB RAM
- Raspberry Pi OS Lite (64-bit), headless
- Python 3.12+ (system or pyenv)
- Chromium from apt (ARM64)
- Playwright configured to use system Chromium

### 7.2 Systemd Units

- `inmuebles24.service` — oneshot, runs scraper
- `inmuebles24.timer` — every 15 min, 07:00-18:00 America/Mexico_City, Persistent=true

### 7.3 File Layout

```
~/.inmuebles24/
  .env                          # Credentials (chmod 600)
  seen_leads.json               # Dedup state
  .session/chrome-profile/      # Persistent Chrome profile
  logs/                         # Loguru rotation, 14-day retention
```

### 7.4 Security

- `.env` with `chmod 600`
- No credentials in code or logs
- Pi firewall: outbound only, no inbound ports

---

## 8. Implementation Order

| Phase | What | Depends on |
|-------|------|------------|
| 1 | Scraper upgrades (proxy, dedup, heartbeat, standardized output) | Bright Data credentials |
| 2 | Postgres DB + n8n WF1 (lead ingestion) | Phase 1 |
| 3 | n8n WF2 (heartbeat monitor) | Phase 2 |
| 4 | Pi deployment (systemd timer, .env, full loop test) | Phase 1-3 |
| 5 | WhatsApp bot (n8n WF3, Meta setup, conversation memory, AI agent) | Phase 2 + Meta Business verification |
| 6 | CRM adapter | Client provides CRM + API keys |

---

## 9. Prerequisites Per Phase

- **Phases 1-4:** Bright Data account + credentials
- **Phase 5:** Meta Business account verified, WhatsApp Business phone number
- **Phase 6:** CRM name + API keys from client

---

## 10. Out of Scope

- Multi-tenant support (single agency only)
- Image/media responses in WhatsApp bot
- Automated visit scheduling
- Price negotiation by the bot
- Scraping sites other than Inmuebles24
- Mobile app or web dashboard
