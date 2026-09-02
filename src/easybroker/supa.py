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


def normalize_easybroker_phone_mx(value: object) -> str | None:
    """Normalize EasyBroker's Mexico phone variants without guessing."""
    raw = str(value or "").strip()
    if raw.startswith("+"):
        return normalize_e164(raw)
    digits = re.sub(r"\D", "", raw)
    if len(digits) == 10:
        return f"+52{digits}"
    if len(digits) == 12 and digits.startswith("52"):
        return f"+{digits}"
    return None


def sanitize_contact_request(row: dict) -> dict | None:
    """Return allowlisted request fields; never forward the raw provider row."""
    normalized = _normalize_contact_request(row)
    if normalized is None:
        return None
    email = normalize_email(row.get("email"))
    phone = normalize_easybroker_phone_mx(row.get("phone_e164") or row.get("phone"))
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


def _creation_name(claim: dict) -> str | None:
    context = claim.get("offer_context")
    if not isinstance(context, dict):
        return None
    value = context.get("name") or context.get("lead_name")
    return str(value).strip() or None


def _creation_payload(claim: dict) -> dict:
    """Build the documented EasyBroker POST body from allowlisted fields."""
    context = claim.get("offer_context")
    context = context if isinstance(context, dict) else {}
    message = str(context.get("message_preview") or "").strip()[:500]
    payload = {
        "name": _creation_name(claim),
        "phone": claim.get("e164_phone"),
        "email": claim.get("normalized_email"),
        "property_id": str(claim.get("property_public_id") or "").strip().upper(),
        "message": message or "Nuevo lead de Inmuebles24.",
        "source": "inmuebles24.com",
    }
    return {key: value for key, value in payload.items() if value not in (None, "")}


def _creation_match(claim: dict, row: dict) -> bool:
    """Match one existing provider request without trusting names or raw rows."""
    normalized = row if row.get("eb_request_id") else sanitize_contact_request(row)
    if not normalized:
        return False
    if claim.get("remote_request_id") is not None:
        try:
            if int(normalized["eb_request_id"]) != int(claim["remote_request_id"]):
                return False
        except (KeyError, TypeError, ValueError):
            return False
    if str(normalized.get("property_public_id") or "").upper() != str(
        claim.get("property_public_id") or ""
    ).upper():
        return False
    expected_email = normalize_email(claim.get("normalized_email"))
    expected_phone = normalize_e164(claim.get("e164_phone"))
    actual_email = normalized.get("normalized_email")
    actual_phone = normalized.get("e164_phone")
    if not ((expected_email and expected_email == actual_email)
            or (expected_phone and expected_phone == actual_phone)):
        return False
    if expected_email and actual_email and expected_email != actual_email:
        return False
    if expected_phone and actual_phone and expected_phone != actual_phone:
        return False
    try:
        happened = datetime.fromisoformat(str(normalized["happened_at"]).replace("Z", "+00:00"))
        start = datetime.fromisoformat(str(claim["correlation_window_start_at"]).replace("Z", "+00:00"))
        horizon = datetime.fromisoformat(str(claim["correlation_horizon_at"]).replace("Z", "+00:00"))
        if not (start <= happened <= horizon):
            return False
    except (KeyError, TypeError, ValueError):
        return False
    return True


def _creation_window(claim: dict) -> tuple[datetime, datetime] | None:
    """Return one trustworthy UTC correlation window, or fail closed."""
    try:
        start = datetime.fromisoformat(
            str(claim["correlation_window_start_at"]).replace("Z", "+00:00")
        )
        horizon = datetime.fromisoformat(
            str(claim["correlation_horizon_at"]).replace("Z", "+00:00")
        )
    except (KeyError, TypeError, ValueError):
        return None
    if start.tzinfo is None or horizon.tzinfo is None:
        return None
    start = start.astimezone(timezone.utc)
    horizon = horizon.astimezone(timezone.utc)
    return (start, horizon) if start <= horizon else None


async def claim_v3_easybroker_request_creations(settings, *, limit: int = 20) -> list[dict]:
    endpoint = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/claim_v3_easybroker_request_creations"
    payload = {"p_limit": limit, "p_now": datetime.now(timezone.utc).isoformat(),
               "p_lease_duration": "00:02:00"}
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(endpoint, headers=_headers(settings.supabase_service_key), json=payload)
        response.raise_for_status()
        result = response.json()
    return result if isinstance(result, list) else []


async def reserve_v3_easybroker_request_creation(
    settings, *, capture_event_id: int, lease_token: str, manual_retry: bool = False,
) -> bool:
    endpoint = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/reserve_v3_easybroker_request_creation"
    payload = {"p_capture_event_id": capture_event_id, "p_lease_token": lease_token,
               "p_now": datetime.now(timezone.utc).isoformat(),
               "p_manual_retry": manual_retry}
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(endpoint, headers=_headers(settings.supabase_service_key), json=payload)
        response.raise_for_status()
        result = response.json()
    return isinstance(result, dict) and result.get("ok") is True and result.get("post_allowed") is True


async def authorize_v3_easybroker_request_retry(
    settings, *, capture_event_id: int, authorized_by: str, reason: str,
) -> dict:
    """Authorize one exact retry after an operator confirmed provider absence."""
    endpoint = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/authorize_v3_easybroker_request_retry"
    payload = {"p_capture_event_id": capture_event_id, "p_authorized_by": authorized_by,
               "p_reason": reason, "p_now": datetime.now(timezone.utc).isoformat()}
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(endpoint, headers=_headers(settings.supabase_service_key), json=payload)
        response.raise_for_status()
        result = response.json()
    return result if isinstance(result, dict) else {"ok": False}


async def finish_v3_easybroker_request_creation(
    settings, *, capture_event_id: int, lease_token: str, state: str,
    remote_request_id: int | None = None, evidence: dict | None = None,
    error: str | None = None, preexisting: bool = False,
) -> dict:
    if state not in {"created", "recovery", "manual_review"}:
        raise ValueError("invalid EasyBroker creation state")
    endpoint = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/finish_v3_easybroker_request_creation"
    payload = {
        "p_capture_event_id": capture_event_id,
        "p_lease_token": lease_token,
        "p_state": state,
        "p_remote_request_id": remote_request_id,
        "p_evidence": evidence or {},
        "p_error": error,
        "p_preexisting": preexisting,
        "p_now": datetime.now(timezone.utc).isoformat(),
    }
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(endpoint, headers=_headers(settings.supabase_service_key), json=payload)
        response.raise_for_status()
        result = response.json()
    return result if isinstance(result, dict) else {"ok": False}


async def post_v3_easybroker_contact_request(settings, claim: dict) -> dict:
    """Perform exactly one provider POST; callers classify status failures.

    Contract: https://dev.easybroker.com/reference/post_contact-requests
    The account API returns 200/status=successful without a request id, so the
    durable GET reconciliation remains the only proof of creation.
    """
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(
            CONTACT_REQUESTS_URL,
            headers={"X-Authorization": settings.api_key,
                     "Content-Type": "application/json"},
            json=_creation_payload(claim),
        )
        status = response.status_code
        try:
            body = response.json()
        except ValueError:
            body = {}
        body = body if isinstance(body, dict) else {}
        response_meta = {
            "provider_content_length": len(response.content),
            "provider_body_keys": sorted(str(key)[:64] for key in body)[:20],
        }
        if status >= 400:
            return {"kind": "ambiguous" if status in {408, 409, 429} or status >= 500 else "definitive",
                    "status_code": status, **response_meta}
        nested = []
        for key in ("contact_request", "data"):
            value = body.get(key)
            if isinstance(value, dict):
                nested.append(value)
        raw_id = body.get("id") or body.get("contact_request_id")
        if raw_id is None:
            for candidate in nested:
                raw_id = candidate.get("id") or candidate.get("contact_request_id")
                if raw_id is not None:
                    break
        try:
            request_id = int(str(raw_id))
        except (TypeError, ValueError):
            request_id = None
        if request_id is None or request_id < 1:
            return {"kind": "ambiguous", "status_code": status, **response_meta}
        return {"kind": "created", "status_code": status,
                "remote_request_id": request_id, **response_meta}


async def create_pending_easybroker_requests(
    settings, *, limit: int = 20,
    manual_retry_capture_ids: frozenset[int] = frozenset(),
) -> list[dict]:
    """Create eligible captures; retries require an exact operator allowlist."""
    if (not getattr(settings, "easybroker_create_requests", False)
            or not getattr(settings, "api_key", "")
            or not settings.supabase_url
            or not settings.supabase_service_key):
        return []
    claims = await claim_v3_easybroker_request_creations(settings, limit=limit)
    if not claims:
        return []
    windows = {
        int(claim["capture_event_id"]): _creation_window(claim)
        for claim in claims
    }
    valid_starts = [window[0] for window in windows.values() if window is not None]
    existing = await fetch_contact_requests(
        settings,
        happened_after=min(valid_starts) if valid_starts else None,
    )
    outcomes: list[dict] = []
    for claim in claims:
        capture_id = int(claim["capture_event_id"])
        manual_retry = capture_id in manual_retry_capture_ids
        token = str(claim["lease_token"])
        if windows[capture_id] is None:
            saved = await finish_v3_easybroker_request_creation(
                settings,
                capture_event_id=capture_id,
                lease_token=token,
                state="manual_review",
                evidence={"post_skipped": True, "invalid_correlation_window": True},
                error="invalid_correlation_window",
            )
            outcomes.append({
                "capture_event_id": capture_id,
                "state": "manual_review",
                "saved": bool(saved.get("ok")),
            })
            continue
        matches = [row for row in existing if _creation_match(claim, row)]
        if len(matches) > 1:
            saved = await finish_v3_easybroker_request_creation(
                settings, capture_event_id=capture_id, lease_token=token,
                state="manual_review", error="multiple_existing_requests",
            )
            outcomes.append({"capture_event_id": capture_id, "state": "manual_review", "saved": bool(saved.get("ok"))})
            continue
        if len(matches) == 1:
            request_id = int(matches[0]["eb_request_id"])
            try:
                ingested = await ingest_contact_request_batch(
                    settings, [matches[0]], account_key=getattr(settings, "account_key", "default")
                )
                correlation = await correlate_easybroker_request(
                    settings, request_id=request_id, capture_event_id=capture_id,
                    opportunity_id=claim.get("opportunity_id"),
                    idempotency_key=f"v3:creation:existing:{capture_id}:{request_id}",
                    evidence={"source": "preexisting_contact_request"},
                )
            except Exception as exc:
                ingested, correlation = {"ok": False}, {"ok": False, "state": "error"}
                logger.warning("EasyBroker preexisting correlation failed for {}: {}", capture_id, exc)
            confirmed = (
                isinstance(ingested, dict) and ingested.get("ok") is True
                and isinstance(correlation, dict) and correlation.get("ok") is True
                and correlation.get("state") in {"linked", "already_linked"}
            )
            effect = {"ok": False, "state": "not_enqueued"}
            if confirmed:
                try:
                    effect = await enqueue_v3_easybroker_effect(
                        settings, request_id=request_id,
                    )
                except Exception as exc:
                    logger.warning("EasyBroker effect enqueue failed for {}: {}", request_id, exc)
            confirmed = confirmed and effect.get("ok") is True
            if not confirmed:
                saved = await finish_v3_easybroker_request_creation(
                    settings, capture_event_id=capture_id, lease_token=token,
                    state="recovery", remote_request_id=request_id,
                    evidence={"preexisting": True, "correlation_state": correlation.get("state"),
                              "effect_state": effect.get("state")},
                    error="preexisting_correlation_or_effect_not_confirmed",
                    preexisting=False,
                )
                outcomes.append({"capture_event_id": capture_id, "state": "recovery", "saved": bool(saved.get("ok"))})
                continue
            saved = await finish_v3_easybroker_request_creation(
                settings, capture_event_id=capture_id, lease_token=token,
                state="created", remote_request_id=request_id,
                evidence={"preexisting": True, "eb_request_id": request_id,
                          "correlation_state": correlation["state"],
                          "effect_state": effect.get("state")},
                preexisting=True,
            )
            outcomes.append({"capture_event_id": capture_id, "state": "preexisting", "saved": bool(saved.get("ok"))})
            continue
        if not claim.get("post_allowed", True) and not manual_retry:
            if _creation_horizon_expired(claim):
                state, error = "manual_review", "correlation_horizon_expired"
            else:
                state, error = "recovery", "post_skipped_pending_get"
            saved = await finish_v3_easybroker_request_creation(
                settings, capture_event_id=capture_id, lease_token=token,
                state=state, remote_request_id=claim.get("remote_request_id"),
                evidence={"post_skipped": True}, error=error,
            )
            outcomes.append({"capture_event_id": capture_id, "state": state, "saved": bool(saved.get("ok"))})
            continue
        if not await reserve_v3_easybroker_request_creation(
            settings, capture_event_id=capture_id, lease_token=token,
            manual_retry=manual_retry,
        ):
            outcomes.append({"capture_event_id": capture_id, "state": "recovery"})
            continue
        try:
            result = await post_v3_easybroker_contact_request(settings, claim)
        except httpx.RequestError:
            result = {"kind": "ambiguous", "status_code": None}
        if result["kind"] == "definitive":
            state, error = "manual_review", f"provider_http_{result['status_code']}"
        else:
            # A POST response is never proof that the request is in the GET
            # feed; persist recovery and let the next pass verify, ingest and
            # correlate before the ledger can become created.
            state, error = "recovery", "post_requires_posterior_get"
        evidence = {"provider_status": result.get("status_code"), "post_once": True}
        evidence["provider_content_length"] = result.get("provider_content_length")
        evidence["provider_body_keys"] = result.get("provider_body_keys") or []
        if result.get("remote_request_id"):
            evidence["eb_request_id"] = result["remote_request_id"]
        saved = await finish_v3_easybroker_request_creation(
            settings, capture_event_id=capture_id, lease_token=token, state=state,
            remote_request_id=result.get("remote_request_id"), evidence=evidence,
            error=error,
        )
        outcomes.append({"capture_event_id": capture_id, "state": state, "saved": bool(saved.get("ok"))})
    return outcomes


def _creation_horizon_expired(claim: dict) -> bool:
    try:
        horizon = datetime.fromisoformat(str(claim["correlation_horizon_at"]).replace("Z", "+00:00"))
    except (KeyError, TypeError, ValueError):
        return False
    return datetime.now(timezone.utc) >= horizon


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
            # EasyBroker returns pagination.next_page as a URL (or null on the
            # last page), so only its presence matters.
            if not (payload.get("pagination") or {}).get("next_page"):
                break
            page += 1
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


async def enqueue_v3_easybroker_effect(
    settings, *, request_id: int, now: datetime | None = None,
) -> dict:
    """Idempotently enqueue note/Atendida after an exact durable link."""
    endpoint = f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/enqueue_v3_easybroker_effect"
    payload = {
        "p_eb_request_id": request_id,
        "p_now": (now or datetime.now(timezone.utc)).isoformat(),
    }
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(endpoint, headers=_headers(settings.supabase_service_key), json=payload)
        response.raise_for_status()
        result = response.json()
    return result if isinstance(result, dict) else {"ok": False}


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
