"""Local contract tests for the one-shot I24 -> EasyBroker bridge."""
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
        "remote_id": 107,
        "name": "Lead", "phone": "+525511112222", "email": "a@b.test",
        "property_id": "EB-ABCD1", "message": "Hola",
    }


def test_creation_payload_requires_stable_numeric_remote_id_and_message_fallback():
    payload = supa._creation_payload({
        "i24_lead_id": "108", "property_public_id": "EB-X",
        "offer_context": {"name": "Lead"},
    })
    assert payload["remote_id"] == 108
    assert payload["message"] == "Nuevo lead de Inmuebles24."


def test_creation_gate_fails_closed_without_partner_key(monkeypatch):
    settings = SimpleNamespace(easybroker_create_requests=True, supabase_url="https://supa",
                               supabase_service_key="key", api_key="account",
                               partner_api_key="", partner_country_code="MX")
    # No network calls are permitted when the dedicated Partners key is absent.
    monkeypatch.setattr(supa, "claim_v3_easybroker_request_creations",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("claim must not run")))
    import asyncio
    assert asyncio.run(supa.create_pending_easybroker_requests(settings)) == []


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
             "correlation_horizon_at": "2026-08-29T10:00:00Z", "offer_context": {"name": "Lead"}}
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


async def _async(value):
    return value
