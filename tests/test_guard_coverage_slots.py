"""Static contracts for LRV2-004 guard coverage schema, workflow, and UI."""

import json
import re
from pathlib import Path


ROOT = Path(__file__).parents[1]
SQL = (ROOT / "whatsapp-agent/migrations/0022_guard_coverage_slots.sql").read_text(encoding="utf-8")
ACL_SQL = (ROOT / "whatsapp-agent/migrations/0037_guard_coverage_acl_hardening.sql").read_text(encoding="utf-8")
ACTION = (ROOT / "dashboard/src/app/(dashboard)/calendario/actions.ts").read_text(encoding="utf-8")
SERVER_CLIENT = (ROOT / "dashboard/src/lib/supabase.ts").read_text(encoding="utf-8")
UI = (ROOT / "dashboard/src/app/(dashboard)/calendario/calendar-editor.tsx").read_text(encoding="utf-8")
WORKFLOW = json.loads((ROOT / "whatsapp-agent/workflows/WF6_guard_schedule.json").read_text(encoding="utf-8"))
QUERY = next(node for node in WORKFLOW["nodes"] if node["name"] == "Sync On-Shift Agents")["parameters"]["query"]


def compact(value: str) -> str:
    return re.sub(r"\s+", " ", value).lower()


def test_schema_has_explicit_ordered_slots_and_duplicate_role_guard():
    sql = compact(SQL)
    assert "coverage_role in ('primary', 'backup')" in sql
    assert "unique index if not exists agent_schedule_coverage_role_uniq" in sql
    assert "on agent_schedule (schedule_date, shift, coverage_role)" in sql
    assert "where coverage_role is not null" in sql
    assert "order by case s.coverage_role when 'primary' then 1 when 'backup' then 2 end" in sql
    assert "order by agent_id" not in sql


def test_rpc_validates_missing_invalid_duplicate_and_dates_before_delete():
    sql = compact(SQL)
    delete = sql.index("delete from public.agent_schedule")
    required_before_delete = (
        "p_rows is null or jsonb_typeof(p_rows) is distinct from 'array'",
        "p_last_date - p_first_date > 30",
        "not between p_first_date and p_last_date",
        "not a.is_available",
        "nullif(btrim(a.whatsapp_number), '') is null",
        "primary and backup must be different agents",
        "having count(*) > 2",
    )
    for contract in required_before_delete:
        assert contract in sql
        assert sql.index(contract) < delete


def test_empty_rows_reaches_delete_and_action_does_not_bypass_rpc():
    sql = compact(SQL)
    assert "jsonb_array_length(p_rows) = 0" not in sql
    assert "delete from public.agent_schedule" in sql
    assert "if (rows.length === 0)" not in ACTION
    assert 'p_rows: rows' in ACTION


def test_legacy_backfill_only_promotes_one_null_row():
    sql = compact(SQL)
    assert "having count(*) = 1 and count(*) filter (where coverage_role is null) = 1" in sql
    assert "set coverage_role = 'primary'" in sql
    assert "where coverage_role is null" in sql


def test_functions_are_invoker_only_and_service_role_only():
    sql = compact(SQL)
    assert "security definer" not in sql
    assert sql.count("security invoker") == 2
    for signature in (
        "save_month_schedule(date, date, jsonb)",
        "get_guard_coverage_slots(date, text)",
    ):
        assert f"revoke all on function {signature} from public" in sql
        assert f"revoke all on function {signature} from anon, authenticated" in sql
        assert f"grant execute on function {signature} to service_role" in sql


def test_acl_hardening_removes_direct_anon_access_and_preserves_server_service_role_path():
    acl = compact(ACL_SQL)
    assert "revoke all on table public.agent_schedule, public.agents from public, anon, authenticated" in acl
    assert "grant all privileges on table public.agent_schedule to anon, authenticated" in acl
    assert "grant all privileges on table public.agents to anon, authenticated" in acl
    assert "grant all privileges on table public.agent_schedule to public" not in acl
    assert "grant all privileges on table public.agents to public" not in acl
    assert "service_role" not in re.sub(r"--[^\n]*", "", ACL_SQL, flags=re.I)
    assert "SUPABASE_SERVICE_ROLE_KEY" in SERVER_CLIENT
    assert "createSupabaseServer" in ACTION
    assert '.rpc("save_month_schedule"' in ACTION
    fixture = (ROOT / "tests/fixtures/routing_v2/test_guard_acl_hardening.sql").read_text(encoding="utf-8")
    fixture_compact = compact(fixture)
    assert "set local role anon" in fixture_compact
    assert "set local role authenticated" in fixture_compact
    assert "set local role service_role" in fixture_compact
    assert "has_table_privilege" in fixture_compact
    assert "save_month_schedule" in fixture_compact
    assert "get_guard_coverage_slots" in fixture_compact
    assert "rollback;" in fixture_compact


def test_ui_loads_slots_blocks_ambiguity_and_explicit_clear_resolves_it():
    assert "V3: exactly one guard per shift" in UI
    assert 'const slot = row.shift === "morning" ? "morning" : "afternoon"' in UI
    assert "legacyConflictKeys(initialSchedule)" in UI
    assert "if (unresolvedLegacy.length > 0)" in UI
    clear = re.search(r"const clearAll = \(\) => \{(?P<body>.*?)\n  \};", UI, re.DOTALL)
    assert clear
    body = clear.group("body")
    assert "confirm(" in body
    assert "setSchedule(buildInitialState(year, month, []))" in body
    assert "setUnresolvedLegacy([])" in body
    assert body.index("confirm(") < body.index("setUnresolvedLegacy([])")
    assert "morning: [day.morning].filter(Boolean)" in UI
    assert "afternoon: [day.afternoon].filter(Boolean)" in UI


def test_wf6_validates_before_reset_and_allows_only_single_legacy_fallback():
    query = compact(QUERY)
    reset = query.index("update agents set on_shift = false")
    for guard in (
        "invalid guard coverage",
        "ambiguous legacy guard coverage",
        "count(*) filter (where coverage_role is null) > 1",
    ):
        assert guard in query
        assert query.index(guard) < reset
    assert "coalesce(s.coverage_role, 'primary')" in query
    assert "s.coverage_role is null and not exists" in query
    assert "other.id <> s.id" in query
