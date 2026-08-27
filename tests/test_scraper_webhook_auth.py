import asyncio
import json

import httpx
import pytest

from inmobiliaria24 import scraper


def test_detail_merge_keeps_inbox_listing_when_detail_page_omits_it():
    merged = scraper._merge_lead_detail(
        {"lead_id": "265183003", "listing_id": "150421528"},
        {"phone": "525539660807", "listing_id": ""},
    )
    assert merged["listing_id"] == "150421528"


def test_send_to_webhook_requires_token_before_http(monkeypatch):
    called = False

    def forbidden_client(**kwargs):
        nonlocal called
        called = True
        raise AssertionError("HTTP client must not be created")

    monkeypatch.setattr(scraper.httpx, "AsyncClient", forbidden_client)

    with pytest.raises(ValueError, match="I24_WEBHOOK_TOKEN"):
        asyncio.run(scraper.send_to_webhook([], "https://n8n.example/webhook/scraper-leads"))
    assert called is False


def test_send_to_webhook_uses_private_header(monkeypatch):
    captured = {}

    def handler(request):
        captured["token"] = request.headers.get("X-I24-Webhook-Token")
        captured["body"] = json.loads(request.content)
        return httpx.Response(200, request=request)

    real_client = httpx.AsyncClient
    monkeypatch.setattr(
        scraper.httpx,
        "AsyncClient",
        lambda **kwargs: real_client(transport=httpx.MockTransport(handler), **kwargs),
    )

    asyncio.run(
        scraper.send_to_webhook(
            [{"lead_id": "test", "phone": "525539660807"}],
            "https://n8n.example/webhook/scraper-leads",
            "shared-secret",
        )
    )

    assert captured == {
        "token": "shared-secret",
        "body": [{"lead_id": "test", "phone": "+525539660807"}],
    }
