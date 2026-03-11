---
phase: 01-foundation
plan: 02
subsystem: auth
tags: [playwright, playwright-stealth, stealth, session-cache, storage-state, loguru, argparse, async]

# Dependency graph
requires:
  - phase: 01-foundation/01-01
    provides: Settings dataclass with load_dotenv + fail-fast credential loading from env vars

provides:
  - auth.py with load_or_login(), login(), is_session_fresh(), save_failure_screenshot(), AuthenticationError
  - storage_state caching at .session/storage_state.json with 12-hour TTL
  - Automatic stale/corrupt session detection with fallback to fresh login
  - Stealth browser context via Stealth().apply_stealth_async() (playwright_stealth 2.x)
  - Randomised timing jitter on all login interactions
  - Failure screenshots saved to logs/screenshots/ on auth errors
  - main.py with async_main() owning full browser lifecycle with nested async with
  - CLI flags --headful (visible browser) and --dry-run (auth-only, exits 0)
  - __main__.py enabling python -m inmobiliaria24 invocation
  - Credential-safe logging: only email logged, password never appears in logs/tracebacks

affects:
  - 02-extraction (imports load_or_login, passes context to scraper)
  - 03-state (inherits browser context pattern)
  - 04-notification (uses same CLI entrypoint, adds notification step)

# Tech tracking
tech-stack:
  added:
    - playwright_stealth 2.x Stealth class (replaces legacy stealth_async function from 1.x)
  patterns:
    - Session caching pattern: storage_state.json with mtime freshness check
    - Auth lifecycle: load_or_login() returns ready-to-use BrowserContext, caller closes it
    - Stealth pattern: Stealth().apply_stealth_async(page) applied before any navigation
    - Jitter pattern: asyncio.sleep(random.uniform(0.8, 2.5)) before each login interaction
    - Credential hygiene: password field repr=False, never passed to logger
    - Browser lifecycle pattern: nested async with async_playwright(); browser.close() in finally
    - Failure screenshot pattern: save screenshot to logs/screenshots/ before raising AuthenticationError

key-files:
  created:
    - src/inmobiliaria24/auth.py
    - src/inmobiliaria24/main.py
    - src/inmobiliaria24/__main__.py
  modified: []

key-decisions:
  - "playwright_stealth 2.x API change: stealth_async(page) replaced by Stealth().apply_stealth_async(page) — the installed playwright-stealth==2.0.2 exports Stealth class, not stealth_async"
  - "Stealth instance created once as module-level constant (_STEALTH) — stateless config object, safe to reuse"
  - "async_main() accepts settings as parameter (not re-loaded inside) to keep Settings.load() in main() as single validation point"
  - "__main__.py added (not in plan) to support python -m inmobiliaria24 invocation as specified in success criteria"
  - "AUTH_INDICATOR_SELECTOR is best-guess only — will require adjustment after live browser inspection on Inmuebles24"

patterns-established:
  - "Browser lifecycle pattern: main.py owns launch/close; auth.py creates/returns contexts; caller closes context"
  - "Session cache pattern: check freshness (mtime < 12h) -> validate live -> fallback to fresh login on any failure"
  - "Auth failure pattern: save screenshot, log error without credentials, raise AuthenticationError with human-readable message"

requirements-completed: [AUTH-01, AUTH-02]

# Metrics
duration: 10min
completed: 2026-03-11
---

# Phase 1 Plan 02: Playwright Auth Session Summary

**Stealth-capable Playwright login with storage_state caching, automatic stale session fallback, failure screenshots, and CLI entrypoint with --headful/--dry-run flags**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-03-11T17:54:34Z
- **Completed:** 2026-03-11T18:04:00Z
- **Tasks:** 2 (2 commits)
- **Files modified:** 3 created

## Accomplishments
- `auth.py`: full authentication lifecycle — session reuse, stale detection, fresh login, failure screenshots
- `main.py`: browser lifecycle owner with nested `async with`, clean exit codes, never logs credentials
- `__main__.py`: enables `python -m inmobiliaria24` invocation
- Missing credentials exits with a clear config error message (not a traceback)
- playwright_stealth 2.x API difference handled automatically (Rule 1 auto-fix)

## Task Commits

Each task was committed atomically:

1. **Task 1: Auth module** - `869b83f` (feat)
2. **Task 2: CLI entrypoint** - `8c28e5d` (feat)

**Plan metadata:** _(docs commit — see below)_

## Files Created/Modified
- `src/inmobiliaria24/auth.py` — Full auth lifecycle: load_or_login(), login(), is_session_fresh(), save_failure_screenshot(), AuthenticationError
- `src/inmobiliaria24/main.py` — CLI entrypoint: --headful/--dry-run, browser lifecycle, Settings validation, exit codes
- `src/inmobiliaria24/__main__.py` — Enables python -m inmobiliaria24 invocation

## Decisions Made
- **playwright_stealth 2.x API:** The plan specified `stealth_async(page)` (1.x API), but the installed version (2.0.2) exports `Stealth` class. Used `Stealth().apply_stealth_async(page)` throughout. Created module-level `_STEALTH = Stealth()` to avoid re-instantiation.
- **Settings passed to async_main:** Rather than calling `Settings.load()` inside the async context, `main()` validates settings first and passes them as a parameter. This keeps the failure surface clean — config errors are caught before any browser is launched.
- **__main__.py added:** Not in the original plan but required for `python -m inmobiliaria24` to work (Python module invocation requires `__main__.py`).
- **AUTH_INDICATOR_SELECTOR:** Using best-guess selectors (`[data-qa='user-menu'], .user-menu, [aria-label='Mi cuenta']`). Must be validated in a live browser session before relying on session validity checks.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed playwright_stealth API mismatch**
- **Found during:** Task 1 (auth module import verification)
- **Issue:** Plan specified `from playwright_stealth import stealth_async` and `await stealth_async(page)`. The installed playwright_stealth==2.0.2 exports `Stealth` class only; `stealth_async` does not exist.
- **Fix:** Changed import to `from playwright_stealth import Stealth`, created `_STEALTH = Stealth()` at module level, replaced all `stealth_async(page)` calls with `await _STEALTH.apply_stealth_async(page)`.
- **Files modified:** src/inmobiliaria24/auth.py
- **Verification:** `from inmobiliaria24.auth import load_or_login, AuthenticationError, is_session_fresh` imports without error
- **Committed in:** 869b83f (Task 1 commit)

**2. [Rule 2 - Missing Critical] Added __main__.py for module invocation**
- **Found during:** Task 2 (verifying `python -m inmobiliaria24 --help`)
- **Issue:** Plan success criteria specify `python -m inmobiliaria24 --dry-run` must work. Python requires `__main__.py` in the package directory for `-m` module invocation. Without it, the command fails.
- **Fix:** Created `src/inmobiliaria24/__main__.py` that calls `main()`.
- **Files modified:** src/inmobiliaria24/__main__.py (created)
- **Verification:** `python -m inmobiliaria24 --help` shows --headful and --dry-run; `python -m inmobiliaria24 --dry-run` with no .env exits 1 with clear config error
- **Committed in:** 8c28e5d (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 bug, 1 missing critical)
**Impact on plan:** Both auto-fixes required for correctness. No scope creep.

## Issues Encountered

- `playwright_stealth==2.0.2` has a completely different API from 1.x (which the plan was written against). The `stealth_async` function no longer exists; the library now uses a `Stealth` class with `apply_stealth_async()`. Handled automatically via Rule 1.

## Selector Note

`AUTH_INDICATOR_SELECTOR = "[data-qa='user-menu'], .user-menu, [aria-label='Mi cuenta']"` is a best-guess. This selector must be validated during a live `--dry-run` with real credentials. If the selector is wrong, `_assert_authenticated()` will time out and fall back to a fresh login unnecessarily. Adjust the selector in `auth.py` after first successful run.

Similarly, `LOGIN_URL` and `ACCOUNT_CHECK_URL` are set to the expected Inmuebles24 URLs but have not been tested live. Adjust if the site uses different paths.

## User Setup Required

To run `python -m inmobiliaria24 --dry-run` successfully:
1. Copy `.env.example` to `.env`
2. Fill in `INMUEBLES24_EMAIL` and `INMUEBLES24_PASSWORD`
3. Run `python -m inmobiliaria24 --dry-run`
4. If CAPTCHA or bot block occurs, check `logs/screenshots/` for a screenshot and adjust `AUTH_INDICATOR_SELECTOR` in `auth.py`

## Next Phase Readiness
- `load_or_login(browser, settings) -> BrowserContext` ready for Phase 2 (extraction)
- Session caching in place — second run reuses `.session/storage_state.json`
- All logs go to `logs/run.log` (DEBUG) and stderr (INFO); no credentials appear in either
- Phase 2 can call `load_or_login` and use the returned context for scraping immediately

---
*Phase: 01-foundation*
*Completed: 2026-03-11*
