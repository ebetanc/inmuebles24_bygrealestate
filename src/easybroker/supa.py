"""Supabase poll + idempotency for the EB Buzón bot.

Source of truth for "which EB leads still need the Atendida + note actions":
conversations that came from EasyBroker (eb_contact_id NOT NULL), have been
genuinely claimed by an agent (claimed_via != escalation, or escalated but
responded to), and still need note or status evidence. An expiring lease keeps
portal side effects exclusive across workers and permits crash recovery.
"""
from __future__ import annotations

import httpx
from loguru import logger


def _headers(key: str) -> dict:
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }


async def fetch_pending_attend(settings) -> list[dict]:
    """Atomically lease genuinely-claimed EB leads pending Atendida + note."""
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
        "&and=(or(claimed_via.is.null,claimed_via.neq.escalation,first_response_at.not.is.null),"
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
