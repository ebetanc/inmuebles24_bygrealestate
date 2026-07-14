"""Supabase poll + idempotency for the EB Buzón bot.

Source of truth for "which EB leads still need the Atendida + note actions":
conversations that came from EasyBroker (eb_contact_id NOT NULL), have been
genuinely claimed by an agent (claimed_via != escalation, or escalated but
responded to), and have not yet been marked attended (eb_marked_attended =
false). The bot performs the two UI actions, then flips eb_marked_attended so
the lead is never touched again.
"""
from __future__ import annotations

from datetime import datetime, timezone

import httpx
from loguru import logger


def _headers(key: str) -> dict:
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }


async def fetch_pending_attend(settings) -> list[dict]:
    """Return genuinely-claimed EB leads pending Atendida + note."""
    url = settings.supabase_url
    key = settings.supabase_service_key
    if not url or not key:
        logger.warning("Supabase not configured — cannot poll for pending EB leads")
        return []

    base = url.rstrip("/")
    convs_endpoint = (
        f"{base}/rest/v1/conversations"
        "?select=conversation_id,lead_phone,lead_name,assigned_agent_id,eb_contact_id"
        "&eb_contact_id=not.is.null"
        "&assigned_agent_id=not.is.null"
        "&or=(claimed_via.is.null,claimed_via.neq.escalation,first_response_at.not.is.null)"
        "&eb_marked_attended=is.false"
    )
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.get(convs_endpoint, headers=_headers(key))
        resp.raise_for_status()
        convs = resp.json()
        if not convs:
            return []
        # Resolve agent names in one extra call (avoids PostgREST embed FK
        # ambiguity — conversations has multiple FKs to agents).
        agent_ids = sorted({c["assigned_agent_id"] for c in convs if c.get("assigned_agent_id")})
        names: dict[str, str] = {}
        if agent_ids:
            in_list = ",".join(f'"{a}"' for a in agent_ids)
            ag_endpoint = f"{base}/rest/v1/agents?select=agent_id,name&agent_id=in.({in_list})"
            ag_resp = await client.get(ag_endpoint, headers=_headers(key))
            ag_resp.raise_for_status()
            names = {a["agent_id"]: a["name"] for a in ag_resp.json()}

    for c in convs:
        c["agent_name"] = names.get(c.get("assigned_agent_id"), c.get("assigned_agent_id") or "asesor")
    logger.info("Found {} EB lead(s) pending Atendida + note", len(convs))
    return convs


async def mark_attended(settings, conversation_id: str) -> bool:
    """Set eb_marked_attended=true + eb_attended_at=now for one conversation."""
    url = settings.supabase_url
    key = settings.supabase_service_key
    if not url or not key:
        return False
    endpoint = (
        f"{url.rstrip('/')}/rest/v1/conversations?conversation_id=eq.{conversation_id}"
    )
    payload = {
        "eb_marked_attended": True,
        "eb_attended_at": datetime.now(timezone.utc).isoformat(),
    }
    headers = {**_headers(key), "Prefer": "return=minimal"}
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.patch(endpoint, json=payload, headers=headers)
            resp.raise_for_status()
        logger.info("Marked conversation {} eb_marked_attended=true", conversation_id)
        return True
    except Exception as e:
        logger.warning("Failed to mark conversation {} attended: {}", conversation_id, e)
        return False
