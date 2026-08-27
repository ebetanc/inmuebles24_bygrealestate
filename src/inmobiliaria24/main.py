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
import os
import sys
from datetime import datetime, timezone

from loguru import logger
from playwright.async_api import async_playwright

from inmobiliaria24.auth import AuthenticationError, launch_chrome, load_or_login
from inmobiliaria24.config import Settings
from inmobiliaria24.monitor import check_stale_runs, send_error_alert, send_heartbeat
from inmobiliaria24.scraper import (
    SessionStaleError,
    dump_lead_controls,
    enrich_property_public_ids,
    extract_leads_list,
    extract_property_public_id_map,
    mark_lead_contacted,
    scrape_pendiente_leads,
    send_to_webhook,
)
from inmobiliaria24.state import StateStore
from inmobiliaria24.supa import log_scrape_run

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
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Only scrape and send the first N Pendiente leads (0 = all). Useful for a single-lead test.",
    )
    parser.add_argument(
        "--mark-test",
        action="store_true",
        default=False,
        dest="mark_test",
        help=(
            "Test: find the first Pendiente lead in the inbox and set it to "
            "Contactado via the status dropdown (forces MARK_CONTACTED for this "
            "run; no webhook/auction). Proves the status-change works, then exit."
        ),
    )
    parser.add_argument(
        "--inspect-status",
        action="store_true",
        default=False,
        dest="inspect_status",
        help=(
            "Diagnostic: open the inbox, find the per-row 'Pendiente' status "
            "dropdown and dump its menu options (e.g. 'Contactado') to "
            "logs/status_dropdown.json. Read-only. Then exit."
        ),
    )
    parser.add_argument(
        "--inspect-controls",
        nargs="?",
        const="",
        default=None,
        metavar="LEAD_ID",
        help=(
            "Diagnostic: open a lead detail page and dump every clickable control "
            "to logs/lead_controls_<id>.json (to find the 'mark Contactado' selector). "
            "Pass a lead_id, or omit it to use the first Pendiente lead. Then exit."
        ),
    )
    return parser.parse_args()


async def _run_v3_contactado(page, leads: list[dict]) -> set[str]:
    """Mark Contactado per durable capture, returning verified lead IDs."""
    from inmobiliaria24.supa import (
        claim_v3_i24_contact_effects,
        finish_v3_i24_contact_effect,
    )

    by_lead_id = {
        str(lead.get("lead_id") or "").strip(): lead
        for lead in leads
        if str(lead.get("lead_id") or "").strip()
    }
    verified: set[str] = set()
    for contact in await claim_v3_i24_contact_effects():
        lead_id = str(contact.get("i24_lead_id") or "").strip()
        if not lead_id:
            await finish_v3_i24_contact_effect(
                int(contact["capture_event_id"]), str(contact["lease_token"]),
                success=False, error_code="missing_i24_lead_id",
            )
            continue
        # The detail URL is keyed only by lead_id and can reconcile an already
        # Contactado lead after a crash, even when it no longer appears in the
        # Pendiente scrape. The durable route payload lives in Supabase.
        lead_payload = by_lead_id.get(lead_id, {"lead_id": lead_id})
        evidence: dict = {}
        contacted = False
        try:
            contacted = await mark_lead_contacted(
                page, lead_payload, evidence=evidence
            )
        except Exception as exc:
            evidence["error_code"] = "portal_interaction_failed"
            logger.warning("V3 Contactado failed for lead {}: {}", lead_id, exc)
        finished = await finish_v3_i24_contact_effect(
            int(contact["capture_event_id"]), str(contact["lease_token"]),
            success=contacted,
            error_code=evidence.get("error_code"),
        )
        if contacted and finished:
            verified.add(lead_id)
    return verified


async def _run_v3_route_dispatch(settings, store: StateStore) -> list[dict]:
    """Deliver durable post-Contactado captures, even after portal removal."""
    from inmobiliaria24.supa import (
        claim_v3_route_dispatches,
        finish_v3_route_dispatch,
    )

    dispatched: list[dict] = []
    for claim in await claim_v3_route_dispatches():
        capture_event_id = int(claim["capture_event_id"])
        lease_token = str(claim["lease_token"])
        context = claim.get("offer_context")
        payload = dict(context) if isinstance(context, dict) else {}
        payload.update({
            "lead_id": str(claim.get("i24_lead_id") or payload.get("lead_id") or ""),
            "capture_event_id": capture_event_id,
            "opportunity_id": claim.get("opportunity_id"),
            "disposition": claim.get("disposition"),
            "property_public_id": claim.get("property_public_id") or payload.get("property_public_id"),
            "contactado_status": "verified",
            "source": "inmuebles24",
        })
        if not payload["lead_id"]:
            await finish_v3_route_dispatch(
                capture_event_id, lease_token, success=False,
                error_code="missing_i24_lead_id",
            )
            continue
        try:
            await send_to_webhook(
                [payload],
                webhook_url=settings.webhook_url,
                webhook_token=settings.webhook_token,
                idempotency_key=f"v3-route:{capture_event_id}",
            )
        except Exception as exc:
            await finish_v3_route_dispatch(
                capture_event_id, lease_token, success=False,
                error_code="webhook_dispatch_failed",
            )
            logger.warning("V3 route dispatch failed for capture {}: {}", capture_event_id, exc)
            continue
        if await finish_v3_route_dispatch(
            capture_event_id, lease_token, success=True
        ):
            store.mark_seen([payload])
            dispatched.append(payload)
        else:
            logger.warning("V3 route dispatch lease lost for capture {}", capture_event_id)
    return dispatched


# ---------------------------------------------------------------------------
# Async main
# ---------------------------------------------------------------------------


async def async_main(args: argparse.Namespace, settings: Settings) -> int:
    """Run the scraper lifecycle. Returns an integer exit code (0=success, 1=failure)."""
    with StateStore(settings.state_db_path) as store:
        run_id = store.start_run()
        started_at = datetime.now(timezone.utc)
        total = 0
        new_count = 0
        status = "ok"
        error_message: str | None = None

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
                    status = "dry_run"
                    store.finish_run(run_id, status="dry_run")
                    return 0

                # Test: mark the first live Pendiente lead Contactado via the
                # status dropdown (forces the gate on for this run; no webhook).
                if args.mark_test:
                    leads = await extract_leads_list(page)
                    target = next(
                        (l for l in leads if l.get("lead_id") and l.get("status") == "Pendiente"),
                        None,
                    )
                    if not target:
                        print("No Pendiente lead with an id found to mark-test.")
                        store.finish_run(run_id, status="dry_run")
                        return 1
                    os.environ["MARK_CONTACTED"] = "1"
                    print(f"Mark-test target: {target.get('name')!r} lead_id={target.get('lead_id')} tab={target.get('source_tab')}")
                    ok = await mark_lead_contacted(page, target)
                    print(f"Mark-test result: {'CONTACTADO OK' if ok else 'FAILED/UNVERIFIED'} (lead_id={target.get('lead_id')})")
                    status = "dry_run"
                    store.finish_run(run_id, status="dry_run")
                    return 0 if ok else 1

                # Diagnostic: inspect the inbox-row status dropdown + its menu.
                if args.inspect_status:
                    from inmobiliaria24.scraper import dump_status_dropdown
                    res = await dump_status_dropdown(page)
                    print(
                        f"Status dropdown: found in tab {res.get('found_tab')!r}, "
                        f"{len(res.get('menu', []))} menu option(s) -> logs/status_dropdown.json"
                    )
                    status = "dry_run"
                    store.finish_run(run_id, status="dry_run")
                    return 0

                # Diagnostic: dump the clickable controls on a lead detail page so
                # we can identify the real "mark as Contactado" selector. Read-only.
                if args.inspect_controls is not None:
                    lead_id = args.inspect_controls
                    if not lead_id:
                        leads = await extract_leads_list(page)
                        lead_id = next(
                            (l.get("lead_id") for l in leads if l.get("lead_id")), ""
                        )
                        if not lead_id:
                            print("No Pendiente lead with an id found to inspect.")
                            status = "dry_run"
                            store.finish_run(run_id, status="dry_run")
                            return 1
                    controls = await dump_lead_controls(page, lead_id)
                    print(f"Dumped {len(controls)} controls for lead {lead_id} -> logs/lead_controls_{lead_id}.json")
                    status = "dry_run"
                    store.finish_run(run_id, status="dry_run")
                    return 0

                # Mis avisos exposes both the Inmuebles24 listing ID and the
                # EB advertiser code; lead detail pages expose only the first.
                conflicting_listing_ids: set[str] = set()
                try:
                    live_property_map = await extract_property_public_id_map(
                        page, conflicts_out=conflicting_listing_ids
                    )
                    store.delete_property_public_id_mappings(conflicting_listing_ids)
                    store.upsert_property_public_id_map(live_property_map)
                except Exception as e:
                    logger.warning("Property mapping refresh failed safely: {}", str(e))
                    live_property_map = {}

                # Scrape all Pendiente leads (with session recovery).
                try:
                    all_leads = await scrape_pendiente_leads(page, limit=args.limit)
                except SessionStaleError:
                    logger.warning("Session stale — re-authenticating and retrying")
                    from inmobiliaria24.auth import login, navigate_to_avisos

                    await login(page, settings)
                    await navigate_to_avisos(page)
                    all_leads = await scrape_pendiente_leads(page, limit=args.limit)
                total = len(all_leads)
                property_map = store.property_public_id_map()
                property_map.update(live_property_map)
                enrich_property_public_ids(all_leads, property_map)

                # One-shot diagnostic: when INSPECT_ON_PENDIENTE is set, dump the
                # clickable controls of the first real Pendiente lead so we can
                # confirm the chat composer + "Enviar" selectors on a live lead
                # (read-only; piggybacks on the normal run, no extra proxy data).
                if os.environ.get("INSPECT_ON_PENDIENTE", "").strip() and all_leads:
                    insp_id = next(
                        (l.get("lead_id") for l in all_leads if l.get("lead_id")), ""
                    )
                    if insp_id:
                        try:
                            await dump_lead_controls(page, insp_id)
                        except Exception as e:
                            logger.warning("INSPECT_ON_PENDIENTE dump failed: {}", e)

                v3_enabled = bool(getattr(settings, "lead_routing_v3_enabled", False))
                if v3_enabled:
                    # V3 durable intake is the first state transition. No
                    # webhook or portal effect runs before every lead has an
                    # idempotent capture result.
                    from inmobiliaria24.supa import v3_intake_lead

                    for lead in all_leads:
                        lead_id = str(lead.get("lead_id") or "").strip()
                        if not lead_id:
                            continue
                        try:
                            await v3_intake_lead(settings, lead)
                        except Exception as exc:
                            logger.warning("V3 intake failed for lead {}: {}", lead_id, exc)

                    await _run_v3_contactado(page, all_leads)
                    # The route queue is durable and contains the full lead
                    # context. It remains the source of truth after Contactado
                    # removes a lead from the next portal scrape.
                    new_leads = await _run_v3_route_dispatch(settings, store)
                    new_count = len(new_leads)
                else:
                    # V2 compatibility path. Kept behind the explicit V3 flag.
                    new_leads = store.filter_new(all_leads)
                    new_count = len(new_leads)
                    if new_leads:
                        await send_to_webhook(
                            new_leads,
                            webhook_url=settings.webhook_url,
                            webhook_token=settings.webhook_token,
                        )
                        store.mark_seen(new_leads)
                    else:
                        logger.info("No new leads to send — all already pushed")

                # V2 portal side effect. V3 has already completed its per-capture
                # Contactado gate above and must never use the legacy RPC.
                if not v3_enabled and os.environ.get("MARK_CONTACTED", "").strip().lower() in ("1", "true", "yes"):
                    from inmobiliaria24.supa import (
                        claim_pending_i24_contacts,
                        finish_i24_contact_attempt,
                        validate_i24_contact_attempt,
                    )

                    for contact in await claim_pending_i24_contacts():
                        try:
                            opportunity_id = int(contact["opportunity_id"])
                            lease_token = str(contact["lease_token"])
                            if not await validate_i24_contact_attempt(opportunity_id, lease_token):
                                await finish_i24_contact_attempt(
                                    opportunity_id, lease_token, success=False,
                                    error_code="assignment_changed_before_portal",
                                )
                                logger.warning("Skipping stale i24 Contactado lease for opportunity {}", opportunity_id)
                                continue
                            evidence: dict = {}
                            contacted = await mark_lead_contacted(
                                page,
                                {"lead_id": contact["i24_lead_id"]},
                                evidence=evidence,
                            )
                            await finish_i24_contact_attempt(
                                opportunity_id,
                                lease_token,
                                success=contacted,
                                error_code=evidence.get("error_code"),
                                screenshot_path=evidence.get("screenshot_path"),
                            )
                        except Exception as e:
                            logger.warning("i24 Contactado task failed safely: {}", str(e))

                # V2-only: V3 never writes an advisor note in Inmuebles24.
                if not v3_enabled:
                    try:
                        from inmobiliaria24.notes import write_pending_for_page

                        notes_written = await write_pending_for_page(page)
                        if notes_written:
                            logger.info("Wrote {} i24 advisor note(s)", notes_written)
                    except Exception as e:
                        logger.warning("i24 note pass failed: {}", str(e))

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
                error_message = str(e)
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
                error_message = str(e)
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
                # Mirror this run to Supabase scrape_logs so the dashboard sees
                # every 15-min run, including empty ones. Never raises.
                await log_scrape_run(
                    started_at=started_at,
                    status=status,
                    total=total,
                    new=new_count,
                    error_message=error_message,
                )
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
