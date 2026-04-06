"""Webhook POST with exponential backoff retry and local JSON fallback."""
from __future__ import annotations

import asyncio
import json
from datetime import datetime, timezone
from pathlib import Path

import httpx
from loguru import logger


async def send_leads(
    leads: list[dict],
    *,
    webhook_url: str,
    max_retries: int = 3,
    fallback_dir: str | Path | None = None,
) -> bool:
    """POST leads to webhook. Retries with exponential backoff.

    On total failure, saves leads to a local JSON fallback file so the
    next run can pick them up.

    Returns True if POST succeeded, False otherwise.
    """
    for attempt in range(1, max_retries + 1):
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.post(webhook_url, json=leads)
                resp.raise_for_status()
            logger.info(
                "Webhook POST success ({} leads, attempt {}/{})",
                len(leads), attempt, max_retries,
            )
            return True
        except Exception as e:
            wait = 2 ** attempt
            logger.warning(
                "Webhook POST failed (attempt {}/{}): {} — retrying in {}s",
                attempt, max_retries, e, wait,
            )
            if attempt < max_retries:
                await asyncio.sleep(wait)

    logger.error("Webhook POST failed after {} retries — saving to local fallback", max_retries)
    if fallback_dir:
        _save_local_fallback(leads, Path(fallback_dir))
    return False


def _save_local_fallback(leads: list[dict], fallback_dir: Path) -> None:
    """Save leads to a timestamped JSON file for later retry."""
    fallback_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f")
    path = fallback_dir / f"fallback_{ts}.json"
    path.write_text(json.dumps(leads, indent=2, ensure_ascii=False), encoding="utf-8")
    logger.info("Saved {} leads to fallback: {}", len(leads), path)


def _load_local_fallback(fallback_dir: Path) -> list[dict]:
    """Load and delete all fallback JSON files, returning accumulated leads."""
    if not fallback_dir.exists():
        return []

    all_leads: list[dict] = []
    for path in sorted(fallback_dir.glob("fallback_*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            all_leads.extend(data)
            path.unlink()
            logger.info("Loaded and removed fallback file: {}", path)
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("Could not read fallback {}: {}", path, e)

    return all_leads
