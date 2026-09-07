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


def test_contacted_without_capture_is_reported_without_reassignment(monkeypatch):
    requests = []

    class Client:
        def __init__(self, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

        async def get(self, url, **kwargs):
            requests.append(kwargs["params"])
            return _Response([{"external_event_id": "100"}])

        async def post(self, *args, **kwargs):
            raise AssertionError("observation must never mutate or reassign")

    monkeypatch.setattr(supa.httpx, "AsyncClient", Client)
    monkeypatch.setattr(supa, "_supa_cfg", lambda: ("https://example.test", "test"))
    settings = type("Settings", (), {"lead_routing_account_key": "default"})()
    rows = [
        {"lead_id": "100", "status": "Contactado"},
        {"lead_id": "200", "status": "Contactado", "listing_id": "300", "source_tab": "whatsapp"},
        {"lead_id": "200", "status": "Contactado", "listing_id": "300", "source_tab": "whatsapp"},
        {"lead_id": "400", "status": "Pendiente"},
    ]
    assert asyncio.run(supa.find_uncaptured_contacted_rows(settings, rows)) == [
        {"lead_id": "200", "listing_id": "300", "source_tab": "whatsapp", "status": "Contactado"}
    ]
    assert requests[0]["external_event_id"] == "in.(100,200)"

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
        if len(calls) > 1:
            return []
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
        ("claim", 1),
        ("finish", 31, "lease-31", {"success": True, "error_code": None}),
        ("claim", 1),
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
        return [claims.pop(0)] if claims else []

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
        return [row] if claim_calls % 2 else []

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
    assert claim_calls == 4
    assert finishes[-1] == {"success": True}


def test_v3_route_dispatch_blocks_incomplete_easybroker_property(monkeypatch):
    claim = {
        "capture_event_id": 31,
        "opportunity_id": 17,
        "disposition": "created_new",
        "i24_lead_id": "265183003",
        "property_public_id": None,
        "offer_context": {
            "name": "Prospecto",
            "listing_id": "150316170",
            "property": "Departamento",
        },
        "lease_token": "route-31",
    }
    finished = []

    async def claim_dispatches(limit=20):
        return [] if finished else [claim]

    async def finish(capture_event_id, lease_token, **kwargs):
        finished.append((capture_event_id, lease_token, kwargs))
        return True

    async def webhook(*args, **kwargs):
        raise AssertionError("an incomplete property must never reach n8n or WhatsApp")

    class Store:
        def mark_seen(self, leads):
            raise AssertionError("blocked dispatch must not be marked seen")

    monkeypatch.setattr(supa, "claim_v3_route_dispatches", claim_dispatches)
    monkeypatch.setattr(supa, "finish_v3_route_dispatch", finish)
    monkeypatch.setattr(main, "send_to_webhook", webhook)
    settings = type("Settings", (), {
        "webhook_url": "https://n8n.example/v3",
        "webhook_token": "tok",
    })()

    assert asyncio.run(main._run_v3_route_dispatch(settings, Store())) == []
    assert finished == [(
        31,
        "route-31",
        {"success": False, "error_code": "missing_property_public_id"},
    )]


def test_v3_main_orders_intake_contactado_then_webhook_and_skips_i24_notes():
    source = inspect.getsource(main.async_main)
    assert source.index("v3_intake_lead") < source.index("_run_v3_contactado")
    assert source.index("_run_v3_contactado") < source.index("_run_v3_route_dispatch")
    # V3 is the only path: no legacy advisor-note or webhook fan-out survives here.
    assert "write_pending_for_page" not in source
    assert "send_to_webhook" not in source
    dispatch = inspect.getsource(main._run_v3_route_dispatch)
    assert dispatch.index("send_to_webhook") > 0
    assert '"contactado_status": "verified"' in dispatch


def test_slow_work_does_not_consume_the_next_items_lease():
    """Each item takes 100 seconds; a batch lease would expire the third item."""
    clock = 0
    remaining = list(range(3))
    completed = []

    async def claim(limit):
        assert limit == 1
        if not remaining:
            return []
        return [{"id": remaining.pop(0), "expires": clock + 120}]

    async def run():
        nonlocal clock
        async for row in main._claim_v3_serially(claim):
            clock += 100
            assert clock < row["expires"]
            completed.append(row["id"])

    asyncio.run(run())
    assert completed == [0, 1, 2]


def test_serial_claim_still_bounds_work_per_scraper_cycle():
    calls = 0

    async def claim(limit):
        nonlocal calls
        calls += 1
        return [{"id": calls}]

    async def run():
        return [row async for row in main._claim_v3_serially(claim)]

    assert len(asyncio.run(run())) == calls == 20
