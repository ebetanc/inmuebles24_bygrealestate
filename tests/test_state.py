"""Tests for the StateStore module."""
from pathlib import Path
import tempfile

from inmobiliaria24.state import StateStore


def _make_store(tmp_path: Path) -> StateStore:
    return StateStore(tmp_path / "test.db")


def test_new_lead_not_seen(tmp_path: Path):
    store = _make_store(tmp_path)
    assert not store.is_seen("123")
    store.close()


def test_mark_seen_then_is_seen(tmp_path: Path):
    store = _make_store(tmp_path)
    leads = [{"lead_id": "100", "name": "Ana", "listing_id": "L1", "source_tab": "mensajes"}]
    store.mark_seen(leads)
    assert store.is_seen("100")
    assert not store.is_seen("999")
    store.close()


def test_filter_new(tmp_path: Path):
    store = _make_store(tmp_path)
    # Mark lead 1 as seen.
    store.mark_seen([{"lead_id": "1", "name": "A"}])
    # Filter: lead 1 (old) + lead 2 (new).
    result = store.filter_new([
        {"lead_id": "1", "name": "A"},
        {"lead_id": "2", "name": "B"},
    ])
    assert len(result) == 1
    assert result[0]["lead_id"] == "2"
    store.close()


def test_run_log(tmp_path: Path):
    store = _make_store(tmp_path)
    assert store.last_successful_run() is None

    run_id = store.start_run()
    store.finish_run(run_id, total=5, new=3, status="ok")

    assert store.last_successful_run() is not None
    store.close()


def test_crm_tracking(tmp_path: Path):
    store = _make_store(tmp_path)
    leads = [{"lead_id": "10", "name": "Test"}]
    store.mark_seen(leads)

    unpushed = store.get_unpushed_leads()
    assert len(unpushed) == 1

    store.mark_crm_pushed("10", crm_id="CRM-001")
    unpushed = store.get_unpushed_leads()
    assert len(unpushed) == 0
    store.close()


def test_context_manager(tmp_path: Path):
    with _make_store(tmp_path) as store:
        store.mark_seen([{"lead_id": "X"}])
        assert store.is_seen("X")


def test_daily_stats(tmp_path: Path):
    store = _make_store(tmp_path)

    # Create some runs.
    r1 = store.start_run()
    store.finish_run(r1, total=10, new=5, status="ok")

    r2 = store.start_run()
    store.finish_run(r2, total=8, new=3, status="ok")

    r3 = store.start_run()
    store.finish_run(r3, total=0, new=0, status="error")

    # Mark some leads as pushed.
    store.mark_seen([{"lead_id": "A"}, {"lead_id": "B"}])
    store.mark_crm_pushed("A", crm_id="CRM-1")

    stats = store.daily_stats(hours=24)
    assert stats["total_runs"] == 3
    assert stats["successful_runs"] == 2
    assert stats["failed_runs"] == 1
    assert stats["total_leads_scraped"] == 18
    assert stats["new_leads"] == 8
    assert stats["leads_pushed_crm"] == 1
    store.close()
