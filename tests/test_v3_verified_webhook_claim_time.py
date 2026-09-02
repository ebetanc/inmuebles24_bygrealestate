"""Static contract for verified webhook-time V3 claims.

The migration deliberately keeps the existing atomic claim RPC and supplies
it with the database-created ingress timestamp of one exact verified event.
"""

from pathlib import Path


ROOT = Path(__file__).parents[1]
BASE_MIGRATION = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260831170000_fix_v3_verified_webhook_claim_time.sql"
)
APPEND_ONLY_FIX = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260831182500_fix_v3_append_only_claim_evidence.sql"
)


def _sql() -> str:
    return "\n".join(
        path.read_text(encoding="utf-8").lower()
        for path in (BASE_MIGRATION, APPEND_ONLY_FIX)
    )


def _function(sql: str, name: str, next_name: str | None = None) -> str:
    start = sql.rindex(f"create or replace function public.{name}")
    if next_name is None:
        return sql[start:]
    next_marker = f"create or replace function public.{next_name}"
    end = sql.find(next_marker, start)
    if end < 0:
        end = len(sql)
    return sql[start:end]


def test_wrapper_uses_database_created_ingress_time_not_worker_time():
    sql = _sql()
    wrapper = _function(
        sql,
        "claim_v3_delivery_from_webhook",
        "claim_pending_v3_webhook_for_attempt",
    )

    assert "p_webhook_event_id bigint" in wrapper
    assert "where i.webhook_event_id = p_webhook_event_id" in wrapper
    assert "v_webhook.created_at" in wrapper
    assert "v_webhook.received_at" not in wrapper
    assert "provider_event_at" not in wrapper
    assert "now()" not in wrapper
    assert "public.claim_v3_delivery(" in wrapper
    assert "v_webhook.created_at\n  );" in wrapper
    assert "set updated_at = clock_timestamp()" in wrapper
    assert "'verified_webhook_time', true" in wrapper


def test_wrapper_preserves_the_append_only_event_ledger():
    wrapper = _function(_sql(), "claim_v3_delivery_from_webhook")

    assert "update public.lead_routing_events" not in wrapper
    assert "insert into public.lead_routing_events(" in wrapper
    assert "'claim_webhook_verified'" in wrapper
    assert "'v3-verified-webhook-claim:' || p_webhook_event_id::text" in wrapper
    assert "on conflict (idempotency_key) do nothing" in wrapper
    assert "v_result->>'outcome' = 'claimed'" in wrapper
    assert "v_result->>'outcome' in ('claimed', 'already_assigned')" in wrapper
    assert "from public.agents ag\n  where ag.agent_id = v_attempt.target_agent_id\n  for share" not in wrapper
    assert "from public.i24_capture_events c" in wrapper


def test_wrapper_binds_the_exact_verified_meta_button_and_attempt():
    sql = _sql()
    wrapper = _function(
        sql,
        "claim_v3_delivery_from_webhook",
        "claim_pending_v3_webhook_for_attempt",
    )

    for required in (
        "v_webhook.event_kind is distinct from 'message'",
        "v_webhook.hmac_verified is distinct from true",
        "v_event_wamid is distinct from v_webhook.wamid",
        "{interactive,button_reply,id}",
        "{button,payload}",
        "^claim:v3:",
        "v_context_wamid is distinct from v_attempt.provider_message_id",
        "v_target_number is distinct from v_sender_number",
        "v_agent_number is distinct from v_sender_number",
        "v_opp.current_delivery_attempt_id is distinct from v_attempt_id",
        "v_attempt.delivery_kind is distinct from 'offer'",
        "v_attempt.capture_event_id is null",
        "c.contactado_status = 'verified'",
        "c.disposition = 'created_new'",
        "v_webhook.created_at < v_attempt.requested_at",
        "v_webhook.created_at >= v_opp.expires_at",
    ):
        assert required in wrapper


def test_pending_helper_finds_only_an_exact_in_window_verified_event():
    sql = _sql()
    helper = _function(
        sql,
        "claim_pending_v3_webhook_for_attempt",
        "v3_advance_routing_tier",
    )

    assert "i.event_kind = 'message'" in helper
    assert "i.hmac_verified" in helper
    assert "i.created_at >= v_attempt.requested_at" in helper
    assert "i.created_at < v_opp.expires_at" in helper
    assert "i.wamid = i.sanitized_payload #>> '{event,id}'" in helper
    assert "{event,context,id}" in helper
    assert "{event,from}" in helper
    assert "claim:v3:' || p_opportunity_id::text || ':' || p_attempt_id::text" in helper
    assert "public.claim_v3_delivery_from_webhook(v_webhook_event_id)" in helper
    assert "processing_state" not in helper
    assert "received_at" not in helper
    assert "now()" not in helper


def test_sweeper_consumes_verified_claim_before_any_timeout_fallback():
    sql = _sql()
    advance = _function(sql, "v3_advance_routing_tier")

    rescue = advance.index("public.claim_pending_v3_webhook_for_attempt(")
    first_sandy = advance.index("public.v3_assign_sandy(")
    assert rescue < first_sandy
    assert "'state', 'assigned'" in advance
    assert "'tier', 'verified_claim'" in advance
    assert "'attempt_id', v_attempt.attempt_id" in advance
    assert "'capture_event_id', v_attempt.capture_event_id" in advance


def test_no_automatic_override_of_an_existing_sandy_assignment():
    sql = _sql()
    wrapper = _function(
        sql,
        "claim_v3_delivery_from_webhook",
        "claim_pending_v3_webhook_for_attempt",
    )
    helper = _function(
        sql,
        "claim_pending_v3_webhook_for_attempt",
        "v3_advance_routing_tier",
    )

    assert "if not found or v_opp.assigned_agent_id is not null" in helper
    assert "set assigned_agent_id" not in wrapper
    assert "setassigned_agent_id=null" not in wrapper.replace(" ", "")
    assert "guard_expired" not in wrapper
    assert "agent_manager" not in wrapper


def test_new_rpc_boundary_is_invoker_only_and_service_role_scoped():
    sql = _sql()
    assert sql.count("language plpgsql security invoker") >= 3
    assert "security definer" not in sql
    assert "revoke all on function public.claim_v3_delivery_from_webhook(bigint)" in sql
    assert "public.claim_pending_v3_webhook_for_attempt(bigint,bigint)" in sql
    assert "to service_role" in sql
