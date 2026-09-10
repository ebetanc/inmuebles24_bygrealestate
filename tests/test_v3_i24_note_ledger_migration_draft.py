"""Static contract for the Inmuebles24 internal-note ledger migration.

No database: these assertions read the migration text so the shape of the change
is pinned even where docker is unavailable. The behavioural gate lives in
tests/test_v3_i24_note_ledger_migration.py.
"""

from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260913100000_v3_i24_note_ledger.sql"


@pytest.fixture(scope="module")
def sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_migration_exists(sql):
    assert sql.strip(), "migration file is empty"


def test_creates_the_ledger_table(sql):
    assert "CREATE TABLE IF NOT EXISTS public.i24_note_ledger" in sql
    assert "opportunity_id bigint PRIMARY KEY REFERENCES public.lead_routing_opportunities(opportunity_id)" in sql
    assert "'pending','leased','succeeded','failed','manual_review'" in sql
    assert "ALTER TABLE public.i24_note_ledger ENABLE ROW LEVEL SECURITY;" in sql


def test_state_change_trigger_feeds_the_ledger(sql):
    assert "CREATE FUNCTION public.v3_enqueue_i24_note()" in sql
    assert "CREATE TRIGGER v3_enqueue_i24_note AFTER UPDATE OF state ON public.lead_routing_opportunities" in sql
    body = sql[sql.index("CREATE FUNCTION public.v3_enqueue_i24_note()"):]
    body = body[: body.index("$$;")]
    assert "NEW.state IS NOT DISTINCT FROM OLD.state" in body, "only real transitions enqueue"
    assert "NOT NEW.v3_enabled" in body, "legacy opportunities are out of scope"
    assert "SIN ASIGNACIÓN" in body
    assert "split_part(regexp_replace(BTRIM(a.name), '\\s+', ' ', 'g'), ' ', 1)" in body
    assert "e.external_event_id IS NOT NULL" in body, "the conversation id is required"
    assert "ON CONFLICT (opportunity_id) DO NOTHING" in body


def test_defines_the_lease_and_finish_functions(sql):
    assert "CREATE FUNCTION public.claim_v3_i24_notes(p_limit integer, p_now timestamptz)" in sql
    assert "CREATE FUNCTION public.finish_v3_i24_note(p_opportunity_id bigint, p_token uuid," in sql
    claim = sql[sql.index("CREATE FUNCTION public.claim_v3_i24_notes"):]
    claim = claim[: claim.index("$$;")]
    assert "FOR UPDATE SKIP LOCKED" in claim
    assert "l.attempts < 5" in claim
    assert "interval '3 minutes'" in claim
    finish = sql[sql.index("CREATE FUNCTION public.finish_v3_i24_note"):]
    finish = finish[: finish.index("$$;")]
    assert "l.attempts >= 5 THEN 'manual_review'" in finish
    assert "l.lease_token = p_token" in finish and "l.state = 'leased'" in finish
    assert "RETURN v_rows = 1;" in finish


def test_grants_mirror_the_easybroker_functions(sql):
    assert "GRANT SELECT,INSERT,UPDATE ON public.i24_note_ledger TO service_role;" in sql
    for signature in ("public.claim_v3_i24_notes(INTEGER,TIMESTAMPTZ)",
                      "public.finish_v3_i24_note(BIGINT,UUID,BOOLEAN,JSONB)"):
        assert f"REVOKE ALL ON FUNCTION {signature}" in sql
        assert f"GRANT EXECUTE ON FUNCTION {signature}" in sql
