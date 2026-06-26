"""CLI for the EasyBroker Buzón bot.

Usage:
    python -m easybroker [--headful] [options]

Modes:
    (default)            Poll Supabase for assigned EB leads and, for each,
                         set the Buzón request to Atendida + add the agent note,
                         then flip eb_marked_attended. No-op until EB_MARK_ATTENDED=1.
    --inspect-login      Dump the EB login form controls (read-only). Then exit.
    --inspect-buzon [PH] Open the Buzón (optionally select phone PH) and dump the
                         action-bar / status-menu / note-modal controls. Then exit.
    --once PHONE         Attend exactly one lead by phone (agent via --agent).
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
from easybroker.supa import fetch_pending_attend, mark_attended

logger.remove()
logger.add(sys.stderr, level="INFO", format="{time:YYYY-MM-DD HH:mm:ss} | {level} | {message}")
logger.add("logs/eb_run.log", level="DEBUG", rotation="10 MB", retention="7 days",
           format="{time:YYYY-MM-DD HH:mm:ss} | {level} | {message}")


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="easybroker", description="EasyBroker Buzón attend bot")
    p.add_argument("--headful", action="store_true", default=False,
                   help="Run Chrome with a visible window (default: headless)")
    p.add_argument("--dry-run", action="store_true", dest="dry_run", default=False,
                   help="Log in, verify session, then exit")
    p.add_argument("--inspect-login", action="store_true", dest="inspect_login", default=False,
                   help="Dump the EB login form controls and exit (read-only)")
    p.add_argument("--inspect-buzon", nargs="?", const="", default=None, metavar="PHONE",
                   dest="inspect_buzon",
                   help="Dump Buzón controls (optionally selecting PHONE) and exit (read-only)")
    p.add_argument("--once", default=None, metavar="PHONE",
                   help="Attend exactly one lead by phone (use with --agent). Forces the gate on.")
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
        context, chrome_proc = await launch_chrome(pw, headless=not args.headful)
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
                res = await attend_lead(page, phone=args.once, agent_name=args.agent,
                                        note_text=args.note)
                print(f"--once {args.once}: {res}")
                return 0 if (res["status_ok"] and res["note_ok"]) else 1

            # Default: poll + attend each pending EB lead.
            gate = os.environ.get("EB_MARK_ATTENDED", "").strip() == "1"
            leads = await fetch_pending_attend(settings)
            if not leads:
                print("No EB leads pending Atendida + note.")
                return 0
            if not gate:
                print(f"{len(leads)} EB lead(s) pending, but EB_MARK_ATTENDED!=1 — dry listing only:")
                for l in leads:
                    print(f"  {l.get('lead_name','?')} {l.get('lead_phone')} -> {l.get('agent_name')}")
                return 0

            attended = 0
            for l in leads:
                res = await attend_lead(
                    page, phone=l["lead_phone"], agent_name=l["agent_name"],
                    note_text=f"Atendido por {l['agent_name']}",
                )
                if res["status_ok"] and res["note_ok"]:
                    await mark_attended(settings, l["conversation_id"])
                    attended += 1
                else:
                    logger.warning("Lead {} not fully attended: {}", l.get("lead_phone"), res)
            print(f"Attended {attended}/{len(leads)} EB lead(s)")
            return 0

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
