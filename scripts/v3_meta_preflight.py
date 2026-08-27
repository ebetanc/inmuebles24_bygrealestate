"""Read-only Meta WhatsApp V3 preflight without printing credentials."""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output" / "v3-execution" / "meta-preflight.json"


def load_env() -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in (ROOT / ".env.meta.local").read_text(encoding="utf-8-sig").splitlines():
        match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", raw)
        if not match:
            continue
        value = match.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[match.group(1)] = value
    return values


def get(version: str, token: str, path: str, fields: str | None = None) -> dict:
    query = urllib.parse.urlencode({"fields": fields}) if fields else ""
    url = f"https://graph.facebook.com/{version}/{path}" + (f"?{query}" if query else "")
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return {"ok": True, "status_code": response.status, "data": json.load(response)}
    except urllib.error.HTTPError as error:
        return {"ok": False, "status_code": error.code, "error": "meta_api_error"}


def main() -> None:
    values = load_env()
    version = values["META_GRAPH_API_VERSION"]
    token = values["META_ACCESS_TOKEN"]
    app_id = values["META_APP_ID"]
    waba_id = values["META_WABA_ID"]
    phone_id = values["META_PHONE_NUMBER_ID"]

    subscribed = get(version, token, f"{waba_id}/subscribed_apps")
    phone = get(
        version,
        token,
        phone_id,
        "id,display_phone_number,verified_name,quality_rating,code_verification_status",
    )
    subscriptions = get(version, token, f"{app_id}/subscriptions")

    subscribed_apps = []
    if subscribed["ok"]:
        for item in subscribed["data"].get("data", []):
            subscribed_apps.append(
                {
                    "id": item.get("id"),
                    "name": item.get("name"),
                    "subscribed_fields": item.get("subscribed_fields", []),
                }
            )

    webhook_entries = []
    if subscriptions["ok"]:
        for item in subscriptions["data"].get("data", []):
            webhook_entries.append(
                {
                    "object": item.get("object"),
                    "active": item.get("active"),
                    "fields": sorted(field.get("name", "") for field in item.get("fields", [])),
                }
            )

    phone_data = phone.get("data", {}) if phone["ok"] else {}
    report = {
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "graph_version": version,
        "waba_subscription_query": {
            "ok": subscribed["ok"],
            "status_code": subscribed["status_code"],
            "apps": subscribed_apps,
            "expected_app_present": any(item.get("id") == app_id for item in subscribed_apps),
        },
        "app_webhook_query": {
            "ok": subscriptions["ok"],
            "status_code": subscriptions["status_code"],
            "entries": webhook_entries,
        },
        "phone_number": {
            "ok": phone["ok"],
            "status_code": phone["status_code"],
            "id": phone_data.get("id"),
            "display_phone_number": phone_data.get("display_phone_number"),
            "verified_name": phone_data.get("verified_name"),
            "quality_rating": phone_data.get("quality_rating"),
            "code_verification_status": phone_data.get("code_verification_status"),
        },
        "token_printed": False,
        "messages_sent": 0,
        "mutations": 0,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
