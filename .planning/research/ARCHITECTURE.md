# Architecture Research

**Domain:** Scheduled web scraper with state persistence and webhook notification delivery
**Researched:** 2026-03-11
**Confidence:** HIGH

## Standard Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Scheduler Layer                         │
│  (cron on VPS — triggers process every N hours)             │
└──────────────────────┬──────────────────────────────────────┘
                       │ spawns
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                     Entrypoint (main.py)                     │
│  Wires components together, handles top-level error capture  │
└──┬───────────────────┬─────────────────────────┬────────────┘
   │                   │                         │
   ▼                   ▼                         ▼
┌──────────┐   ┌───────────────┐       ┌─────────────────┐
│  Config  │   │  Auth Module  │       │  State Manager  │
│  Loader  │   │  (Playwright) │       │  (JSON on disk) │
│          │   │               │       │                 │
│ .env →   │   │ Login flow →  │       │ Load seen IDs → │
│ typed    │   │ storage_state │       │ compare →       │
│ Settings │   │ file cache    │       │ save new IDs    │
└──────────┘   └──────┬────────┘       └────────┬────────┘
                      │                         │
                      ▼                         │
         ┌────────────────────────┐             │
         │    Scraper Module      │             │
         │    (Playwright)        │             │
         │                       │             │
         │ - listings page        │             │
         │ - per-listing stats    │             │
         │ - leads/inquiries      │◄────────────┘
         │                       │  (new-only filter)
         └──────────┬────────────┘
                    │ structured data
                    ▼
         ┌────────────────────────┐
         │   Formatter Module     │
         │                       │
         │ raw dicts → Telegram  │
         │ markdown message str  │
         └──────────┬────────────┘
                    │ formatted string
                    ▼
         ┌────────────────────────┐
         │   Notifier Module      │
         │                       │
         │ POST to webhook URL   │
         │ (Telegram Bot API)    │
         └────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation |
|-----------|----------------|------------------------|
| Scheduler | Trigger the process on a fixed cadence | Linux cron (`*/4 * * * *`) or `APScheduler` if embedded |
| Entrypoint | Wire all components, catch unhandled errors, exit codes | `main.py` with `asyncio.run()` |
| Config Loader | Load and validate credentials + settings from environment | `python-dotenv` + dataclass `Settings` |
| Auth Module | Log into Inmuebles24, cache session to disk, revalidate on expiry | Playwright `storage_state` saved to `auth_state.json` |
| Scraper Module | Navigate to listings, extract per-listing stats and leads | Playwright async page traversal |
| State Manager | Load previously seen lead IDs, return only new ones, persist updated set | Read/write `state.json` with atomic write |
| Formatter | Convert raw lead dicts into a Telegram-ready markdown string | Pure Python string formatting, no I/O |
| Notifier | HTTP POST the formatted message to the Telegram webhook URL | `httpx` (async) or `requests` (sync) |

## Recommended Project Structure

```
inmobiliaria24/
├── main.py                 # entrypoint — wires everything, asyncio.run()
├── config.py               # Settings dataclass loaded from environment
├── .env                    # credentials (gitignored)
├── .env.example            # template committed to repo
│
├── scraper/
│   ├── __init__.py
│   ├── auth.py             # login flow, storage_state save/load
│   ├── listings.py         # navigate to listings page, extract list
│   └── leads.py            # per-listing lead extraction
│
├── state/
│   ├── __init__.py
│   └── store.py            # load_seen_ids(), save_seen_ids(), diff_new()
│
├── notify/
│   ├── __init__.py
│   ├── formatter.py        # raw data → Telegram message string
│   └── webhook.py          # HTTP POST to Telegram webhook URL
│
├── data/
│   ├── state.json          # persisted seen lead IDs (gitignored)
│   └── auth_state.json     # Playwright storage state (gitignored)
│
└── logs/
    └── run.log             # rotating log file
```

### Structure Rationale

- **scraper/:** Groups all Playwright logic. Auth is separate from data extraction because login state needs its own lifecycle (cache, expiry, retry). Listings and leads are separate files because they map to distinct page types.
- **state/:** Isolated I/O boundary. The scraper never writes its own state — it hands data to `store.py`. This makes the deduplication logic testable without a browser.
- **notify/:** Formatter has no I/O (pure function), webhook has no formatting logic. Keeping them separate means you can unit-test message formatting without hitting the network.
- **data/:** Runtime artifacts, both gitignored. Keeps source tree clean.

## Architectural Patterns

### Pattern 1: Storage State Auth Caching

**What:** After first login, serialize the full browser context (cookies, localStorage, IndexedDB) to a JSON file via `context.storage_state(path="auth_state.json")`. On subsequent runs, restore the context from the file instead of re-logging in.

**When to use:** Always for sites with login flows. Avoids triggering bot-detection on repeated logins and cuts startup time significantly.

**Trade-offs:** Session files expire; the module must detect auth failure mid-run and re-login. Add a `max_age_hours` check on the file mtime before trusting it.

**Example:**
```python
async def get_context(browser, path="data/auth_state.json"):
    if Path(path).exists() and is_fresh(path, max_age_hours=12):
        return await browser.new_context(storage_state=path)
    context = await browser.new_context()
    await login(context)
    await context.storage_state(path=path)
    return context
```

### Pattern 2: Atomic JSON State Write

**What:** Never write state.json in-place. Write to a `.tmp` file first, then `os.replace()` it over the target. This is atomic on POSIX systems — a crash between runs leaves either the old file or the new file, never a half-written one.

**When to use:** Any file-based state that must survive process interruption (cron can be killed mid-run).

**Trade-offs:** Adds two lines of code. No meaningful downside at this scale.

**Example:**
```python
import json, os, tempfile
from pathlib import Path

def save_seen_ids(ids: set, path="data/state.json"):
    tmp = Path(path).with_suffix(".tmp")
    tmp.write_text(json.dumps(sorted(ids), indent=2))
    os.replace(tmp, path)
```

### Pattern 3: New-Only Filter at the State Boundary

**What:** The scraper returns all leads it found this run. The state manager computes the diff: `new = found - seen`. Only `new` is passed to the notifier. The state manager then merges `found` back into `seen` and persists.

**When to use:** Always — this is the core value proposition. Never let scraper or notifier know about "seen"; that belongs entirely to state.

**Trade-offs:** If `state.json` is lost, the next run reports all leads as new (false positives). Acceptable — the user gets one noisy run, then normal operation resumes.

**Example:**
```python
def filter_new_leads(all_leads: list[dict], state_path: str) -> list[dict]:
    seen = load_seen_ids(state_path)           # set of str IDs
    new = [l for l in all_leads if l["id"] not in seen]
    updated = seen | {l["id"] for l in all_leads}
    save_seen_ids(updated, state_path)
    return new
```

## Data Flow

### Normal Run (new leads found)

```
cron trigger
    │
    ▼
main.py loads config from .env
    │
    ▼
auth.py checks auth_state.json age → still fresh → restore context
    │                               → stale/missing → login + save
    ▼
listings.py navigates to account → returns list of listing dicts
    │  [{id, title, url, views, contacts}, ...]
    ▼
leads.py visits each listing URL → returns lead dicts per listing
    │  [{listing_id, lead_id, buyer_name, date, message}, ...]
    ▼
state/store.py loads state.json
    │  computes diff: new_leads = all_leads - seen_ids
    │  persists: seen_ids = seen_ids ∪ all_lead_ids
    ▼
formatter.py converts new_leads → Telegram markdown string
    │
    ▼
webhook.py POST to Telegram API URL
    │
    ▼
exit 0 → cron silent
```

### No New Leads Run

```
cron trigger → scrape → state diff = empty set → notifier skipped → exit 0
```

### Auth Failure Mid-Run

```
scraper gets 401/redirect → re-login → clear auth_state.json → retry once
    │  if retry fails → log error → exit 1 (cron mails stderr)
```

### Key Data Flows

1. **Config propagation:** Settings loaded once at entrypoint, passed as arguments to module functions — no global state, no `os.getenv()` scattered across files.
2. **Lead deduplication:** Raw leads flow downward from scraper; only the state manager touches `state.json`; no other module reads or writes it.
3. **Notification gate:** Notifier is only called when `new_leads` is non-empty. The check lives in `main.py`, not inside the notifier — keeps notifier stateless and reusable.

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| 1 agent, 1 portal | Current design — single process, cron, file state. Appropriate. |
| Multiple agents / portals | Extract per-portal scraper as plugin; shared state DB (SQLite); one cron per portal or a single runner with per-portal configs |
| High-frequency (every 5 min) | Consider APScheduler embedded process to avoid Python startup cost; SQLite WAL mode for state |
| Multiple notification channels | Add adapter pattern to notifier; each channel implements `send(message: str)` |

### Scaling Priorities

1. **First bottleneck:** Playwright startup time (~2s). Acceptable at hourly cadence; becomes relevant at sub-10-minute intervals. Fix: persistent browser process with APScheduler instead of cron respawn.
2. **Second bottleneck:** Sequential listing traversal. If 50+ listings, add modest concurrency with `asyncio.gather` and a semaphore to rate-limit page loads.

## Anti-Patterns

### Anti-Pattern 1: Credentials in Source Code

**What people do:** Hardcode username/password or Telegram webhook URL in the script.
**Why it's wrong:** Credentials end up in git history, cron logs, or error messages. Impossible to rotate without editing code.
**Do this instead:** Load exclusively from environment variables via `python-dotenv`. Commit `.env.example` with placeholder values, gitignore `.env`.

### Anti-Pattern 2: Login on Every Run

**What people do:** Call the login flow at the top of `main.py` unconditionally every run.
**Why it's wrong:** Repeated logins from the same IP within short windows trigger CAPTCHA or temporary blocks on most portals. Slower runs. Unnecessary load on the target.
**Do this instead:** Cache `storage_state` to disk. Only re-login when the session is stale (check file mtime) or when a page redirects to the login URL mid-run.

### Anti-Pattern 3: State Written Inside the Scraper

**What people do:** Have the scraper check and update `state.json` as it extracts each lead.
**Why it's wrong:** If the scraper fails halfway, state is partially updated — some leads are marked seen but the notifier never got them. Silent data loss.
**Do this instead:** Scraper returns all leads found this run. State update and notification happen only after the full scrape succeeds. Fail-fast: if scraping errors, state is untouched.

### Anti-Pattern 4: Sending a Telegram Message Per Lead

**What people do:** Call the webhook once per new lead found.
**Why it's wrong:** Telegram rate-limits bots at ~30 messages/minute per chat. A run with 10 new leads fires 10 requests; with 50 leads, the later ones fail silently.
**Do this instead:** Batch all new leads into a single message (or a small number of chunked messages if content exceeds 4096 chars). One HTTP request per run.

### Anti-Pattern 5: Silent Failures

**What people do:** Wrap the entire `main.py` in a broad `except: pass` to prevent cron spam.
**Why it's wrong:** Scraper breaks silently. The agent receives no notifications and assumes no new leads — when actually the bot has been dead for days.
**Do this instead:** Let unhandled exceptions propagate to stderr. Cron emails stderr to the system user by default. Add structured logging with timestamps to `logs/run.log`. On critical failure, attempt to send a Telegram error notification before exiting.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| Inmuebles24 | Playwright headless browser, session cookies | JavaScript-heavy SPA; no public API; session expires ~12-24h |
| Telegram Bot API | HTTP POST to `https://api.telegram.org/bot{TOKEN}/sendMessage` | Webhook URL is the full endpoint; no incoming webhook listener needed |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| main ↔ auth | Direct function call, returns `BrowserContext` | Auth is the only module that manages Playwright lifecycle |
| main ↔ scraper | Direct async function call, returns `list[dict]` | Scraper never touches state or notifications |
| scraper ↔ state | One-way: scraper out, state in | State manager is the only writer of `state.json` |
| state ↔ notifier | Via main.py: `new_leads = filter(); if new_leads: notify()` | State and notifier never call each other directly |
| notifier ↔ Telegram | HTTPS POST | Fire-and-forget; log response status; raise on non-2xx |

## Build Order

Components have clear dependency direction. Build in this order:

1. **Config Loader** — everything else depends on settings being available
2. **State Manager** — pure I/O, no browser needed; testable immediately with mock data
3. **Auth Module** — needs config; produces context used by scraper
4. **Scraper (listings)** — needs auth context; produces listing data
5. **Scraper (leads)** — needs listings output; adds lead extraction per listing
6. **Formatter** — pure function; testable with hardcoded fixture data
7. **Notifier** — needs formatter output and config webhook URL
8. **Entrypoint (main.py)** — wires all components; last to complete
9. **Cron / deployment** — configure only after end-to-end works manually

Each layer can be tested independently before the next is built. State manager and formatter in particular are pure functions with no external dependencies — build and test them first to establish confidence before adding browser complexity.

## Sources

- [Playwright Python Authentication Docs](https://playwright.dev/python/docs/auth) — storage_state pattern (HIGH confidence)
- [Playwright Persistent Context — BrowserStack](https://www.browserstack.com/guide/playwright-persistent-context) — session caching rationale (MEDIUM confidence)
- [Crash-safe JSON atomic writes — DEV Community](https://dev.to/constanta/crash-safe-json-at-scale-atomic-writes-recovery-without-a-db-3aic) — atomic write pattern (MEDIUM confidence)
- [Scrapy Deduplication Pipeline](https://docs.scrapy.org/en/latest/topics/item-pipeline.html) — seen-IDs filter pattern (HIGH confidence, adapted for non-Scrapy use)
- [Telegram Bot API](https://core.telegram.org/bots/api) — sendMessage endpoint, rate limits (HIGH confidence)
- [Automate Web Scraping with Playwright and Cron — Medium](https://medium.com/@arslandevs/automate-web-scraping-with-scrapy-playwright-and-cron-a-powerful-combination-458f48fdba21) — scheduling pattern (MEDIUM confidence)
- [Cosmic Python — Project Structure](https://www.cosmicpython.com/book/appendix_project_structure.html) — module boundary rationale (HIGH confidence)

---
*Architecture research for: Scheduled Python Playwright scraper — Inmobiliaria24 Lead Monitor*
*Researched: 2026-03-11*
