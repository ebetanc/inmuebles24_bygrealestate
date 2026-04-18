# Roadmap: Inmobiliaria24 Lead Monitor

## Overview

Build a scheduled Python + Playwright automation that logs into Inmuebles24, extracts leads across active listings, deduplicates against persisted state, and delivers a structured Telegram notification — only when new leads exist. The build order follows the architectural dependency chain: auth before extraction, extraction before state, state before notification. Bot detection (Cloudflare + React) is the highest-risk unknown and is addressed in Phase 1 before any other layer is built.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Foundation** - Config, authenticated Playwright session, stealth, and bot-detection hardening (completed 2026-03-11)
- [ ] **Phase 2: Extraction** - Scrape active listings and per-listing leads into structured data
- [ ] **Phase 3: State and Deduplication** - Persist seen lead IDs, compute new-only diff, guard against concurrent runs
- [ ] **Phase 4: Notification** - Format and deliver Telegram message; suppress on no-new-leads

## Phase Details

### Phase 1: Foundation
**Goal**: A stealth-capable, authenticated Playwright session that can access Inmuebles24 reliably across repeated runs without being blocked
**Depends on**: Nothing (first phase)
**Requirements**: AUTH-01, AUTH-02
**Success Criteria** (what must be TRUE):
  1. Running the script with valid credentials in a `.env` file produces a live authenticated browser session without a 403 or CAPTCHA block
  2. Running the script a second time reuses a cached `storage_state` session without performing a fresh login
  3. If the cached session is stale or invalid, the script falls back to a fresh login automatically without crashing
  4. Credentials are never visible in source code, logs, or error output — only read from environment variables at runtime
**Plans**: 2 plans

Plans:
- [ ] 01-01-PLAN.md — Project scaffold, dependency manifest, and credential-safe config loader
- [ ] 01-02-PLAN.md — Authenticated Playwright session with stealth, storage_state caching, and CLI entrypoint

### Phase 2: Extraction
**Goal**: A scraper that returns structured lead data (linked to its source property) for all active listings in the authenticated account
**Depends on**: Phase 1
**Requirements**: EXTR-01, EXTR-02, EXTR-03
**Success Criteria** (what must be TRUE):
  1. Running the script against a live account returns a non-empty list of active listing records
  2. Each listing record includes its property ID and title
  3. Each lead record includes name, contact info, message excerpt, date, and the property ID it belongs to
  4. If extraction returns zero listings when listings are known to exist, the script logs an error and exits non-zero rather than silently continuing
**Plans**: TBD

### Phase 3: State and Deduplication
**Goal**: The tool deduplicates leads across runs — reporting only genuinely new leads and never re-sending ones already delivered
**Depends on**: Phase 2
**Requirements**: STAT-01, STAT-02, STAT-03
**Success Criteria** (what must be TRUE):
  1. On the first run with no existing state file, all extracted leads are treated as new and the state file is created
  2. On subsequent runs, only leads not present in the state file are identified as new
  3. The state file is updated only after a successful run — a crash mid-run does not corrupt or advance the seen-IDs set
  4. Two overlapping cron executions cannot run simultaneously — a second invocation exits immediately if the first is still running
**Plans**: TBD

### Phase 4: Notification
**Goal**: The agent receives a structured Telegram message the moment new leads appear — and receives nothing when there are no new leads
**Depends on**: Phase 3
**Requirements**: NOTF-01, NOTF-02, NOTF-03
**Success Criteria** (what must be TRUE):
  1. When new leads exist, a single Telegram message is delivered grouping all new leads under their respective property names with property link, lead name, contact info, message excerpt, and date
  2. When no new leads exist, no Telegram message is sent and the run exits cleanly
  3. A Telegram message can be sent successfully to the configured webhook URL using only a webhook URL in the environment — no other Telegram setup required
**Plans**: TBD

### Phase 5: WhatsApp Agent
**Goal**: Full inbound WhatsApp lead handling — routing, intake, AI Q&A, and human handoff — wired to the race-safe auction system (WF3, already built)
**Depends on**: Phase 4 (lead data available); WF3 auction subsystem (already built in `whatsapp-agent/`)
**Subphases (n8n workflows):**

- [ ] **5.1 — Twilio Setup**: Buy/configure number, wire Twilio webhook → n8n public URL
- [ ] **5.2 — WF1 Inbound Router**: Parse Twilio payload, classify sender (new lead / agent claiming / known lead), route to WF2 or WF3b or WF4
- [ ] **5.3 — WF2 Lead Intake**: Extract property ID from first message, fetch from EasyBroker (or cache), create `conversations` row (`mode='pending_assignment'`), call WF3a
- [ ] **5.4 — WF4 AI Conversation**: LLM-powered property Q&A scoped to EasyBroker data; guardrails for visits/negotiation/complex questions trigger WF5
- [ ] **5.5 — WF5 Human Handoff**: Share agent contact with lead, DM conversation summary to agent, flip `mode='human'`; WF1 passes subsequent messages directly

**Already built (in `whatsapp-agent/`):**
- WF3a Auction Launcher, WF3b Claim Handler, WF3c Expiry Sweeper
- Full DB schema + migrations (Supabase Postgres)
- Makefile, seed data, docs

**Stack**: n8n + Supabase Postgres + Twilio WhatsApp API + EasyBroker REST API + Claude/OpenAI (WF4)

**Success Criteria**:
  1. A WhatsApp message to the Twilio number creates a `conversations` row and fans auction notifications to all on-shift agents
  2. The first agent to reply `TOMO-<code>` wins atomically — no double-assignments under concurrent load
  3. The lead receives AI answers to property questions without agent involvement
  4. When the lead asks about visits or negotiation, the human agent is notified with a conversation summary and the lead gets the agent's contact

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 2/2 | Complete | 2026-03-11 |
| 2. Extraction | 0/TBD | Not started | - |
| 3. State and Deduplication | 0/TBD | Not started | - |
| 4. Notification | 0/TBD | Not started | - |
| 5. WhatsApp Agent | 0/5 | Not started (WF3 pre-built) | - |
