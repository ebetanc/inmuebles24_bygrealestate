# Inmuebles24 Production System — TODO

## Phase 1: Scraper Upgrades
- [ ] Integrate Bright Data residential proxy (Mexico IPs) into Playwright launch
- [ ] Add proxy config env vars (PROXY_HOST, PROXY_PORT, PROXY_USER, PROXY_PASS)
- [ ] Implement deduplication with local JSON state file (~/.inmuebles24/seen_leads.json)
- [ ] Atomic writes for state file (write .tmp then os.replace)
- [ ] Standardize lead output schema across all tabs
- [ ] Add heartbeat POST to n8n after each run (status, lead counts, timestamp)
- [ ] Implement failure handling: proxy errors, auth failures, partial scrapes
- [ ] Retry logic for n8n webhook (3x exponential backoff, local save fallback)

## Phase 2: Postgres DB + n8n Lead Ingestion (WF1)
- [ ] Set up Postgres/Supabase database
- [ ] Create `leads` table with schema from design spec
- [ ] Create `conversations` table with phone_number index
- [ ] Build n8n Workflow 1: webhook receiver → validate → store in DB
- [ ] Add disabled CRM push node (placeholder)
- [ ] Add `synced_to_crm` flag logic

## Phase 3: n8n Heartbeat Monitor (WF2)
- [ ] Build n8n Workflow 2: heartbeat webhook receiver
- [ ] Track last-seen timestamp
- [ ] Alert if no heartbeat for 30+ min during operating hours
- [ ] Daily summary at 18:00 CDMX (total leads, new vs dupes, errors)

## Phase 4: Raspberry Pi Deployment
- [ ] Install Raspberry Pi OS Lite (64-bit) on Pi 5
- [ ] Install Python 3.12+, Chromium, Playwright
- [ ] Create ~/.inmuebles24/ directory structure
- [ ] Configure .env file (chmod 600)
- [ ] Create systemd service unit (inmuebles24.service)
- [ ] Create systemd timer unit (every 15min, 7am-18pm CDMX)
- [ ] Test full loop: scrape → webhook → DB storage
- [ ] Verify heartbeat monitoring end-to-end

## Phase 5: WhatsApp Bot (n8n WF3)
- [ ] Register Meta Business account
- [ ] Set up WhatsApp Business Platform app
- [ ] Configure webhook URL to n8n
- [ ] Build n8n Workflow 3: receive message → load history → query listings → AI agent → respond
- [ ] Configure AI Agent node (Spanish system prompt, guardrails)
- [ ] Implement conversation memory (save/load from conversations table)
- [ ] Implement human handoff for out-of-scope requests
- [ ] Test conversation continuity across days

## Phase 6: CRM Integration
- [ ] Receive CRM name + API keys from client
- [ ] Map lead schema to CRM contact/deal fields
- [ ] Configure n8n CRM node in WF1
- [ ] Backfill all synced_to_crm = FALSE leads
- [ ] Set up hourly retry workflow for failed syncs

## Blocked / Waiting
- [ ] Bright Data credentials (needed for Phase 1)
- [ ] Meta Business account verification (needed for Phase 5)
- [ ] CRM details from client (needed for Phase 6)
