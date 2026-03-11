# Roadmap: Inmobiliaria24 Lead Monitor

## Overview

Build a scheduled Python + Playwright automation that logs into Inmuebles24, extracts leads across active listings, deduplicates against persisted state, and delivers a structured Telegram notification — only when new leads exist. The build order follows the architectural dependency chain: auth before extraction, extraction before state, state before notification. Bot detection (Cloudflare + React) is the highest-risk unknown and is addressed in Phase 1 before any other layer is built.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Foundation** - Config, authenticated Playwright session, stealth, and bot-detection hardening
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

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 0/2 | In progress | - |
| 2. Extraction | 0/TBD | Not started | - |
| 3. State and Deduplication | 0/TBD | Not started | - |
| 4. Notification | 0/TBD | Not started | - |
