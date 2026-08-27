"""V3-02b local auto-correlation contract; never calls production."""

from pathlib import Path


ROOT = Path(__file__).parents[1]
DRAFT = ROOT / "output" / "v3-execution" / "drafts" / "V3-02b_auto_correlation.sql"
ROLLBACK = ROOT / "output" / "v3-execution" / "drafts" / "V3-02b_auto_correlation_rollback.sql"


def test_auto_correlation_is_request_level_and_security_invoker():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    assert "correlate_pending_easybroker_requests" in sql
    assert "language plpgsql volatile security invoker" in sql
    assert "for update skip locked" in sql
    assert "correlate_easybroker_request" in sql
    pending = sql[sql.index("create or replace function public.correlate_pending_easybroker_requests") :]
    assert "insert into public.easybroker_i24_request_links" not in pending


def test_exact_link_validates_v3_opportunity_without_conversation_dependency():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    exact = sql[:sql.index("create or replace function public.correlate_pending_easybroker_requests")]
    assert "o.v3_enabled" in exact
    assert "btrim(o.property_id)" in exact
    assert "join public.conversations" not in exact


def test_auto_correlation_never_guesses_identity_or_ambiguity():
    sql = DRAFT.read_text(encoding="utf-8").lower()
    required = (
        "upper(nullif(btrim(i.property_public_id), ''))",
        "normalized_email",
        "e164_phone",
        "multiple_exact_candidates",
        "manual_review:ambiguous",
        "manual_review:identity_contradiction",
        "awaiting_eb_request",
        "manual_review:no_eb_request",
        "watermark_at >= e.correlation_horizon_at",
        "enqueue_v3_easybroker_effect",
    )
    for fragment in required:
        assert fragment in sql


def test_auto_correlation_rollback_only_removes_its_function():
    sql = ROLLBACK.read_text(encoding="utf-8").lower()
    assert "drop function if exists public.correlate_pending_easybroker_requests" in sql
    assert "drop table" not in sql


def test_python_adapter_invokes_durable_correlation_rpc():
    source = (ROOT / "src" / "easybroker" / "supa.py").read_text(encoding="utf-8")
    start = source.index("async def correlate_pending_easybroker_requests")
    end = source.index("async def claim_v3_easybroker_effects", start)
    block = source[start:end]
    assert "correlate_pending_easybroker_requests" in block
    assert "/rest/v1/rpc/" in block
    assert '"p_limit"' in block and '"p_now"' in block
    assert "response.raise_for_status()" in block
