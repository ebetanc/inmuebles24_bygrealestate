"""One daytime deadline, checked again immediately before external writes."""
from datetime import datetime, timedelta, timezone
import os

import httpx

# Current project schedule is CDMX UTC-6 (no daylight saving since 2022).
CDMX = timezone(timedelta(hours=-6))


def parse_time(value: str) -> datetime:
    stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        raise ValueError("Portal timestamp must include its timezone")
    return stamp.astimezone(timezone.utc)


def is_day(stamp: datetime) -> bool:
    local = stamp.astimezone(CDMX)
    return (local.hour, local.minute) >= (8, 5) and local.hour < 20


def require_time(deadline: str | None, *, reserve_seconds: int = 10) -> None:
    if deadline and datetime.now(timezone.utc) + timedelta(seconds=reserve_seconds) >= parse_time(deadline):
        raise TimeoutError("day_deadline_expired")


async def get_deadline(*, capture_id=None, opportunity_id=None, request_id=None) -> str | None:
    if os.environ.get("I24_FAST_DAY") != "1":
        return None
    from inmobiliaria24.supa import _supa_cfg, _headers
    cfg = _supa_cfg()
    if not cfg:
        raise RuntimeError("Cannot check daytime deadline without Supabase")
    url, key = cfg
    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.post(f"{url}/rest/v1/rpc/v3_day_deadline", headers=_headers(key), json={
            "p_capture_id": capture_id, "p_opportunity_id": opportunity_id,
            "p_request_id": request_id,
        })
        response.raise_for_status()
        return response.json()
