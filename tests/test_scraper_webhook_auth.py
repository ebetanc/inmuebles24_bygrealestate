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


@pytest.mark.parametrize("receipt", [
    None, [], {}, {"accepted": False, "capture_event_id": 31, "opportunity_id": 17},
    {"accepted": True, "capture_event_id": 32, "opportunity_id": 17},
    {"accepted": True, "capture_event_id": 31, "opportunity_id": 18},
])
def test_v3_dispatch_rejects_a_200_without_its_durable_receipt(monkeypatch, receipt):
    def handler(request):
        return httpx.Response(200, json=receipt, request=request)

    real_client = httpx.AsyncClient
    monkeypatch.setattr(scraper.httpx, "AsyncClient", lambda **kwargs:
                        real_client(transport=httpx.MockTransport(handler), **kwargs))
    monkeypatch.setattr(scraper, "MAX_RETRIES", 1)
    with pytest.raises(ValueError):
        asyncio.run(scraper.send_to_webhook(
            [{"capture_event_id": 31, "opportunity_id": 17}],
            "https://n8n.example/webhook/scraper-leads", "test-token",
            idempotency_key="v3-route:31",
        ))


def test_v3_dispatch_retries_with_the_same_identity_until_receipt_matches(monkeypatch):
    requests = []

    def handler(request):
        requests.append(request)
        if len(requests) == 1:
            return httpx.Response(200, text="Workflow was started", request=request)
        return httpx.Response(200, json={
            "accepted": True, "capture_event_id": 31, "opportunity_id": 17,
        }, request=request)

    real_client = httpx.AsyncClient
    monkeypatch.setattr(scraper.httpx, "AsyncClient", lambda **kwargs:
                        real_client(transport=httpx.MockTransport(handler), **kwargs))
    monkeypatch.setattr(scraper, "RETRY_BASE_DELAY", 0)
    asyncio.run(scraper.send_to_webhook(
        [{"capture_event_id": 31, "opportunity_id": 17}],
        "https://n8n.example/webhook/scraper-leads", "test-token",
        idempotency_key="v3-route:31",
    ))
    assert len(requests) == 2
    assert requests[0].content == requests[1].content
    assert all(r.headers['X-I24-Idempotency-Key'] == 'v3-route:31' for r in requests)
