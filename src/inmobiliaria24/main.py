"""CLI entrypoint for the Inmobiliaria24 scraper.

Owns the browser lifecycle: launches Chrome, authenticates, scrapes leads,
deduplicates, sends to webhook with retry, and reports heartbeat.

Usage:
    python -m inmobiliaria24 [--headful] [--dry-run]

Exit codes:
    0  Success (dry-run valid or scrape completed).
    1  Auth failed, config missing, or unexpected exception.
"""
from __future__ import annotations

import argparse
import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

from loguru import logger
from playwright.async_api import async_playwright

from inmobiliaria24.auth import AuthenticationError, launch_chrome, load_or_login
from inmobiliaria24.config import Settings
from inmobiliaria24.heartbeat import HeartbeatStatus, send_heartbeat
from inmobiliaria24.scraper import scrape_leads
from inmobiliaria24.state import SeenLeads
from inmobiliaria24.webhook import send_leads, _load_local_fallback

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
    parser = argparse.ArgumentParser(
        prog="inmobiliaria24",
        description="Scheduled lead monitor for Inmuebles24 real estate portal",
    )
    parser.add_argument(
        "--headful", action="store_true", default=False,
        help="Run Chrome with a visible browser window (default: headless)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", default=False, dest="dry_run",
        help="Authenticate and validate the session, then exit without scraping",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Async main
# ---------------------------------------------------------------------------


async def async_main(args: argparse.Namespace, settings: Settings) -> int:
    """Run the scraper lifecycle. Returns exit code (0=success, 1=failure)."""
    hb_status = HeartbeatStatus.OK
    leads_found = 0
    new_leads_count = 0
    error_msg = ""

    async with async_playwright() as pw:
        try:
            context, chrome_proc = await launch_chrome(
                pw,
                headless=not args.headful,
                proxy_server=settings.proxy_server,
                proxy_username=settings.proxy_username_mx,
                proxy_password=settings.proxy_pass,
            )
        except Exception as e:
            logger.error("Failed to launch Chrome (proxy issue?): {}", e)
            await send_heartbeat(
                url=settings.heartbeat_url,
                status=HeartbeatStatus.PROXY_ERROR,
                error_message=str(e),
            )
            return 1

        try:
            page = await load_or_login(context, settings)

            if args.dry_run:
                logger.info("Dry run complete — session is valid")
                print(f"Dry run complete — session valid. URL: {page.url}")
                await send_heartbeat(
                    url=settings.heartbeat_url,
                    status=HeartbeatStatus.OK,
                )
                return 0

            # 1. Scrape leads
            all_leads = await scrape_leads(page)
            leads_found = len(all_leads)

            # 2. Deduplicate
            seen = SeenLeads(settings.state_dir)
            new_leads = seen.filter_new(all_leads)
            new_leads_count = len(new_leads)

            logger.info(
                "Leads: {} total, {} new, {} already seen",
                leads_found, new_leads_count, leads_found - new_leads_count,
            )

            if not new_leads:
                logger.info("No new leads — nothing to send")
                print("No new leads this run.")
            else:
                # 3. Check for fallback leads from previous failed runs
                fallback_dir = Path(settings.state_dir) / "fallback"
                old_leads = _load_local_fallback(fallback_dir)
                if old_leads:
                    logger.info("Recovered {} leads from fallback", len(old_leads))
                    new_leads = old_leads + new_leads

                # 4. Add scraped_at timestamp
                ts = datetime.now(timezone.utc).isoformat()
                for lead in new_leads:
                    lead["scraped_at"] = ts

                # 5. Send to webhook
                success = await send_leads(
                    new_leads,
                    webhook_url=settings.webhook_url,
                    fallback_dir=fallback_dir,
                )

                if success:
                    # 6. Mark as seen only after successful send
                    new_ids = [l["lead_id"] for l in new_leads if l.get("lead_id")]
                    seen.mark_seen(new_ids)
                    print(f"Sent {new_leads_count} new leads to webhook")
                else:
                    error_msg = "Webhook delivery failed — saved to fallback"
                    hb_status = HeartbeatStatus.SCRAPE_ERROR

            return 0

        except AuthenticationError as e:
            logger.error("Authentication failed: {}", str(e))
            hb_status = HeartbeatStatus.AUTH_FAILED
            error_msg = str(e)
            return 1

        except Exception as e:
            logger.exception("Unexpected error: {}", str(e))
            hb_status = HeartbeatStatus.SCRAPE_ERROR
            error_msg = str(e)
            return 1

        finally:
            # Always send heartbeat
            await send_heartbeat(
                url=settings.heartbeat_url,
                status=hb_status,
                leads_found=leads_found,
                new_leads=new_leads_count,
                error_message=error_msg,
            )
            await context.close()
            chrome_proc.terminate()
            chrome_proc.wait(timeout=5)
            logger.debug("Chrome process terminated")


# ---------------------------------------------------------------------------
# Synchronous entrypoint
# ---------------------------------------------------------------------------


def main() -> None:
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
