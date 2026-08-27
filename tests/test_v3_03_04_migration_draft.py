from pathlib import Path
import re


ROOT = Path(__file__).parents[1]
DRAFT = ROOT / "output" / "v3-execution" / "drafts" / "V3-03_04_intake_routing.sql"
ROLLBACK = ROOT / "output" / "v3-execution" / "drafts" / "V3-03_04_intake_routing_rollback.sql"
SNAPSHOT = ROOT / "output" / "v3-execution" / "production-schema-snapshot.json"
PREFLIGHT = ROOT / "output" / "v3-execution" / "guard-schedule-preflight.json"


def test_draft_uses_canonical_schema_and_exact_dispositions():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    for disposition in ("created_new", "active_duplicate", "returning_assigned", "non_routable"):
        assert disposition in sql
    for table in (
        "i24_capture_events",
        "lead_routing_opportunities",
        "lead_routing_delivery_attempts",
    ):
        assert table in sql
    assert not re.search(r"create\s+table[^;]*v3_(delivery_queue|routing_state|routing_guard_slots)", sql)


def test_draft_has_v3_gates_and_timing():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    assert "v3_require_contactado_before_delivery" in sql
    assert "contactado_not_verified" in sql
    assert "15 minutes" in sql and "30 minutes" in sql and "60 minutes" in sql
    assert "manual_review" in sql
    assert "08:05:00" in sql and "america/mexico_city" in sql
    assert "agent_manager" in sql and "role='manager'" in sql
    assert "primary_guard" in sql
    v3_advance = sql.split("create or replace function public.v3_advance_routing_tier", 1)[1]
    assert "backup_guard" not in v3_advance.split("create or replace function public.v3_release_night_queue", 1)[0]
    assert "night_queue" in sql and "insert into public.night_queue" in sql
    assert "current_shift()" not in sql  # all time-dependent routing uses p_now
    assert "security definer" not in sql


def test_contactado_is_per_capture_not_per_opportunity():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    assert "contactado_lease_token" in sql
    assert "contactado_lease_expires_at" in sql
    assert "from public.i24_capture_events e" in sql
    assert "p_capture_event_id bigint" in sql
    assert "v3_contactado_status" in sql
    assert "v_capture_disposition" in sql
    assert "coalesce(p_offer_context, '{}'::jsonb), 'pending'" in sql
    assert "alter table public.lead_routing_i24_contact_effects" not in sql
    assert "p_capture_event_id bigint" in sql
    assert "capture_event_id=p_capture_event_id" in sql
    assert "delivery_kind='assigned_notice'" in sql
    assert "v3_claim_delivery_attempts" in sql
    assert "a.delivery_kind='offer'" in sql
    assert "app.v3_capture_event_id" in sql
    assert "state','no_action'" in sql
    assert "state','direct_assigned'" in sql
    assert "order by e.capture_event_id desc" not in sql


def test_one_guard_cutover_is_represented_and_preflight_is_fresh():
    import json

    sql = DRAFT.read_text(encoding="utf-8").lower()
    preflight = json.loads(PREFLIGHT.read_text(encoding="utf-8"))
    assert preflight["mutations"] == 0
    assert sum(row["rows"] for row in preflight["by_role"] if row["coverage_role"] == "backup") == 62
    assert "coverage_role='backup'" in sql  # only the one-time demotion update
    assert "coverage_role='primary'" in sql
    assert "agent_schedule_one_guard_uniq" in sql
    assert "one guard per date and shift" in sql
    assert "and s.coverage_role='primary'" in sql


def test_draft_keeps_provider_acceptance_distinct_from_delivery():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    assert "v3_record_provider_accepted" in sql
    accepted_block = sql.split("v3_record_provider_accepted", 1)[1].split(
        "create or replace function public.v3_record_read_delivery", 1
    )[0]
    assert "provider_accepted_at" in accepted_block
    assert "status='delivered'" not in accepted_block
    assert "delivered" in sql


def test_draft_reuses_snapshot_tables_only():
    import json

    tables = set(json.loads(SNAPSHOT.read_text(encoding="utf-8"))["tables"])
    sql = DRAFT.read_text(encoding="utf-8").lower()
    for table in ("lead_routing_opportunities", "lead_routing_delivery_attempts", "agents", "conversations"):
        assert table in tables
        assert table in sql


def test_capture_index_is_after_capture_table_creation():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    assert sql.index("create table if not exists public.i24_capture_events") < sql.index("i24_capture_events_external_uniq")


def test_rollback_is_non_destructive_and_function_safe():
    sql = ROLLBACK.read_text(encoding="utf-8").lower()
    assert "proposed / no aplicado" in sql
    assert "non-destructive" in sql
    assert "drop function if exists" in sql
    assert "drop table" not in sql
    assert "drop trigger if exists" in sql
