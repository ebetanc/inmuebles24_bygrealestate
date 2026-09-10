"""Static contract for the daily-report WhatsApp migration (no docker needed)."""

from pathlib import Path

ROOT = Path(__file__).parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260911100000_v3_daily_report_whatsapp.sql"
FIXTURE = ROOT / "tests" / "sql" / "test_v3_daily_report_whatsapp.sql"


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8").lower()


def test_migration_creates_the_three_report_tables():
    sql = _sql()
    for table in ("v3_report_recipients", "v3_daily_reports", "v3_report_sends"):
        assert f"create table if not exists public.{table}" in sql
    assert "report_date date primary key" in sql
    assert "text_chunks text[] not null" in sql
    assert "summary jsonb not null" in sql
    assert "references public.v3_daily_reports(report_date)" in sql


def test_recipient_phone_check_is_e164_digits_without_plus():
    assert "check (phone ~ '^[1-9][0-9]{7,14}$')" in _sql()


def test_send_status_is_constrained():
    assert "check (status in ('accepted','failed'))" in _sql()


def test_service_role_grants_cover_tables_and_sequence():
    sql = _sql()
    assert ("grant select,insert,update on public.v3_report_recipients, "
            "public.v3_daily_reports, public.v3_report_sends to service_role;") in sql
    assert "grant usage,select on sequence public.v3_report_sends_id_seq to service_role;" in sql


def test_esteban_is_seeded_idempotently():
    sql = _sql()
    assert "insert into public.v3_report_recipients(phone,name) values ('33628457768','esteban')" in sql
    assert "on conflict do nothing" in sql


def test_rollback_fixture_covers_the_documented_assertions():
    fixture = FIXTURE.read_text(encoding="utf-8")
    lowered = fixture.lower()
    assert "'5215591970405'" in fixture
    assert "'+33628457768'" in fixture and "'abc'" in fixture
    assert "on conflict (report_date) do update" in lowered
    assert "'bogus'" in fixture
    assert fixture.rstrip().endswith("END $$;")
