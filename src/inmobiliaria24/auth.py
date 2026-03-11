"""Authentication module for Inmuebles24 scraper.

Owns the full authentication lifecycle:
- Storage_state caching with freshness check
- Stealth browser context creation
- Login with timing jitter and credential hygiene
- Stale session detection with automatic re-auth fallback
- Failure screenshots for CAPTCHA / block detection
"""
from __future__ import annotations

import asyncio
import random
from datetime import datetime
from pathlib import Path

from loguru import logger
from playwright.async_api import Browser, BrowserContext, Page
from playwright_stealth import Stealth

from inmobiliaria24.config import Settings

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SESSION_PATH = Path(".session/storage_state.json")
SESSION_MAX_AGE_HOURS = 12
SCREENSHOTS_DIR = Path("logs/screenshots")

LOGIN_URL = "https://www.inmuebles24.com/login"
ACCOUNT_CHECK_URL = "https://www.inmuebles24.com/mis-propiedades"

# Adjust after live browser inspection — these are best-guess selectors.
AUTH_INDICATOR_SELECTOR = "[data-qa='user-menu'], .user-menu, [aria-label='Mi cuenta']"

# Shared stealth instance (stateless config object, safe to reuse).
_STEALTH = Stealth()


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class AuthenticationError(Exception):
    """Raised when authentication fails for any reason."""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def is_session_fresh(path: Path, max_age_hours: int) -> bool:
    """Return True if *path* exists and its mtime is within *max_age_hours*.

    Never raises — returns False on any OS error.
    """
    try:
        if not path.exists():
            return False
        mtime = path.stat().st_mtime
        age_hours = (datetime.now().timestamp() - mtime) / 3600
        return age_hours < max_age_hours
    except OSError:
        return False


async def save_failure_screenshot(page: Page, label: str) -> Path:
    """Capture a screenshot of *page* and save it under SCREENSHOTS_DIR.

    Returns the path to the saved screenshot.
    """
    SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    screenshot_path = SCREENSHOTS_DIR / f"{label}_{timestamp}.png"
    await page.screenshot(path=str(screenshot_path), full_page=True)
    logger.info("Failure screenshot saved: {}", screenshot_path)
    return screenshot_path


# ---------------------------------------------------------------------------
# Core authentication
# ---------------------------------------------------------------------------


async def _assert_authenticated(page: Page) -> None:
    """Navigate to the protected account page and verify the auth indicator.

    Raises AuthenticationError if the session appears invalid.
    """
    await page.goto(ACCOUNT_CHECK_URL, wait_until="domcontentloaded")

    # If redirected back to login, session is invalid.
    if "login" in page.url or "acceso" in page.url:
        raise AuthenticationError("Session invalid — redirected to login page")

    try:
        await page.wait_for_selector(AUTH_INDICATOR_SELECTOR, timeout=10_000)
    except Exception:
        # Selector not found within timeout — check URL again before giving up.
        if "login" in page.url or "acceso" in page.url:
            raise AuthenticationError("Session invalid — redirected to login page")
        raise AuthenticationError(
            "Session invalid — auth indicator not found on account page"
        )


async def login(page: Page, settings: Settings) -> None:
    """Perform a fresh login using *settings* credentials.

    Uses randomised timing jitter between interactions to reduce bot-detection
    risk.  Never logs the password.

    Raises AuthenticationError on failure.
    """
    logger.info("Logging in as {}", settings.email)

    await page.goto(LOGIN_URL, wait_until="domcontentloaded")

    # Jitter before email
    await asyncio.sleep(random.uniform(0.8, 2.5))
    email_field = page.locator("[type=email]")
    await email_field.fill(settings.email)

    # Jitter before password
    await asyncio.sleep(random.uniform(0.8, 2.5))
    password_field = page.locator("[type=password]")
    await password_field.fill(settings.password)

    # Jitter before submit
    await asyncio.sleep(random.uniform(0.8, 2.5))
    submit_button = page.locator("[type=submit]")
    await submit_button.click()

    # Wait for navigation to complete after submit.
    await page.wait_for_load_state("domcontentloaded")

    try:
        await _assert_authenticated(page)
    except AuthenticationError:
        # Capture screenshot before re-raising.
        try:
            await save_failure_screenshot(page, "login_failed")
        except Exception as screenshot_err:
            logger.warning("Could not save failure screenshot: {}", screenshot_err)
        raise AuthenticationError(
            "Login failed — check credentials or CAPTCHA"
        )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def load_or_login(browser: Browser, settings: Settings) -> BrowserContext:
    """Return an authenticated BrowserContext, reusing a cached session if fresh.

    1. If SESSION_PATH exists and is fresh:
       - Create context with storage_state.
       - Apply stealth and verify the session is still valid.
       - Return context on success; fall through to fresh login on failure.
    2. Fresh login path:
       - Delete stale/corrupt cache.
       - Create a new context, apply stealth, perform login.
       - Save storage_state and return the context.

    The caller is responsible for closing the returned context.

    Note: playwright_stealth 2.x uses Stealth().apply_stealth_async(page) instead
    of the legacy stealth_async(page) from 1.x.
    """
    SESSION_PATH.parent.mkdir(parents=True, exist_ok=True)

    if is_session_fresh(SESSION_PATH, SESSION_MAX_AGE_HOURS):
        logger.info("Cached session found — attempting reuse")
        context = await browser.new_context(storage_state=str(SESSION_PATH))
        test_page = await context.new_page()
        try:
            await _STEALTH.apply_stealth_async(test_page)
            await _assert_authenticated(test_page)
            await test_page.close()
            logger.info("Cached session is valid — skipping fresh login")
            return context
        except AuthenticationError:
            logger.warning("Cached session invalid — falling back to fresh login")
            await test_page.close()
            await context.close()
            # Fall through to fresh login below.
        except Exception as e:
            logger.warning(
                "Session validation error ({}): falling back to fresh login", e
            )
            try:
                await test_page.close()
            except Exception:
                pass
            await context.close()
            # Fall through to fresh login below.

    # Fresh login path — delete stale/corrupt cache first.
    if SESSION_PATH.exists():
        try:
            SESSION_PATH.unlink()
            logger.debug("Deleted stale session cache: {}", SESSION_PATH)
        except OSError as e:
            logger.warning("Could not delete stale session file: {}", e)

    logger.info("Starting fresh login")
    context = await browser.new_context(
        extra_http_headers={
            "Accept-Language": "es-MX,es;q=0.9,en;q=0.8",
        }
    )
    page = await context.new_page()

    await page.set_extra_http_headers({
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/131.0.0.0 Safari/537.36"
        )
    })
    await _STEALTH.apply_stealth_async(page)

    try:
        await login(page, settings)
    except AuthenticationError:
        await page.close()
        await context.close()
        raise

    # Persist the session for future runs.
    await context.storage_state(path=str(SESSION_PATH))
    logger.info("Session saved to {}", SESSION_PATH)

    await page.close()
    return context
