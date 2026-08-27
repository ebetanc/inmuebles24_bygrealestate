"""Focused V3 Inmuebles24 adapter tests; no production or Supabase calls."""
import asyncio
import inspect

from inmobiliaria24 import main, supa


class _Response:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self):
        return None

    def json(self):
        return self._payload


class _Client:
    def __init__(self, response):
        self.response = response
        self.calls = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def post(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        return self.response


def test_v3_intake_sends_durable_capture_before_downstream_effect(monkeypatch):
    client = _Client(_Response([{
        "disposition": "created_new",
        "opportunity_id": 17,
        "capture_event_id": 31,
        "contactado_status": "pending",
    }]))
    monkeypatch.setenv("SUPABASE_URL", "https://supabase.example")
    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "service-key")
    monkeypatch.setattr(supa.httpx, "AsyncClient", lambda **kwargs: client)

    class Settings:
        lead_routing_account_key = "byg"

    result = asyncio.run(supa.v3_intake_lead(Settings(), {
        "lead_id": "265183003",
        "portal_person_id": "person-7",
        "property_public_id": "eb-wr4713",
        "email": " Lead@Example.com ",
        "phone": "55 1111 2222",
        "name": "Prospecto",
    }))

    assert result["capture_event_id"] == 31
    assert len(client.calls) == 1
    _, request = client.calls[0]
    assert request["json"] == {
        "p_account_key": "byg",
        "p_idempotency_key": "i24:265183003",
        "p_source": "inmuebles24",
        "p_external_id": "265183003",
        "p_portal_person_id": "person-7",
        "p_property_public_id": "EB-WR4713",
        "p_email": "lead@example.com",
        "p_phone": None,
        "p_offer_context": {
            "lead_id": "265183003",
            "portal_person_id": "person-7",
            "property_public_id": "eb-wr4713",
            "email": " Lead@Example.com ",
            "phone": "55 1111 2222",
            "name": "Prospecto",
        },
    }


def test_v3_phone_accepts_only_explicit_e164_or_scraper_mexico_normalization():
    assert supa._v3_phone("55 1111 2222") is None
    assert supa._v3_phone("525511112222") == "+525511112222"
    assert supa._v3_phone("+52 55 1111 2222") == "+525511112222"


def test_v3_contactado_lease_uses_capture_event_id(monkeypatch):
    calls = []

    async def claim(limit=20):
        calls.append(("claim", limit))
        return [{
            "capture_event_id": 31,
            "opportunity_id": 17,
            "i24_lead_id": "265183003",
            "lease_token": "lease-31",
            "attempt": 1,
        }]

    async def finish(capture_event_id, lease_token, **kwargs):
        calls.append(("finish", capture_event_id, lease_token, kwargs))
        return True

    async def mark(page, lead, *, evidence):
        assert lead["lead_id"] == "265183003"
        evidence["portal_status"] = "Contactado"
        return True

    monkeypatch.setattr(supa, "claim_v3_i24_contact_effects", claim)
    monkeypatch.setattr(supa, "finish_v3_i24_contact_effect", finish)
    monkeypatch.setattr(main, "mark_lead_contacted", mark)

    result = asyncio.run(main._run_v3_contactado(object(), [{"lead_id": "265183003"}]))

    assert result == {"265183003"}
    assert calls == [
        ("claim", 20),
        ("finish", 31, "lease-31", {"success": True, "error_code": None}),
    ]


def test_v3_route_dispatch_recovers_when_lead_left_pendiente_scrape(monkeypatch):
    claims = [{
        "capture_event_id": 31,
        "opportunity_id": 17,
        "disposition": "created_new",
        "i24_lead_id": "265183003",
        "property_public_id": "EB-WR4713",
        "offer_context": {"name": "Prospecto", "phone": "525511112222"},
        "lease_token": "route-31",
    }]
    sent = []
    finished = []

    async def claim(limit=20):
        return claims

    async def finish(capture_event_id, lease_token, **kwargs):
        finished.append((capture_event_id, lease_token, kwargs))
        return True

    async def webhook(leads, **kwargs):
        sent.append((leads, kwargs))

    class Store:
        def __init__(self):
            self.seen = []

        def mark_seen(self, leads):
            self.seen.extend(leads)

    monkeypatch.setattr(supa, "claim_v3_route_dispatches", claim)
    monkeypatch.setattr(supa, "finish_v3_route_dispatch", finish)
    monkeypatch.setattr(main, "send_to_webhook", webhook)
    store = Store()

    # Empty current scrape proves dispatch uses durable offer_context, not page rows.
    result = asyncio.run(main._run_v3_route_dispatch(
        type("Settings", (), {"webhook_url": "https://n8n.example/v3", "webhook_token": "tok"})(),
        store,
    ))

    assert [row["lead_id"] for row in result] == ["265183003"]
    assert sent[0][0][0]["capture_event_id"] == 31
    assert sent[0][1]["idempotency_key"] == "v3-route:31"
    assert finished == [(31, "route-31", {"success": True})]
    assert store.seen[0]["contactado_status"] == "verified"


def test_v3_route_dispatch_failure_is_reclaimable(monkeypatch):
    row = {
        "capture_event_id": 31,
        "opportunity_id": 17,
        "disposition": "created_new",
        "i24_lead_id": "265183003",
        "property_public_id": "EB-WR4713",
        "offer_context": {"name": "Prospecto"},
        "lease_token": "route-31",
    }
    claim_calls = 0
    finishes = []

    async def claim(limit=20):
        nonlocal claim_calls
        claim_calls += 1
        return [row]

    async def finish(capture_event_id, lease_token, **kwargs):
        finishes.append(kwargs)
        return True

    async def webhook(leads, **kwargs):
        if len(finishes) == 0:
            raise RuntimeError("temporary n8n outage")

    class Store:
        def mark_seen(self, leads):
            raise AssertionError("failed dispatch must not be marked seen")

    monkeypatch.setattr(supa, "claim_v3_route_dispatches", claim)
    monkeypatch.setattr(supa, "finish_v3_route_dispatch", finish)
    monkeypatch.setattr(main, "send_to_webhook", webhook)
    settings = type("Settings", (), {
        "webhook_url": "https://n8n.example/v3", "webhook_token": "tok"
    })()

    assert asyncio.run(main._run_v3_route_dispatch(settings, Store())) == []
    assert finishes == [{"success": False, "error_code": "webhook_dispatch_failed"}]
    # Next worker cycle can claim same durable row after SQL retry deadline.
    class GoodStore:
        def __init__(self):
            self.seen = []

        def mark_seen(self, leads):
            self.seen.extend(leads)

    good_store = GoodStore()
    assert len(asyncio.run(main._run_v3_route_dispatch(settings, good_store))) == 1
    assert claim_calls == 2
    assert finishes[-1] == {"success": True}


def test_v3_main_orders_intake_contactado_then_webhook_and_skips_i24_notes():
    source = inspect.getsource(main.async_main)
    assert source.index("v3_intake_lead") < source.index("_run_v3_contactado")
    assert source.index("_run_v3_contactado") < source.index("send_to_webhook", source.index("_run_v3_contactado"))
    assert source.index("_run_v3_contactado") < source.index("_run_v3_route_dispatch")
    v3_block = source[source.index("if v3_enabled:"):source.index("else:", source.index("if v3_enabled:"))]
    assert "write_pending_for_page" not in v3_block
    assert '"contactado_status": "verified"' in inspect.getsource(main._run_v3_route_dispatch)
