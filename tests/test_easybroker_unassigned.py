"""Worker/parser behavior for unclaimed leads: RESPONSABLE: SIN ASIGNACIÓN.

Claims for leads nobody took arrive with responsible_first_name='SIN
ASIGNACIÓN', note_due=True, attended_due=False. The note must carry the
literal value and Atendida must never be marked for that claim. This mirrors
the fixture style of tests/test_claim_gate.py (not modified here, per task
scope).
"""
import asyncio

from easybroker import inbox
from easybroker import main as eb_main


def test_find_responsible_notes_recognizes_sin_asignacion():
    class Notes:
        async def all_inner_texts(self):
            return ["RESPONSABLE: SIN ASIGNACIÓN", "RESPONSABLE: Gina"]

    class Page:
        def get_by_text(self, pattern):
            return Notes()

    result = asyncio.run(inbox.find_responsible_notes(Page()))

    assert result == sorted(["RESPONSABLE: SIN ASIGNACIÓN", "RESPONSABLE: Gina"])
    assert inbox._responsible_from_note("RESPONSABLE: SIN ASIGNACIÓN") == "sin asignación"


def test_worker_writes_sin_asignacion_note_and_never_marks_atendida(monkeypatch):
    captured = []

    async def provider_rows(settings):
        return [{
            "eb_request_id": 40526079,
            "property_public_id": "EB-WT7488",
            "e164_phone": "+525599569566",
        }]

    async def claims(settings, limit):
        return [{
            "eb_request_id": 40526079,
            "responsible_first_name": "SIN ASIGNACIÓN",
            "lease_token": "lease",
            "note_due": True,
            "attended_due": False,
        }]

    async def attend(page, **kwargs):
        captured.append(kwargs)
        return {
            "found": True,
            "match_method": "property+identity",
            "status_ok": False,
            "note_ok": True,
            "status_changed": False,
            "note_changed": True,
        }

    async def finish(settings, **kwargs):
        captured.append({"finish": kwargs})
        return {"ok": True}

    monkeypatch.setattr(eb_main, "fetch_contact_requests", provider_rows)
    monkeypatch.setattr(eb_main, "claim_v3_easybroker_effects", claims)
    monkeypatch.setattr(eb_main, "attend_lead", attend)
    monkeypatch.setattr(eb_main, "finish_v3_easybroker_effect", finish)

    completed, failed = asyncio.run(eb_main._run_v3_effect_worker(object(), object()))

    assert (completed, failed) == (0, False)
    attend_calls = [c for c in captured if "note_text" in c]
    assert len(attend_calls) == 1
    assert attend_calls[0]["note_text"] == "RESPONSABLE: SIN ASIGNACIÓN"
    assert attend_calls[0]["status_done"] is True  # note step never asks the portal to set Atendida
    finish_calls = [c["finish"] for c in captured if "finish" in c]
    assert [c["step"] for c in finish_calls] == ["note"]  # attended step never runs


def test_worker_still_marks_atendida_when_attended_due(monkeypatch):
    captured = []

    async def provider_rows(settings):
        return [{
            "eb_request_id": 1,
            "property_public_id": "EB-1",
            "e164_phone": "+525599569566",
        }]

    async def claims(settings, limit):
        return [{
            "eb_request_id": 1,
            "responsible_first_name": "Gina",
            "lease_token": "lease",
            "note_due": False,
            "attended_due": True,
        }]

    async def attend(page, **kwargs):
        captured.append(kwargs)
        return {
            "found": True,
            "match_method": "property+identity",
            "status_ok": True,
            "note_ok": True,
            "status_changed": True,
            "note_changed": False,
        }

    async def finish(settings, **kwargs):
        captured.append({"finish": kwargs})
        return {"ok": True}

    monkeypatch.setattr(eb_main, "fetch_contact_requests", provider_rows)
    monkeypatch.setattr(eb_main, "claim_v3_easybroker_effects", claims)
    monkeypatch.setattr(eb_main, "attend_lead", attend)
    monkeypatch.setattr(eb_main, "finish_v3_easybroker_effect", finish)

    completed, failed = asyncio.run(eb_main._run_v3_effect_worker(object(), object()))

    assert (completed, failed) == (1, False)
    finish_calls = [c["finish"] for c in captured if "finish" in c]
    assert [c["step"] for c in finish_calls] == ["attended"]
