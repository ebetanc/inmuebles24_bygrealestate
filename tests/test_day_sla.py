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
