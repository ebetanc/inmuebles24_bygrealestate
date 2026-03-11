# Phase 1: Foundation - Context

**Gathered:** 2026-03-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Config, authenticated Playwright session, stealth, and bot-detection hardening. Delivers a working, reusable browser session that downstream phases (extraction, state, notification) can build on. No data extraction in this phase.

</domain>

<decisions>
## Implementation Decisions

### Bot Evasion
- Use `playwright-stealth` + random timing jitter between actions
- Run headless on VPS by default; support `--headful` flag for local demo/debug use
- On CAPTCHA or block: save screenshot to `logs/screenshots/`, log the error, exit non-zero — no retry loop
- Screenshots on failure saved to `logs/screenshots/` directory

### Login Failure Handling
- Wrong credentials → log clear error + exit non-zero
- Distinguish between "wrong credentials" and "site down / blocked" — different log messages for each
- After failed login: automatically delete the corrupted session cache so the next run does a fresh login
- No retry loops — one attempt, then exit cleanly

### Session Cache Strategy
- Use Playwright `storage_state` for session persistence across runs
- Store session file at `.session/storage_state.json` — separate directory, added to `.gitignore`
- Stale session detection: live assertion — after loading cached session, navigate to a protected account URL; if redirected to login page, re-authenticate automatically
- `.session/` and `logs/` both added to `.gitignore` (contain sensitive data)

### Project Structure
- Module layout: `src/inmobiliaria24/` package
  - `auth.py` — login, session load/save, stale detection
  - `main.py` — entrypoint, CLI flags
  - (Phase 2+: `scraper.py`, `state.py`, `notifier.py`)
- Dependency management: `uv` + `pyproject.toml`
- Python 3.12
- `--dry-run` flag: authenticates and verifies session but skips extraction and notification — for VPS credential testing
- `--headful` flag: runs with visible browser for local demo/debugging

### Claude's Discretion
- Exact timing jitter ranges (reasonable human-like delays)
- Internal error class hierarchy
- Logging format and rotation strategy

</decisions>

<specifics>
## Specific Ideas

- User needs both headless (VPS production) and headful (local demo) modes — controlled via a CLI flag, not a config file
- The `--dry-run` flag is explicitly for verifying credentials and session health on the VPS without triggering downstream actions

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- None — greenfield project

### Established Patterns
- None yet — Phase 1 establishes the baseline patterns all subsequent phases will follow

### Integration Points
- `auth.py` will be imported by Phase 2's `scraper.py` to get an authenticated browser context
- `.session/storage_state.json` is the handoff artifact between auth and all downstream modules

</code_context>

<deferred>
## Deferred Ideas

- None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-foundation*
*Context gathered: 2026-03-11*
