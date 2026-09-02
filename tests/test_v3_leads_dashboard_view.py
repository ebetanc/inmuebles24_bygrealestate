"""Contract test for the read-only dashboard view (no DB needed)."""
from pathlib import Path


ROOT = Path(__file__).parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260902120000_v3_leads_dashboard_view.sql"

EXPECTED_COLUMNS = (
    "opportunity_id",
    "created_at",
    "lead_name",
    "lead_phone",
    "property_id",
    "property_title",
    "easybroker_url",
    "state",
    "routing_tier",
    "assigned_agent_id",
    "assigned_name",
    "assigned_role",
    "assigned_at",
    "assignment_method",
    "minutes_to_claim",
    "owner_offer_delivered_at",
    "guard_offer_delivered_at",
    "sandy_notice_delivered_at",
    "eb_note_ok",
    "eb_note_at",
    "eb_attended_ok",
    "eb_attended_at",
    "night_queued_at",
    "night_released_at",
    "dispatch_status",
    "problem_reason",
    "has_problem",
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8").lower()


def test_view_is_created_read_only_with_security_invoker():
    sql = _sql()
    assert "create or replace view public.v3_leads_dashboard" in sql
    assert "with (security_invoker = true)" in sql
    # Read-only: a dashboard view must never write.
    for forbidden in ("insert into", "update public.", "delete from", "create function"):
        assert forbidden not in sql


def test_view_exposes_every_column_the_dashboard_reads():
    lines = [line.strip().rstrip(",") for line in _sql().splitlines()]
    for column in EXPECTED_COLUMNS:
        assert any(
            line == column or line.endswith(f".{column}") or line.endswith(f" as {column}")
            for line in lines
        ), column


def test_view_joins_the_v3_engine_tables():
    sql = _sql()
    for table in (
        "public.lead_routing_opportunities",
        "public.lead_routing_delivery_attempts",
        "public.lead_routing_events",
        "public.i24_capture_events",
        "public.easybroker_i24_request_links",
        "public.easybroker_effect_attempts",
        "public.agents",
        "public.conversations",
    ):
        assert table in sql


def test_grants_mirror_the_existing_ops_view():
    sql = _sql()
    assert "revoke all on table public.v3_leads_dashboard from public, anon;" in sql
    assert "grant select on table public.v3_leads_dashboard to authenticated;" in sql
    assert "grant select on table public.v3_leads_dashboard to service_role;" in sql
