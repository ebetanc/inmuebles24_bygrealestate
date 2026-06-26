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

    proxy = os.environ.get("CHROME_PROXY", "").strip()
    if proxy:
        args.append(f"--proxy-server={proxy}")
        logger.info("Chrome using proxy {}", proxy)

    logger.info("Launching Chrome via CDP on port {}", CDP_PORT)
    proc = subprocess.Popen(
        args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    await asyncio.sleep(4)

    browser = await pw.chromium.connect_over_cdp(f"http://127.0.0.1:{CDP_PORT}")
    context = browser.contexts[0]
    logger.info("Connected to Chrome via CDP")
    return context, proc


async def wait_for_spa(page: Page, timeout_ms: int = 45_000) -> None:
    """Wait for the EasyBroker React SPA to render meaningful content."""
    try:
        await page.wait_for_function(
            "() => (document.body && document.body.innerText || '').trim().length > 80",
            timeout=timeout_ms,
        )
    except Exception:
        # Fall through — callers screenshot + inspect on failure.
        logger.warning("SPA content wait timed out after {}ms", timeout_ms)
    await asyncio.sleep(1.5)


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
