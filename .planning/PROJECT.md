# Inmobiliaria24 Lead Monitor

## What This Is

A scheduled web automation that logs into Inmuebles24, extracts active listings, their stats, and associated leads/inquiries, then sends a structured Telegram notification via webhook — only when new leads have appeared since the last run. Designed to run every few hours on a VPS.

## Core Value

The moment a potential buyer shows interest in a property, the agent knows about it — without ever opening a browser.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Authenticate to Inmuebles24 with supplied credentials
- [ ] Navigate to account and extract all active listings
- [ ] Extract listing stats (views, contacts) per property
- [ ] Extract leads/inquiries linked to each property
- [ ] Detect and report only new leads since last run
- [ ] Format data as property → leads message structure for Telegram
- [ ] Send report to a webhook that forwards to Telegram
- [ ] Run on a schedule (every few hours) on a VPS

### Out of Scope

- Billing/credits extraction — not requested
- Mobile app — web automation only
- Two-way Telegram interaction — send-only

## Context

- Target site: Inmuebles24 (inmuebles24.com) — Mexican real estate portal
- Credentials supplied by user at deployment time (not hardcoded)
- Telegram delivery via webhook (user-supplied webhook URL)
- State tracking needed: must persist "seen leads" between runs to detect new ones
- Runs on a Linux VPS with cron or a process scheduler

## Constraints

- **Auth**: Credentials must not be hardcoded — use environment variables
- **State**: Must persist last-seen lead IDs between runs (file or DB)
- **Robustness**: Site layout may change; scraper must be resilient and log failures
- **Rate limiting**: Respectful scraping — no aggressive parallel requests

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Playwright for scraping | Handles JavaScript-heavy portals, login flows, and dynamic content well | — Pending |
| Python runtime | Wide ecosystem for web automation, scheduling, and HTTP on VPS | — Pending |
| JSON file for state | Simple persistence for "seen leads" without a full DB | — Pending |

---
*Last updated: 2026-03-11 after initialization*
