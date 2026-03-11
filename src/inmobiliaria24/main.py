"""CLI entrypoint for the Inmobiliaria24 scraper.

Owns the browser lifecycle: launches Playwright Chromium, delegates
authentication to auth.py, and coordinates scraper phases (Phase 2+).

Usage:
    python -m inmobiliaria24 [--headful] [--dry-run]

Exit codes:
    0  Session valid; dry-run completed or scraper work completed.
    1  Auth failed, configuration missing, or unexpected exception.
"""
from __future__ import annotations

import argparse
import asyncio
import sys

from loguru import logger
from playwright.async_api import async_playwright

from inmobiliaria24.auth import AuthenticationError, launch_chrome, load_or_login
from inmobiliaria24.config import Settings
from inmobiliaria24.scraper import scrape_and_send

# ---------------------------------------------------------------------------
# Logging configuration
# ---------------------------------------------------------------------------

logger.remove()
logger.add(
    sys.stderr,
    level="INFO",
    format="{time:YYYY-MM-DD HH:mm:ss} | {level} | {message}",
)
logger.add(
    "logs/run.log",
    level="DEBUG",
    rotation="10 MB",
    retention="14 days",
    format="{time:YYYY-MM-DD HH:mm:ss} | {level} | {message}",
)


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def _parse_args() -> argparse.Namespace:
    """Parse and return CLI arguments."""
    parser = argparse.ArgumentParser(
        prog="inmobiliaria24",
        description="Scheduled lead monitor for Inmuebles24 real estate portal",
    )
    parser.add_argument(
        "--headful",
        action="store_true",
        default=False,
        help="Run Chrome with a visible browser window (default: headless)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        dest="dry_run",
        help="Authenticate and validate the session, then exit without running extraction",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Async main
# ---------------------------------------------------------------------------


async def async_main(args: argparse.Namespace, settings: Settings) -> int:
    """Run the scraper lifecycle. Returns an integer exit code (0=success, 1=failure)."""
    async with async_playwright() as pw:
        context, chrome_proc = await launch_chrome(
            pw, headless=not args.headful
        )
        try:
            page = await load_or_login(context, settings)
            if args.dry_run:
                logger.info("Dry run complete — session is valid, on Mis avisos")
                print("Dry run complete — session is valid, on Mis avisos")
                print(f"Final URL: {page.url}")
                return 0

            # Scrape Pendiente leads from Interesados inbox.
            leads = await scrape_and_send(page)
            print(f"Sent {len(leads)} Pendiente leads to webhook")
            for lead in leads:
                print(f"  - {lead.get('name', '?')} (lead_id={lead.get('lead_id', '?')}, listing={lead.get('listing_id', '?')})")
            return 0
        except AuthenticationError as e:
            logger.error("Authentication failed: {}", str(e))
            print(f"AUTH FAILED: {e}")
            return 1
        except Exception as e:
            logger.exception("Unexpected error: {}", str(e))
            return 1
        finally:
            await context.close()
            chrome_proc.terminate()
            chrome_proc.wait(timeout=5)
            logger.debug("Chrome process terminated")


# ---------------------------------------------------------------------------
# Synchronous entrypoint
# ---------------------------------------------------------------------------


def main() -> None:
    """Synchronous entrypoint registered in pyproject.toml scripts."""
    args = _parse_args()
    try:
        settings = Settings.load()
    except ValueError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        sys.exit(1)

    exit_code = asyncio.run(async_main(args, settings))
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
