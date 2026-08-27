"""CLI for the EasyBroker Buzón bot.

Usage:
    python -m easybroker [options]   # headful by default (EB blocks headless)

Modes:
    (default)            Correlate assigned I24 leads, then poll Supabase and
                         for each exact EasyBroker request,
                         set the Buzón request to Atendida + add the agent note,
                         then flip eb_marked_attended. No-op until EB_MARK_ATTENDED=1.
    --inspect-login      Dump the EB login form controls (read-only). Then exit.
    --inspect-buzon [PH] Open the Buzón (optionally select phone PH) and dump the
                         action-bar / status-menu / note-modal controls. Then exit.
    --once REQUEST_ID    Attend exactly one lead by exact EasyBroker request ID.
                         Forces EB_MARK_ATTENDED for this run; does not touch Supabase.
    --dry-run            Log in, verify session, then exit.

Exit codes: 0 success, 1 failure.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys

from loguru import logger
from playwright.async_api import async_playwright

from easybroker.auth import AuthenticationError, dump_login_form, load_or_login
from easybroker.browser import launch_chrome
from easybroker.config import EBSettings
from easybroker.inbox import attend_lead, dump_buzon
from easybroker.supa import (
    claim_v3_easybroker_effects,
    finish_v3_easybroker_effect,
    fetch_pending_attend,
    finish_attend_attempt,
    list_pending_attend,
    reconcile_i24_easybroker_requests,
)

logger.remove()
logger.add(sys.stderr, level="INFO", format="{time:YYYY-MM-DD HH:mm:ss} | {level} | {message}")
logger.add("logs/eb_run.log", level="DEBUG", rotation="10 MB", retention="7 days",
           format="{time:YYYY-MM-DD HH:mm:ss} | {level} | {message}")


async def _run_v3_effect_worker(settings, page, *, limit: int = 20) -> tuple[int, bool]:
    """Execute one request-level V3 effect step with exact-request evidence.

    One lease handles one step per invocation. This deliberately lets the
    database release a lease after recording the note before a later claim
    performs Atendida, so status can never outrun durable note evidence.
    """
    try:
        claims = await claim_v3_easybroker_effects(settings, limit=limit)
    except Exception as exc:
        logger.warning("EasyBroker V3 effect claim failed: {}", exc)
        return 0, True

    completed = 0
    failed = False
    for claim in claims:
        request_id = int(claim["eb_request_id"])
        responsible = str(claim.get("responsible_first_name") or "").strip()
        lease_token = str(claim["lease_token"])
        note_text = f"RESPONSABLE: {responsible}"

        if claim.get("note_due"):
            result = await attend_lead(
                page,
                request_id=request_id,
                agent_name=responsible,
                note_text=note_text,
                note_done=False,
                status_done=True,
                allow_legacy_note=False,
            )
            note_ok = bool(result.get("found") and result.get("note_ok"))
            evidence = {
                "eb_request_id": str(request_id),
                "note": note_text,
                "note_written": bool(result.get("note_changed")),
                "reconciled_existing": bool(note_ok and not result.get("note_changed")),
            }
            try:
                saved = await finish_v3_easybroker_effect(
                    settings,
                    request_id=request_id,
                    lease_token=lease_token,
                    step="note",
                    ok=note_ok,
                    evidence=evidence,
                )
                if not saved.get("ok"):
                    failed = True
            except Exception as exc:
                logger.warning("EasyBroker V3 note evidence failed for {}: {}", request_id, exc)
                failed = True
            continue

        if claim.get("attended_due"):
            result = await attend_lead(
                page,
                request_id=request_id,
                agent_name=responsible,
                note_text=note_text,
                note_done=True,
                status_done=False,
                allow_legacy_note=False,
            )
            status_ok = bool(result.get("found") and result.get("status_ok"))
            evidence = {
                "eb_request_id": str(request_id),
                "status": "Atendida",
                "status_changed": bool(result.get("status_changed")),
            }
            try:
                saved = await finish_v3_easybroker_effect(
                    settings,
                    request_id=request_id,
                    lease_token=lease_token,
                    step="attended",
                    ok=status_ok,
                    evidence=evidence,
                )
                if saved.get("ok"):
                    completed += 1
                else:
                    failed = True
            except Exception as exc:
                logger.warning("EasyBroker V3 Atendida evidence failed for {}: {}", request_id, exc)
                failed = True

    return completed, failed


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="easybroker", description="EasyBroker Buzón attend bot")
    # EB's WAF/anti-bot serves blank/403 to HEADLESS Chrome — it must run HEADFUL
    # (under xvfb on a headless host). So headful is the DEFAULT here (unlike the
    # Inmuebles24 scraper). --headless is an escape hatch, not for normal use.
    p.add_argument("--headless", action="store_true", default=False,
                   help="Run Chrome headless (DO NOT use for EB — its WAF blocks headless; default is headful)")
    p.add_argument("--dry-run", action="store_true", dest="dry_run", default=False,
                   help="Log in, verify session, then exit")
    p.add_argument("--inspect-login", action="store_true", dest="inspect_login", default=False,
                   help="Dump the EB login form controls and exit (read-only)")
    p.add_argument("--inspect-buzon", nargs="?", const="", default=None, metavar="PHONE",
                   dest="inspect_buzon",
                   help="Dump Buzón controls (optionally selecting PHONE) and exit (read-only)")
    p.add_argument("--once", default=None, metavar="REQUEST_ID",
                   help="Attend exactly one lead by exact EasyBroker request ID. Forces the gate on.")
    p.add_argument("--agent", default="asesor", help="Agent name for --once note")
    p.add_argument("--note", default=None, help="Override the note text for --once")
    return p.parse_args()


async def async_main(args: argparse.Namespace) -> int:
    # --inspect-login does not need Supabase, only EB creds.
    try:
        settings = EBSettings.load()
    except ValueError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        return 1

    async with async_playwright() as pw:
        context, chrome_proc = await launch_chrome(pw, headless=args.headless)
        try:
            if args.inspect_login:
                page = await context.new_page()
                controls = await dump_login_form(page)
                print(f"Dumped {len(controls)} login controls -> logs/eb_login_form.json")
                return 0

            page = await load_or_login(context, settings)

            if args.dry_run:
                print(f"Dry run OK — EB session valid (url={page.url})")
                return 0

            if args.inspect_buzon is not None:
                phone = args.inspect_buzon or None
                res = await dump_buzon(page, phone)
                print(f"Buzón dump: selected={res['selected']}, {res['count']} controls "
                      f"-> logs/eb_buzon_controls.json")
                return 0

            if args.once:
                os.environ["EB_MARK_ATTENDED"] = "1"
                res = await attend_lead(page, request_id=args.once, agent_name=args.agent,
                                        note_text=args.note)
                print(f"--once {args.once}: {res}")
                return 0 if (res["status_ok"] and res["note_ok"]) else 1

            # Default: poll + attend each pending EB lead.
            gate = os.environ.get("EB_MARK_ATTENDED", "").strip() == "1"
            reconcile_failed = False
            if settings.v3_inbox_enabled:
                # V3 ingestion/correlation is durable and idempotent. The
                # external EasyBroker mutations remain behind the existing
                # explicit gate, preserving the V2 safe-mode behavior.
                reconcile_failed = await reconcile_i24_easybroker_requests(settings) is None
                if not gate:
                    print("EasyBroker V3 inbox reconciled; EB_MARK_ATTENDED!=1 — effect worker paused.")
                    return 1 if reconcile_failed else 0
                completed, effects_failed = await _run_v3_effect_worker(settings, page)
                print(f"V3 EasyBroker effects completed: {completed}; failures: {int(effects_failed)}")
                return 1 if (reconcile_failed or effects_failed) else 0
            if gate:
                reconcile_failed = await reconcile_i24_easybroker_requests(settings) is None
            leads = (await fetch_pending_attend(settings) if gate
                     else await list_pending_attend(settings))
            if not leads:
                print("No EB leads pending Atendida + note.")
                return 1 if reconcile_failed else 0
            if not gate:
                print(f"{len(leads)} EB lead(s) pending, but EB_MARK_ATTENDED!=1 — dry listing only:")
                for l in leads:
                    print(
                        f"  conversation={l.get('conversation_id')} "
                        f"request={l.get('eb_contact_id')} -> {l.get('agent_name')}"
                    )
                return 0

            attended = 0
            for l in leads:
                res = await attend_lead(
                    page, request_id=l["eb_contact_id"], phone=l["lead_phone"],
                    agent_name=l["agent_name"], note_done=l["eb_note_added"],
                    status_done=l["eb_marked_attended"],
                    note_text=f"RESPONSABLE: {l['agent_name']}",
                )
                error_code = None
                if not res["found"]:
                    error_code = "request_not_found"
                elif not res["note_ok"]:
                    error_code = "note_failed"
                elif not res["status_ok"]:
                    error_code = "status_failed"
                evidence_ok = await finish_attend_attempt(
                    settings, l["conversation_id"], l["lease_token"],
                    note_ok=res["note_ok"], status_ok=res["status_ok"],
                    error_code=error_code,
                )
                if res["status_ok"] and res["note_ok"] and evidence_ok:
                    attended += 1
                elif not evidence_ok:
                    logger.warning(
                        "EasyBroker lease expired or evidence persistence failed for {}",
                        l["conversation_id"],
                    )
                elif not res["found"]:
                    logger.warning(
                        "EasyBroker request {} not found; preserving pending evidence for retry",
                        l.get("eb_contact_id"),
                    )
                else:
                    logger.warning(
                        "Conversation {} not fully attended: found={} note_ok={} status_ok={}",
                        l.get("conversation_id"), res["found"], res["note_ok"], res["status_ok"],
                    )
            print(f"Attended {attended}/{len(leads)} EB lead(s)")
            return 1 if reconcile_failed else 0

        except AuthenticationError as e:
            print(f"AUTH FAILED: {e}", file=sys.stderr)
            return 1
        except Exception as e:
            logger.exception("Unexpected error: {}", str(e))
            print(f"ERROR: {e}", file=sys.stderr)
            return 1
        finally:
            await context.close()
            chrome_proc.terminate()
            try:
                chrome_proc.wait(timeout=5)
            except Exception:
                pass


def main() -> None:
    args = _parse_args()
    sys.exit(asyncio.run(async_main(args)))


if __name__ == "__main__":
    main()
