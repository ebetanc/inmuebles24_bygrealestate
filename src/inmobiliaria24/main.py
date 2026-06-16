"""CLI entrypoint for the Inmobiliaria24 scraper.

Owns the browser lifecycle: launches real Chrome via CDP, delegates
authentication to auth.py, runs extraction with deduplication, and
sends alerts on errors.

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
from inmobiliaria24.monitor import check_stale_runs, send_error_alert, send_heartbeat
from inmobiliaria24.scraper import (
    SessionStaleError,
    scrape_pendiente_leads,
    send_to_webhook,
)
from inmobiliaria24.state import StateStore

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
    retention="7 days",
    format="{time:YYYY-MM-DD HH:mm:ss} | {level} | {message}",
)
# Structured JSON log for production monitoring / log aggregation.
logger.add(
    "logs/run.json",
    level="INFO",
    rotation="10 MB",
    retention="7 days",
    serialize=True,
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
    with StateStore(settings.state_db_path) as store:
        run_id = store.start_run()
        total = 0
        new_count = 0
        status = "ok"

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
                    store.finish_run(run_id, status="dry_run")
                    return 0

                # Scrape all Pendiente leads (with session recovery).
                try:
                    all_leads = await scrape_pendiente_leads(page)
                except SessionStaleError:
                    logger.warning("Session stale — re-authenticating and retrying")
                    from inmobiliaria24.auth import login, navigate_to_avisos

                    await login(page, settings)
                    await navigate_to_avisos(page)
                    all_leads = await scrape_pendiente_leads(page)
                total = len(all_leads)

                # Dedup: only send leads we have not already pushed. A lead stays
                # Pendiente on the portal until an agent attends it, so without
                # this filter the same lead would be re-sent on every run.
                new_leads = store.filter_new(all_leads)
                new_count = len(new_leads)

                # Send only new leads, then mark them seen. Marking AFTER a
                # successful POST means a webhook failure is retried next run
                # instead of being silently dropped.
                if new_leads:
                    await send_to_webhook(
                        new_leads, webhook_url=settings.webhook_url
                    )
                    store.mark_seen(new_leads)
                else:
                    logger.info("No new leads to send — all already pushed")

                print(f"Scraped {total} Pendiente leads, {new_count} new")
                for lead in new_leads:
                    print(f"  NEW: {lead.get('name', '?')} (lead_id={lead.get('lead_id', '?')})")

                # Send heartbeat.
                await send_heartbeat(
                    settings.telegram_bot_token,
                    settings.telegram_alert_chat_id,
                    total_leads=total,
                    new_leads=new_count,
                )

                store.finish_run(run_id, total=total, new=new_count, status="ok")

                # Check for stale-run condition (alert if no success in 24h).
                await check_stale_runs(
                    settings.telegram_bot_token,
                    settings.telegram_alert_chat_id,
                    store.last_successful_run(),
                )

                return 0

            except AuthenticationError as e:
                status = "auth_error"
                logger.error("Authentication failed: {}", str(e))
                print(f"AUTH FAILED: {e}")
                await send_error_alert(
                    settings.telegram_bot_token,
                    settings.telegram_alert_chat_id,
                    str(e),
                    context="Authentication phase",
                )
                store.finish_run(run_id, status=status)
                return 1

            except Exception as e:
                status = "error"
                logger.exception("Unexpected error: {}", str(e))
                await send_error_alert(
                    settings.telegram_bot_token,
                    settings.telegram_alert_chat_id,
                    str(e),
                    context="Scraper run",
                )
                store.finish_run(run_id, total=total, new=new_count, status=status)
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
