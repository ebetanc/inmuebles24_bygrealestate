"""Regression: browser/auth failure must not delay a released capture."""
import asyncio
from types import SimpleNamespace

from inmobiliaria24 import dispatch, main, supa


def test_ready_capture_dispatches_without_browser_and_is_not_repeated(monkeypatch, tmp_path):
    pending = True
    sent = []

    def browser_unavailable(*args, **kwargs):
        raise AssertionError("standalone dispatch must never start a browser")

    async def claim(limit):
        assert limit == 1
        return [{
            "capture_event_id": 304,
            "opportunity_id": 783,
            "i24_lead_id": "synthetic-304",
            "property_public_id": "EB-TEST1234",
            "disposition": "created_new",
            "offer_context": {"name": "Synthetic"},
            "lease_token": "lease-304",
        }] if pending else []

    async def send(leads, **kwargs):
        assert kwargs["idempotency_key"] == "v3-route:304"
        assert leads[0]["contactado_status"] == "verified"
        sent.extend(leads)

    async def finish(capture_id, token, **kwargs):
        nonlocal pending
        assert (capture_id, token, kwargs) == (304, "lease-304", {"success": True})
        pending = False
        return True

    monkeypatch.setattr(main, "async_playwright", browser_unavailable)
    monkeypatch.setattr(main, "launch_chrome", browser_unavailable)
    monkeypatch.setattr(main, "load_or_login", browser_unavailable)
    monkeypatch.setattr(supa, "claim_v3_route_dispatches", claim)
    monkeypatch.setattr(supa, "finish_v3_route_dispatch", finish)
    monkeypatch.setattr(main, "send_to_webhook", send)
    settings = SimpleNamespace(state_db_path=tmp_path / "state.db",
                               webhook_url="https://example.test/webhook", webhook_token="test")
    assert asyncio.run(dispatch.dispatch_once(settings)) == 1
    assert asyncio.run(dispatch.dispatch_once(settings)) == 0
    assert len(sent) == 1
