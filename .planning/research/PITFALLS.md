# Pitfalls Research

**Domain:** Scheduled Playwright scraper with login, state persistence, and Telegram notifications (VPS)
**Researched:** 2026-03-11
**Confidence:** HIGH — all critical pitfalls verified via official docs, GitHub issues, and community reports

---

## Critical Pitfalls

### Pitfall 1: Unclosed Browser / Context Causes Chromium Zombie Processes

**What goes wrong:**
Each scheduled run spawns a Playwright browser. If an exception occurs before `browser.close()` or `context.close()`, the Chromium subprocess stays alive. On a VPS running cron every few hours this accumulates until OOM kills the box or the disk fills with `/tmp` files.

**Why it happens:**
Developers call `browser.launch()` then fail to wrap the entire scrape in a `try/finally` or `async with` block. A single unexpected exception (login timeout, site error) bypasses cleanup.

**How to avoid:**
Always use the async context manager form:
```python
async with async_playwright() as p:
    async with p.chromium.launch(headless=True) as browser:
        async with browser.new_context() as context:
            # all scraping here
```
Never rely on GC or the process exiting to close the browser. Add `--no-sandbox` and verify `/dev/shm` is at least 256 MB on the VPS (default Docker/LXC shared memory is 64 MB and causes silent crashes).

**Warning signs:**
- `ps aux | grep chromium` shows multiple orphan processes after successive runs
- RAM usage grows monotonically between cron runs
- Runs start timing out more frequently over time

**Phase to address:** Auth / Core Scraping phase — establish the browser lifecycle pattern before any real extraction code is written.

---

### Pitfall 2: Session Cookie Expiry Causes Silent Login Failure

**What goes wrong:**
The scraper saves `storageState` (cookies + localStorage) after the first successful login and reuses it on every subsequent run. When the portal's session expires (minutes to hours depending on the site), Playwright successfully loads a page — but it's the login redirect, not the account page. Selectors find nothing. The run "succeeds" with zero leads extracted.

**Why it happens:**
Developers check for login success once during initial setup, then assume cookies are permanent. Many portals use short-lived session tokens, not persistent cookies.

**How to avoid:**
After restoring session state, add an explicit post-login assertion: navigate to the expected authenticated URL (e.g., account dashboard) and assert a known authenticated element is present. If the assertion fails, fall through to a fresh login flow. Implement age-based state checks — if the state file is older than N hours (tune based on observed session TTL), force re-authentication.

**Warning signs:**
- Run completes in unusually short time (no data pages to parse)
- Lead count is consistently zero even though the portal has new activity
- Logs show the scraper visiting `/login` or `/acceso` instead of the dashboard

**Phase to address:** Auth phase — the re-auth fallback must be designed into the login flow from the start, not bolted on later.

---

### Pitfall 3: Selector Brittleness — CSS Classes Break on Site Redesign

**What goes wrong:**
Selectors targeting presentational CSS classes (`div.listing-card__title`, `.stat-number`) break silently when the portal updates its frontend framework or runs an A/B test. The scraper returns empty data rather than raising an error.

**Why it happens:**
CSS classes tied to styling are chosen because they work in the browser's DevTools. They are also the classes most likely to change during any redesign.

**How to avoid:**
Prefer stable anchors in this order: `data-*` attributes > ARIA roles and labels (`get_by_role`, `get_by_label`) > structural text content > stable ID attributes. Avoid long CSS selector chains. Centralize all selectors in a single `selectors.py` constants file so a site change requires editing one place, not hunting through all scraping code. Add post-extraction validation: assert the extracted listing count is greater than zero and that key fields (title, lead count) are non-null before writing state.

**Warning signs:**
- A run that previously returned 10 leads returns 0 without any exception
- Log shows pages loaded successfully but extracted data is empty dicts
- Manually visiting the site shows the expected data is present

**Phase to address:** Extraction phase — establish selector centralization and post-extraction assertions before building the notification layer.

---

### Pitfall 4: Concurrent Cron Runs Corrupt the State File

**What goes wrong:**
If a scraping run takes longer than the cron interval (e.g., the site is slow and a 2-hour job slips past a 2-hour cron tick), a second instance starts and both processes read and write the `seen_leads.json` simultaneously. The result is a half-written JSON file, a corrupted state, or duplicate Telegram notifications for leads that were already reported.

**Why it happens:**
Cron has no awareness of whether the previous invocation is still running. JSON files have no built-in locking. Developers assume scraping will always finish quickly.

**How to avoid:**
Use `flock` at the shell level to prevent overlapping runs:
```bash
# In crontab
0 */2 * * * flock -n /tmp/inmobiliaria24.lock python /opt/inmobiliaria24/run.py >> /var/log/inmobiliaria24.log 2>&1
```
Also write state atomically: serialize to a temp file, then use `os.replace()` (POSIX-atomic) to move it into place. Never write directly to the live state file mid-update.

**Warning signs:**
- `seen_leads.json` contains invalid JSON (partial write)
- Telegram receives duplicate notifications for the same lead on back-to-back runs
- Two `run.py` processes visible in `ps` simultaneously

**Phase to address:** Scheduling / State phase — lock and atomic-write must be in place before the scheduler is set up, not after the first corruption incident.

---

### Pitfall 5: Bot Detection Gets the Scraper Blocked After a Few Runs

**What goes wrong:**
The first few runs succeed. Then the portal starts returning CAPTCHAs, empty responses, or permanently blocks the VPS IP. Datacenter IPs are the first to be flagged. Headless Playwright exposes `navigator.webdriver = true` by default.

**Why it happens:**
Portals serving real estate leads (high commercial value) often deploy Cloudflare or custom bot protection. A VPS IP with no browsing history, a headless fingerprint, and perfectly consistent timing is trivially identifiable as a bot.

**How to avoid:**
- Launch browser with a realistic user agent matching an up-to-date Chrome version
- Add random `time.sleep()` jitter between page navigations (1–4 seconds)
- Respect rate limits — never open parallel contexts for this single-account use case
- Reuse the session cookie across runs (reduces login frequency, which is a strong bot signal)
- Do not run with `--disable-blink-features=AutomationControlled` removed — explicitly patch it
- Monitor for unexpected redirects to CAPTCHA pages and log them as a hard failure (do not silently continue)

**Warning signs:**
- Response pages contain "Verificación de seguridad" or CAPTCHA elements
- HTTP status 403 or 429 appearing in network logs
- Site loads but all content sections are empty (bot wall returning skeleton HTML)

**Phase to address:** Auth phase — set up the browser launch profile, user agent, and timing jitter before any extraction. Do not treat this as an optimization to add later.

---

### Pitfall 6: Silent Failures — Scraper Appears to Run but Reports Nothing

**What goes wrong:**
The cron job runs on schedule, exits with code 0, produces a log file, and no Telegram notification arrives. The user has no idea whether the scraper is working. Days pass before anyone notices leads have been missed.

**Why it happens:**
The notification is only sent when new leads are found. If the scraper fails silently (session expired, selector broke, network error swallowed) it also exits without sending anything, and this looks identical to "no new leads."

**How to avoid:**
Implement a heartbeat notification: once per day (or every N runs) send a Telegram message confirming the scraper ran successfully, even if no new leads were found. Use a separate "health check" message format so the user knows the system is alive. Log structured output (timestamp, leads_checked, leads_new, errors) to a rotating log file on the VPS for debugging.

**Warning signs:**
- No Telegram messages for 24+ hours (for a portal with regular activity)
- Log timestamps stop advancing (cron silently stopped)
- Run durations logged as suspiciously short (< 10 seconds for a scrape that normally takes 60+)

**Phase to address:** Notification phase — design the heartbeat alongside the lead notification, not as an afterthought.

---

### Pitfall 7: Credentials or Webhook URL Leak Into Logs or State Files

**What goes wrong:**
Debug logging prints the full page URL (which may contain auth tokens), the loaded cookies dict (which contains session tokens), or the constructed Telegram webhook URL. These end up in world-readable log files on the VPS.

**Why it happens:**
Developers enable verbose logging during development and never audit what gets written to production logs.

**How to avoid:**
- Never log cookie values, session tokens, or the webhook URL string
- Use environment variables (`INMUEBLES24_USER`, `INMUEBLES24_PASS`, `TELEGRAM_WEBHOOK_URL`) — never hardcode or write them to files
- Set log file permissions to `600` (owner read/write only)
- Add a pre-run check: if any required env var is missing, fail immediately with a clear error rather than proceeding with a None value

**Warning signs:**
- Log files contain the string `webhook.site` or `api.telegram.org` in plaintext
- Saved `storageState.json` contains cookie values stored in a world-readable location

**Phase to address:** Configuration phase (first thing built) — env var loading and log sanitization must be established before credentials are ever used.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Hardcode selectors as inline strings throughout the code | Faster initial development | Site change requires grep-and-pray across all files | Never — centralize from day one |
| Skip re-auth fallback and assume cookies are permanent | Simpler auth code | Silent zero-lead runs when session expires | Never for a production scheduler |
| Write state directly to `seen_leads.json` without atomic swap | Simpler code | Corrupted JSON on crash mid-write | Never — `os.replace()` costs nothing |
| No flock / concurrency guard | One less dependency | Duplicate notifications and state corruption on slow runs | Never for cron-scheduled jobs |
| Print credentials in debug logs temporarily | Easier debugging in dev | Credential exposure if log files are shipped or readable | Dev only — never in production config |
| Single Telegram message per run with all leads bundled | Simpler formatting code | Hits message length limit (4096 chars) with many listings | Acceptable for MVP if lead counts are small |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Inmuebles24 login | Re-login on every run | Save `storageState`, reuse, fall back to re-login only when session check fails |
| Inmuebles24 login | Treating a 200 response on the login page as success | Assert authenticated element (e.g., username in header) is present after navigation |
| Telegram webhook | Sending one message per lead regardless of count | Batch leads by property; send one message per property with its lead list |
| Telegram webhook | Not handling 429 Too Many Requests | Check response status; back off and retry with `Retry-After` seconds + jitter |
| Telegram webhook | Sending the webhook URL in logs for debugging | Log only a truncated hash or `[WEBHOOK_CONFIGURED]` boolean |
| JSON state file | Reading file that doesn't exist on first run | Initialize with empty `{"seen": []}` if file missing — never crash on first run |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Launching a new browser on every cron run | Cold start adds 5–10 seconds; fine at low frequency | Acceptable for this use case (runs every few hours) | Never for this project's scale |
| Loading all historical lead IDs into memory for dedup | Memory grows as seen-leads set grows | Use a rolling window (last 30 days of seen IDs) or SQLite with an index | At ~100K+ accumulated IDs — not a concern for typical single-agent use |
| No timeout on `page.goto()` or `page.wait_for_selector()` | Scraper hangs indefinitely if site is slow | Always set explicit `timeout` on navigation and wait calls (30–60s) | First time the portal has downtime |
| Waiting for `networkidle` on every navigation | Extremely slow on portals with always-active websockets or analytics beacons | Use `domcontentloaded` or `load` state instead for most navigation; `networkidle` only when strictly necessary | Immediately on any portal with live-update features |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Storing credentials in the script file or a committed config file | Credential exposure via git history or repository access | Use environment variables; add `.env` to `.gitignore` |
| Storing `storageState.json` in the project root without access controls | Session hijacking if VPS is compromised | Store outside web root; `chmod 600`; never commit |
| Running the scraper as root on the VPS | Chromium escape → full system compromise | Create a dedicated low-privilege user; run cron under that user |
| Logging the Telegram webhook URL | Webhook URL = direct write access to the Telegram channel | Never log the URL; validate it is set but treat it as a secret |

---

## "Looks Done But Isn't" Checklist

- [ ] **Auth flow:** Works on first run. Does it also work when the state file is stale or missing? Verify by deleting `storageState.json` and running again.
- [ ] **New-lead detection:** Returns results on first run. Does it correctly detect zero new leads on the second run (no duplicate notifications)? Verify by running twice in a row.
- [ ] **State corruption recovery:** Does the scraper handle a malformed `seen_leads.json` (simulate with `echo "{broken" > seen_leads.json`) gracefully and reset state rather than crashing?
- [ ] **Cron scheduling:** The cron job runs in a clean environment without the developer's shell `PATH` or virtualenv activated. Verify by running `crontab -l`, then trigger manually via `run-parts` or check actual cron logs, not just `python run.py` in the terminal.
- [ ] **Telegram delivery:** The webhook URL is set in the environment, not just in the developer's shell session. Verify `printenv | grep TELEGRAM` from the cron context (add a debug cron entry).
- [ ] **Silent failure detection:** If the site returns a login redirect instead of data, does the scraper log an error and exit non-zero? Verify by pointing the scraper at a URL that requires auth with an expired session.
- [ ] **Zombie process cleanup:** After a run that raises an exception mid-scrape, are there any lingering Chromium processes? Verify with `ps aux | grep chromium` after forcing an exception.

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Zombie Chromium processes accumulated | LOW | `pkill -f chromium`; add `async with` pattern; redeploy |
| Corrupted `seen_leads.json` | LOW | Delete the file; next run initializes fresh state; may send duplicate notifications for recent leads — acceptable one-time cost |
| VPS IP blocked by portal | HIGH | Change VPS IP or use a residential proxy; implement better jitter and rate limiting; may need to wait out a ban period |
| Credentials accidentally committed to git | HIGH | Rotate credentials immediately; use `git filter-repo` to scrub history; audit all forks/clones |
| Duplicate Telegram notifications sent | LOW | No rollback possible; notify user that a state reset occurred; tighten idempotency logic |
| Cron silently stopped running | LOW | Check cron daemon status (`systemctl status cron`); verify user crontab; check for syntax errors in the crontab entry |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Zombie browser processes | Phase 1: Auth & Browser Setup | After a forced exception, `ps aux | grep chromium` shows no orphans |
| Session cookie expiry / silent login failure | Phase 1: Auth & Browser Setup | Delete state file, run again — scraper re-authenticates and continues |
| Bot detection / IP block | Phase 1: Auth & Browser Setup | Three consecutive runs do not trigger CAPTCHA or 403 |
| Credentials / webhook leak | Phase 1: Configuration | `grep -r "INMUEBLES24_PASS" .` returns nothing; log files contain no secrets |
| Brittle CSS selectors | Phase 2: Extraction | All selectors in `selectors.py`; extraction returns non-empty data with assertions |
| Concurrent cron / state corruption | Phase 3: State & Scheduling | Run two instances simultaneously; second exits immediately via flock; state file is valid JSON |
| Silent failures — no observability | Phase 4: Notification | Send a daily heartbeat even when zero new leads are found; log run summary on each exit |
| Telegram rate limit / duplicate alerts | Phase 4: Notification | Sending 10 notifications in a burst returns no 429s; second run after first sends zero duplicates |

---

## Sources

- [Automate Login and Session Handling in Playwright — Prosperasoft](https://prosperasoft.com/blog/web-scrapping/playwright/playwright-login-session-scraping/)
- [Playwright Authentication (official docs)](https://playwright.dev/docs/auth)
- [8GB Was a Lie: Playwright in Production — Medium](https://medium.com/@onurmaciit/8gb-was-a-lie-playwright-in-production-c2bdbe4429d6)
- [Playwright Python memory leak issue #2511 — GitHub](https://github.com/microsoft/playwright-python/issues/2511)
- [BrowserContext resource cleanup — Playwright Python official docs](https://playwright.dev/python/docs/browser-contexts)
- [Prevent Concurrent Cron Jobs Using flock — Hong's Tech Blog](https://tech.mrleong.net/prevent-concurrent-cron-jobs-using-flock)
- [Safe atomic file writes for JSON in Python — GitHub Gist](https://gist.github.com/therightstuff/cbdcbef4010c20acc70d2175a91a321f)
- [atomicwrites — PyPI](https://pypi.org/project/atomicwrites/)
- [Stop Silent Failures in Web Scrapers — DEV Community](https://dev.to/anderecit/stop-silent-failures-using-llms-to-validate-web-scraper-output-24gf)
- [Playwright Selector Best Practices 2026 — BrowserStack](https://www.browserstack.com/guide/playwright-selectors-best-practices)
- [How to Avoid Bot Detection with Playwright — ZenRows](https://www.zenrows.com/blog/avoid-playwright-bot-detection)
- [Telegram Bot API rate limits and Flood Wait — python-telegram-bot wiki](https://github.com/python-telegram-bot/python-telegram-bot/wiki/Avoiding-flood-limits)
- [Avoiding Flood Limits — grammY docs](https://grammy.dev/advanced/flood)
- [Scalable Web Scraping with Playwright — Browserless](https://www.browserless.io/blog/scraping-with-playwright-a-developer-s-guide-to-scalable-undetectable-data-extraction)

---
*Pitfalls research for: Inmobiliaria24 — scheduled Playwright scraper (login, state, Telegram VPS)*
*Researched: 2026-03-11*
