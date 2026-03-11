# Stack Research

**Domain:** Scheduled web automation — login, scraping, state persistence, webhook notifications
**Researched:** 2026-03-11
**Confidence:** HIGH (core choices verified against PyPI and official docs)

---

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Python | 3.13.x | Runtime | Stable as of Oct 2024, EOL Oct 2029. Best ecosystem for browser automation + HTTP + scheduling on Linux VPS. 3.13 is safe; avoid 3.14 (released Oct 2025, too new for production libraries to have caught up). |
| Playwright (Python) | 1.58.0 | Browser automation — login + scraping | Standard choice for JavaScript-heavy portals. Handles React SPAs, login flows, dynamic content, and waiting for async renders. Inmuebles24 uses React with Cloudflare — Playwright is the only Python-native option that reliably handles this. |
| APScheduler | 3.11.2 | In-process task scheduler | Runs the scraper loop inside the Python process on a cron-like interval. No external daemon needed. Stick with 3.x stable; 4.0 is alpha and breaking. |
| httpx | 0.28.1 | HTTP client — Telegram API calls | Async-native, clean API, used to POST to Telegram Bot API. No overhead of a bot framework — we only need outbound `sendMessage`. |
| python-dotenv | 1.2.2 | Environment variable management | Loads `.env` at runtime for credentials and webhook URL. Keeps secrets out of code. 12-factor compliant. |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| playwright-stealth | 2.0.2 | Anti-bot evasion | Apply on every browser context to mask the `navigator.webdriver` flag and headless indicators. Inmuebles24 is behind Cloudflare — without stealth the scraper will be blocked quickly. |
| loguru | 0.7.x (latest) | Structured logging | Zero-config logging with rotation and level filtering. Better than stdlib `logging` for scripts. Use it for every scraper run log so failures are diagnosable. |
| json (stdlib) | — | State persistence | Store seen lead IDs as a JSON set in a local file (e.g., `state.json`). No database needed for this scale — a flat file read/write on each run is sufficient and auditable. |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| venv / uv | Dependency isolation | Use `uv` (Astral) as the modern pip replacement — significantly faster installs. Falls back to standard `venv` if uv is not available. |
| systemd timer or cron | OS-level scheduling | Preferred over APScheduler's internal loop on a production VPS: crash-resilient, no long-lived Python process required. Use `systemd` if the VPS runs a modern Ubuntu; use `cron` as fallback. |
| Playwright's `--headed` / `--slow-mo` | Debug mode | During development, run headed to observe login flow and selector identification. Never run headed on the VPS. |

---

## Installation

```bash
# Create venv
python3.13 -m venv .venv
source .venv/bin/activate

# Core
pip install playwright==1.58.0 APScheduler==3.11.2 httpx==0.28.1 python-dotenv==1.2.2

# Supporting
pip install playwright-stealth==2.0.2 loguru

# Install browser binary (Chromium only — smallest footprint)
playwright install chromium
playwright install-deps chromium
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Playwright | Selenium | Only if the team already has Selenium infrastructure and can't migrate. Selenium has slower API, no built-in async, and inferior waiting primitives for SPAs. |
| Playwright | Scrapy + scrapy-playwright | Only if scraping hundreds of pages in parallel. Scrapy's overhead is unjustified for a single-account, few-page scraper. |
| Playwright | requests + BeautifulSoup | Only for fully static HTML sites. Inmuebles24 renders listings in React — requests will fetch server-side shell HTML with no data. Not viable here. |
| APScheduler 3.x | APScheduler 4.x alpha | When 4.0 reaches stable (expected mid-2026). API is breaking-change from 3.x, async-first redesign. Not yet production-safe. |
| APScheduler (in-process) | systemd timer | Preferred on a production VPS where process longevity is a concern. systemd restarts on crash; APScheduler loops are lost on any unhandled exception. Consider both: APScheduler for dev, systemd timer for prod. |
| httpx | requests | requests is sync-only. For simple one-shot fire-and-forget Telegram calls, requests works fine and has zero async overhead. Use requests if async adds no benefit elsewhere in the script. |
| httpx | python-telegram-bot | Only if the project evolves to receive Telegram commands (two-way bot). The full framework is overkill for send-only notifications. |
| playwright-stealth | tf-playwright-stealth | tf-playwright-stealth (1.2.0) is a port from puppeteer-extra-plugin-stealth and may be slightly more comprehensive, but playwright-stealth (2.0.2) is the more actively maintained Python-native choice. Consider tf-playwright-stealth if Cloudflare blocks persist after applying playwright-stealth. |
| json (stdlib) | SQLite | Use SQLite if the state grows beyond simple ID sets — e.g., storing lead timestamps, history, or needing queries. For the current scope (a set of seen lead IDs), JSON file is simpler with no schema overhead. |
| loguru | stdlib logging | Use stdlib logging only if the script must ship into a larger Python package that already uses it. For a standalone scraper, loguru is unambiguously easier. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Selenium / SeleniumBase | Older API, no native async, inferior network interception, higher detection surface. Playwright supersedes it for new projects. | Playwright |
| Puppeteer (Node.js) | This is a Python project on a VPS where the entire toolchain is Python. Mixing Node.js adds deployment complexity for no gain. | Playwright Python |
| Scrapy | Framework overhead is enormous for single-account scraping. It adds a learning curve, pipeline configuration, and middleware — none of which are needed here. | Playwright + plain Python |
| requests + lxml / BeautifulSoup | Cannot execute JavaScript. Inmuebles24 renders listing data client-side via React. This stack will silently return empty HTML. | Playwright |
| APScheduler 4.0.0a6 | Alpha software with breaking API changes from 3.x. Not production-safe as of March 2026. | APScheduler 3.11.2 |
| Hardcoded credentials | Security and portability failure. Commits or shares credentials accidentally. | python-dotenv with `.env` excluded from git via `.gitignore` |
| Playwright in headed mode on VPS | VPS typically has no display server. Headed mode requires Xvfb or similar — adds fragility. | Playwright `--headless` (default); use headed only in local dev. |

---

## Stack Patterns by Variant

**If Cloudflare blocks increase (bot detection escalates):**
- Add `tf-playwright-stealth` alongside or instead of `playwright-stealth`
- Consider launching Chromium with a persistent user-data directory so cookies and browser fingerprints accumulate across runs
- Add random human-like delays between actions (1–3 seconds) using `asyncio.sleep(random.uniform(1, 3))`

**If the VPS runs Ubuntu 22.04 or 24.04:**
- Use `systemd` timer instead of APScheduler's internal loop for production scheduling
- This makes crash recovery automatic and run history visible via `journalctl`

**If state grows beyond a flat ID set:**
- Migrate `state.json` to SQLite using Python's stdlib `sqlite3` — no new dependency
- Schema: `leads(id TEXT PRIMARY KEY, property_id TEXT, seen_at TEXT)`

**If login requires 2FA or CAPTCHA:**
- This is a blocking issue — Playwright cannot solve CAPTCHA automatically
- Options: use the site's mobile API (if it exists and is less protected), or contact Inmuebles24 for a data API/partner access

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| playwright==1.58.0 | Python 3.9–3.14 | Chromium bundled at install time. Pin the Playwright version to keep browser binary and API in sync. |
| playwright-stealth==2.0.2 | playwright>=1.40 | Version 2.0.0+ has breaking API changes vs 1.x. Import as `from playwright_stealth import stealth_async`. |
| APScheduler==3.11.2 | Python 3.8+ | 3.x and 4.x are NOT compatible. Do not accidentally upgrade to 4.x alpha. Pin to `APScheduler>=3.11,<4.0` in requirements. |
| httpx==0.28.1 | Python 3.8+ | Stable. No known conflicts with Playwright. |
| python-dotenv==1.2.2 | Python 3.10+ (required by 1.2.x) | Use 1.1.x if Python 3.9 is needed. |

---

## Key Architecture Note: Cloudflare + React

W3Techs confirms Inmuebles24 runs **Cloudflare as reverse proxy and CDN**, uses **React** for its frontend, and the site returned a `403` when fetched without a real browser user-agent. This has two implications:

1. **Playwright is non-negotiable** — no static HTTP scraper will work here.
2. **Stealth is required from day one** — the 403 response on direct fetch confirms active bot filtering. Apply `playwright-stealth` immediately; do not defer to a later phase.

---

## Sources

- [playwright · PyPI](https://pypi.org/project/playwright/) — version 1.58.0 confirmed (HIGH confidence)
- [Playwright Python official docs](https://playwright.dev/python/docs/intro) — installation, browser support (HIGH confidence)
- [APScheduler · PyPI](https://pypi.org/project/APScheduler/) — version 3.11.2 stable confirmed, 4.0.0a6 alpha flagged (HIGH confidence)
- [httpx · PyPI](https://pypi.org/project/httpx/) — version 0.28.1 confirmed (HIGH confidence)
- [python-dotenv · PyPI](https://pypi.org/project/python-dotenv/) — version 1.2.2 confirmed (HIGH confidence)
- [playwright-stealth · PyPI](https://pypi.org/project/playwright-stealth/) — version 2.0.2 confirmed, active maintenance verified (HIGH confidence)
- [tf-playwright-stealth · PyPI](https://pypi.org/project/tf-playwright-stealth/) — version 1.2.0, alternative evaluated (MEDIUM confidence)
- [W3Techs — inmuebles24.com](https://w3techs.com/sites/info/inmuebles24.com) — Cloudflare + React confirmed (MEDIUM confidence, third-party analysis)
- [ZenRows — Playwright bot detection](https://www.zenrows.com/blog/avoid-playwright-bot-detection) — stealth techniques (MEDIUM confidence)
- [BetterStack — APScheduler guide](https://betterstack.com/community/guides/scaling-python/apscheduler-scheduled-tasks/) — scheduler pattern confirmation (MEDIUM confidence)

---
*Stack research for: Inmobiliaria24 Lead Monitor — scheduled web automation, VPS*
*Researched: 2026-03-11*
