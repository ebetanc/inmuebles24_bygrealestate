"""CLI entrypoint for the Inmobiliaria24 scraper.

Owns the browser lifecycle: launches Chromium, delegates authentication to
auth.py, and coordinates scraper phases (Phase 2+).

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

from inmobiliaria24.auth import AuthenticationError, load_or_login
from inmobiliaria24.config import Settings

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
        help="Run Chromium with a visible browser window (default: headless)",
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
        browser = await pw.chromium.launch(
            headless=not args.headful,
            args=["--no-sandbox", "--disable-dev-shm-usage"],
        )
        try:
            context = await load_or_login(browser, settings)
            try:
                if args.dry_run:
                    logger.info("Dry run complete — session is valid")
                    print("Dry run complete — session is valid")
                    return 0
                # Phase 2+ will add scraper call here
                return 0
            finally:
                await context.close()
        except AuthenticationError as e:
            logger.error("Authentication failed: {}", str(e))
            return 1
        except Exception as e:
            logger.exception("Unexpected error: {}", str(e))
            return 1
        finally:
            await browser.close()


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
