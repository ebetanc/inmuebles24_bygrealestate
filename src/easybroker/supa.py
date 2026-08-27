"""Supabase poll + idempotency for the EB Buzón bot.

Source of truth for "which leads still need the Atendida + note actions":
assigned conversations linked to one exact EasyBroker request. I24 links are
created only from a unique property + identity + time match. An expiring lease
keeps portal side effects exclusive across workers and permits crash recovery.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from urllib.parse import quote

import httpx
from loguru import logger
import hashlib
import re


CONTACT_REQUESTS_URL = "https://api.easybroker.com/v1/contact_requests"


def normalize_email(value: object) -> str | None:
    value = str(value or "").strip().lower()
    return value or None


def normalize_e164(value: object, country_code: object = None) -> str | None:
    """Normalize only with an explicit + country code or explicit country_code."""
    raw = str(value or "").strip()
    if raw.startswith("+"):
        digits = "+" + re.sub(r"\D", "", raw)
    else:
        cc = re.sub(r"\D", "", str(country_code or ""))
        local = re.sub(r"\D", "", raw)
        digits = f"+{cc}{local}" if cc and local else ""
    return digits if re.fullmatch(r"\+[1-9][0-9]{7,14}", digits) else None


def sanitize_contact_request(row: dict) -> dict | None:
    """Return allowlisted request fields; never forward the raw provider row."""
    normalized = _normalize_contact_request(row)
    if normalized is None:
        return None
    email = normalize_email(row.get("email"))
    phone = normalize_e164(row.get("phone_e164") or row.get("phone"), row.get("country_code"))
    evidence = {
        "eb_request_id": normalized["id"],
        "property_public_id": normalized["property_id"] or None,
        "happened_at": normalized["happened_at"],
    }
    if row.get("contact_id") is not None:
        evidence["has_contact_id"] = True
    return {
        "eb_request_id": normalized["id"],
        "eb_person_contact_id": int(row["contact_id"]) if str(row.get("contact_id", "")).isdigit() else None,
        "property_public_id": normalized["property_id"] or None,
        "normalized_email": email,
        "e164_phone": phone,
        "email_hash": hashlib.sha256(email.encode()).hexdigest() if email else None,
        "phone_hash": hashlib.sha256(phone.encode()).hexdigest() if phone else None,
        "sanitized_evidence": evidence,
        "happened_at": normalized["happened_at"],
    }


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
    email = normalize_email(row.get("email"))
    # Legacy helper preserves its historical digits-only return shape.
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
        "email": email,
        "phone": phone,
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


async def fetch_contact_requests(settings, *, happened_after: datetime | None = None,
                                overlap: timedelta = timedelta(minutes=10)) -> list[dict]:
    """Fetch every page, deduplicated by request id and ordered by (time, id)."""
    if not settings.api_key:
        return []
    cutoff = (happened_after - overlap if happened_after else
              datetime.now(timezone.utc) - timedelta(hours=48))
    rows: dict[int, dict] = {}
    page = 1
    async with httpx.AsyncClient(timeout=20) as client:
        while True:
            response = await client.get(
                CONTACT_REQUESTS_URL,
                headers={"X-Authorization": settings.api_key},
                params={"page": page, "limit": 50, "happened_after": cutoff.isoformat()},
            )
            response.raise_for_status()
            payload = response.json()
            content = payload.get("content")
            if not isinstance(content, list):
                raise ValueError("EasyBroker contact_requests returned no content array")
            for row in content:
                normalized = sanitize_contact_request(row) if isinstance(row, dict) else None
                if normalized:
                    rows[normalized["eb_request_id"]] = normalized
            next_page = (payload.get("pagination") or {}).get("next_page")
            if not next_page:
                break
            next_page = int(next_page)
            if next_page == page:
                raise ValueError("EasyBroker pagination did not advance")
            page = next_page
    return sorted(rows.values(), key=lambda r: (r["happened_at"], r["eb_request_id"]))


def _checkpoint_due(row: dict | None, *, now: datetime | None = None) -> bool:
    if not row or not row.get("updated_at"):
        return True
    current = now or datetime.now(timezone.utc)
    try:
        updated = datetime.fromisoformat(str(row["updated_at"]).replace("Z", "+00:00"))
    except ValueError:
        return True
    return updated.tzinfo is None or current - updated.astimezone(timezone.utc) >= timedelta(minutes=5)


async def get_ingestion_checkpoint(settings, *, account_key: str) -> dict | None:
    endpoint = (
        f"{settings.supabase_url.rstrip('/')}/rest/v1/easybroker_ingestion_checkpoints"
        f"?select=watermark_at,watermark_request_id,updated_at"
        f"&account_key=eq.{quote(account_key, safe='')}&source=eq.easybroker&limit=1"
    )
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.get(endpoint, headers=_headers(settings.supabase_service_key))
        response.raise_for_status()
        rows = response.json()
    return rows[0] if isinstance(rows, list) and rows else None


async def ingest_contact_request_batch(settings, requests: list[dict], *, account_key: str) -> dict:
    """Persist one complete sanitized batch; checkpointing is DB-transactional."""
    endpoint = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/ingest_easybroker_contact_request_batch"
    # Keep the public Python model explicit while adapting to the existing G1
    # RPC contract.  Only allowlisted, already-sanitized fields cross this
    # boundary; provider payloads and names are never forwarded.
    rpc_requests = [{
        "id": row.get("eb_request_id"),
        "contact_id": row.get("eb_person_contact_id"),
        "property_id": row.get("property_public_id"),
        "email": row.get("normalized_email"),
        "phone_e164": row.get("e164_phone"),
        "email_hash": row.get("email_hash"),
        "phone_hash": row.get("phone_hash"),
        "sanitized_evidence": row.get("sanitized_evidence") or {},
        "happened_at": row.get("happened_at"),
    } for row in requests]
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(endpoint, headers=_headers(settings.supabase_service_key), json={
            "p_account_key": account_key, "p_requests": rpc_requests,
        })
        response.raise_for_status()
        result = response.json()
    return result if isinstance(result, dict) else {"ok": False}


async def correlate_pending_easybroker_requests(
    settings, *, limit: int = 100, now: datetime | None = None,
) -> list[dict]:
    """Resolve pending I24 captures against the durable EasyBroker inbox.

    The database function is the authority for exact property + identity
    matching, horizon handling, ambiguity, immutable links, and effect
    enqueueing.  This adapter only invokes it and returns sanitized results.
    """
    if not settings.supabase_url or not settings.supabase_service_key:
        return []
    if limit < 1 or limit > 500:
        raise ValueError("V3 correlation limit must be between 1 and 500")
    endpoint = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/correlate_pending_easybroker_requests"
    payload = {"p_limit": limit, "p_now": (now or datetime.now(timezone.utc)).isoformat()}
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(endpoint, headers=_headers(settings.supabase_service_key), json=payload)
        response.raise_for_status()
        result = response.json()
    return result if isinstance(result, list) else []


async def claim_v3_easybroker_effects(settings, *, limit: int = 20) -> list[dict]:
    """Lease request-level EasyBroker note/status effects for one worker."""
    endpoint = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/claim_v3_easybroker_effects"
    payload = {
        "p_limit": limit,
        "p_now": datetime.now(timezone.utc).isoformat(),
        "p_lease_duration": "00:10:00",
    }
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(endpoint, headers=_headers(settings.supabase_service_key), json=payload)
        response.raise_for_status()
        result = response.json()
    return result if isinstance(result, list) else []


async def finish_v3_easybroker_effect(
    settings, *, request_id: int, lease_token: str, step: str,
    ok: bool, evidence: dict, now: datetime | None = None,
) -> dict:
    """Persist exact-request evidence and release the V3 effect lease."""
    endpoint = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/finish_v3_easybroker_effect"
    payload = {
        "p_eb_request_id": request_id,
        "p_lease_token": lease_token,
        "p_step": step,
        "p_ok": ok,
        "p_evidence": evidence,
        "p_now": (now or datetime.now(timezone.utc)).isoformat(),
    }
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(endpoint, headers=_headers(settings.supabase_service_key), json=payload)
        response.raise_for_status()
        result = response.json()
    return result if isinstance(result, dict) else {"ok": False}


async def correlate_easybroker_request(settings, *, request_id: int | None,
                                       capture_event_id: int, opportunity_id: int | None,
                                       idempotency_key: str, evidence: dict | None = None) -> dict:
    """Call the request-level correlation RPC; legacy eb_contact_id is untouched."""
    endpoint = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/correlate_easybroker_request"
    payload = {
        "p_exact_request_id": request_id,
        "p_i24_capture_event_id": capture_event_id,
        "p_opportunity_id": opportunity_id,
        "p_idempotency_key": idempotency_key,
        "p_evidence": evidence or {},
    }
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(endpoint, headers=_headers(settings.supabase_service_key), json=payload)
        response.raise_for_status()
        result = response.json()
    return result if isinstance(result, dict) else {"ok": False}


async def reconcile_i24_easybroker_requests(settings) -> int | None:
    """Link assigned I24 leads to exact EB requests; never choose an ambiguity.

    Returns the number of links, or None when the read-only EB fetch / Supabase
    reconciliation failed. Only the fields needed for matching are forwarded.
    """
    if not settings.api_key or not settings.supabase_url or not settings.supabase_service_key:
        logger.error("EasyBroker reconciliation is not configured")
        return None

    if getattr(settings, "v3_inbox_enabled", False):
        try:
            account_key = getattr(settings, "account_key", "default")
            checkpoint = await get_ingestion_checkpoint(settings, account_key=account_key)
            ingested = 0
            if _checkpoint_due(checkpoint):
                watermark = checkpoint.get("watermark_at") if checkpoint else None
                happened_after = (
                    datetime.fromisoformat(str(watermark).replace("Z", "+00:00"))
                    if watermark else None
                )
                requests = await fetch_contact_requests(settings, happened_after=happened_after)
                result = await ingest_contact_request_batch(
                    settings, requests, account_key=account_key,
                )
                if not result.get("ok"):
                    return None
                ingested = int(result.get("persisted", 0))

            # Correlation runs every worker invocation, including the four
            # minutes in which inbox ingestion is intentionally rate-limited.
            # This lets a newly-arrived capture link as soon as its matching
            # request is already present in the inbox and also retries an
            # awaiting-responsible effect after assignment.
            outcomes = await correlate_pending_easybroker_requests(settings)
            linked = sum(1 for row in outcomes if row.get("state") == "linked")
            logger.info(
                "EasyBroker V3 reconciliation: ingested={}, correlated_linked={}, scanned={}",
                ingested, linked, len(outcomes),
            )
            return linked
        except Exception as e:
            logger.warning("EasyBroker V3 inbox ingestion failed: {}", e)
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
