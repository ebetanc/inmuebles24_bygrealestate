# Requirements: Inmobiliaria24 Lead Monitor

**Defined:** 2026-03-11
**Core Value:** The moment a buyer shows interest in a property, the agent knows — without opening a browser.

## v1 Requirements

### Authentication

- [x] **AUTH-01**: System logs in to Inmuebles24 with email and password supplied via environment variables
- [x] **AUTH-02**: Credentials are never hardcoded — read from `.env` file at runtime

### Extraction

- [ ] **EXTR-01**: System fetches all active listings from the authenticated account
- [ ] **EXTR-02**: System extracts leads/inquiries associated with each listing (name, contact info, message, date)
- [ ] **EXTR-03**: Each lead record is linked to its source property (property ID and title)

### State & Deduplication

- [ ] **STAT-01**: System persists seen lead IDs to a local file between runs
- [ ] **STAT-02**: On each run, system compares extracted leads against seen IDs and identifies only new ones
- [ ] **STAT-03**: After successful Telegram delivery, seen IDs are updated so leads are not re-reported

### Notification

- [ ] **NOTF-01**: System sends a Telegram message via webhook for each property that has new leads, grouping all new leads under that property
- [ ] **NOTF-02**: Message format shows: property name, property link, and for each new lead — name, contact, message excerpt, and date
- [ ] **NOTF-03**: If no new leads are found, no message is sent

## v2 Requirements

### Authentication

- **AUTH-V2-01**: Session cookies cached and reused across runs to avoid re-login overhead
- **AUTH-V2-02**: Stale session detected automatically; system re-authenticates without intervention

### State

- **STAT-V2-01**: First-run full sync — all existing leads imported as seen on initial run (no Telegram flood)
- **STAT-V2-02**: State file uses atomic writes (write-to-tmp then replace) to prevent corruption on crash

### Notifications

- **NOTF-V2-01**: Daily heartbeat message confirms scraper is alive even when no new leads found
- **NOTF-V2-02**: Error alert sent to Telegram when the scraper crashes or fails

### Scheduling & Ops

- **OPS-V2-01**: Cron or systemd timer configured on VPS to run automatically every few hours
- **OPS-V2-02**: Structured logging to file with timestamp, run outcome, and lead counts

## Out of Scope

| Feature | Reason |
|---------|--------|
| Two-way Telegram bot (replies, commands) | Out of scope — send-only notification tool |
| Real-time polling / webhooks from Inmuebles24 | Inmuebles24 has no outbound webhook API |
| Web dashboard / UI | Single-user tool — Telegram is the interface |
| Billing/credits extraction | Not requested |
| Multiple account support | Single account only for v1 |
| Mobile app | Not applicable |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| AUTH-01 | Phase 1 | Complete |
| AUTH-02 | Phase 1 | Complete |
| EXTR-01 | Phase 2 | Pending |
| EXTR-02 | Phase 2 | Pending |
| EXTR-03 | Phase 2 | Pending |
| STAT-01 | Phase 3 | Pending |
| STAT-02 | Phase 3 | Pending |
| STAT-03 | Phase 3 | Pending |
| NOTF-01 | Phase 4 | Pending |
| NOTF-02 | Phase 4 | Pending |
| NOTF-03 | Phase 4 | Pending |

**Coverage:**
- v1 requirements: 11 total
- Mapped to phases: 11
- Unmapped: 0 ✓

---
*Requirements defined: 2026-03-11*
*Last updated: 2026-03-11 after roadmap creation*
