import asyncio
from datetime import datetime, timedelta, timezone

import pytest

from inmobiliaria24.day_sla import is_day, parse_time, require_time
from inmobiliaria24.fast_inbox import normalize_row


def test_arrival_uses_portal_lead_time_not_advisor_reply():
    row = {
        "id": "wrong-group-id", "contact_publisher_user_id": "123456",
        "last_lead_date": "2026-09-07T14:00:13+00:00",
        "last_message": {"date": "2026-09-07T14:06:20+00:00"},
        "lead_user": {"name": "Prueba", "phone": "5512345678"},
        "posting": {"id": "987", "internal_code": "EB-QJ4964"},
        "contact_response_status": {"name": "Contactado"},
    }
    lead = normalize_row(row, "whatsapp")
    assert lead["lead_id"] == "123456"
    assert lead["phone"] == "525512345678"
    assert parse_time(lead["portal_received_at"]).minute == 0
    assert lead["status"] == "Contactado"  # Never silently discard human-touched rows.


@pytest.mark.parametrize("raw", ["2026-09-07T14:00:00", "", "not a date"])
def test_missing_timezone_or_arrival_rejected(raw):
    with pytest.raises(ValueError):
        parse_time(raw)


@pytest.mark.parametrize("utc,expected", [
    ("2026-09-07T14:04:59Z", False), ("2026-09-07T14:05:00Z", True),
    ("2026-09-08T01:59:59Z", True), ("2026-09-08T02:00:00Z", False),
])
def test_existing_night_boundary_unchanged(utc, expected):
    assert is_day(parse_time(utc)) is expected


def test_write_check_includes_network_reserve():
    require_time(None)
    require_time((datetime.now(timezone.utc)+timedelta(minutes=1)).isoformat())
    with pytest.raises(TimeoutError):
        require_time((datetime.now(timezone.utc)+timedelta(seconds=5)).isoformat())
    with pytest.raises(TimeoutError):
        require_time((datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat())


def test_eb_attended_cannot_click_after_deadline(monkeypatch):
    from easybroker import inbox
    clicks = []
    class Locator:
        @property
        def first(self): return self
        async def click(self, **kwargs): clicks.append("clicked")
    class Page:
        async def evaluate(self, script, *args):
            return "Pendiente" if script == inbox._TAG_STATUS_TRIGGER_JS else True
        def locator(self, selector): return Locator()
    async def noop(*args): pass
    monkeypatch.setattr(inbox, "_clear_tag", noop)
    monkeypatch.setattr(inbox.asyncio, "sleep", noop)
    with pytest.raises(TimeoutError):
        asyncio.run(inbox.set_status_atendida(Page(), deadline="2026-01-01T00:00:00Z"))
    assert len(clicks) == 1  # Opening the dropdown is safe; selecting Atendida was blocked.


def test_fast_reader_ignores_assets_redirects_and_counter_prefetches():
    from inmobiliaria24.fast_inbox import read_fast_inbox
    now = datetime.now(timezone.utc)
    class Response:
        status = 200
        def __init__(self, url, limit=20): self.url, self.limit = url, limit
        async def json(self):
            assert "/leads-api/publisher/leads" in self.url, "Unrelated body must never be read"
            return {"paging": {"offset": 0, "limit": self.limit, "total": 1}, "result": [{
                "contact_publisher_user_id": "123", "last_lead_date": now.isoformat(),
                "lead_user": {"name": "Prueba"}, "posting": {"internal_code": "EB-QJ4964"},
            }]}
    class Page:
        handler = None
        def on(self, name, handler): self.handler = handler
        def remove_listener(self, name, handler):
            assert self.handler == handler
            self.handler = None
        async def emit(self):
            await self.handler(Response("https://cdn.example.test/redirect.js"))
            await self.handler(Response("https://www.inmuebles24.com/leads-api/publisher/leads", 2))
            await self.handler(Response("https://www.inmuebles24.com/leads-api/publisher/leads"))
        async def goto(self, *args, **kwargs): await self.emit()
        def locator(self, selector): return self
        async def click(self, **kwargs): await self.emit()
    page = Page()
    rows = asyncio.run(read_fast_inbox(page, since=now-timedelta(seconds=1)))
    assert [r["lead_id"] for r in rows] == ["123"]
    assert page.handler is None
