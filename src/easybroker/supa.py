"""Supabase poll + idempotency for the EB Buzón bot.

Source of truth for "which leads still need the Atendida + note actions":
assigned conversations linked to one exact EasyBroker request. I24 links are
created only from a unique property + identity + time match. An expiring lease
keeps portal side effects exclusive across workers and permits crash recovery.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import httpx
from loguru import logger


CONTACT_REQUESTS_URL = "https://api.easybroker.com/v1/contact_requests"


def _headers(key: str) -> dict:
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }


def _normalize_contact_request(row: dict) -> dict | None:
    """Keep only valid fields needed for exact matching."""
    raw_id = row.get("id") or row.get("contact_request_id")
    try:
        request_id = int(str(raw_id))
    except (TypeError, ValueError):
        return None
    if request_id < 1 or request_id >= 10**18:
        return None

    property_id = str(row.get("property_id") or "").strip().upper()
    email = str(row.get("email") or "").strip().lower()
    phone = "".join(ch for ch in str(row.get("phone") or "") if ch.isdigit())
    happened_raw = str(row.get("happened_at") or "").strip()
    try:
        happened_at = datetime.fromisoformat(happened_raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if happened_at.tzinfo is None or not property_id or not (email or phone):
        return None

    return {
        "id": request_id,
        "property_id": property_id,
        "email": email or None,
        "phone": phone or None,
        "happened_at": happened_at.astimezone(timezone.utc).isoformat(),
    }


async def fetch_pending_attend(settings) -> list[dict]:
    """Atomically lease final-responsibility leads pending Atendida + note."""
    url = settings.supabase_url
    key = settings.supabase_service_key
    if not url or not key:
        logger.warning("Supabase not configured — cannot poll for pending EB leads")
        return []

    base = url.rstrip("/")
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.post(
            f"{base}/rest/v1/rpc/claim_easybroker_attend_effects",
            json={"p_limit": 20}, headers=_headers(key),
        )
        resp.raise_for_status()
        convs = resp.json()
        if not convs:
            return []
        # Resolve agent names in one extra call (avoids PostgREST embed FK
        # ambiguity — conversations has multiple FKs to agents).
        names = await _agent_names(client, base, key, convs)

    for c in convs:
        c["agent_name"] = names.get(c.get("assigned_agent_id"), c.get("assigned_agent_id") or "asesor")
    logger.info("Found {} EB lead(s) pending Atendida + note", len(convs))
    return convs


async def list_pending_attend(settings) -> list[dict]:
    """Read-only listing used while the EasyBroker mutation gate is disabled."""
    url = settings.supabase_url
    key = settings.supabase_service_key
    if not url or not key:
        return []
    base = url.rstrip("/")
    endpoint = (
        f"{base}/rest/v1/conversations"
        "?select=conversation_id,lead_phone,lead_name,assigned_agent_id,eb_contact_id,eb_note_added,eb_marked_attended"
        "&eb_contact_id=not.is.null&assigned_agent_id=not.is.null"
        "&and=(or(claimed_via.is.null,claimed_via.neq.escalation,first_response_at.not.is.null,"
        "assignment_method.eq.manager_escalation),"
        "or(eb_note_added.is.false,eb_marked_attended.is.false))"
    )
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.get(endpoint, headers=_headers(key))
        response.raise_for_status()
        rows = response.json()
        names = await _agent_names(client, base, key, rows)
    for row in rows:
        row["agent_name"] = names.get(
            row.get("assigned_agent_id"), row.get("assigned_agent_id") or "asesor"
        )
    return rows


async def reconcile_i24_easybroker_requests(settings) -> int | None:
    """Link assigned I24 leads to exact EB requests; never choose an ambiguity.

    Returns the number of links, or None when the read-only EB fetch / Supabase
    reconciliation failed. Only the fields needed for matching are forwarded.
    """
    if not settings.api_key or not settings.supabase_url or not settings.supabase_service_key:
        logger.error("EasyBroker reconciliation is not configured")
        return None

    happened_after = (datetime.now(timezone.utc) - timedelta(hours=48)).isoformat()
    requests_by_id: dict[int, dict] = {}
    page = 1
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            for _ in range(10):
                response = await client.get(
                    CONTACT_REQUESTS_URL,
                    headers={"X-Authorization": settings.api_key},
                    params={
                        "page": page,
                        "limit": 50,
                        "happened_after": happened_after,
                    },
                )
                response.raise_for_status()
                payload = response.json()
                content = payload.get("content")
                if not isinstance(content, list):
                    raise ValueError("EasyBroker contact_requests returned no content array")
                for row in content:
                    normalized = _normalize_contact_request(row) if isinstance(row, dict) else None
                    if normalized is not None:
                        requests_by_id[normalized["id"]] = normalized
                next_page = (payload.get("pagination") or {}).get("next_page")
                if not next_page:
                    break
                page = int(next_page)

            endpoint = (
                f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/"
                "reconcile_easybroker_contact_requests"
            )
            response = await client.post(
                endpoint,
                json={"p_requests": list(requests_by_id.values())},
                headers=_headers(settings.supabase_service_key),
            )
            response.raise_for_status()
            linked = response.json()
        count = len(linked) if isinstance(linked, list) else 0
        logger.info("Linked {} I24 lead(s) to exact EasyBroker requests", count)
        return count
    except Exception as e:
        logger.warning("EasyBroker request reconciliation failed: {}", e)
        return None


async def _agent_names(client, base: str, key: str, rows: list[dict]) -> dict[str, str]:
    """Resolve names without ambiguous PostgREST relationship embedding."""
    agent_ids = sorted({row["assigned_agent_id"] for row in rows if row.get("assigned_agent_id")})
    if not agent_ids:
        return {}
    in_list = ",".join(f'"{agent_id}"' for agent_id in agent_ids)
    response = await client.get(
        f"{base}/rest/v1/agents?select=agent_id,name&agent_id=in.({in_list})",
        headers=_headers(key),
    )
    response.raise_for_status()
    return {agent["agent_id"]: agent["name"] for agent in response.json()}


async def finish_attend_attempt(
    settings, conversation_id: str, lease_token: str, *, note_ok: bool,
    status_ok: bool, error_code: str | None = None,
) -> bool:
    """Persist step evidence and release only the worker-held lease."""
    url = settings.supabase_url
    key = settings.supabase_service_key
    if not url or not key:
        return False
    endpoint = f"{url.rstrip('/')}/rest/v1/rpc/finish_easybroker_attend_effect"
    payload = {
        "p_conversation_id": conversation_id,
        "p_lease_token": lease_token,
        "p_note_ok": note_ok,
        "p_status_ok": status_ok,
        "p_error_code": error_code,
    }
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(endpoint, json=payload, headers=_headers(key))
            resp.raise_for_status()
        return resp.json() is True
    except Exception as e:
        logger.warning("Failed to finish EasyBroker attempt for {}: {}", conversation_id, e)
        return False
