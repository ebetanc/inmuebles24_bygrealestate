"""Heartbeat reporting — POST run status to n8n for monitoring."""
from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum

import httpx
from loguru import logger


class HeartbeatStatus(Enum):
    OK = "ok"
    AUTH_FAILED = "auth_failed"
    PROXY_ERROR = "proxy_error"
    SCRAPE_ERROR = "scrape_error"


async def send_heartbeat(
    *,
    url: str,
    status: HeartbeatStatus,
    leads_found: int = 0,
    new_leads: int = 0,
    error_message: str = "",
) -> None:
    """POST a heartbeat to the monitoring webhook. Never raises."""
    if not url:
        logger.debug("Heartbeat URL not configured — skipping")
        return

    payload = {
        "status": status.value,
        "leads_found": leads_found,
        "new_leads": new_leads,
        "error_message": error_message,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(url, json=payload)
            resp.raise_for_status()
        logger.info("Heartbeat sent: status={}, leads={}/{}", status.value, new_leads, leads_found)
    except Exception as e:
        logger.warning("Heartbeat POST failed (non-fatal): {}", e)
