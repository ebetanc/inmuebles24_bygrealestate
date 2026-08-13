import inspect
import asyncio
import os
import sys
from pathlib import Path

from easybroker import inbox
from easybroker import main as eb_main
from easybroker.main import async_main as easybroker_main
from easybroker.supa import fetch_pending_attend, finish_attend_attempt
from inmobiliaria24.main import async_main
from inmobiliaria24.scraper import _capture_i24_status_evidence, mark_lead_contacted
from inmobiliaria24.supa import (
    claim_pending_i24_contacts,
    fetch_pending_i24_notes,
    finish_i24_contact_attempt,
    validate_i24_contact_attempt,
)


def test_portal_side_effect_queries_require_a_genuine_claim():
    gate = "or=(claimed_via.is.null,claimed_via.neq.escalation,first_response_at.not.is.null)"
    assert gate in inspect.getsource(fetch_pending_i24_notes)
    sql = (Path(__file__).parents[1] / "whatsapp-agent/migrations/0033_easybroker_attend_effect_lease.sql").read_text()
    assert "c.claimed_via IS NULL OR c.claimed_via <> 'escalation' OR c.first_response_at IS NOT NULL" in sql


def test_i24_contact_queue_uses_atomic_durable_lease():
    source = inspect.getsource(claim_pending_i24_contacts)

    assert 'rpc/claim_i24_contact_effects' in source
    assert '"p_limit": limit' in source


def test_i24_contact_side_effect_uses_lease_then_retries_after_crash():
    source = inspect.getsource(async_main)

    claim = source.index("for contact in await claim_pending_i24_contacts()")
    portal_mutation = source.index("contacted = await mark_lead_contacted")
    result = source.index("await finish_i24_contact_attempt", portal_mutation)
    validate = source.index("await validate_i24_contact_attempt", claim)
    assert claim < validate < portal_mutation < result
    assert "assignment_changed_before_portal" in source
    assert 'contact["i24_lead_id"]' in source
    assert 'contact["lease_token"]' in source


def test_i24_contact_evidence_is_idempotent_and_pii_safe():
    recorder = inspect.getsource(finish_i24_contact_attempt)
    marker = inspect.getsource(mark_lead_contacted)
    screenshot = inspect.getsource(_capture_i24_status_evidence)

    assert 'rpc/finish_i24_contact_effect' in recorder
    assert '"p_lease_token": lease_token' in recorder
    assert "rpc/validate_i24_contact_effect" in inspect.getsource(validate_i24_contact_attempt)
    assert "full_page=True" not in marker
    assert "sha256" in screenshot
    assert ".locator(" in screenshot


def test_i24_effect_migration_serializes_workers_and_revalidates_assignment():
    sql = (Path(__file__).parents[1] / "whatsapp-agent/migrations/0032_i24_contact_effect_lease.sql").read_text()
    compact = " ".join(sql.lower().split())

    assert "for update of o, c skip locked" in compact
    assert "c.assigned_agent_id=o.assigned_agent_id" in compact
    assert "e.status='leased' and e.lease_expires_at<=p_now" in compact
    assert "select candidate.opportunity_id, candidate.assigned_agent_id, candidate.i24_lead_id" in compact
    assert "from candidates as candidate" in compact
    assert "on conflict on constraint lead_routing_i24_contact_effects_pkey do update" in compact
    assert "select claimed_effect.opportunity_id, 'i24_contact_claimed', claimed_effect.assigned_agent_id" in compact
    assert "from claimed as claimed_effect" in compact
    assert "select opportunity_id, assigned_agent_id, i24_lead_id" not in compact
    assert "on conflict(opportunity_id)" not in compact
    assert "where opportunity_id=p_opportunity_id for update" in compact
    assert "v_effect.lease_token is distinct from p_lease_token" in compact
    assert "v_event.event_type is distinct from (case when v_effective_success then 'i24_contacted' else 'i24_contact_attempt' end)" in compact
    assert "is distinct from case when p_success" not in compact
    assert "public.validate_i24_contact_effect(bigint,uuid)" in compact
    assert "from public, anon, authenticated" in compact
    assert "to service_role" in compact
    assert compact.rindex("insert into public.lead_routing_events") < compact.index("update public.lead_routing_i24_contact_effects set status=case when v_effective_success")


def test_i24_success_revalidates_assignment_and_audits_drift():
    sql = (Path(__file__).parents[1] / "whatsapp-agent/migrations/0032_i24_contact_effect_lease.sql").read_text()
    compact = " ".join(sql.lower().split())

    assert "for share of opportunity, conversation" in compact
    assert "opportunity.state='assigned'" in compact
    assert "opportunity.assigned_agent_id=effect.assigned_agent_id" in compact
    assert "conversation.assigned_agent_id=effect.assigned_agent_id" in compact
    assert "v_effective_success:=p_success and public.validate_i24_contact_effect" in compact
    assert "assignment_changed_before_completion" in compact
    assert "case when v_effective_success then 'i24_contacted' else 'i24_contact_attempt' end" in compact


def test_easybroker_pending_rows_include_exact_request_and_step_flags():
    source = inspect.getsource(fetch_pending_attend)
    assert "rpc/claim_easybroker_attend_effects" in source
    assert 'json={"p_limit": 20}' in source


def test_easybroker_effect_uses_atomic_lease_before_ui_and_token_bound_finish():
    main_source = inspect.getsource(easybroker_main)
    finish_source = inspect.getsource(finish_attend_attempt)
    sql = (Path(__file__).parents[1] / "whatsapp-agent/migrations/0033_easybroker_attend_effect_lease.sql").read_text()
    compact = " ".join(sql.lower().split())

    claim = main_source.index("fetch_pending_attend(settings)")
    portal = main_source.index("res = await attend_lead(", claim)
    finish = main_source.index("evidence_ok = await finish_attend_attempt(", portal)
    assert claim < portal < finish
    assert 'l["lease_token"]' in main_source
    assert "rpc/finish_easybroker_attend_effect" in finish_source
    assert '"p_lease_token": lease_token' in finish_source
    assert "for update of c skip locked" in compact
    assert "eb_effect_lease_expires_at" in compact
    assert "v_conversation.eb_effect_lease_token is distinct from p_lease_token" in compact
    assert "v_conversation.eb_effect_lease_expires_at <= p_now" in compact
    assert "revoke all on function public.claim_easybroker_attend_effects" in compact
    assert "to service_role" in compact


def test_easybroker_pg_fixture_covers_two_workers_crash_and_retry():
    fixture = (Path(__file__).parent / "fixtures/routing_v2/test_easybroker_effect_lease.sql").read_text()
    assert "second worker claimed leased fixture" in fixture
    assert "expired lease was not recovered with a fresh token" in fixture
    assert "stale worker finished replacement lease" in fixture
    assert "retry did not receive separate step evidence" in fixture


def test_easybroker_exact_request_navigation_uses_id_url(monkeypatch):
    class Page:
        url = ""

    page = Page()

    async def navigate(target, href):
        assert href == "/agent/conversations/222"
        target.url = "https://www.easybroker.com/agent/conversations/222"
        return True

    monkeypatch.setattr(inbox, "_open_conv_href", navigate)

    assert asyncio.run(inbox.find_request_by_id(page, 222)) is True
    assert asyncio.run(inbox.find_request_by_id(page, "not-an-id")) is False


def test_attend_lead_uses_exact_request_id_and_skips_completed_note(monkeypatch):
    calls = []

    async def yes(*args, **kwargs):
        return True

    async def open_exact(page, request_id):
        calls.append(("request", request_id))
        return True

    async def add_note(page, text):
        calls.append(("note", text))
        return True

    async def set_status(page):
        calls.append(("status", None))
        return True

    monkeypatch.setattr(inbox, "goto_buzon", yes)
    monkeypatch.setattr(inbox, "find_request_by_id", open_exact)
    monkeypatch.setattr(inbox, "note_exists", yes)
    monkeypatch.setattr(inbox, "add_note", add_note)
    monkeypatch.setattr(inbox, "set_status_atendida", set_status)

    result = asyncio.run(inbox.attend_lead(
        object(), request_id=222, phone="5551112222", agent_name="Ana",
        note_done=True, status_done=False,
    ))

    assert result == {
        "found": True,
        "match_method": "request_id",
        "status_ok": True,
        "note_ok": True,
        "status_changed": True,
        "note_changed": False,
    }
    assert calls == [("request", 222), ("status", None)]


def test_same_phone_opportunities_open_only_the_requested_easybroker_id(monkeypatch):
    opened = []

    async def yes(*args, **kwargs):
        return True

    async def open_exact(page, request_id):
        opened.append(request_id)
        return True

    async def no_phone_lookup(*args, **kwargs):
        raise AssertionError("phone lookup must not run without explicit fallback")

    monkeypatch.setattr(inbox, "goto_buzon", yes)
    monkeypatch.setattr(inbox, "find_request_by_id", open_exact)
    monkeypatch.setattr(inbox, "find_request_by_phone", no_phone_lookup)

    for request_id in (222, 333):
        result = asyncio.run(inbox.attend_lead(
            object(), request_id=request_id, phone="5551112222", agent_name="Ana",
            note_done=True, status_done=True,
        ))
        assert result["match_method"] == "request_id"

    assert opened == [222, 333]


def test_easybroker_note_retry_reconciles_after_crash_without_duplicate(monkeypatch):
    notes = set()
    calls = []

    async def yes(*args, **kwargs):
        return True

    async def existing(page, text):
        calls.append(("check", text))
        return text in notes

    async def add(page, text):
        calls.append(("add", text))
        notes.add(text)
        return True

    monkeypatch.setattr(inbox, "goto_buzon", yes)
    monkeypatch.setattr(inbox, "find_request_by_id", yes)
    monkeypatch.setattr(inbox, "note_exists", existing)
    monkeypatch.setattr(inbox, "add_note", add)
    monkeypatch.setattr(inbox, "set_status_atendida", yes)

    first = asyncio.run(inbox.attend_lead(
        object(), request_id=222, agent_name="Ana", note_done=False, status_done=False,
    ))
    # Simulate a crash before mark_note_added persisted the successful portal write.
    second = asyncio.run(inbox.attend_lead(
        object(), request_id=222, agent_name="Ana", note_done=False, status_done=True,
    ))

    marker = "Atendido por Ana [BYG-EB:222]"
    assert calls.count(("add", marker)) == 1
    assert first["note_ok"] is True
    assert second["note_ok"] is True
    assert second["note_changed"] is True  # asks main to reconcile durable evidence


class _FakeChromeContext:
    async def close(self):
        pass


class _FakeChromeProc:
    def terminate(self):
        pass

    def wait(self, timeout=None):
        pass


class _FakePlaywrightCtx:
    async def __aenter__(self):
        return object()

    async def __aexit__(self, *exc_info):
        return False


async def _fake_launch_chrome(pw, headless=False):
    return _FakeChromeContext(), _FakeChromeProc()


async def _fake_load_or_login(context, settings):
    class Page:
        url = "https://www.easybroker.com/agent/conversations"

    return Page()


def test_once_cli_wires_request_id_into_attend_lead(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["easybroker", "--once", "999", "--agent", "Ana"])
    args = eb_main._parse_args()
    assert args.once == "999"

    monkeypatch.setenv("EASYBROKER_EMAIL", "bot@example.com")
    monkeypatch.setenv("EASYBROKER_PASSWORD", "secret")
    monkeypatch.delenv("EB_MARK_ATTENDED", raising=False)
    monkeypatch.setattr(eb_main, "launch_chrome", _fake_launch_chrome)
    monkeypatch.setattr(eb_main, "load_or_login", _fake_load_or_login)
    monkeypatch.setattr(eb_main, "async_playwright", lambda: _FakePlaywrightCtx())

    calls = {}

    async def fake_attend_lead(page, **kwargs):
        calls.update(kwargs)
        return {
            "found": True, "match_method": "request_id", "status_ok": True,
            "note_ok": True, "status_changed": True, "note_changed": True,
        }

    monkeypatch.setattr(eb_main, "attend_lead", fake_attend_lead)

    exit_code = asyncio.run(eb_main.async_main(args))

    assert exit_code == 0
    assert calls["request_id"] == "999"  # this must break if --once stops feeding request_id
    assert calls["agent_name"] == "Ana"
    assert os.environ["EB_MARK_ATTENDED"] == "1"


def test_default_poll_and_once_paths_never_enable_phone_fallback(monkeypatch):
    monkeypatch.setenv("EASYBROKER_EMAIL", "bot@example.com")
    monkeypatch.setenv("EASYBROKER_PASSWORD", "secret")
    monkeypatch.setattr(eb_main, "launch_chrome", _fake_launch_chrome)
    monkeypatch.setattr(eb_main, "load_or_login", _fake_load_or_login)
    monkeypatch.setattr(eb_main, "async_playwright", lambda: _FakePlaywrightCtx())

    captured_kwargs = []

    async def fake_attend_lead(page, **kwargs):
        captured_kwargs.append(kwargs)
        return {
            "found": True, "match_method": "request_id", "status_ok": True,
            "note_ok": True, "status_changed": True, "note_changed": True,
        }

    monkeypatch.setattr(eb_main, "attend_lead", fake_attend_lead)

    # --once path
    monkeypatch.delenv("EB_MARK_ATTENDED", raising=False)
    monkeypatch.setattr(sys, "argv", ["easybroker", "--once", "999"])
    once_args = eb_main._parse_args()
    assert asyncio.run(eb_main.async_main(once_args)) == 0

    # default poll path (gate forced on)
    monkeypatch.setenv("EB_MARK_ATTENDED", "1")

    async def fake_fetch_pending_attend(settings):
        return [{
            "eb_contact_id": 222, "lead_phone": "5551112222", "agent_name": "Ana",
            "eb_note_added": False, "eb_marked_attended": False,
            "conversation_id": "conv-1", "lease_token": "tok-1",
        }]

    async def fake_finish_attend_attempt(settings, conversation_id, lease_token, **kwargs):
        return True

    monkeypatch.setattr(eb_main, "fetch_pending_attend", fake_fetch_pending_attend)
    monkeypatch.setattr(eb_main, "finish_attend_attempt", fake_finish_attend_attempt)
    monkeypatch.setattr(sys, "argv", ["easybroker"])
    default_args = eb_main._parse_args()
    assert asyncio.run(eb_main.async_main(default_args)) == 0

    assert len(captured_kwargs) == 2  # one from --once, one from the default poll loop
    for kwargs in captured_kwargs:
        assert kwargs.get("allow_phone_fallback", False) is False


def test_add_note_reports_failure_when_note_not_visible_after_save(monkeypatch):
    class Locator:
        def __init__(self):
            self.first = self

        async def click(self):
            return None

        async def count(self):
            return 1

        async def wait_for(self, **kwargs):
            return None

        async def fill(self, text):
            return None

    class Page:
        async def evaluate(self, js):
            return True

        def locator(self, selector):
            return Locator()

        def get_by_placeholder(self, pattern):
            return Locator()

        def get_by_role(self, role, name=None):
            return Locator()

    async def no_sleep(_):
        return None

    async def cleared(page, tag):
        return None

    seen = {}

    async def verify(page, text):
        seen["text"] = text
        return seen["result"]

    monkeypatch.setattr(inbox.asyncio, "sleep", no_sleep)
    monkeypatch.setattr(inbox, "_clear_tag", cleared)
    monkeypatch.setattr(inbox, "note_exists", verify)

    # Portal silently drops the note: Guardar clicked but note never appears.
    seen["result"] = False
    assert asyncio.run(inbox.add_note(Page(), "[BYG-EB:222] nota")) is False
    # Note visible after save -> success.
    seen["result"] = True
    assert asyncio.run(inbox.add_note(Page(), "[BYG-EB:222] nota")) is True
    assert seen["text"] == "[BYG-EB:222] nota"
