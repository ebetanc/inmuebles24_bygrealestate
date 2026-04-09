"""Monitoring and alerting module.

Sends health heartbeats and error alerts to Telegram.
Telegram is used ONLY for system monitoring — lead notifications
go through the CRM/WhatsApp pipeline.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import httpx
from loguru import logger


async def send_telegram_alert(
    bot_token: str,
    chat_id: str,
    message: str,
    *,
    parse_mode: str = "HTML",
) -> bool:
    """Send an alert message to Telegram. Returns True on success."""
    if not bot_token or not chat_id:
        logger.warning("Telegram alerting not configured — skipping")
        return False

    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": message,
        "parse_mode": parse_mode,
    }

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(url, json=payload)
            resp.raise_for_status()
            logger.debug("Telegram alert sent (chat_id={})", chat_id)
            return True
    except Exception as e:
        logger.error("Failed to send Telegram alert: {}", e)
        return False


async def send_error_alert(
    bot_token: str,
    chat_id: str,
    error: str,
    context: str = "",
) -> bool:
    """Send a formatted error alert."""
    msg = f"<b>Inmobiliaria24 Error</b>\n\n<code>{error}</code>"
    if context:
        msg += f"\n\n<i>{context}</i>"
    return await send_telegram_alert(bot_token, chat_id, msg)


async def send_heartbeat(
    bot_token: str,
    chat_id: str,
    *,
    total_leads: int = 0,
    new_leads: int = 0,
    status: str = "ok",
) -> bool:
    """Send a run-complete heartbeat."""
    icon = "✅" if status == "ok" else "⚠️"
    msg = (
        f"{icon} <b>Inmobiliaria24 Run Complete</b>\n"
        f"Status: {status}\n"
        f"Total leads: {total_leads}\n"
        f"New leads: {new_leads}"
    )
    return await send_telegram_alert(bot_token, chat_id, msg)


# ---------------------------------------------------------------------------
# Stale-run detection
# ---------------------------------------------------------------------------


async def check_stale_runs(
    bot_token: str,
    chat_id: str,
    last_success_iso: str | None,
    *,
    max_hours: int = 24,
) -> bool:
    """Alert if there has been no successful run in the last `max_hours`.

    `last_success_iso` is the ISO-8601 timestamp of the last successful run
    (from StateStore.last_successful_run()).

    Returns True if an alert was sent.
    """
    if last_success_iso is None:
        return await send_telegram_alert(
            bot_token, chat_id,
            "🚨 <b>Inmobiliaria24 — No Successful Runs</b>\n\n"
            "No successful run has been recorded in the database.",
        )

    last_ok = datetime.fromisoformat(last_success_iso)
    if last_ok.tzinfo is None:
        last_ok = last_ok.replace(tzinfo=timezone.utc)
    elapsed = datetime.now(timezone.utc) - last_ok

    if elapsed > timedelta(hours=max_hours):
        hours = elapsed.total_seconds() / 3600
        return await send_telegram_alert(
            bot_token, chat_id,
            f"🚨 <b>Inmobiliaria24 — No Success in {hours:.1f}h</b>\n\n"
            f"Last successful run: <code>{last_success_iso}</code>\n"
            f"Threshold: {max_hours}h",
        )

    return False


# ---------------------------------------------------------------------------
# Daily summary
# ---------------------------------------------------------------------------


async def send_daily_summary(
    bot_token: str,
    chat_id: str,
    *,
    total_runs: int = 0,
    successful_runs: int = 0,
    failed_runs: int = 0,
    total_leads_scraped: int = 0,
    new_leads: int = 0,
    leads_pushed_crm: int = 0,
) -> bool:
    """Send a daily operations summary to Telegram."""
    msg = (
        "📊 <b>Inmobiliaria24 — Daily Summary</b>\n\n"
        f"<b>Runs:</b> {total_runs} total, "
        f"{successful_runs} OK, {failed_runs} failed\n"
        f"<b>Leads scraped:</b> {total_leads_scraped}\n"
        f"<b>New leads:</b> {new_leads}\n"
        f"<b>Pushed to CRM:</b> {leads_pushed_crm}"
    )
    return await send_telegram_alert(bot_token, chat_id, msg)
