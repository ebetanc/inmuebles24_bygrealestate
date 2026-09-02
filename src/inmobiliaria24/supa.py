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
import re
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
    key = (
        os.environ.get("SUPABASE_SERVICE_KEY", "").strip()
        or os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    )
    if not url or not key:
        logger.debug("Supabase not configured")
        return None
    return url.rstrip("/"), key


def _headers(key: str) -> dict:
    return {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}


def _v3_phone(value: object) -> str | None:
    """Accept E.164 or scraper-normalized Mexico numbers; never infer country."""
    phone = str(value or "").strip()
    compact = re.sub(r"[ ()-]", "", phone)
    if re.fullmatch(r"\+[1-9][0-9]{7,14}", compact):
        return compact
    # scraper.py explicitly normalizes Mexican portal numbers to 52 + 10 digits.
    if re.fullmatch(r"52[1-9][0-9]{9}", compact):
        return f"+{compact}"
    return None


def _v3_rpc_rows(value: object) -> list[dict]:
    """Normalize PostgREST table responses for small RPC result sets."""
    if isinstance(value, list):
        return [row for row in value if isinstance(row, dict)]
    if isinstance(value, dict):
        return [value]
    return []


def _v3_offer_context(lead: dict) -> dict:
    """Keep scraped lead details durable for downstream WhatsApp rendering."""
    return {key: value for key, value in lead.items() if key != "page_text"}


async def v3_intake_lead(settings, lead: dict) -> dict:
    """Persist one I24 capture before any portal or WhatsApp effect."""
    cfg = _supa_cfg()
    if not cfg:
        raise RuntimeError("Supabase is required when Lead Routing V3 is enabled")
    external_id = str(lead.get("lead_id") or "").strip()
    if not external_id:
        raise ValueError("V3 intake requires lead_id")
    account_key = str(getattr(settings, "lead_routing_account_key", "default") or "default").strip()
    payload = {
        "p_account_key": account_key,
        "p_idempotency_key": f"i24:{external_id}",
        "p_source": "inmuebles24",
        "p_external_id": external_id,
        "p_portal_person_id": str(
            lead.get("portal_person_id") or lead.get("person_id") or ""
        ).strip() or None,
        "p_property_public_id": str(lead.get("property_public_id") or "").strip().upper() or None,
        "p_email": str(lead.get("email") or "").strip().lower() or None,
        "p_phone": _v3_phone(lead.get("phone_e164") or lead.get("phone")),
        "p_offer_context": _v3_offer_context(lead),
    }
    url, key = cfg
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(
            f"{url}/rest/v1/rpc/v3_intake", json=payload, headers=_headers(key)
        )
        response.raise_for_status()
    rows = _v3_rpc_rows(response.json())
    if not rows:
        raise RuntimeError("V3 intake returned no durable capture")
    return rows[0]


async def claim_v3_i24_contact_effects(limit: int = 20) -> list[dict]:
    """Lease per-capture Contactado effects for the logged-in I24 browser."""
    cfg = _supa_cfg()
    if not cfg:
        return []
    url, key = cfg
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(
            f"{url}/rest/v1/rpc/claim_v3_i24_contact_effects",
            json={"p_limit": limit}, headers=_headers(key),
        )
        response.raise_for_status()
    return _v3_rpc_rows(response.json())


async def finish_v3_i24_contact_effect(
    capture_event_id: int,
    lease_token: str,
    *,
    success: bool,
    error_code: str | None = None,
) -> bool:
    """Commit verified Contactado evidence for exactly one capture event."""
    cfg = _supa_cfg()
    if not cfg:
        return False
    url, key = cfg
    async with httpx.AsyncClient(timeout=15) as client:
        response = await client.post(
            f"{url}/rest/v1/rpc/finish_v3_i24_contact_effect",
            json={
                "p_capture_event_id": capture_event_id,
                "p_lease_token": lease_token,
                "p_success": success,
                "p_error_code": error_code,
            },
            headers=_headers(key),
        )
        response.raise_for_status()
    return response.json() is True


async def claim_v3_route_dispatches(limit: int = 20) -> list[dict]:
    """Lease verified captures whose downstream route has not been sent."""
    cfg = _supa_cfg()
    if not cfg:
        return []
    url, key = cfg
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(
            f"{url}/rest/v1/rpc/claim_v3_route_dispatches",
            json={"p_limit": limit}, headers=_headers(key),
        )
        response.raise_for_status()
    return _v3_rpc_rows(response.json())


async def finish_v3_route_dispatch(
    capture_event_id: int,
    lease_token: str,
    *,
    success: bool,
    error_code: str | None = None,
) -> bool:
    """Commit or retry one leased downstream route dispatch."""
    cfg = _supa_cfg()
    if not cfg:
        return False
    url, key = cfg
    async with httpx.AsyncClient(timeout=15) as client:
        response = await client.post(
            f"{url}/rest/v1/rpc/finish_v3_route_dispatch",
            json={
                "p_capture_event_id": capture_event_id,
                "p_lease_token": lease_token,
                "p_success": success,
                "p_error_code": error_code,
            },
            headers=_headers(key),
        )
        response.raise_for_status()
    return response.json() is True
