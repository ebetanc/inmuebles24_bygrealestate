"""Mirror scraper run telemetry to Supabase (scrape_logs table).

The Pi already tracks every run in local SQLite (state.run_log). This
additionally pushes one row per run to Supabase's scrape_logs table so the
dashboard ("Logs de Subastas") can show every 15-min run — including empty
runs that bring zero leads — without needing SSH access to the Pi.

Telemetry must never break the scraper: missing config is a silent no-op and
any HTTP failure is logged and swallowed.
"""
from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone

import httpx
from loguru import logger


async def log_scrape_run(
    *,
    started_at: datetime,
    status: str,
    total: int = 0,
    new: int = 0,
    error_message: str | None = None,
) -> None:
    """Insert one row into Supabase scrape_logs describing a finished run."""
    url = os.environ.get("SUPABASE_URL", "").strip()
    key = os.environ.get("SUPABASE_SERVICE_KEY", "").strip()
    if not url or not key:
        logger.debug("Supabase not configured — skipping scrape_logs push")
        return

    endpoint = f"{url.rstrip('/')}/rest/v1/scrape_logs"
    completed = datetime.now(timezone.utc)
    payload = {
        "run_id": str(uuid.uuid4()),
        "started_at": started_at.isoformat(),
        "completed_at": completed.isoformat(),
        "status": status,
        "total_scraped": total,
        "new_listings": new,
        "error_message": error_message,
    }
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Prefer": "return=minimal",
    }
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(endpoint, json=payload, headers=headers)
            resp.raise_for_status()
        logger.info("scrape_logs row written to Supabase (status={}, new={})", status, new)
    except Exception as e:  # never let telemetry break the scraper
        logger.warning("Failed to write scrape_logs to Supabase: {}", str(e))
