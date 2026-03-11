# Project Research Summary

**Project:** Inmobiliaria24 Lead Monitor
**Domain:** Scheduled web automation — authenticated scraping, state persistence, Telegram notifications
**Researched:** 2026-03-11
**Confidence:** HIGH

## Executive Summary

The Inmobiliaria24 Lead Monitor is a scheduled automation tool that logs into the Inmuebles24 real estate portal, extracts new leads across the agent's active listings, and delivers structured Telegram notifications — all unattended on a Linux VPS. This is a well-understood domain: Python + Playwright is the established pattern for authenticated scraping of JavaScript-heavy portals, and a cron-driven single-process script with flat-file state is the right fit at this scale. The key technical constraint is that Inmuebles24 runs Cloudflare as a reverse proxy and renders listings in React; this makes Playwright non-negotiable and stealth measures mandatory from day one, not as a later optimization.

The recommended approach is a modular Python script with clean component boundaries: Config Loader, Auth Module (Playwright with `storage_state` session caching), Scraper (listings then per-listing leads), State Manager (JSON file with atomic writes), Formatter, and Notifier (httpx POST to Telegram Bot API). This layered architecture is both testable and maintainable — pure-function components (formatter, state diff) can be validated without a browser, and the browser lifecycle is isolated entirely in the auth and scraper modules. The build order follows the dependency chain: config first, state second, auth third, scraper fourth, formatter fifth, notifier sixth, entrypoint last.

The primary risks are bot detection (Cloudflare blocks a VPS IP with a headless fingerprint quickly), silent failures masquerading as "no new leads," and state corruption from concurrent cron runs. All three are addressed by well-known patterns: `playwright-stealth` + randomized delays for detection, a daily heartbeat notification for observability, and `flock` + atomic `os.replace()` writes for state integrity. None of these require exotic tooling — they are standard practices for this class of tool and must be in place from the start, not retrofitted.

---

## Key Findings

### Recommended Stack

Python 3.13 with Playwright 1.58.0 is the correct and only viable stack for this project. Inmuebles24 confirmed Cloudflare + React, meaning static HTTP scrapers (requests, BeautifulSoup, Scrapy without Playwright) will receive empty or 403 responses. Playwright handles the full browser lifecycle, SPA rendering, and login flows natively. `playwright-stealth 2.0.2` must be applied on every browser context to mask headless indicators — the site returned a 403 on direct fetch, confirming active bot filtering.

For scheduling, the recommended split is APScheduler 3.11.2 during development (in-process, no daemon needed) and a `systemd` timer or `cron` with `flock` in production (crash-resilient, no long-lived Python process). `httpx 0.28.1` handles Telegram API calls cleanly. `python-dotenv 1.2.2` manages credentials. `loguru` handles structured logging. State is a flat JSON file — no database is warranted at this scale.

**Core technologies:**
- **Python 3.13.x**: Runtime — stable, best ecosystem for browser automation on Linux VPS
- **Playwright 1.58.0**: Browser automation — only option that handles Cloudflare + React SPA login and scraping
- **playwright-stealth 2.0.2**: Anti-bot evasion — required from day one given confirmed Cloudflare protection
- **APScheduler 3.11.2**: In-process scheduling (dev) — pin to 3.x; 4.0 alpha is not production-safe
- **httpx 0.28.1**: Telegram HTTP calls — async-native, clean API
- **python-dotenv 1.2.2**: Credential management — 12-factor compliant, keeps secrets out of code
- **loguru**: Structured logging — zero-config rotation and level filtering
- **json (stdlib)**: State persistence — flat file is sufficient; SQLite only if lead volume exceeds ~10k rows

### Expected Features

**Must have (table stakes) — v1 launch:**
- Authenticated login to Inmuebles24 via env-var credentials — nothing works without this
- Extract active listings and per-listing lead data — core data extraction
- Deduplicate against persisted state (JSON file) — without this the tool sends duplicate spam every run
- Send structured Telegram message via webhook — the passive delivery mechanism
- Structured logging to file and stdout — required to debug VPS failures
- Graceful error handling with non-zero exit codes — required for cron to detect failures
- All configuration from environment variables — deployable without touching code

**Should have (differentiators) — v1.x after validation:**
- Session reuse with `storage_state` caching — reduces login frequency and bot detection surface
- Failure notification via Telegram — agent knows when the monitor breaks
- Exponential backoff and retry — self-healing on transient network errors
- Randomized navigation delays and realistic user-agent — reduces IP/session ban risk
- Silence suppression — no notification when no new leads (silence means all quiet)

**Defer (v2+):**
- Multi-account support — only if agent manages multiple Inmuebles24 accounts
- Per-property filtering — only if lead volume becomes noisy
- Historical lead log — only with a validated use case; current scope is deduplication IDs only
- Two-way Telegram bot commands — adds a long-running service architecture; out of scope
- Web dashboard — would require a project 10x larger; Telegram IS the UI

### Architecture Approach

The architecture is a single-process pipeline triggered by cron. Components are strictly layered with unidirectional data flow: Config → Auth → Scraper → State Manager → Formatter → Notifier. No component reaches "up" or "sideways" — the state manager is the only writer of `state.json`, the notifier is only called when `new_leads` is non-empty (enforced in `main.py`), and credentials are loaded once at the entrypoint and passed as arguments. This separation makes each component independently testable and failure-isolated.

**Major components:**
1. **Config Loader** (`config.py`) — loads and validates all env vars into a typed `Settings` dataclass; fail-fast on missing values
2. **Auth Module** (`scraper/auth.py`) — login flow with `storage_state` session caching; age-based revalidation; re-login fallback on session expiry mid-run
3. **Scraper** (`scraper/listings.py`, `scraper/leads.py`) — Playwright async navigation; returns raw lead dicts; never touches state or notifications
4. **State Manager** (`state/store.py`) — loads seen IDs, computes new-only diff, persists updated set atomically via `os.replace()`
5. **Formatter** (`notify/formatter.py`) — pure function; raw lead dicts to Telegram markdown string; grouped by property
6. **Notifier** (`notify/webhook.py`) — httpx POST to Telegram Bot API; batches all leads into one message; handles 429 with retry
7. **Entrypoint** (`main.py`) — wires all components; catches unhandled errors; exits non-zero on failure; conditionally calls notifier

### Critical Pitfalls

1. **Zombie Chromium processes accumulate on VPS** — Always use `async with async_playwright()` and nested `async with browser` context managers; never rely on GC for cleanup. Verify `/dev/shm` is 256 MB+ (LXC/Docker default of 64 MB causes silent crashes).

2. **Session expiry causes silent zero-lead runs** — After restoring `storage_state`, assert an authenticated element is present before proceeding. Implement age-based revalidation (`max_age_hours`); if state file is stale or assertion fails, fall through to fresh login. Never assume cookies are permanent.

3. **Bot detection blocks the VPS IP after a few runs** — Apply `playwright-stealth` on every context, add 1–4 second randomized delays between navigation steps, reuse session cookies across runs, launch with a realistic Chrome user agent. Log CAPTCHA redirects as hard failures (do not silently continue). This must be in place before any extraction code is written.

4. **Concurrent cron runs corrupt `state.json`** — Use `flock -n` in the crontab entry to prevent overlapping runs. Write state atomically: serialize to `.tmp`, then `os.replace()`. Never write directly to the live state file.

5. **Silent failures indistinguishable from "no new leads"** — Implement a daily heartbeat Telegram message confirming the scraper ran. Log a structured summary line (timestamp, leads_checked, leads_new, errors) on every exit. Let unhandled exceptions propagate to stderr so cron can capture them.

---

## Implications for Roadmap

Based on the combined research, a 4-phase build order is recommended. The phase order follows the architectural dependency chain and front-loads the highest-risk work (bot detection, auth) before building on top of it.

### Phase 1: Foundation — Config, Auth, and Browser Setup

**Rationale:** Config loader and auth module are prerequisites for everything else. Bot detection is the highest-risk technical unknown — if Cloudflare blocks the VPS IP, nothing else matters. Resolving this first establishes a stable base and proves the tool can access the portal reliably.

**Delivers:** A working, stealth-capable authenticated Playwright session that persists across runs and re-authenticates gracefully when sessions expire.

**Addresses:** Authenticated login, configurable env-var credentials, session reuse with `storage_state`

**Avoids:**
- Zombie browser processes (establish `async with` lifecycle pattern here)
- Session expiry silent failures (build re-auth fallback into auth module from the start)
- Bot detection / IP block (apply `playwright-stealth`, user-agent, timing jitter before any extraction)
- Credential / webhook leaks (env-var loading and log sanitization established before credentials are ever used)

**Research flag:** Standard patterns (Playwright auth + storage_state is well-documented). No additional research needed.

---

### Phase 2: Core Extraction

**Rationale:** With a stable auth layer, the scraper can be built and validated in isolation. Listings and leads are separate modules because they navigate distinct page types. Selector centralization must happen here — retrofitting it after the notification layer is built creates unnecessary rework.

**Delivers:** A scraper that returns structured listing and lead data from the authenticated session; all selectors centralized in `selectors.py`; post-extraction assertions confirming non-empty results.

**Addresses:** Extract active listings, extract per-listing stats and leads

**Avoids:**
- Brittle CSS selectors (centralize in `selectors.py`; prefer `data-*` and ARIA role selectors over presentational class names)
- Empty data on site redesign (add post-extraction assertion: count > 0, key fields non-null)

**Research flag:** May need selector research during planning — Inmuebles24's React component structure requires hands-on browser inspection to identify stable anchors. Plan for a short selector-scouting session before writing extraction code.

---

### Phase 3: State Management and Scheduling

**Rationale:** State management is the deduplication core — it makes the tool useful rather than spammy. The atomic write pattern and concurrency guard must be established before the scheduler is configured; adding them after a corruption incident is reactive and higher-cost.

**Delivers:** Atomic JSON state file with new-only diff logic; `flock`-protected cron entry that prevents overlapping runs; first-run initialization (empty state file on missing).

**Addresses:** State persistence, deduplication, scheduled execution, graceful exit codes

**Avoids:**
- Concurrent cron runs corrupting `state.json` (flock + `os.replace()`)
- State written inside scraper — scraper returns all leads; state update happens only after full scrape succeeds

**Research flag:** Standard patterns. No additional research needed.

---

### Phase 4: Notification and Observability

**Rationale:** Notification is the delivery layer built on top of the validated extraction and state pipeline. The heartbeat mechanism is included here rather than deferred — it directly prevents the "silent failure" failure mode that makes the tool untrustworthy in production.

**Delivers:** Structured Telegram message formatter (grouped by property), batched webhook delivery (one message per run), failure notification on critical errors, daily heartbeat confirming the monitor is alive.

**Addresses:** Telegram notification, structured message format, failure notification, silence suppression on no-new-leads, per-run summary log line

**Avoids:**
- Telegram rate limit hits (batch all leads into one message; chunk at 4096 chars if needed)
- One-message-per-lead pattern (groups leads by property into a single POST)
- Silent failures (heartbeat notification; structured exit log)

**Research flag:** Standard patterns. Telegram Bot API sendMessage endpoint is well-documented. No additional research needed.

---

### Phase Ordering Rationale

- **Auth before extraction:** No scraper can be written or tested without a stable authenticated context. Bot detection must be solved at this layer — it cannot be patched after extraction logic is built.
- **Extraction before state:** The state manager needs real lead IDs to diff against; building state on mock data risks designing for a data shape that doesn't match reality.
- **State before scheduling:** Configuring cron before atomic writes and flock are in place is a guaranteed path to the first state corruption.
- **Notification last:** The delivery layer depends on all upstream components being stable; building it last means no rework when the data shape changes during extraction development.
- **Architecture build order confirmed:** Config → State Manager → Auth → Scraper (listings) → Scraper (leads) → Formatter → Notifier → Entrypoint → Cron/Deployment. This is both the dependency order and the testability order — each component is independently verifiable before the next is added.

### Research Flags

Phases needing deeper research during planning:
- **Phase 2 (Extraction):** Inmuebles24's React component structure requires hands-on browser inspection to identify stable selector anchors for listings, leads, and auth assertions. Plan a scouting step before writing extraction selectors.

Phases with standard, well-documented patterns (skip research-phase):
- **Phase 1:** Playwright `storage_state` auth pattern is extensively documented
- **Phase 3:** Atomic JSON writes (`os.replace`) and `flock` for cron are established Unix patterns
- **Phase 4:** Telegram Bot API `sendMessage` is straightforward; batching and rate-limit handling are well-documented

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Core technologies verified against PyPI and official docs; Cloudflare + React confirmed on Inmuebles24 via W3Techs |
| Features | HIGH (table stakes), MEDIUM (differentiators) | Table stakes verified via multiple scraper and monitoring sources; differentiator value is inferred from analogous tools |
| Architecture | HIGH | Component boundaries and data flow follow established patterns (Playwright auth docs, Cosmic Python, Scrapy pipeline adapted); all patterns verified |
| Pitfalls | HIGH | All critical pitfalls verified via official docs, GitHub issues, and community incident reports |

**Overall confidence:** HIGH

### Gaps to Address

- **Inmuebles24 selector structure:** The exact CSS or ARIA structure of the account dashboard, listing cards, and lead panels is unknown without live browser inspection. This is a known unknown — plan for a brief scouting session at the start of Phase 2. Do not write selectors speculatively.
- **Session TTL:** The actual session expiry window for Inmuebles24 cookies is not documented. Start with a conservative `max_age_hours=12` revalidation threshold and tune based on observed behavior in Phase 1.
- **CAPTCHA / 2FA presence:** If the account has 2FA enabled, or if Cloudflare serves a CAPTCHA to the VPS IP, Phase 1 may require escalation to the STACK.md fallback options (persistent user-data directory, residential proxy, or Inmuebles24 partner API). This is a potential blocker that should be tested on day one of Phase 1.
- **Lead inbox navigation depth:** It is unknown whether leads are accessible from the listings summary page or require navigating into each individual listing's detail view. This affects Phase 2 complexity and run duration.

---

## Sources

### Primary (HIGH confidence)
- [Playwright Python official docs](https://playwright.dev/python/docs/intro) — installation, browser support, storage_state auth pattern
- [Playwright Python Authentication Docs](https://playwright.dev/python/docs/auth) — session persistence pattern
- [Telegram Bot API](https://core.telegram.org/bots/api) — sendMessage endpoint, rate limits
- [APScheduler · PyPI](https://pypi.org/project/APScheduler/) — version 3.11.2 stable, 4.0.0a6 alpha flagged
- [playwright · PyPI](https://pypi.org/project/playwright/) — version 1.58.0 confirmed
- [Scrapy Deduplication Pipeline](https://docs.scrapy.org/en/latest/topics/item-pipeline.html) — seen-IDs filter pattern
- [BrowserContext resource cleanup — Playwright Python official docs](https://playwright.dev/python/docs/browser-contexts)
- [Playwright Python memory leak issue #2511 — GitHub](https://github.com/microsoft/playwright-python/issues/2511)

### Secondary (MEDIUM confidence)
- [W3Techs — inmuebles24.com](https://w3techs.com/sites/info/inmuebles24.com) — Cloudflare + React confirmed
- [ZenRows — Playwright bot detection](https://www.zenrows.com/blog/avoid-playwright-bot-detection) — stealth techniques
- [Prevent Concurrent Cron Jobs Using flock — Hong's Tech Blog](https://tech.mrleong.net/prevent-concurrent-cron-jobs-using-flock) — flock pattern
- [Crash-safe JSON atomic writes — DEV Community](https://dev.to/constanta/crash-safe-json-at-scale-atomic-writes-recovery-without-a-db-3aic) — atomic write pattern
- [Playwright Persistent Context — BrowserStack](https://www.browserstack.com/guide/playwright-persistent-context) — session caching rationale
- [Playwright Selector Best Practices 2026 — BrowserStack](https://www.browserstack.com/guide/playwright-selectors-best-practices) — selector strategy
- [8GB Was a Lie: Playwright in Production — Medium](https://medium.com/@onurmaciit/8gb-was-a-lie-playwright-in-production-c2bdbe4429d6) — zombie process pitfall
- [Telegram Bot API rate limits — python-telegram-bot wiki](https://github.com/python-telegram-bot/python-telegram-bot/wiki/Avoiding-flood-limits)
- [Automate Web Scraping with Playwright and Cron — Medium](https://medium.com/@arslandevs/automate-web-scraping-with-scrapy-playwright-and-cron-a-powerful-combination-458f48fdba21) — scheduling pattern

### Tertiary (MEDIUM-LOW confidence)
- [n8n: Automated Web Scraper with Telegram Alert](https://n8n.io/workflows/6663-automated-web-scraper-niche-jobproduct-monitor-with-telegram-alert/) — deduplication and conditional notification pattern analogy
- [Firecrawl: 10 Common Web Scraping Mistakes](https://www.firecrawl.dev/blog/web-scraping-mistakes-and-fixes) — pitfall confirmation

---
*Research completed: 2026-03-11*
*Ready for roadmap: yes*
