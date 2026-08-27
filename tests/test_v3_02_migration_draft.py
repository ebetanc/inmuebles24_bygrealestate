"""Static safety contract for the local-only V3-02 SQL draft."""

from pathlib import Path


ROOT = Path(__file__).parents[1]
DRAFTS = ROOT / "output" / "v3-execution" / "drafts"
FORWARD = DRAFTS / "V3-02_easybroker_inbox_correlation.sql"
ROLLBACK = DRAFTS / "V3-02_easybroker_inbox_correlation_rollback.sql"


def sql_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").lower()


def compact_sql(path: Path) -> str:
    return " ".join(sql_text(path).split())


def test_forward_draft_is_explicitly_non_applied_and_request_level():
    sql = sql_text(FORWARD)
    compact = compact_sql(FORWARD)
    assert "proposed / no aplicado" in sql
    assert "create table if not exists public.i24_capture_events" in sql
    assert "create table if not exists public.easybroker_contact_request_inbox" in sql
    assert "eb_request_id bigint primary key" in sql
    assert "eb_person_contact_id bigint" in sql
    assert "create table if not exists public.easybroker_i24_request_links" in sql
    assert "i24_capture_event_id bigint not null" in sql
    assert "unique (i24_capture_event_id)" in compact

    inbox_sql = sql.split(
        "create table if not exists public.easybroker_contact_request_inbox", 1
    )[1].split("create table if not exists public.easybroker_i24_request_links", 1)[0]
    assert "i24_capture_event_id" not in inbox_sql


def test_forward_draft_has_checkpoint_correlation_and_default_deny_security():
    sql = sql_text(FORWARD)
    compact = compact_sql(FORWARD)
    assert "create table if not exists public.easybroker_ingestion_checkpoints" in sql
    assert "create or replace function public.ingest_easybroker_contact_request_batch" in sql
    assert "create or replace function public.correlate_easybroker_request" in sql
    assert "p_i24_capture_event_id bigint" in sql
    assert "security invoker" in sql
    assert "enable row level security" in sql
    assert "frompublic,anon,authenticated" in compact.replace(" ", "")
    assert "to service_role" in sql
    assert "conversations_eb_contact_id_uniq" not in sql
    assert "pg_advisory_xact_lock" in sql
    assert "watermark_at" in sql and "correlation_horizon_at" in sql
    assert "correlation_window_start_at timestamptz not null" in compact
    assert "correlation_horizon_at timestamptz not null" in compact
    assert "correlated_at=p_now" in compact.replace(" ", "")


def test_forward_draft_blocks_ambiguous_or_contradictory_auto_linking():
    sql = sql_text(FORWARD)
    for required in (
        "awaiting_eb_request",
        "manual_review:no_eb_request",
        "manual_review:ambiguous",
        "identity_contradiction",
        "candidate_count",
        "property_public_id",
    ):
        assert required in sql


def test_rollback_only_targets_v3_02_objects():
    sql = sql_text(ROLLBACK)
    assert "proposed / no aplicado" in sql
    assert "drop function if exists public.correlate_easybroker_request" in sql
    assert "drop function if exists public.ingest_easybroker_contact_request_batch" in sql
    assert "drop table if exists public.easybroker_i24_request_links" in sql
    assert "drop table if exists public.easybroker_contact_request_inbox" in sql
    assert "drop table if exists public.easybroker_ingestion_checkpoints" in sql
    assert "drop table if exists public.i24_capture_events" in sql
    assert "drop table public.conversations" not in sql
