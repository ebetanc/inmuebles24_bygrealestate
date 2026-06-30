"""Authentication module for Inmuebles24 scraper.

Owns the full authentication lifecycle:
- Playwright Chromium browser launch with persistent profile (cookies survive between runs)
- Multi-step login: homepage -> Ingresar -> email -> Continuar -> password -> Iniciar sesion
- Navigation to "Mis avisos" panel after login
"""
from __future__ import annotations

import asyncio
import os
import random
import subprocess
from pathlib import Path

from loguru import logger
from playwright.async_api import BrowserContext, Page, Playwright

from inmobiliaria24.config import Settings

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PROFILE_DIR = Path(".session/chrome-profile")
CDP_PORT = 9222

_CHROME_CANDIDATES = [
    # Linux
    Path("/usr/bin/google-chrome"),
    Path("/usr/bin/google-chrome-stable"),
    Path("/usr/bin/chromium-browser"),
    Path("/usr/bin/chromium"),
    # Windows
    Path("C:/Program Files/Google/Chrome/Application/chrome.exe"),
    Path("C:/Program Files (x86)/Google/Chrome/Application/chrome.exe"),
]

HOME_URL = "https://www.inmuebles24.com/"
AVISOS_URL = "https://www.inmuebles24.com/panel.bum"

# Selectors (from live DOM inspection)
BTN_INGRESAR = '[data-qa="HEADER_LOGIN"] >> visible=true'
INPUT_EMAIL = '[data-qa="input_usuario_login"]'
BTN_CONTINUAR = '[data-qa="boton_continuar_login"]'
INPUT_PASSWORD = '[data-qa="input_contraseña_login"]'
BTN_INICIAR_SESION = '[data-qa="boton_iniciar_sesion_login"]'
MENU_MIS_AVISOS = '[data-qa="mis-avisos"]'


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class AuthenticationError(Exception):
    """Raised when authentication fails for any reason."""


# ---------------------------------------------------------------------------
# Cloudflare handling
# ---------------------------------------------------------------------------


_CF_TITLES = ("just a moment", "un momento")

# Titles that mean we are NOT on a usable logged-in panel: the Cloudflare
# interstitial AND the hard "1020 / Attention Required" block page. Used by the
# session-validity check so a block/empty page is never mistaken for a live
# session (the old bug: it only checked the URL and silently scraped 0 leads).
_LOGGED_OUT_TITLES = _CF_TITLES + (
    "attention required",
    "access denied",
    "you have been blocked",
)


def _is_cloudflare_page(title: str) -> bool:
    """Return True if the page title matches a Cloudflare challenge (EN or ES)."""
    lower = title.lower()
    return any(t in lower for t in _CF_TITLES)


async def _session_is_valid(page: Page) -> bool:
    """Return True only if we are on a real logged-in panel.

    Hardened against the silent-failure mode where a Cloudflare block or an
    empty shell passed a URL-only check, so the scraper reported "session valid"
    and scraped 0 leads without re-logging-in. This only ADDS rejections (never
    accepts a page the old check rejected), so it cannot cause a spurious
    re-login of a genuinely valid session.
    """
    url = page.url.lower()
    if any(frag in url for frag in ("login", "acceso", "ingresar")):
        return False

    title = (await page.title()).lower()
    if any(t in title for t in _LOGGED_OUT_TITLES):
        return False

    # A logged-out page renders the "Ingresar" login control; a logged-in panel
    # does not. Its presence is a definitive logged-out signal.
    try:
        if await page.locator(BTN_INGRESAR).count() > 0:
            return False
    except Exception:
        pass

    # Reject an empty/error shell (a real panel renders substantial content).
    try:
        text = await page.evaluate("() => (document.body && document.body.innerText) || ''")
    except Exception:
        text = ""
    if len(text.strip()) < 100:
        return False

    return True


async def _wait_for_cloudflare(page: Page, timeout_ms: int = 90_000) -> None:
    """Wait for Cloudflare Turnstile challenge to resolve, if present."""
    await asyncio.sleep(1.5)
    title = await page.title()
    if not _is_cloudflare_page(title):
        return

    logger.info(
        "Cloudflare challenge detected (title={!r}) — waiting up to {}s for "
        "auto-resolve (click the checkbox if running --headful)",
        title, timeout_ms // 1000,
    )

    try:
        await page.wait_for_function(
            """() => {
                const t = document.title.toLowerCase();
                return !t.includes('just a moment') && !t.includes('un momento');
            }""",
            timeout=timeout_ms,
        )
        await page.wait_for_load_state("domcontentloaded")
        await asyncio.sleep(random.uniform(1.5, 3.0))
        logger.info("Cloudflare challenge resolved")
    except Exception as e:
        raise AuthenticationError(
            f"Cloudflare challenge did not resolve within "
            f"{timeout_ms // 1000}s — try running with --headful and clicking "
            f"the checkbox manually. Error: {e}"
        )


# ---------------------------------------------------------------------------
# Core login flow
# ---------------------------------------------------------------------------


async def login(page: Page, settings: Settings) -> None:
    """Perform a fresh login.

    Flow:
      1. Navigate to homepage
      2. Click "Ingresar" button
      3. Fill email
      4. Click "Continuar"
      5. Fill password
      6. Click "Iniciar sesion"
      7. Verify we landed on the panel
    """
    logger.info("Starting login for {}", settings.email)

    # Step 1: Navigate to homepage
    logger.info("Step 1: Navigating to {}", HOME_URL)
    await page.goto(HOME_URL, wait_until="domcontentloaded")
    await _wait_for_cloudflare(page)

    # Step 2: Click "Ingresar"
    logger.info("Step 2: Clicking 'Ingresar' button")
    await asyncio.sleep(random.uniform(1.0, 2.5))
    try:
        await page.wait_for_selector(BTN_INGRESAR, timeout=15_000)
        # The header login button can sit outside the viewport (sticky header,
        # negative y), so a normal click misses. JS click is position-agnostic.
        await page.locator(BTN_INGRESAR).first.evaluate("e => e.click()")
    except Exception as e:
        raise AuthenticationError(f"Could not find/click 'Ingresar' button: {e}")
    await asyncio.sleep(random.uniform(1.0, 2.0))

    # Step 3: Fill email
    logger.info("Step 3: Filling email field")
    try:
        await page.wait_for_selector(INPUT_EMAIL, timeout=15_000)
        await page.fill(INPUT_EMAIL, settings.email)
    except Exception as e:
        raise AuthenticationError(f"Could not find/fill email field: {e}")
    await asyncio.sleep(random.uniform(0.5, 1.5))

    # Step 4: Click "Continuar"
    logger.info("Step 4: Clicking 'Continuar' button")
    try:
        await page.wait_for_selector(BTN_CONTINUAR, timeout=10_000)
        await page.click(BTN_CONTINUAR)
    except Exception as e:
        raise AuthenticationError(f"Could not find/click 'Continuar' button: {e}")
    await asyncio.sleep(random.uniform(1.0, 2.5))

    # Step 5: Fill password
    logger.info("Step 5: Filling password field")
    try:
        await page.wait_for_selector(INPUT_PASSWORD, timeout=15_000)
        await page.fill(INPUT_PASSWORD, settings.password)
    except Exception as e:
        raise AuthenticationError(f"Could not find/fill password field: {e}")
    await asyncio.sleep(random.uniform(0.5, 1.5))

    # Step 6: Click "Iniciar sesion"
    logger.info("Step 6: Clicking 'Iniciar sesion' button")
    try:
        await page.wait_for_selector(BTN_INICIAR_SESION, timeout=10_000)
        await page.click(BTN_INICIAR_SESION)
    except Exception as e:
        raise AuthenticationError(f"Could not find/click 'Iniciar sesion' button: {e}")

    # Wait for post-login navigation to complete.
    await page.wait_for_load_state("domcontentloaded")
    await asyncio.sleep(random.uniform(2.0, 4.0))
    await _wait_for_cloudflare(page)

    # Step 7: Verify login succeeded
    logger.info("Step 7: Verifying login succeeded (current url: {})", page.url)
    if "login" in page.url or "acceso" in page.url:
        raise AuthenticationError(
            "Login failed — still on login page after submitting credentials"
        )
    logger.info("Login successful!")


async def navigate_to_avisos(page: Page) -> None:
    """Navigate to 'Mis avisos' panel after login."""
    logger.info("Step 8: Navigating to 'Mis avisos'")

    # Try clicking the menu item directly first.
    try:
        avisos_link = page.locator(f"{MENU_MIS_AVISOS} a")
        if await avisos_link.count() > 0:
            await avisos_link.click()
            await page.wait_for_load_state("domcontentloaded")
            await asyncio.sleep(random.uniform(1.0, 2.0))
            await _wait_for_cloudflare(page)
            logger.info("Navigated to Mis avisos via menu click")
            return
    except Exception:
        logger.debug("Menu click failed — falling back to direct navigation")

    # Fallback: navigate directly.
    await page.goto(AVISOS_URL, wait_until="domcontentloaded")
    await asyncio.sleep(random.uniform(1.0, 2.0))
    await _wait_for_cloudflare(page)
    logger.info("Navigated to Mis avisos via direct URL")


# ---------------------------------------------------------------------------
# Browser launch
# ---------------------------------------------------------------------------


def _find_chrome() -> Path:
    """Locate the system Chrome binary."""
    env_path = os.environ.get("CHROME_PATH")
    if env_path:
        p = Path(env_path)
        if p.exists():
            return p
    for candidate in _CHROME_CANDIDATES:
        if candidate.exists():
            return candidate
    raise RuntimeError(
        "Chrome not found. Install Google Chrome or set the CHROME_PATH "
        "environment variable."
    )


async def launch_chrome(
    pw: Playwright, *, headless: bool = False
) -> tuple[BrowserContext, subprocess.Popen]:
    """Launch real Chrome with a persistent profile and connect via CDP.

    Unlike Playwright's bundled Chromium, the real Chrome binary does NOT
    expose automation markers (navigator.webdriver, etc.), so Cloudflare
    Turnstile passes without a challenge.

    Returns (context, chrome_process) — caller must terminate the process.
    """
    chrome_path = _find_chrome()
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)

    args = [
        str(chrome_path),
        f"--remote-debugging-port={CDP_PORT}",
        f"--user-data-dir={PROFILE_DIR.resolve()}",
        "--lang=es-MX",
        "--start-maximized",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-blink-features=AutomationControlled",
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
    ]
    if headless:
        args.append("--headless=new")

    # Optional upstream proxy (e.g. a local gost relay forwarding to a
    # residential/mobile proxy). Set CHROME_PROXY to a no-auth proxy URL.
    proxy = os.environ.get("CHROME_PROXY", "").strip()
    if proxy:
        args.append(f"--proxy-server={proxy}")
        logger.info("Chrome using proxy {}", proxy)

    logger.info("Launching Chrome via CDP on port {}", CDP_PORT)
    proc = subprocess.Popen(
        args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    # Give Chrome time to start and open the debug port.
    await asyncio.sleep(4)

    browser = await pw.chromium.connect_over_cdp(f"http://127.0.0.1:{CDP_PORT}")
    context = browser.contexts[0]
    logger.info("Connected to Chrome via CDP")

    return context, proc


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def load_or_login(context: BrowserContext, settings: Settings) -> Page:
    """Ensure the context is authenticated, then navigate to Mis avisos.

    Because we use a persistent browser profile, cookies (including
    Cloudflare cf_clearance and login session) survive between runs
    automatically — no manual storage_state needed.

    Returns the Page object sitting on the avisos panel.

    Raises AuthenticationError on failure.
    """
    page = await context.new_page()

    # Try navigating directly — cookies from previous run may still be valid.
    logger.info("Checking if persistent session is still valid")
    try:
        await page.goto(AVISOS_URL, wait_until="domcontentloaded")
        await _wait_for_cloudflare(page)

        if await _session_is_valid(page):
            logger.info("Persistent session is valid — skipping login")
            return page
        logger.warning(
            "Session not valid (expired / blocked / logged out, url={}) — performing fresh login",
            page.url,
        )
    except Exception as e:
        logger.warning("Session check error ({}): performing fresh login", e)

    # Fresh login.
    await login(page, settings)

    # Navigate to Mis avisos.
    await navigate_to_avisos(page)

    return page
