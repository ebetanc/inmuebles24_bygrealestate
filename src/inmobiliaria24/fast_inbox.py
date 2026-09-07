"""Read the responses loaded by the authenticated inbox, without fixed sleeps."""
import re
from datetime import datetime, timezone, timedelta
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
import json

from inmobiliaria24.day_sla import parse_time
from inmobiliaria24.scraper import INTERESADOS_URL, _TABS

LEADS_PATH = "/leads-api/publisher/leads"


def next_page_request(request, paging: dict) -> dict:
    """Adjust only pagination keys present in the browser's real request."""
    offset = int(paging["offset"]) + int(paging["limit"])
    parts = urlsplit(request.url)
    params = dict(parse_qsl(parts.query, keep_blank_values=True))
    body = json.loads(request.post_data) if request.post_data else None
    if "offset" in params:
        params["offset"] = str(offset)
    elif isinstance(body, dict) and "offset" in body:
        body["offset"] = offset
    elif isinstance(body, dict) and isinstance(body.get("paging"), dict) and "offset" in body["paging"]:
        body["paging"]["offset"] = offset
    else:
        raise RuntimeError("Unknown I24 pagination format; cannot verify complete coverage")
    return {"url": urlunsplit(parts._replace(query=urlencode(params))),
            "method": request.method, "body": json.dumps(body) if body is not None else None}


def normalize_row(row: dict, tab: str) -> dict:
    user, posting = row.get("lead_user") or {}, row.get("posting") or {}
    lead_id = str(row.get("contact_publisher_user_id") or "")
    if not lead_id.isdigit():
        raise ValueError("Missing exact I24 request ID")
    received = parse_time(str(row.get("last_lead_date") or ""))
    if received > datetime.now(timezone.utc) + timedelta(seconds=5):
        raise ValueError("Portal arrival is in the future")
    digits = re.sub(r"\D", "", str(user.get("phone") or row.get("phone") or ""))
    if len(digits) == 10:
        digits = "52" + digits
    return {
        "lead_id": lead_id, "name": user.get("name") or "",
        "email": user.get("email") or "", "phone": digits,
        "listing_id": str(posting.get("id") or ""),
        "property_public_id": str(posting.get("internal_code") or "").strip().upper(),
        "property_title": posting.get("title") or "",
        "status": (row.get("contact_response_status") or {}).get("name") or "",
        "source_tab": tab, "portal_received_at": received.isoformat(),
        "day_sla_version": 1,
    }


async def read_fast_inbox(page, *, since: datetime) -> list[dict]:
    """Wait for each tab's complete list, not its two-row counter prefetch.

    Pagination stays in the actual UI. Stop once rows precede the activation
    cutoff; exact request IDs deduplicate the three overlapping tabs.
    """
    found: dict[str, dict] = {}
    async def is_full_list(response):
        parts = urlsplit(response.url)
        if parts.hostname != "www.inmuebles24.com" or parts.path != LEADS_PATH or response.status != 200:
            return False
        try:
            payload = await response.json()
            return payload.get("paging", {}).get("limit", 0) >= 20
        except (ValueError, TypeError):
            return False
    for tab, selector in _TABS:
        async with page.expect_response(
            is_full_list,
            timeout=25_000,
        ) as incoming:
            if selector:
                await page.locator(selector).click(timeout=10_000)
            else:
                await page.goto(INTERESADOS_URL, wait_until="domcontentloaded")
        response = await incoming.value
        payload = await response.json()
        for _ in range(50):
            rows = payload.get("result")
            if not isinstance(rows, list):
                raise ValueError("I24 inbox response is not a lead list")
            for row in rows:
                lead = normalize_row(row, tab)
                if parse_time(lead["portal_received_at"]) >= since:
                    found[lead["lead_id"]] = lead
            paging = payload.get("paging") or {}
            if (not rows or int(paging.get("offset",0))+int(paging.get("limit",20)) >= int(paging.get("total",0))
                or any(parse_time(str(r["last_lead_date"])) < since for r in rows)):
                break
            req = next_page_request(response.request, paging)
            headers = await response.request.all_headers()
            req["headers"] = {k:v for k,v in headers.items() if k.lower() not in {
                'host','cookie','content-length','origin','referer','user-agent','connection','accept-encoding'
            } and not k.lower().startswith('sec-')}
            result = await page.evaluate("""async ({url,method,body,headers}) => {
                const r=await fetch(url,{method,credentials:'include',
                    headers,body});
                if(!r.ok) throw new Error('I24 pagination HTTP '+r.status);
                return await r.json();
            }""", req)
            if int(result.get("paging",{}).get("offset",-1)) <= int(paging.get("offset",0)):
                raise RuntimeError("I24 pagination did not advance")
            payload=result
        else:
            raise RuntimeError("I24 pagination exceeded 50 pages")
    return sorted(found.values(), key=lambda row: row["portal_received_at"])
