# Feature Research

**Domain:** Scheduled web scraper / account monitor with Telegram notifications — real estate leads
**Researched:** 2026-03-11
**Confidence:** HIGH (core features), MEDIUM (differentiators)

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features the tool must have. Missing any of these means the tool doesn't work as described.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Authenticated login to Inmuebles24 | The account and leads are behind auth — no login, no data | MEDIUM | Playwright `storage_state` to persist session and avoid re-login on every run |
| Extract all active listings | Core data source — agent needs to know which properties are being watched | LOW | Navigate account dashboard, scrape listing cards |
| Extract per-listing stats (views, contacts) | Agent context — knowing a listing has 200 views vs 2 changes urgency of the lead | LOW | Scraped alongside listing detail |
| Extract leads / inquiries per listing | The primary signal the tool was built for | MEDIUM | May require navigating into each listing's lead inbox panel |
| Deduplicate — only notify on new leads | Without this the agent gets spammed every run with the same leads | MEDIUM | Persist seen lead IDs in a state file; diff against current run |
| Send Telegram notification on new leads | The delivery mechanism — what makes the tool useful passively | LOW | HTTP POST to webhook URL; Telegram formats markdown natively |
| Structured message format (property → leads) | Agent must understand at a glance what property the lead came in on | LOW | Group leads under their property heading in the message |
| Configurable credentials via env vars | Security baseline — credentials must never be hardcoded | LOW | `.env` file or shell environment; never committed to source control |
| Configurable webhook URL via env var | Deployment flexibility — different agents, different Telegram targets | LOW | Same pattern as credentials |
| Scheduled execution (cron / systemd) | Tool must run unattended every few hours without manual trigger | LOW | cron on Linux VPS; systemd timer is an alternative |
| Structured logging with timestamps | Without logs, diagnosing failures on a VPS is nearly impossible | LOW | Log to file + stdout; include run ID, timestamp, outcome |
| Graceful failure handling and exit codes | Cron needs a non-zero exit code to know a job failed | MEDIUM | Try/except around scraping steps; log errors; exit 1 on fatal failure |
| State persistence between runs | Must remember which leads were seen in the last run | LOW | JSON file on disk is sufficient; no DB required |

### Differentiators (Competitive Advantage)

Features that improve reliability, observability, or agent experience beyond the baseline.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Session reuse (cached auth state) | Avoids re-login on every cron run — reduces detection surface and latency | LOW | Playwright `storage_state(path="session.json")`; reload on next run |
| Exponential backoff + retry on transient errors | Site hiccups or rate-limit responses don't kill the run; scraper self-heals | MEDIUM | Retry up to 3x with backoff for network errors and HTTP 429/5xx |
| Failure notification via Telegram | Agent knows the monitor is broken, not just silently failing | LOW | Send a "scraper failed: [reason]" message to same webhook on unrecoverable error |
| Configurable run interval (env var) | One config change to shift from every-2h to every-30m without touching code | LOW | Passed as cron expression or interval in a `.env` or config file |
| Human-readable "nothing new" suppression | No notification when there are no new leads — silence means all quiet | LOW | Simply skip sending if diff is empty; do not send "no new leads" noise |
| Per-run summary log line | Single-line structured log at end of run: leads found, new leads, duration | LOW | Useful for log aggregation and quick auditing |
| Headless browser detection avoidance (basic) | Reduces risk of Inmuebles24 flagging the session as a bot | MEDIUM | Playwright with non-headless viewport, realistic user-agent, random delays between navigation steps |
| Idempotent state file writes | Safe to interrupt mid-run; state file only updated after successful full extraction | MEDIUM | Write to a `.tmp` file, rename atomically after run completes |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Two-way Telegram interaction (bot commands) | "Can I query leads on demand?" feels useful | Turns a simple script into a long-running service requiring a bot polling loop; adds infrastructure complexity, auth for commands, and error surface | Stick to send-only webhook; add a `/status` command only if demand is validated |
| Real-time monitoring (sub-minute polling) | Faster alerts feel better | Aggressive polling increases bot-detection risk on Inmuebles24 and may trigger IP/session bans; also wastes VPS resources | Every 2-4 hours is appropriate for this domain; leads don't expire in minutes |
| Database for state storage | Feels more "production ready" | A SQLite or Postgres dependency adds setup friction and failure modes without meaningful benefit at this scale (one account, dozens of leads) | A flat JSON file is sufficient; migrate only if lead volume exceeds ~10k rows |
| Storing full lead data historically | "Keep all historical leads" seems useful | Out of scope; creates storage growth, query complexity, and PII retention concerns | Only persist lead IDs needed for deduplication; not full contact records |
| Parallel listing scraping | Faster extractions | Concurrent requests to the same authenticated session on a JS portal is a reliable path to session invalidation and bans | Sequential navigation with small delays; fast enough at this scale |
| Web dashboard / admin UI | "Nice to see all leads in one place" | Requires a web server, auth, and frontend — a project 10x larger than the tool itself | Telegram IS the UI; the structured message format does the job |
| Billing / credits extraction | Sometimes asked for in the same pass | Not requested; adds navigation complexity and a fragile scraping path for data that changes rarely | Separate tool if ever needed |

---

## Feature Dependencies

```
[Authenticated login]
    └──requires──> [Credentials via env vars]
    └──enables──>  [Extract active listings]
                       └──enables──> [Extract per-listing stats]
                       └──enables──> [Extract leads per listing]
                                         └──requires──> [State persistence]
                                         └──enables──>  [Deduplication]
                                                            └──enables──> [Telegram notification]

[Session reuse]
    └──enhances──> [Authenticated login] (skips login step when session is valid)

[Failure notification]
    └──enhances──> [Graceful failure handling] (uses same webhook path)

[Exponential backoff]
    └──enhances──> [Graceful failure handling]

[Idempotent state writes]
    └──enhances──> [State persistence]

[Scheduled execution (cron)]
    └──requires──> [Structured logging] (no tty; logs must go to file)
    └──requires──> [Graceful failure handling + exit codes] (cron detects failures via exit code)
```

### Dependency Notes

- **Extract leads requires State persistence:** Deduplication is meaningless without a record of what was seen in prior runs.
- **Telegram notification requires Deduplication:** Without diffing, every run sends every known lead — agent ignores the tool within days.
- **Session reuse enhances Authenticated login:** Playwright's `storage_state` lets the scraper skip the login form on every run, reducing both latency and bot-detection surface. Falls back to fresh login when session expires.
- **Failure notification conflicts with Two-way bot:** Both use Telegram, but failure notification is fire-and-forget (webhook POST); a two-way bot requires a polling loop or webhook server — a completely different architecture. Do not conflate them.

---

## MVP Definition

### Launch With (v1)

Minimum viable product — what's needed to prove the tool works.

- [ ] Authenticate to Inmuebles24 with env-var credentials — without this nothing works
- [ ] Extract active listings and per-listing lead data — the core data extraction
- [ ] Deduplicate against persisted state (JSON file) — without this the tool is unusable
- [ ] Send structured Telegram message via webhook — the delivery that makes it passive
- [ ] Structured logging to file + stdout — required to debug failures on VPS
- [ ] Graceful error handling with exit codes — required for cron to detect failures
- [ ] Cron-ready: reads all config from env vars — must be deployable without touching code

### Add After Validation (v1.x)

Features to add once core is running reliably.

- [ ] Session reuse (cached auth state) — add when login latency or detection becomes observable
- [ ] Failure notification via Telegram — add once the tool is deployed and the agent relies on it passively
- [ ] Exponential backoff + retry — add when intermittent failures are observed in logs
- [ ] Headless browser detection avoidance (randomized delays, realistic user-agent) — add if session bans start occurring

### Future Consideration (v2+)

Defer until there is a concrete use case.

- [ ] Multi-account support — only if the agent manages multiple Inmuebles24 accounts
- [ ] Per-property filtering (only alert on specific listings) — only if lead volume becomes noisy
- [ ] Historical lead log (append-only) — only if the agent wants a searchable archive

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Authenticated login | HIGH | MEDIUM | P1 |
| Extract listings + leads | HIGH | MEDIUM | P1 |
| State persistence (JSON) | HIGH | LOW | P1 |
| Deduplication | HIGH | LOW | P1 |
| Telegram notification | HIGH | LOW | P1 |
| Structured logging | HIGH | LOW | P1 |
| Graceful failure + exit codes | HIGH | MEDIUM | P1 |
| Env-var configuration | HIGH | LOW | P1 |
| Session reuse | MEDIUM | LOW | P2 |
| Failure notification via Telegram | MEDIUM | LOW | P2 |
| Exponential backoff + retry | MEDIUM | MEDIUM | P2 |
| Human-readable silence on no-new-leads | MEDIUM | LOW | P2 |
| Detection avoidance (delays, user-agent) | MEDIUM | MEDIUM | P2 |
| Idempotent state file writes | LOW | MEDIUM | P3 |
| Multi-account support | LOW | HIGH | P3 |
| Per-property filtering | LOW | MEDIUM | P3 |

**Priority key:**
- P1: Must have for launch
- P2: Should have, add when possible
- P3: Nice to have, future consideration

---

## Competitor Feature Analysis

This is a custom single-use automation, not a commercial product. The comparison below is against common analogous tools in the same category.

| Feature | Generic scraper tools (Apify, Octoparse) | n8n/Zapier workflows | This tool |
|---------|------------------------------------------|----------------------|-----------|
| Auth to specific portal | Plugin-based, config-heavy | Requires custom HTTP node | Bespoke Playwright — exact fit |
| Telegram delivery | Integration available | Native node | Direct webhook POST — minimal |
| Deduplication | External DB or cloud storage required | State node available | Local JSON file — simple |
| Scheduled runs | Cloud-hosted scheduler (paid) | Cloud-hosted (paid) | cron on VPS — free, owned |
| Failure alerting | Platform-level notifications | Node-level error branch | Same Telegram webhook |
| Cost | Per-run or subscription pricing | Subscription pricing | VPS cost only |

**Takeaway:** Off-the-shelf tools can do this but require paid cloud tiers, non-trivial configuration, and vendor lock-in. A focused Python + Playwright script on a VPS is the right fit: cheaper, faster to deploy, easier to maintain for one specific account.

---

## Sources

- [ScrapingBee Web Scraping Best Practices 2026](https://www.scrapingbee.com/blog/web-scraping-best-practices/) — scheduling, monitoring, retry patterns
- [ScrapeOps Monitoring & Scheduling](https://scrapeops.io/monitoring-scheduling/) — job monitoring features
- [Playwright Python Authentication Docs](https://playwright.dev/python/docs/auth) — session persistence with `storage_state`
- [Medium: Building a scraper with Telegram notifications](https://medium.com/@julia.nikulski/building-a-job-listings-web-scraper-that-sends-out-telegram-notifications-830763890a92) — Telegram webhook pattern for scraper alerts
- [n8n: Automated Web Scraper with Telegram Alert](https://n8n.io/workflows/6663-automated-web-scraper-niche-jobproduct-monitor-with-telegram-alert/) — deduplication and conditional notification pattern
- [Cronitor: Cron Job Monitoring](https://cronitor.io/cron-job-monitoring) — exit code patterns, failure alerting
- [DEV: Monitor Cron Jobs and Get Notified on Failures](https://dev.to/hexshift/how-to-monitor-cron-jobs-and-get-notified-on-failures-automatically-4loa) — webhook on failure pattern
- [ZenRows: Bypass Bot Detection](https://www.zenrows.com/blog/bypass-bot-detection) — anti-detection techniques for Playwright scrapers
- [Firecrawl: 10 Common Web Scraping Mistakes](https://www.firecrawl.dev/blog/web-scraping-mistakes-and-fixes) — pitfalls including aggressive parallelism and missing retries

---

*Feature research for: Scheduled web scraper / Inmuebles24 lead monitor with Telegram alerts*
*Researched: 2026-03-11*
