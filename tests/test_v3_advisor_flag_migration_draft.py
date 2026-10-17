"""Static contract for the advisor-flag migration (no database).

The behavioural gate lives in tests/test_v3_advisor_flag_migration.py.
"""

from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20261017100000_v3_advisor_flag.sql"


@pytest.fixture(scope="module")
def sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def _body(sql: str, name: str) -> str:
    start = sql.index(f"CREATE OR REPLACE FUNCTION public.{name}")
    end = sql.index("$$;", start)
    return sql[start:end]


def test_defines_flag_table(sql):
    assert "CREATE TABLE IF NOT EXISTS public.lead_advisor_flags" in sql
    assert "opportunity_id BIGINT NOT NULL UNIQUE" in sql
    assert "ENABLE ROW LEVEL SECURITY" in sql


def test_heuristic_covers_name_message_and_corporate_mail(sql):
    body = _body(sql, "v3_identity_looks_like_advisor")
    assert "inmobiliaria" in body and "bienes" in body and "asesor" in body
    assert "soy\\s+asesor" in body
    assert "gmail|googlemail|hotmail|outlook" in body
    assert "prodigy" in body  # Telmex consumer mail is not corporate


def test_returning_rule_excludes_advisors(sql):
    body = _body(sql, "v3_returning_client_agent")
    assert "public.v3_advisor_reason(o.opportunity_id) IS NULL" in body
    # The rest of the rule is untouched.
    assert "INTERVAL '90 days'" in body
    assert "'^\\s*mls\\s*$'" in body


def test_webhook_flag_function_outcomes(sql):
    body = _body(sql, "v3_flag_advisor_from_webhook")
    for outcome in ("advisor_flagged", "advisor_ambiguous", "advisor_no_lead",
                    "advisor_no_identity", "wrong_sender_number", "verified_webhook_mismatch"):
        assert f"'{outcome}'" in body
    assert "'advisor_flagged'" in body and "'v3-advisor-flag:'" in body
    assert "INTERVAL '24 hours'" in body


def test_service_role_only(sql):
    assert "REVOKE ALL ON FUNCTION public.v3_flag_advisor_from_webhook(bigint) FROM PUBLIC, anon, authenticated;" in sql
    assert "GRANT EXECUTE ON FUNCTION public.v3_flag_advisor_from_webhook(bigint) TO service_role;" in sql
