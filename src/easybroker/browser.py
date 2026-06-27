"""Chrome launch + SPA helpers for the EasyBroker bot.

Mirrors inmobiliaria24.auth.launch_chrome but uses a SEPARATE persistent
profile and CDP port so the EB bot and the Inmuebles24 scraper can run side by
side on the Pi without clobbering each other's session or debug port.
"""
from __future__ import annotations

import asyncio
import os
import subprocess
from pathlib import Path

from loguru import logger
from playwright.async_api import BrowserContext, Page, Playwright

# Separate profile + port from the Inmuebles24 scraper (which uses
# .session/chrome-profile and port 9222).
PROFILE_DIR = Path(".session/eb-chrome-profile")
CDP_PORT = 9223

_CHROME_CANDIDATES = [
    Path("/usr/bin/google-chrome"),
    Path("/usr/bin/google-chrome-stable"),
    Path("/usr/bin/chromium-browser"),
    Path("/usr/bin/chromium"),
    Path("C:/Program Files/Google/Chrome/Application/chrome.exe"),
    Path("C:/Program Files (x86)/Google/Chrome/Application/chrome.exe"),
]


def _find_chrome() -> Path:
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
    """Launch real Chrome with the EB persistent profile, connect via CDP.

    Returns (context, chrome_process) — the caller must terminate the process.
    """
    chrome_path = _find_chrome()
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)

    # Self-heal: a previous timeout-killed run can orphan a Chrome bound to CDP
    # port 9223 (xvfb-run does not forward SIGTERM to the grandchild), which the
    # next connect_over_cdp would attach to — stuck on a blank page. Kill any
    # stale EB Chrome (matched by its unique 9223 flag; the scraper's 9222 is
    # safe) and drop the profile lock before launching a fresh one.
    try:
        # NOTE the [r] in the pattern: pkill -f matches against full command
        # lines, INCLUDING this pkill's own argv. A literal
        # "remote-debugging-port=9223" would self-match and kill our own parent
        # shell. "[r]emote-…" matches the same Chrome cmdline but not the pattern
        # string itself (classic grep-avoiding-itself trick).
        subprocess.run(
            ["pkill", "-9", "-f", f"[r]emote-debugging-port={CDP_PORT}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
        for lock in PROFILE_DIR.glob("Singleton*"):
            lock.unlink(missing_ok=True)
        await asyncio.sleep(1.0)
    except Exception as e:
        logger.warning("stale-Chrome cleanup skipped: {}", e)

    args = [
        str(chrome_path),
        f"--remote-debugging-port={CDP_PORT}",
        f"--user-data-dir={PROFILE_DIR.resolve()}",
        "--lang=es-MX",
        # Force a DESKTOP viewport. Under xvfb --start-maximized yields a narrow
        # window and EB renders its MOBILE layout (collapsed action bar, hidden
        # desktop search) which breaks the validated desktop selectors. An
        # explicit wide window keeps EB on the desktop layout.
        "--window-size=1920,1080",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-blink-features=AutomationControlled",
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
    ]
    if headless:
        args.append("--headless=new")

    # Use a DEDICATED proxy var, NOT the scraper's CHROME_PROXY: the Inmuebles24
    # scraper sets CHROME_PROXY to a Mexico mobile proxy (needed to beat that
    # portal's Cloudflare) which is slow/flaky and metered. EB reaches fine from
    # the host's own IP, so EB runs direct unless EB_CHROME_PROXY is set explicitly.
    proxy = os.environ.get("EB_CHROME_PROXY", "").strip()
    if proxy:
        args.append(f"--proxy-server={proxy}")
        logger.info("Chrome using proxy {}", proxy)
    else:
        logger.info("Chrome running WITHOUT proxy (EB reaches direct)")

    logger.info("Launching Chrome via CDP on port {}", CDP_PORT)
    proc = subprocess.Popen(
        args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    await asyncio.sleep(4)

    browser = await pw.chromium.connect_over_cdp(f"http://127.0.0.1:{CDP_PORT}")
    context = browser.contexts[0]
    logger.info("Connected to Chrome via CDP")
    return context, proc


async def wait_for_spa(page: Page, timeout_ms: int = 30_000) -> None:
    """Wait for the EasyBroker React SPA to render meaningful content.

    Polls document body length from Python (re-evaluating each second) instead of
    page.wait_for_function: when EB does a client-side redirect (e.g. probing the
    login URL while already authenticated → /manager), the page execution context
    is destroyed mid-evaluation. wait_for_function stalls for the full timeout on
    that; this loop just catches the error and retries, surviving the redirect."""
    deadline = timeout_ms
    step = 1000
    while deadline > 0:
        try:
            await page.wait_for_load_state("domcontentloaded")
            length = await page.evaluate(
                "() => (document.body && document.body.innerText || '').trim().length"
            )
            if length and length > 80:
                await asyncio.sleep(1.0)
                return
        except Exception:
            pass  # execution context destroyed during a redirect — retry
        await asyncio.sleep(step / 1000)
        deadline -= step
    logger.warning("SPA content wait timed out after {}ms", timeout_ms)


async def screenshot(page: Page, label: str) -> str | None:
    """Capture a full-page screenshot for debugging. Returns path or None."""
    from datetime import datetime, timezone

    logs = Path("logs")
    logs.mkdir(exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    filepath = logs / f"eb_{label}_{ts}.png"
    try:
        await page.screenshot(path=str(filepath), full_page=True)
        logger.info("Screenshot saved to {}", filepath)
        return str(filepath)
    except Exception as e:
        logger.warning("Failed to capture screenshot: {}", e)
        return None
