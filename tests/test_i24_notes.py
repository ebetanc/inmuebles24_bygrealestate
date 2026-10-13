import asyncio
import re
from types import SimpleNamespace

from inmobiliaria24 import i24_notes
from inmobiliaria24.config import Settings


def _row(text: str) -> str:
    return i24_notes.NOTE_ROW_TEMPLATE.format(text=re.escape(text))


class FakeLocator:
    def __init__(self, page, selector):
        self._page = page
        self._selector = selector

    async def count(self):
        return self._page.present.get(self._selector, 0)


class FakePage:
    """Records portal interactions; `present` maps a selector to its DOM count."""

    def __init__(self, present=None, on_submit=None):
        self.present = dict(present or {})
        self._on_submit = on_submit
        self.calls: list[tuple] = []

    def locator(self, selector):
        return FakeLocator(self, selector)

    async def click(self, selector, **kwargs):
        self.calls.append(("click", selector))
        if selector == i24_notes.NOTE_SUBMIT and self._on_submit:
            self._on_submit(self)

    async def fill(self, selector, value, **kwargs):
        self.calls.append(("fill", selector, value))

    async def wait_for_timeout(self, ms):
        self.calls.append(("wait", ms))

    async def is_disabled(self, selector, **kwargs):
        self.calls.append(("is_disabled", selector))
        return self.present.get("__submit_disabled__", 0) == 1


def _patch_navigation(monkeypatch, visited):
    async def navigate(page, url, **kwargs):
        visited.append(url)

    monkeypatch.setattr(i24_notes, "_navigate_spa", navigate)


def test_existing_note_is_never_written_twice(monkeypatch):
    visited: list[str] = []
    _patch_navigation(monkeypatch, visited)
    page = FakePage(present={_row("Gina"): 1})

    result = asyncio.run(i24_notes.write_internal_note(page, "266673624", "Gina"))

    assert result["ok"] is True
    assert result["already"] is True
    assert [call for call in page.calls if call[0] in ("fill", "click")] == []


def test_note_is_typed_and_verified_on_the_lead_conversation(monkeypatch):
    visited: list[str] = []
    _patch_navigation(monkeypatch, visited)

    def on_submit(page):
        page.present[_row("Gina")] = 1

    page = FakePage(
        present={i24_notes.NOTES_TAB_SELECTORS[0]: 1}, on_submit=on_submit
    )

    result = asyncio.run(i24_notes.write_internal_note(page, "266673624", "Gina"))

    assert visited == ["https://www.inmuebles24.com/panel/interesados/266673624"]
    assert result == {
        "ok": True,
        "already": False,
        "reason": None,
        "url": "https://www.inmuebles24.com/panel/interesados/266673624",
    }
    assert ("click", i24_notes.NOTES_TAB_SELECTORS[0]) in page.calls
    assert ("fill", i24_notes.NOTE_INPUT, "Gina") in page.calls
    assert ("click", i24_notes.NOTE_SUBMIT) in page.calls


def test_unverified_note_is_reported_as_failure(monkeypatch):
    _patch_navigation(monkeypatch, [])
    page = FakePage(present={i24_notes.NOTES_TAB_SELECTORS[0]: 1})

    result = asyncio.run(i24_notes.write_internal_note(page, "266673624", "Gina"))

    assert result["ok"] is False
    assert result["reason"] == "note_not_visible"


def test_missing_notes_tab_stops_before_typing(monkeypatch):
    _patch_navigation(monkeypatch, [])
    page = FakePage()

    result = asyncio.run(i24_notes.write_internal_note(page, "266673624", "Gina"))

    assert result["ok"] is False
    assert result["reason"] == "notes_tab_not_found"
    assert [call for call in page.calls if call[0] == "fill"] == []


def test_worker_closes_every_lease_including_the_failing_one(monkeypatch):
    finished: list[tuple] = []

    async def claim_v3_i24_notes(limit):
        return [
            {"opportunity_id": 1, "i24_lead_id": "111", "note_text": "Gina",
             "lease_token": "tok-1", "attempt": 1},
            {"opportunity_id": 2, "i24_lead_id": "222", "note_text": "Carol",
             "lease_token": "tok-2", "attempt": 3},
        ]

    async def finish_v3_i24_note(opportunity_id, token, ok, evidence):
        finished.append((opportunity_id, token, ok))
        return True

    supa = SimpleNamespace(
        claim_v3_i24_notes=claim_v3_i24_notes,
        finish_v3_i24_note=finish_v3_i24_note,
    )

    async def write(page, lead_id, text, *, evidence=None):
        if lead_id == "222":
            raise RuntimeError("portal down")
        return {"ok": True, "already": False, "reason": None, "url": ""}

    monkeypatch.setattr(i24_notes, "write_internal_note", write)
    _contactado(monkeypatch, {})

    written = asyncio.run(i24_notes.run_v3_i24_note_worker(FakePage(), supa))

    assert written == 1
    assert finished == [(1, "tok-1", True), (2, "tok-2", False)]


def _contactado(monkeypatch, outcomes: dict, marked=None):
    """outcomes: lead_id -> error_code; a missing lead_id means Contactado OK."""
    async def mark(page, lead, *, evidence=None):
        if marked is not None:
            marked.append(lead["lead_id"])
        if lead["lead_id"] in outcomes:
            evidence["error_code"] = outcomes[lead["lead_id"]]
            return False
        return True

    monkeypatch.setattr(i24_notes, "mark_lead_contacted", mark)


def test_worker_marks_contactado_before_the_note_and_skips_the_note_on_failure(monkeypatch):
    finished, typed, marked = [], [], []

    async def claim(limit):
        return [
            {"opportunity_id": 1, "i24_lead_id": "111", "note_text": "Lupita · V3 16:18",
             "lease_token": "t1", "attempt": 1},
            {"opportunity_id": 2, "i24_lead_id": "222", "note_text": "Gina · V3 10:00",
             "lease_token": "t2", "attempt": 1},
            {"opportunity_id": 3, "i24_lead_id": "333", "note_text": "Paty · V3 11:00",
             "lease_token": "t3", "attempt": 1},
        ]

    async def finish(opportunity_id, token, ok, evidence):
        finished.append((opportunity_id, ok))
        return True

    async def write(page, lead_id, text, *, evidence=None):
        typed.append(lead_id)
        return {"ok": True}

    monkeypatch.setattr(i24_notes, "write_internal_note", write)
    _contactado(monkeypatch, {"222": "status_chip_not_found",
                              "333": "unexpected_terminal_status"}, marked)
    supa = SimpleNamespace(claim_v3_i24_notes=claim, finish_v3_i24_note=finish)

    asyncio.run(i24_notes.run_v3_i24_note_worker(FakePage(), supa))

    assert marked == ["111", "222", "333"]
    # 222 failed Contactado: retried later, no note. 333 Finalizado: noted, left as is.
    assert typed == ["111", "333"]
    assert finished == [(1, True), (2, False), (3, True)]


def test_tokko_lead_pairs_only_with_a_single_matching_conversation():
    opps = [
        # Vanessa 1191: email matches
        {"opportunity_id": 1191, "email": "van.del.rosal@gmail.com", "phone": "+525564223458",
         "listing_id": "151311972", "property_public_id": "EB-WV7938"},
        # phone only (email differs in i24), matched by EB code
        {"opportunity_id": 2, "email": "otro@x.com", "phone": "+525511112222",
         "listing_id": "", "property_public_id": "EB-AAA111"},
        # same person on a different listing: no pair
        {"opportunity_id": 3, "email": "ana@x.com", "phone": "",
         "listing_id": "999", "property_public_id": "EB-ZZZ999"},
        # two conversations match: ambiguous, no pair
        {"opportunity_id": 4, "email": "dup@x.com", "phone": "",
         "listing_id": "555", "property_public_id": ""},
    ]
    rows = [
        {"lead_id": "900", "email": "Van.Del.Rosal@gmail.com", "phone": "5215500000000",
         "listing_id": "151311972", "property_public_id": "EB-WV7938"},
        {"lead_id": "901", "email": "", "phone": "525511112222",
         "listing_id": "777", "property_public_id": "eb-aaa111"},
        {"lead_id": "902", "email": "ana@x.com", "phone": "", "listing_id": "123",
         "property_public_id": "EB-OTRA01"},
        {"lead_id": "903", "email": "dup@x.com", "phone": "", "listing_id": "555",
         "property_public_id": ""},
        {"lead_id": "904", "email": "dup@x.com", "phone": "", "listing_id": "555",
         "property_public_id": ""},
    ]

    assert i24_notes.pair_tokko_leads(opps, rows) == [(1191, "900"), (2, "901")]


def test_note_worker_is_off_unless_explicitly_enabled(monkeypatch):
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.c")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "x")
    monkeypatch.delenv("I24_NOTES", raising=False)
    monkeypatch.delenv("WEBHOOK_URL", raising=False)

    assert Settings.load(env_file="/nonexistent.env").i24_notes_enabled is False
