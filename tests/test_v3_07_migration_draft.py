"""Static safety contract for local-only V3-07 effects draft."""
import json
from pathlib import Path

ROOT = Path(__file__).parents[1]
DRAFT = ROOT / "output" / "v3-execution" / "drafts" / "V3-07_easybroker_effects.sql"
ROLLBACK = ROOT / "output" / "v3-execution" / "drafts" / "V3-07_easybroker_effects_rollback.sql"
SNAPSHOT = ROOT / "output" / "v3-execution" / "production-schema-snapshot.json"
INBOX = ROOT / "src" / "easybroker" / "inbox.py"


def test_v3_07_only_references_snapshot_canonical_keys():
    snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    tables = set(snapshot["tables"])
    columns = {(row["table_name"], row["column_name"]) for row in snapshot["columns"]}
    assert {"agents", "lead_routing_opportunities", "easybroker_contact_request_inbox",
            "easybroker_i24_request_links"} <= tables
    assert {("agents", "agent_id"), ("agents", "name"),
            ("lead_routing_opportunities", "opportunity_id"),
            ("lead_routing_opportunities", "state"),
            ("lead_routing_opportunities", "assigned_agent_id"),
            ("easybroker_contact_request_inbox", "eb_request_id"),
            ("easybroker_contact_request_inbox", "correlation_state"),
            ("easybroker_i24_request_links", "eb_request_id"),
            ("easybroker_i24_request_links", "opportunity_id")} <= columns


def test_easybroker_worker_reconciles_exact_note_before_writing():
    source = INBOX.read_text(encoding="utf-8")
    flow = source[source.index("async def attend_lead"):source.index("# Diagnostics")]
    assert flow.index("note_exists(page, note)") < flow.index("add_note(page, note)")
    assert "The exact request page scopes idempotency" in flow


def test_v3_07_is_explicitly_local_and_request_keyed():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    assert "proposed / no aplicado" in sql
    assert "eb_request_id bigint primary key" in sql
    assert "references public.lead_routing_opportunities" in sql
    assert "references public.agents" in sql
    assert "conversations" not in sql
    assert "enqueue_v3_easybroker_effect" in sql
    assert "claim_v3_easybroker_effects" in sql
    assert "finish_v3_easybroker_effect" in sql
    assert "for update skip locked" in sql
    assert "service_role" in sql and "security invoker" in sql
    assert sql.count("security invoker") == 5
    assert sql.count("grant execute on function") == 5
    assert "gen_random_uuid" in sql
    assert "'awaiting_responsible', p_now" in sql
    assert "e.close_state = 'awaiting_responsible'" in sql
    assert "join public.agents a on a.agent_id = o.assigned_agent_id" in sql


def test_v3_07_has_independent_steps_and_absolute_retry_schedule():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    assert "note_state" in sql and "attended_state" in sql
    assert "note_retry_count" in sql and "attended_retry_count" in sql
    assert "easybroker_effect_attempts" in sql
    assert "effect_idempotency_key" in sql
    assert "on conflict (effect_idempotency_key) do update" in sql
    assert "where public.easybroker_effect_attempts.finished_at is null" in sql
    assert "finished_at is null" in sql
    assert "note_state = 'succeeded'" in sql
    assert "note_required" in sql
    assert "note_written" in sql and "reconciled_existing" in sql
    assert "state', 'attempt_conflict'" in sql
    assert "responsable: " in sql
    for interval in ("1 minute", "5 minutes", "15 minutes", "30 minutes"):
        assert f"interval '{interval}'" in sql
    assert "next_retry_at" in sql and "sandy_alerted_at" in sql
    assert "easybroker_effect_alerts" in sql
    assert "'target', 'sandy'" in sql
    assert "x.attempts < 5" in sql
    assert "status in ('pending','leased','sent','failed','exhausted')" in sql
    assert "'retry_count', v_retry_count" in sql
    assert "easybroker_effect_exhausted:" in sql
    assert "claim_v3_easybroker_effect_alerts" in sql
    assert "finish_v3_easybroker_effect_alert" in sql
    assert "easybroker_effect_attempts_attempt_id_seq" in sql
    assert "easybroker_effect_alerts_alert_id_seq" in sql
    assert "already_succeeded" in sql
    assert "p_step is null" in sql
    assert "exact easybroker request evidence required" in sql
    assert "atendida status evidence required" in sql


def test_v3_07_note_then_attended_requires_two_claim_finish_cycles():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    claim = sql[sql.index("create or replace function public.claim_v3_easybroker_effects"):
                sql.index("create or replace function public.finish_v3_easybroker_effect")]
    finish = sql[sql.index("create or replace function public.finish_v3_easybroker_effect"):
                 sql.index("create or replace function public.claim_v3_easybroker_effect_alerts")]
    assert "v_attended_due := r.attended_state in ('pending','failed')" in claim
    assert "and r.note_state = 'succeeded'" in claim
    assert "if v_attended_due then" in claim
    assert "insert into public.easybroker_effect_attempts" in claim
    assert "lease_token = null" in finish and "lease_expires_at = null" in finish
    assert "if p_step = 'attended' and l.note_state <> 'succeeded'" in finish


def test_v3_07_rollback_is_scoped_and_local():
    sql = ROLLBACK.read_text(encoding="utf-8").lower()
    assert "proposed / no aplicado" in sql
    assert "preserve" in sql
    assert "drop function if exists" in sql
    assert "drop table" not in sql
    assert "eb_contact_id" not in sql
