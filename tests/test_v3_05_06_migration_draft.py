"""Static contract for the local-only V3-05/V3-06 SQL draft."""
from pathlib import Path


ROOT = Path(__file__).parents[1]
DRAFT = ROOT / "output" / "v3-execution" / "drafts" / "V3-05_06_claim_webhook.sql"
ROLLBACK = ROOT / "output" / "v3-execution" / "drafts" / "V3-05_06_claim_webhook_rollback.sql"


def test_webhook_is_durable_idempotent_and_verified_before_response():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    assert "lead_routing_meta_webhook_inbox" in sql
    assert "sanitized_payload jsonb" in sql
    assert "payload_sha256" in sql
    assert "hmac_verified boolean" in sql
    assert "hmac" in sql and "sanitization happen outside" in sql
    assert "create or replace function public.ingest_v3_meta_webhook_event" in sql
    assert "create or replace function public.claim_v3_meta_webhook_events" in sql
    assert "create or replace function public.finish_v3_meta_webhook_event" in sql
    assert "create or replace function public.replay_v3_meta_webhook_event" in sql
    assert "unique index if not exists lead_routing_meta_webhook_inbox_wamid_kind_status_uniq" in sql
    assert "on conflict" in sql
    assert "for update skip locked" in sql
    assert "p_hmac_verified is distinct from true" in sql
    assert "security definer" not in sql


def test_webhook_retries_are_leased_and_bounded():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    assert "processing_state in ('pending', 'leased', 'processed', 'failed', 'exhausted')" in sql
    assert "lease_token uuid" in sql and "lease_expires_at timestamptz" in sql
    assert "attempts = i.attempts + 1" in sql
    for interval in ("1 minute", "5 minutes", "15 minutes", "30 minutes"):
        assert f"interval '{interval}'" in sql
    assert "v_row.attempts >= 5" in sql
    assert "processing_state in ('failed', 'exhausted')" in sql


def test_delivery_claim_is_atomic_first_wins_and_fail_closed():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    assert "create or replace function public.claim_v3_delivery" in sql
    for outcome in (
        "opportunity_not_found", "attempt_mismatch", "attempt_not_current",
        "wrong_sender", "wrong_sender_number", "wrong_context",
        "attempt_not_v3_offer", "capture_not_verified", "delivery_not_confirmed",
        "missing_deadline", "late", "conversation_already_assigned_other",
        "already_assigned", "already_assigned_other", "state_not_claimable", "claimed",
    ):
        assert f"'{outcome}'" in sql
    assert "v_attempt.target_agent_id" in sql
    assert "v_attempt.target_number" in sql
    assert "v_attempt.delivery_kind is distinct from 'offer'" in sql
    assert "v_attempt.capture_event_id is distinct from p_capture_event_id" in sql
    assert "contactado_status = 'verified'" in sql
    assert "disposition = 'created_new'" in sql
    assert "v_opp.v3_enabled" in sql
    assert "v_opp.routing_tier is distinct from v_attempt.routing_tier" in sql
    assert "claimed_at = coalesce(claimed_at, p_now)" in sql
    assert "external_conversation_id = coalesce" not in sql
    assert "p_deadline_at" not in sql
    assert "delivery_status = 'delivered'" in sql
    assert "status_name in ('delivered', 'read')" in sql
    assert "assigned_agent_id is null" in sql
    assert "first-wins" in sql
    assert "insert into public.lead_routing_events" in sql
    assert "on conflict (idempotency_key) do nothing" in sql
    assert "routing_tier not in ('owner', 'primary_guard')" in sql
    assert "security definer" not in sql


def test_security_and_rollback_are_scoped():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    rollback = ROLLBACK.read_text(encoding="utf-8").lower()
    assert sql.count("security invoker") >= 5
    assert "grant execute" in sql and "to service_role" in sql
    assert "proposed / no aplicado" in sql
    assert "proposed / no aplicado" in rollback
    assert "drop function if exists" in rollback
    assert "drop table" not in rollback
    assert "delete from" not in rollback
