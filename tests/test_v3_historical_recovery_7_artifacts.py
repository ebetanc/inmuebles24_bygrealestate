"""Static fail-closed contracts for the approval-gated historical recovery."""

from pathlib import Path


ROOT = Path(__file__).parents[1]
BASE = ROOT / "output" / "v3-execution" / "incident-20260901"
PREFLIGHT = BASE / "historical_recovery_7_preflight_readonly.sql"
REPAIR = BASE / "historical_recovery_7_cas_STOP.sql"
COMPENSATE = BASE / "historical_recovery_7_compensate_before_workers_STOP.sql"
CAPTURES = (197, 199, 201, 202, 221, 222, 225, 226)


def test_preflight_is_read_only_and_names_all_targets():
    sql = PREFLIGHT.read_text(encoding="utf-8").lower()

    assert "begin transaction isolation level repeatable read read only" in sql
    assert "rollback;" in sql
    assert "eligible_for_explicitly_approved_cas" in sql
    assert "active_identity_property_conflicts" in sql
    assert "projected_target_identity_property_conflicts" in sql
    assert "conflicting.property_id = x.property_public_id" in sql
    assert "easybroker_link_count" in sql
    assert "easybroker_creation_ledger_count" in sql
    assert "exact_easybroker_candidate_count" in sql
    assert "exact_easybroker_candidate_count <= 1" in sql
    assert "exact_easybroker_candidate_count = 1" not in sql
    assert "contradictory_easybroker_candidate_count = 0" in sql
    assert "linked_exact_easybroker_candidate_count = 0" in sql
    assert "shared_exact_easybroker_candidate_count = 0" in sql
    assert "easybroker_creation_payload_ready" in sql
    assert "provider_history_window_covered" in sql
    assert "now() - interval '47 hours'" in sql
    assert "recovery_date_allowed" in sql
    assert "date '2026-09-01'" in sql
    assert "easybroker_creation_claim_window_v1" in sql
    assert "now() + interval '24 hours'" in sql
    assert "split_new_opportunity" in sql
    for capture_event_id in CAPTURES:
        assert str(capture_event_id) in sql


def test_repair_is_explicitly_approval_gated_and_splits_cap202():
    sql = REPAIR.read_text(encoding="utf-8").lower()

    assert "stop: do not run without explicit production approval" in sql
    assert "inmobiliaria24.timer and easybroker.timer" in sql
    assert "historical recovery allowed only 08:05-19:30" in sql
    assert "begin transaction isolation level serializable" in sql
    assert "authorization bundle expired after 2026-09-01" in sql
    assert "pg_advisory_xact_lock" in sql
    assert "expected 7 opportunity rows" in sql
    assert "expected 8 capture rows" in sql
    assert "v_new_opportunity_id" in sql
    assert "set opportunity_id = v_new_opportunity_id" in sql
    assert "c.created_at" not in sql
    assert "c.happened_at, v_now" in sql
    assert "disposition = 'created_new'" in sql
    assert "historical_split_from_opportunity_id" in sql
    assert "projected identity/property collision" in sql
    assert "easybroker creation safety gate failed" in sql
    assert "easybroker_contact_request_creation_ledger" in sql
    assert "easybroker_creation_claim_window_v1" in sql
    assert "candidate_matches" in sql
    assert "shared_candidates" in sql
    assert "creation_payload_ready" in sql
    assert "provider_history_window_covered" in sql
    assert "v_now - interval '47 hours'" in sql
    assert "up to eight new contact-request posts" in sql
    assert "set correlation_horizon_at" not in sql
    assert "route_dispatch_attempts = 5" in sql
    assert "set route_dispatch_attempts" not in sql
    assert "no_message_sent_by_cas" in sql
    assert "no delivery exists" in sql
    for capture_event_id in CAPTURES:
        assert f"historical-recovery:' || r.capture_event_id" in sql or str(capture_event_id) in sql


def test_compensation_aborts_after_any_downstream_effect():
    sql = COMPENSATE.read_text(encoding="utf-8").lower()

    assert "post-commit compensation, not a message rollback" in sql
    assert "messages cannot be unsent" in sql
    assert "lead_routing_delivery_attempts" in sql
    assert "v3-route-dispatched:202" in sql
    assert "easybroker_i24_request_links" in sql
    assert "easybroker_contact_request_creation_ledger" in sql
    assert "downstream effect exists; database compensation is unsafe" in sql
    assert "historical_recovery_compensated" in sql
    assert "correlation_horizon_at" not in sql
    assert "correlation_window_start_at" not in sql
