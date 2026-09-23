"""Static contract for the `unassigned` terminal-state migration.

No database: these assertions read the migration text so the shape of the change
is pinned even where docker is unavailable. The behavioural gate lives in
tests/test_v3_unassigned_migration.py.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260912100000_v3_unassigned.sql"
TERMINAL_GUARD = ROOT / "supabase" / "migrations" / "20260923000000_v3_terminal_route_guard.sql"


@pytest.fixture(scope="module")
def sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def _body(sql: str, name: str) -> str:
    """The text between `CREATE OR REPLACE FUNCTION public.<name>` and its `$$;`."""
    start = sql.index(f"CREATE OR REPLACE FUNCTION public.{name}")
    end = sql.index("$$;", start)
    return sql[start:end]


def test_migration_exists(sql):
    assert sql.strip(), "migration file is empty"


def test_defines_v3_mark_unassigned(sql):
    assert "CREATE OR REPLACE FUNCTION public.v3_mark_unassigned(" in sql
    body = _body(sql, "v3_mark_unassigned")
    assert "'left_unassigned'" in body
    assert "'v3-unassigned:'" in body
    assert "'v3_final_route','unassigned'" in body
    # Never touches conversations, never notifies Sandy.
    assert "public.conversations" not in body
    assert "v3_enqueue_assigned_notice" not in body


@pytest.mark.parametrize("fn", ["v3_route_ready_opportunity", "v3_advance_routing_tier"])
def test_routing_functions_no_longer_call_sandy(sql, fn):
    body = _body(sql, fn)
    assert "v3_assign_sandy(" not in body, f"{fn} still falls back to Sandy"
    assert "public.v3_mark_unassigned(" in body
    assert "'state','unassigned'" in body


def test_advance_routing_tier_treats_unassigned_as_terminal(sql):
    body = _body(sql, "v3_advance_routing_tier")
    assert re.search(r"v_opp\.state\s*=\s*'unassigned'", body)


def test_route_ready_preserves_unassigned_terminal_before_night_queue():
    body = _body(TERMINAL_GUARD.read_text(encoding="utf-8"), "v3_route_ready_opportunity")
    assert body.index("v_opp.state = 'unassigned'") < body.index("v_is_night :=")


def test_creation_claim_excludes_stale_captures():
    body = _body(TERMINAL_GUARD.read_text(encoding="utf-8"), "claim_v3_easybroker_request_creations")
    assert body.count("e.happened_at >= p_now - INTERVAL '24 hours'") == 2
    assert body.count("e.happened_at >= TIMESTAMPTZ '2026-09-23T02:00:00Z'") == 2


def _constraint(sql: str, name: str) -> str:
    """The `ADD CONSTRAINT <name> CHECK (...)` statement text."""
    m = re.search(rf"ADD CONSTRAINT {name}\s+CHECK.*?;", sql, re.S)
    assert m, f"{name} is not re-added"
    return m.group(0)


def test_state_check_gains_unassigned(sql):
    block = _constraint(sql, "lead_routing_opportunities_state_check")
    assert "'unassigned'" in block
    # The pre-existing states survive.
    for state in ("'assigned'", "'unassigned_alerted'", "'closed_won'", "'queued_night'"):
        assert state in block


def test_attended_state_check_gains_skipped(sql):
    block = _constraint(sql, "easybroker_effect_ledger_attended_state_check")
    assert "'skipped'" in block


def test_ledger_completion_check_accepts_skipped(sql):
    block = _constraint(sql, "easybroker_effect_ledger_check1")
    assert "attended_state IN ('succeeded','skipped')" in block


def test_claim_effects_promotes_unassigned_with_sin_asignacion(sql):
    body = _body(sql, "claim_v3_easybroker_effects")
    assert "SIN ASIGNACIÓN" in body
    assert "'unassigned'" in body
    assert "responsible_agent_id IS NOT NULL" in body, "attended_due must gate on a real agent"


def test_request_creations_accepts_unassigned(sql):
    body = _body(sql, "claim_v3_easybroker_request_creations")
    assert "LEFT JOIN public.agents a ON a.agent_id=o.assigned_agent_id" in body, \
        "an unassigned lead has no agent row to join"
    assert "OR (o.state='unassigned' AND o.assigned_agent_id IS NULL)" in body


def test_day_sweep_counts_unassigned_as_closed(sql):
    body = sql[sql.index("CREATE OR REPLACE FUNCTION public.v3_day_sweep()"):]
    body = body[: body.index("$$;")]
    assert "o.state='unassigned' AND o.unassigned_at <= c.day_deadline_at" in body
    assert "e.attended_state IN ('succeeded','skipped')" in body
    assert "o.state <> 'unassigned' THEN 'responsible_not_assigned'" in body


def test_callback_terminal_guard_includes_unassigned(sql):
    body = _body(sql, "reconcile_delivery_callback")
    assert "v_opp.state IN ('assigned','unassigned','unassigned_alerted','closed_won','closed_lost')" in body


def test_dashboard_view_reports_unassigned(sql):
    view = sql[sql.index("CREATE OR REPLACE VIEW public.v3_leads_dashboard"):]
    assert "'unassigned' AS assignment_method" in view or "END AS assignment_method" in view
    assert "o.external_evidence->>'v3_final_route' = 'unassigned'" in view
    assert "'sandy_fallback'" in view and "'claim'" in view


def test_assign_sandy_is_kept_for_rollback(sql):
    assert "DROP FUNCTION" not in sql.upper() or "v3_assign_sandy" not in sql.upper().split("DROP FUNCTION")[1][:200]
