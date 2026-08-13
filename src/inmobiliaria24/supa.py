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
        "metadata": {"source": "inmuebles24"},
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


# ---------------------------------------------------------------------------
# Inmuebles24 advisor-note queue (case A)
# ---------------------------------------------------------------------------


def _supa_cfg() -> tuple[str, str] | None:
    url = os.environ.get("SUPABASE_URL", "").strip()
    key = os.environ.get("SUPABASE_SERVICE_KEY", "").strip()
    if not url or not key:
        logger.debug("Supabase not configured")
        return None
    return url.rstrip("/"), key


def _headers(key: str) -> dict:
    return {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}


async def fetch_pending_i24_notes(limit: int = 20) -> list[dict]:
    """i24 leads that are genuinely claimed, have a known id, and have no note yet.

    A genuine claim excludes escalation-only assignments unless the escalated
    lead has since received a first response.

    Returns dicts: conversation_id, i24_lead_id, assigned_agent_id, agent_name.
    """
    cfg = _supa_cfg()
    if not cfg:
        return []
    url, key = cfg
    q = (
        f"{url}/rest/v1/conversations?source=eq.inmuebles24"
        "&assigned_agent_id=not.is.null&i24_lead_id=not.is.null&i24_note_added=eq.false"
        "&or=(claimed_via.is.null,claimed_via.neq.escalation,first_response_at.not.is.null)"
        f"&select=conversation_id,i24_lead_id,assigned_agent_id,lead_name&limit={limit}"
    )
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            r = await client.get(q, headers=_headers(key))
            r.raise_for_status()
            rows = r.json()
            if not rows:
                return []
            ids = sorted({x["assigned_agent_id"] for x in rows if x.get("assigned_agent_id")})
            names: dict[str, str] = {}
            if ids:
                inlist = ",".join(ids)
                ar = await client.get(
                    f"{url}/rest/v1/agents?agent_id=in.({inlist})&select=agent_id,name",
                    headers=_headers(key),
                )
                ar.raise_for_status()
                names = {a["agent_id"]: a.get("name") or a["agent_id"] for a in ar.json()}
            for x in rows:
                x["agent_name"] = names.get(x.get("assigned_agent_id"), x.get("assigned_agent_id"))
            return rows
    except Exception as e:
        logger.warning("fetch_pending_i24_notes failed: {}", str(e))
        return []


async def claim_pending_i24_contacts(limit: int = 20) -> list[dict]:
    """Atomically lease assigned i24 opportunities for one portal mutation."""
    cfg = _supa_cfg()
    if not cfg:
        return []
    url, key = cfg
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.post(
                f"{url}/rest/v1/rpc/claim_i24_contact_effects",
                json={"p_limit": limit}, headers=_headers(key),
            )
            response.raise_for_status()
            return response.json()
    except Exception as e:
        logger.warning("claim_pending_i24_contacts failed: {}", str(e))
        return []


async def finish_i24_contact_attempt(
    opportunity_id: int,
    lease_token: str,
    *,
    success: bool | None,
    error_code: str | None = None,
    screenshot_path: str | None = None,
) -> bool:
    """Finish only worker-held lease; RPC writes append-only result evidence first."""
    cfg = _supa_cfg()
    if not cfg:
        return False
    url, key = cfg
    if success is None:
        return False
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.post(
                f"{url}/rest/v1/rpc/finish_i24_contact_effect",
                json={
                    "p_opportunity_id": opportunity_id,
                    "p_lease_token": lease_token,
                    "p_success": success,
                    "p_error_code": error_code,
                    "p_screenshot_path": screenshot_path,
                }, headers=_headers(key),
            )
            response.raise_for_status()
        return response.json() is True
    except Exception as e:
        logger.warning("finish_i24_contact_attempt failed for opportunity {}: {}", opportunity_id, str(e))
        return False


async def validate_i24_contact_attempt(opportunity_id: int, lease_token: str) -> bool:
    """Revalidate lease and exact assignment immediately before portal I/O."""
    cfg = _supa_cfg()
    if not cfg:
        return False
    url, key = cfg
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.post(
                f"{url}/rest/v1/rpc/validate_i24_contact_effect",
                json={"p_opportunity_id": opportunity_id, "p_lease_token": lease_token},
                headers=_headers(key),
            )
            response.raise_for_status()
        return response.json() is True
    except Exception as e:
        logger.warning("validate_i24_contact_attempt failed for opportunity {}: {}", opportunity_id, str(e))
        return False


async def mark_i24_note_added(conversation_id: str) -> bool:
    """Set conversations.i24_note_added = true (idempotency guard)."""
    cfg = _supa_cfg()
    if not cfg:
        return False
    url, key = cfg
    endpoint = f"{url}/rest/v1/conversations?conversation_id=eq.{conversation_id}"
    h = {**_headers(key), "Prefer": "return=minimal"}
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            r = await client.patch(endpoint, json={"i24_note_added": True}, headers=h)
            r.raise_for_status()
        return True
    except Exception as e:
        logger.warning("mark_i24_note_added failed for {}: {}", conversation_id, str(e))
        return False
