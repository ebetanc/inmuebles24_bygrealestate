"""Local contract tests for the one-shot I24 -> EasyBroker bridge."""
import asyncio
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest
import httpx

from easybroker import supa
from easybroker.config import EBSettings


ROOT = Path(__file__).parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260828100000_lead_routing_v3_easybroker_creation.sql"
FORWARD_MIGRATION = ROOT / "supabase" / "migrations" / "20260828104617_fix_v3_easybroker_creation_claim.sql"
EVIDENCE_MERGE_MIGRATION = ROOT / "supabase" / "migrations" / "20260828180500_fix_v3_easybroker_creation_evidence_merge.sql"
MANUAL_RETRY_MIGRATION = ROOT / "supabase" / "migrations" / "20260828190000_add_manual_easybroker_retry_gate.sql"
MANUAL_RETRY_CONSTRAINT_FIX = ROOT / "supabase" / "migrations" / "20260828191500_fix_manual_retry_post_count_constraint.sql"
AGENT_GRANT_MIGRATION = ROOT / "supabase" / "migrations" / "20260829124733_grant_v3_easybroker_effect_agent_read.sql"
AGENT_LOCK_FIX_MIGRATION = ROOT / "supabase" / "migrations" / "20260829125103_fix_v3_easybroker_effect_agent_lock.sql"
ACCOUNT_API_RETRY_MIGRATION = ROOT / "supabase" / "migrations" / "20260829134500_allow_account_api_retry_for_legacy_attempts.sql"
ACCOUNT_API_AUDIT_FIX = ROOT / "supabase" / "migrations" / "20260829134900_fix_account_api_retry_audit_constraint.sql"


def test_creation_gate_is_off_by_default_and_explicit(monkeypatch):
    monkeypatch.setenv("EASYBROKER_EMAIL", "bot@example.com")
    monkeypatch.setenv("EASYBROKER_PASSWORD", "password")
    monkeypatch.delenv("EASYBROKER_CREATE_REQUESTS", raising=False)
    assert EBSettings.load("/dev/null").easybroker_create_requests is False
    monkeypatch.setenv("EASYBROKER_CREATE_REQUESTS", "1")
    assert EBSettings.load("/dev/null").easybroker_create_requests is True


def test_creation_payload_is_allowlisted():
    payload = supa._creation_payload({
        "i24_lead_id": "107",
        "property_public_id": " eb-abcd1 ", "normalized_email": "a@b.test",
        "e164_phone": "+525511112222", "offer_context": {
            "name": "Lead", "message_preview": "Hola", "secret": "must not cross",
        },
    })
    assert payload == {
        "name": "Lead", "phone": "+525511112222", "email": "a@b.test",
        "property_id": "EB-ABCD1", "message": "Hola", "source": "inmuebles24.com",
    }


def test_creation_payload_has_required_source_and_message_fallback():
    payload = supa._creation_payload({
        "i24_lead_id": "108", "property_public_id": "EB-X",
        "offer_context": {"name": "Lead"},
    })
    assert "remote_id" not in payload
    assert payload["source"] == "inmuebles24.com"
    assert payload["message"] == "Nuevo lead de Inmuebles24."


def test_creation_gate_fails_closed_without_account_key(monkeypatch):
    settings = SimpleNamespace(easybroker_create_requests=True, supabase_url="https://supa",
                               supabase_service_key="key", api_key="")
    # No network calls are permitted when the account key is absent.
    monkeypatch.setattr(supa, "claim_v3_easybroker_request_creations",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("claim must not run")))
    import asyncio
    assert asyncio.run(supa.create_pending_easybroker_requests(settings)) == []


@pytest.mark.asyncio
async def test_account_post_uses_account_endpoint_and_key(monkeypatch):
    calls = []

    class Response:
        status_code = 200
        content = b'{"status":"successful"}'

        @staticmethod
        def json():
            return {"status": "successful"}

    class Client:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def post(self, url, **kwargs):
            calls.append((url, kwargs))
            return Response()

    monkeypatch.setattr(supa.httpx, "AsyncClient", Client)
    settings = SimpleNamespace(api_key="account-key")
    claim = {
        "property_public_id": "EB-ABCD1",
        "normalized_email": "a@b.test",
        "offer_context": {"name": "Lead"},
    }

    result = await supa.post_v3_easybroker_contact_request(settings, claim)

    assert calls[0][0] == "https://api.easybroker.com/v1/contact_requests"
    assert calls[0][1]["headers"] == {
        "X-Authorization": "account-key", "Content-Type": "application/json",
    }
    assert calls[0][1]["json"]["source"] == "inmuebles24.com"
    assert result["kind"] == "ambiguous"
    assert result["status_code"] == 200


def test_creation_match_rejects_contradictory_identity_and_outside_horizon():
    claim = {
        "property_public_id": "EB-ABCD1", "normalized_email": "a@b.test",
        "e164_phone": "+525511112222",
        "correlation_window_start_at": "2026-08-28T10:00:00Z",
        "correlation_horizon_at": "2026-08-29T10:00:00Z",
    }
    row = {"id": 99, "property_id": "EB-ABCD1", "email": "a@b.test",
           "phone_e164": "+525511112222", "happened_at": "2026-08-28T11:00:00Z"}
    assert supa._creation_match(claim, row)
    row["email"] = "other@b.test"
    assert not supa._creation_match(claim, row)
    row["email"] = "a@b.test"
    row["happened_at"] = "2026-08-30T11:00:00Z"
    assert not supa._creation_match(claim, row)


def test_creation_match_requires_claimed_remote_request_id():
    claim = {
        "remote_request_id": 100,
        "property_public_id": "EB-ABCD1", "normalized_email": "a@b.test",
        "e164_phone": "+525511112222",
        "correlation_window_start_at": "2026-08-28T10:00:00Z",
        "correlation_horizon_at": "2026-08-29T10:00:00Z",
    }
    row = {"id": 101, "property_id": "EB-ABCD1", "email": "a@b.test",
           "phone_e164": "+525511112222", "happened_at": "2026-08-28T11:00:00Z"}
    assert not supa._creation_match(claim, row)
    row["id"] = 100
    assert supa._creation_match(claim, row)


def test_creation_migration_has_one_shot_ledger_and_recovery_rules():
    sql = MIGRATION.read_text(encoding="utf-8").lower()
    assert "easybroker_contact_request_creation_ledger" in sql
    assert "primary key" in sql and "capture_event_id" in sql
    assert "post_attempt_count between 0 and 1" in sql
    assert "post_attempt_count=1" in sql
    assert "state in ('pending','recovery')" in sql
    assert "(l.state='recovery' or l.post_attempt_count=0)" not in sql
    assert "l.post_attempt_count=0" in sql
    assert "e.happened_at >= timestamptz '2026-08-28t17:00:05.020z'" in sql
    assert "e.created_at >= timestamptz '2026-08-28t17:00:05.020z'" not in sql
    assert "capture_event_id > 108" not in sql
    assert "external_event_id text not null" in sql
    assert "i24_lead_id text not null" in sql
    assert "unique (account_key, i24_lead_id)" in sql
    assert "on conflict on constraint easybroker_creation_lead_uniq do nothing" in sql
    assert "on conflict (account_key, i24_lead_id) do nothing" not in sql
    assert "set state='leased'" not in sql
    assert "p_preexisting boolean" in sql
    assert "enable row level security" in sql
    assert "grant execute" in sql and "service_role" in sql
    assert "reserve_v3_easybroker_request_creation" in sql


def test_forward_claim_fix_uses_named_unique_constraint_only():
    sql = FORWARD_MIGRATION.read_text(encoding="utf-8").lower()
    assert "create or replace function public.claim_v3_easybroker_request_creations" in sql
    assert "on conflict on constraint easybroker_creation_lead_uniq do nothing" in sql
    assert "on conflict (account_key, i24_lead_id)" not in sql
    assert "revoke all on function public.claim_v3_easybroker_request_creations" in sql
    assert "grant execute on function public.claim_v3_easybroker_request_creations" in sql


def test_forward_evidence_fix_merges_existing_evidence():
    sql = EVIDENCE_MERGE_MIGRATION.read_text(encoding="utf-8").lower()
    assert "create or replace function public.finish_v3_easybroker_request_creation" in sql
    assert "response_evidence=response_evidence || coalesce(p_evidence,'{}'::jsonb)" in sql
    assert "revoke all on function public.finish_v3_easybroker_request_creation" in sql
    assert "grant execute on function public.finish_v3_easybroker_request_creation" in sql


def test_manual_retry_is_explicit_and_capped():
    sql = MANUAL_RETRY_MIGRATION.read_text(encoding="utf-8").lower()
    assert "authorize_v3_easybroker_request_retry" in sql
    assert "manual_retry_authorized_at" in sql
    assert "r.state <> 'recovery'" in sql
    assert "r.post_attempt_count <> 1" in sql
    assert "p_manual_retry boolean default false" in sql
    assert "if p_manual_retry and not (" in sql
    assert "r.post_attempt_count=1 and r.manual_retry_authorized_at is not null" in sql
    assert "set post_attempt_count=post_attempt_count+1" in sql
    assert "manual_retry_consumed_at=case when p_manual_retry then p_now" in sql
    assert "post_attempt_count >= 2" in sql
    # The ordinary worker call does not opt into the retry path.
    main = (ROOT / "src" / "easybroker" / "supa.py").read_text(encoding="utf-8").lower()
    assert "manual_retry: bool = false" in main
    assert '"p_manual_retry": manual_retry' in main
    assert "manual_retry_capture_ids: frozenset[int] = frozenset()" in main


def test_manual_retry_drops_the_original_truncated_one_attempt_constraint():
    initial = MANUAL_RETRY_MIGRATION.read_text(encoding="utf-8").lower()
    forward = MANUAL_RETRY_CONSTRAINT_FIX.read_text(encoding="utf-8").lower()
    old_name = "easybroker_contact_request_creation_le_post_attempt_count_check"
    assert f"drop constraint if exists {old_name}" in initial
    assert f"drop constraint if exists {old_name}" in forward
    assert "post_attempt_count <= 2" in forward


def test_effect_agent_lookup_is_service_only_and_read_only():
    grant_sql = AGENT_GRANT_MIGRATION.read_text(encoding="utf-8").lower()
    fix_sql = AGENT_LOCK_FIX_MIGRATION.read_text(encoding="utf-8").lower()
    assert "grant select on table public.agents to service_role" in grant_sql
    assert "grant update" not in grant_sql
    assert "security invoker" in fix_sql
    assert "from public.agents a" in fix_sql
    assert "for share" not in fix_sql
    assert "from public, anon, authenticated, service_role" in fix_sql
    assert "to service_role" in fix_sql


def test_legacy_retry_is_audited_and_restricted_to_107_108():
    sql = ACCOUNT_API_RETRY_MIGRATION.read_text(encoding="utf-8").lower()
    audit_sql = ACCOUNT_API_AUDIT_FIX.read_text(encoding="utf-8").lower()
    assert "p_capture_event_id not in (107, 108)" in sql
    assert "post_attempt_count between 0 and 3" in sql
    assert "post_attempt_count <> 2" in sql
    assert "account_api_retry_authorized_at" in sql
    assert "account_api_retry_consumed_at" in sql
    assert "security invoker" in sql
    assert "from public, anon, authenticated, service_role" in sql
    assert "to service_role" in sql
    assert "drop constraint if exists easybroker_creation_manual_retry_audit" in audit_sql
    assert "post_attempt_count = 3" in audit_sql
    assert "capture_event_id in (107, 108)" in audit_sql
    assert "account_api_retry_consumed_at is not null" in audit_sql


@pytest.mark.asyncio
async def test_preexisting_request_skips_post(monkeypatch):
    settings = SimpleNamespace(easybroker_create_requests=True, supabase_url="https://supa",
                               supabase_service_key="key", api_key="eb", partner_api_key="partner", partner_country_code="MX", account_key="default")
    claim = {"capture_event_id": 107, "opportunity_id": 588, "lease_token": "lease",
             "property_public_id": "EB-ABCD1", "normalized_email": "a@b.test",
             "e164_phone": "+525511112222", "correlation_window_start_at": "2026-08-28T10:00:00Z",
             "correlation_horizon_at": "2026-08-29T10:00:00Z", "offer_context": {"name": "Lead"}}
    row = {"id": 40506164, "property_id": "EB-ABCD1", "email": "a@b.test",
           "phone_e164": "+525511112222", "happened_at": "2026-08-28T11:00:00Z"}
    monkeypatch.setattr(supa, "claim_v3_easybroker_request_creations", lambda *a, **k: _async([claim]))
    monkeypatch.setattr(supa, "fetch_contact_requests", lambda *a, **k: _async([supa.sanitize_contact_request(row)]))
    monkeypatch.setattr(supa, "ingest_contact_request_batch", lambda *a, **k: _async({"ok": True}))
    monkeypatch.setattr(supa, "correlate_easybroker_request", lambda *a, **k: _async({"ok": True, "state": "linked"}))
    monkeypatch.setattr(supa, "enqueue_v3_easybroker_effect", lambda *a, **k: _async({"ok": True, "state": "pending"}))
    monkeypatch.setattr(supa, "finish_v3_easybroker_request_creation", lambda *a, **k: _async({"ok": True}))
    post = False
    async def fail_post(*args, **kwargs):
        nonlocal post
        post = True
        return {}
    monkeypatch.setattr(supa, "post_v3_easybroker_contact_request", fail_post)
    result = await supa.create_pending_easybroker_requests(settings)
    assert result[0]["state"] == "preexisting"
    assert post is False


@pytest.mark.asyncio
async def test_exact_link_without_effect_enqueue_stays_recoverable(monkeypatch):
    settings = SimpleNamespace(easybroker_create_requests=True, supabase_url="https://supa",
                               supabase_service_key="key", api_key="eb", account_key="default")
    claim = {"capture_event_id": 107, "opportunity_id": 588, "lease_token": "lease",
             "property_public_id": "EB-ABCD1", "normalized_email": "a@b.test",
             "e164_phone": "+525511112222", "correlation_window_start_at": "2026-08-28T10:00:00Z",
             "correlation_horizon_at": "2026-08-29T10:00:00Z", "offer_context": {"name": "Lead"}}
    row = {"id": 40506164, "property_id": "EB-ABCD1", "email": "a@b.test",
           "phone_e164": "+525511112222", "happened_at": "2026-08-28T11:00:00Z"}
    monkeypatch.setattr(supa, "claim_v3_easybroker_request_creations", lambda *a, **k: _async([claim]))
    monkeypatch.setattr(supa, "fetch_contact_requests", lambda *a, **k: _async([supa.sanitize_contact_request(row)]))
    monkeypatch.setattr(supa, "ingest_contact_request_batch", lambda *a, **k: _async({"ok": True}))
    monkeypatch.setattr(supa, "correlate_easybroker_request", lambda *a, **k: _async({"ok": True, "state": "linked"}))
    monkeypatch.setattr(supa, "enqueue_v3_easybroker_effect", lambda *a, **k: _async({"ok": False, "state": "awaiting"}))
    calls = []

    async def finish(*args, **kwargs):
        calls.append(kwargs)
        return {"ok": True}

    monkeypatch.setattr(supa, "finish_v3_easybroker_request_creation", finish)
    result = await supa.create_pending_easybroker_requests(settings)
    assert result[0]["state"] == "recovery"
    assert calls[0]["error"] == "preexisting_correlation_or_effect_not_confirmed"


@pytest.mark.asyncio
async def test_preexisting_correlation_failure_never_marks_created(monkeypatch):
    settings = SimpleNamespace(easybroker_create_requests=True, supabase_url="https://supa",
                               supabase_service_key="key", api_key="eb", partner_api_key="partner", partner_country_code="MX", account_key="default")
    claim = {"capture_event_id": 107, "opportunity_id": 588, "lease_token": "lease",
             "post_allowed": False, "property_public_id": "EB-ABCD1", "normalized_email": "a@b.test",
             "e164_phone": "+525511112222", "correlation_window_start_at": "2026-08-28T10:00:00Z",
             "correlation_horizon_at": "2026-08-29T10:00:00Z", "offer_context": {"name": "Lead"}}
    row = {"id": 40506164, "property_id": "EB-ABCD1", "email": "a@b.test",
           "phone_e164": "+525511112222", "happened_at": "2026-08-28T11:00:00Z"}
    monkeypatch.setattr(supa, "claim_v3_easybroker_request_creations", lambda *a, **k: _async([claim]))
    monkeypatch.setattr(supa, "fetch_contact_requests", lambda *a, **k: _async([supa.sanitize_contact_request(row)]))
    monkeypatch.setattr(supa, "ingest_contact_request_batch", lambda *a, **k: _async({"ok": True}))
    monkeypatch.setattr(supa, "correlate_easybroker_request", lambda *a, **k: _async({"ok": False, "state": "conflict"}))
    calls = []
    async def finish(*args, **kwargs):
        calls.append(kwargs)
        return {"ok": True}
    monkeypatch.setattr(supa, "finish_v3_easybroker_request_creation", finish)
    result = await supa.create_pending_easybroker_requests(settings)
    assert result[0]["state"] == "recovery"
    assert calls[0]["state"] == "recovery"
    assert calls[0].get("preexisting") is False


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("provider_result", "expected_state"),
    [
        ({"kind": "ambiguous", "status_code": 408}, "recovery"),
        ({"kind": "ambiguous", "status_code": 409}, "recovery"),
        ({"kind": "ambiguous", "status_code": 429,
          "provider_content_length": 12, "provider_body_keys": ["error"]}, "recovery"),
        ({"kind": "ambiguous", "status_code": 504}, "recovery"),
        ({"kind": "ambiguous", "status_code": 500}, "recovery"),
        ({"kind": "definitive", "status_code": 422}, "manual_review"),
        ({"kind": "created", "status_code": 201, "remote_request_id": 123}, "recovery"),
    ],
)
async def test_provider_outcomes_are_persisted_without_a_second_post(
    monkeypatch, provider_result, expected_state
):
    settings = SimpleNamespace(easybroker_create_requests=True, supabase_url="https://supa",
                               supabase_service_key="key", api_key="eb", partner_api_key="partner", partner_country_code="MX", account_key="default")
    claim = {"capture_event_id": 108, "opportunity_id": 589, "lease_token": "lease",
             "property_public_id": "EB-ABCD1", "normalized_email": "a@b.test",
             "e164_phone": "+525511112222", "correlation_window_start_at": "2026-08-28T10:00:00Z",
             "correlation_horizon_at": "2026-08-29T10:00:00Z", "offer_context": {"name": "Lead"}}
    monkeypatch.setattr(supa, "claim_v3_easybroker_request_creations", lambda *a, **k: _async([claim]))
    monkeypatch.setattr(supa, "fetch_contact_requests", lambda *a, **k: _async([]))
    monkeypatch.setattr(supa, "reserve_v3_easybroker_request_creation", lambda *a, **k: _async(True))
    calls = []
    monkeypatch.setattr(supa, "post_v3_easybroker_contact_request", lambda *a, **k: _async(provider_result))
    async def finish(*args, **kwargs):
        calls.append(kwargs)
        return {"ok": True}
    monkeypatch.setattr(supa, "finish_v3_easybroker_request_creation", finish)
    result = await supa.create_pending_easybroker_requests(settings)
    assert result[0]["state"] == expected_state
    assert len(calls) == 1
    assert calls[0]["state"] == expected_state
    if provider_result["kind"] == "created":
        assert calls[0]["remote_request_id"] == 123
        assert calls[0]["error"] == "post_requires_posterior_get"
    if "provider_content_length" in provider_result:
        assert calls[0]["evidence"]["provider_content_length"] == 12
        assert calls[0]["evidence"]["provider_body_keys"] == ["error"]


@pytest.mark.asyncio
async def test_exact_manual_retry_bypasses_recovery_skip_and_sets_reserve_flag(monkeypatch):
    settings = SimpleNamespace(easybroker_create_requests=True, supabase_url="https://supa",
                               supabase_service_key="key", api_key="eb", partner_api_key="partner", partner_country_code="MX", account_key="default")
    claim = {"capture_event_id": 108, "opportunity_id": 589, "lease_token": "lease",
             "post_allowed": False, "property_public_id": "EB-ABCD1",
             "normalized_email": "a@b.test", "e164_phone": "+525511112222",
             "correlation_window_start_at": "2026-08-28T10:00:00Z",
             "correlation_horizon_at": "2026-08-29T10:00:00Z",
             "offer_context": {"name": "Lead"}}
    monkeypatch.setattr(supa, "claim_v3_easybroker_request_creations", lambda *a, **k: _async([claim]))
    monkeypatch.setattr(supa, "fetch_contact_requests", lambda *a, **k: _async([]))
    reserve_calls = []
    async def reserve(*args, **kwargs):
        reserve_calls.append(kwargs)
        return True
    monkeypatch.setattr(supa, "reserve_v3_easybroker_request_creation", reserve)
    monkeypatch.setattr(supa, "post_v3_easybroker_contact_request", lambda *a, **k: _async({
        "kind": "ambiguous", "status_code": 429,
    }))
    monkeypatch.setattr(supa, "finish_v3_easybroker_request_creation", lambda *a, **k: _async({"ok": True}))

    result = await supa.create_pending_easybroker_requests(
        settings, manual_retry_capture_ids=frozenset({108}),
    )

    assert result[0]["state"] == "recovery"
    assert reserve_calls == [{"capture_event_id": 108, "lease_token": "lease", "manual_retry": True}]


@pytest.mark.asyncio
async def test_network_timeout_is_recovery(monkeypatch):
    settings = SimpleNamespace(easybroker_create_requests=True, supabase_url="https://supa",
                               supabase_service_key="key", api_key="eb", partner_api_key="partner", partner_country_code="MX", account_key="default")
    claim = {"capture_event_id": 109, "opportunity_id": 590, "lease_token": "lease",
             "property_public_id": "EB-ABCD1", "normalized_email": "a@b.test",
             "e164_phone": "+525511112222", "correlation_window_start_at": "2026-08-28T10:00:00Z",
             "correlation_horizon_at": "2026-08-29T10:00:00Z", "offer_context": {"name": "Lead"}}
    monkeypatch.setattr(supa, "claim_v3_easybroker_request_creations", lambda *a, **k: _async([claim]))
    monkeypatch.setattr(supa, "fetch_contact_requests", lambda *a, **k: _async([]))
    monkeypatch.setattr(supa, "reserve_v3_easybroker_request_creation", lambda *a, **k: _async(True))
    async def timeout(*args, **kwargs):
        raise httpx.ReadTimeout("provider timeout")
    monkeypatch.setattr(supa, "post_v3_easybroker_contact_request", timeout)
    calls = []
    async def finish(*args, **kwargs):
        calls.append(kwargs)
        return {"ok": True}
    monkeypatch.setattr(supa, "finish_v3_easybroker_request_creation", finish)
    result = await supa.create_pending_easybroker_requests(settings)
    assert result[0]["state"] == "recovery"
    assert calls[0]["state"] == "recovery"


@pytest.mark.asyncio
async def test_recovery_zero_match_releases_lease_without_post(monkeypatch):
    settings = SimpleNamespace(easybroker_create_requests=True, supabase_url="https://supa",
                               supabase_service_key="key", api_key="eb", partner_api_key="partner", partner_country_code="MX", account_key="default")
    claim = {"capture_event_id": 108, "lease_token": "lease", "post_allowed": False,
             "property_public_id": "EB-ABCD1", "normalized_email": "a@b.test",
             "e164_phone": "+525511112222", "correlation_window_start_at": "2026-08-28T10:00:00Z",
             "correlation_horizon_at": "2099-08-29T10:00:00Z", "offer_context": {"name": "Lead"}}
    monkeypatch.setattr(supa, "claim_v3_easybroker_request_creations", lambda *a, **k: _async([claim]))
    monkeypatch.setattr(supa, "fetch_contact_requests", lambda *a, **k: _async([]))
    monkeypatch.setattr(supa, "reserve_v3_easybroker_request_creation", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no reserve in recovery")))
    monkeypatch.setattr(supa, "post_v3_easybroker_contact_request", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no post in recovery")))
    calls = []
    async def finish(*args, **kwargs):
        calls.append(kwargs)
        return {"ok": True}
    monkeypatch.setattr(supa, "finish_v3_easybroker_request_creation", finish)
    result = await supa.create_pending_easybroker_requests(settings)
    assert result[0]["state"] == "recovery"
    assert calls[0]["error"] == "post_skipped_pending_get"


@pytest.mark.asyncio
async def test_recovery_zero_match_after_horizon_is_manual_review(monkeypatch):
    settings = SimpleNamespace(easybroker_create_requests=True, supabase_url="https://supa",
                               supabase_service_key="key", api_key="eb", partner_api_key="partner", partner_country_code="MX", account_key="default")
    claim = {"capture_event_id": 108, "lease_token": "lease", "post_allowed": False,
             "property_public_id": "EB-ABCD1", "normalized_email": "a@b.test",
             "correlation_window_start_at": "2026-08-27T10:00:00Z",
             "correlation_horizon_at": "2026-08-27T10:00:01Z", "offer_context": {"name": "Lead"}}
    monkeypatch.setattr(supa, "claim_v3_easybroker_request_creations", lambda *a, **k: _async([claim]))
    monkeypatch.setattr(supa, "fetch_contact_requests", lambda *a, **k: _async([]))
    calls = []
    async def finish(*args, **kwargs):
        calls.append(kwargs)
        return {"ok": True}
    monkeypatch.setattr(supa, "finish_v3_easybroker_request_creation", finish)
    result = await supa.create_pending_easybroker_requests(settings)
    assert result[0]["state"] == "manual_review"
    assert calls[0]["error"] == "correlation_horizon_expired"


def test_recovery_claims_are_reclaimable_after_a_single_post_attempt():
    sql = MIGRATION.read_text(encoding="utf-8").lower()
    candidates = sql.split("with candidates as (", 1)[1].split("), claimed as (", 1)[0]
    assert "l.state in ('pending','recovery')" in candidates
    assert "lease_expires_at is null" in candidates
    assert "post_attempt_count=1" not in candidates


def test_creation_and_effect_gates_are_independent_and_documented():
    config = (ROOT / "src" / "easybroker" / "config.py").read_text(encoding="utf-8")
    main = (ROOT / "src" / "easybroker" / "main.py").read_text(encoding="utf-8")
    readme = (ROOT / "src" / "easybroker" / "README.md").read_text(encoding="utf-8")
    assert "easybroker_create_requests" in config
    assert "POST creation requires its separate explicit gate" in config
    assert "Request\n                # creation has its own gate" in main
    assert "POST creation only when `EASYBROKER_CREATE_REQUESTS=1`" in readme
    assert "EB_MARK_ATTENDED=1" in readme


def test_first_creation_claim_anchors_bounded_window_without_infinite_extension():
    migration = (
        ROOT
        / "supabase"
        / "migrations"
        / "20260901181000_anchor_easybroker_creation_window_to_claim.sql"
    ).read_text(encoding="utf-8").lower()

    assert "easybroker_creation_claim_window_v1" in migration
    assert "and l.post_attempt_count=0" in migration
    assert "p_now+interval '24 hours'" in migration
    assert "p_now-interval '5 minutes'" in migration
    assert "returning e.capture_event_id, e.correlation_window_start_at" in migration
    assert "coalesce(r.correlation_horizon_at,e.correlation_horizon_at)" in migration


def test_creation_window_is_timezone_aware_ordered_and_fail_closed():
    valid = {
        "correlation_window_start_at": "2026-08-31T14:17:10Z",
        "correlation_horizon_at": "2026-09-01T14:17:10+00:00",
    }
    window = supa._creation_window(valid)
    assert window is not None
    assert window[0] < window[1]
    assert window[0].tzinfo is not None
    assert supa._creation_window({}) is None
    assert supa._creation_window({
        "correlation_window_start_at": "2026-09-02T00:00:00Z",
        "correlation_horizon_at": "2026-09-01T00:00:00Z",
    }) is None


@pytest.mark.asyncio
async def test_creation_fetch_covers_oldest_claim_window_and_invalid_claim_never_posts(monkeypatch):
    settings = SimpleNamespace(
        easybroker_create_requests=True,
        supabase_url="https://supa",
        supabase_service_key="key",
        api_key="eb",
        partner_api_key="partner",
        partner_country_code="MX",
        account_key="default",
    )
    claims = [
        {
            "capture_event_id": 108,
            "lease_token": "valid",
            "property_public_id": "EB-ABCD1",
            "normalized_email": "a@b.test",
            "correlation_window_start_at": "2026-08-30T10:00:00Z",
            "correlation_horizon_at": "2099-08-31T10:00:00Z",
            "post_allowed": False,
            "offer_context": {"name": "Lead"},
        },
        {
            "capture_event_id": 109,
            "lease_token": "invalid",
            "property_public_id": "EB-ABCD2",
            "normalized_email": "c@d.test",
            "correlation_window_start_at": "bad-date",
            "correlation_horizon_at": "2099-08-31T10:00:00Z",
            "offer_context": {"name": "Lead"},
        },
    ]
    monkeypatch.setattr(
        supa, "claim_v3_easybroker_request_creations", lambda *a, **k: _async(claims)
    )
    fetch_calls = []

    async def fetch(*args, **kwargs):
        fetch_calls.append(kwargs)
        return []

    monkeypatch.setattr(supa, "fetch_contact_requests", fetch)
    monkeypatch.setattr(
        supa,
        "reserve_v3_easybroker_request_creation",
        lambda *a, **k: (_ for _ in ()).throw(AssertionError("no POST reserve expected")),
    )
    monkeypatch.setattr(
        supa,
        "post_v3_easybroker_contact_request",
        lambda *a, **k: (_ for _ in ()).throw(AssertionError("no POST expected")),
    )
    finished = []

    async def finish(*args, **kwargs):
        finished.append(kwargs)
        return {"ok": True}

    monkeypatch.setattr(supa, "finish_v3_easybroker_request_creation", finish)

    result = await supa.create_pending_easybroker_requests(settings)

    assert fetch_calls[0]["happened_after"] == datetime(
        2026, 8, 30, 10, 0, tzinfo=timezone.utc
    )
    assert [row["state"] for row in result] == ["recovery", "manual_review"]
    assert finished[1]["error"] == "invalid_correlation_window"


async def _async(value):
    return value


def test_fetch_contact_requests_follows_url_next_page(monkeypatch):
    calls = []

    class Response:
        def __init__(self, page):
            self._page = page

        def raise_for_status(self):
            pass

        def json(self):
            row = {"id": self._page, "property_id": "EB-AAAA", "phone": "+525500000000",
                   "email": None, "happened_at": "2026-09-02T10:00:00Z"}
            nxt = "https://api.easybroker.com/v1/contact_requests?page=2" if self._page == 1 else None
            return {"content": [row], "pagination": {"next_page": nxt}}

    class Client:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def get(self, url, headers=None, params=None):
            calls.append(params["page"])
            return Response(params["page"])

    monkeypatch.setattr(supa.httpx, "AsyncClient", lambda **kw: Client())
    rows = asyncio.run(supa.fetch_contact_requests(SimpleNamespace(api_key="k")))
    assert calls == [1, 2]
    assert [r["eb_request_id"] for r in rows] == [1, 2]
