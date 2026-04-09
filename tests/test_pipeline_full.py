"""Full pipeline integration tests.

End-to-end tests that simulate realistic multi-step flows:
mock scrape results → pipeline → dedup against state DB → CRM push,
including retry logic, failure scenarios, and edge cases.
"""
from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Optional

import pytest

from inmobiliaria24.crm.base import CRMAdapter, Lead
from inmobiliaria24.pipeline import process_leads, retry_failed_pushes
from inmobiliaria24.state import StateStore


# ---------------------------------------------------------------------------
# Mock CRM adapter with richer control
# ---------------------------------------------------------------------------


class FakeCRM(CRMAdapter):
    """Mock CRM that tracks calls and supports per-call failure injection."""

    def __init__(self) -> None:
        self.pushed: list[Lead] = []
        self.push_calls: int = 0
        self._fail_ids: set[str] = set()
        self._counter = 0
        # Map lead_id -> number of times push was attempted
        self.attempt_counts: dict[str, int] = {}

    def set_fail_ids(self, ids: set[str]) -> None:
        self._fail_ids = ids

    def clear_failures(self) -> None:
        self._fail_ids.clear()

    async def push_lead(self, lead: Lead) -> str:
        self.push_calls += 1
        self.attempt_counts[lead.lead_id] = (
            self.attempt_counts.get(lead.lead_id, 0) + 1
        )
        if lead.lead_id in self._fail_ids:
            raise RuntimeError(f"CRM unavailable for {lead.lead_id}")
        self._counter += 1
        crm_id = f"FCRM-{self._counter}"
        self.pushed.append(lead)
        return crm_id

    async def update_lead(self, crm_id: str, data: dict) -> None:
        pass

    async def check_duplicate(self, email: str, phone: str) -> Optional[str]:
        return None

    async def health_check(self) -> bool:
        return True


# ---------------------------------------------------------------------------
# Sample data
# ---------------------------------------------------------------------------

def _make_lead(lid: str, **overrides: str) -> dict:
    base = {
        "lead_id": lid,
        "name": f"Lead {lid}",
        "email": f"lead{lid}@example.com",
        "phone": f"555000{lid}",
        "message": "Interested",
        "listing_id": f"LST-{lid}",
        "status": "Pendiente",
        "source_tab": "mensajes",
    }
    base.update(overrides)
    return base


BATCH_A = [_make_lead("A1"), _make_lead("A2"), _make_lead("A3")]
BATCH_B = [_make_lead("A2"), _make_lead("A3"), _make_lead("B1"), _make_lead("B2")]


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def store(tmp_path: Path) -> StateStore:
    s = StateStore(tmp_path / "full_test.db")
    yield s
    s.close()


@pytest.fixture
def crm() -> FakeCRM:
    return FakeCRM()


# ---------------------------------------------------------------------------
# 1. Full flow: scrape → dedup → CRM push → state verification
# ---------------------------------------------------------------------------


def test_full_flow_scrape_to_crm(store: StateStore, crm: FakeCRM) -> None:
    """Mock scrape results fed into pipeline should dedup, push to CRM,
    and update the state DB correctly."""
    all_leads, pushed = asyncio.run(process_leads(BATCH_A, store, crm))

    # All 3 leads are new so all should be pushed.
    assert len(all_leads) == 3
    assert len(pushed) == 3
    assert crm.push_calls == 3

    # State DB: all leads marked as seen.
    assert store.filter_new(BATCH_A) == []

    # State DB: all leads have CRM push recorded.
    unpushed = store.get_unpushed_leads()
    assert len(unpushed) == 0

    # Each pushed lead has a crm_id assigned.
    for lead in pushed:
        assert lead.crm_id.startswith("FCRM-")
        assert lead.crm_pushed is True


# ---------------------------------------------------------------------------
# 2. Deduplication: overlapping batches
# ---------------------------------------------------------------------------


def test_dedup_overlapping_batches(store: StateStore, crm: FakeCRM) -> None:
    """Running pipeline twice with overlapping leads should only push new ones
    on the second run."""
    # First run: push A1, A2, A3.
    _, pushed1 = asyncio.run(process_leads(BATCH_A, store, crm))
    assert len(pushed1) == 3
    assert crm.push_calls == 3

    # Second run: BATCH_B has A2, A3 (already seen) + B1, B2 (new).
    _, pushed2 = asyncio.run(process_leads(BATCH_B, store, crm))
    assert len(pushed2) == 2
    pushed_ids = {l.lead_id for l in pushed2}
    assert pushed_ids == {"B1", "B2"}

    # Total CRM pushes: 3 + 2 = 5.
    assert crm.push_calls == 5

    # All 5 unique leads should now be seen.
    all_ids = [_make_lead(lid) for lid in ("A1", "A2", "A3", "B1", "B2")]
    assert store.filter_new(all_ids) == []


# ---------------------------------------------------------------------------
# 3. Retry failed pushes
# ---------------------------------------------------------------------------


def test_retry_failed_pushes_full_cycle(store: StateStore, crm: FakeCRM) -> None:
    """Simulate CRM failure, verify lead is marked failed, then retry succeeds."""
    # Make A2 fail on first run.
    crm.set_fail_ids({"A2"})
    _, pushed = asyncio.run(process_leads(BATCH_A, store, crm))

    # A1 and A3 pushed, A2 failed.
    assert len(pushed) == 2
    pushed_ids = {l.lead_id for l in pushed}
    assert "A2" not in pushed_ids

    # State: A2 is seen but unpushed.
    unpushed = store.get_unpushed_leads()
    assert len(unpushed) == 1
    assert unpushed[0]["lead_id"] == "A2"

    # Now retry with failures cleared.
    crm.clear_failures()
    retried = asyncio.run(retry_failed_pushes(store, crm))
    assert retried == 1

    # No more unpushed leads.
    assert len(store.get_unpushed_leads()) == 0


def test_retry_still_fails_then_succeeds(store: StateStore, crm: FakeCRM) -> None:
    """If retry also fails, lead remains unpushed until a subsequent retry."""
    crm.set_fail_ids({"A1"})
    asyncio.run(process_leads(BATCH_A[:1], store, crm))

    # A1 is unpushed.
    assert len(store.get_unpushed_leads()) == 1

    # First retry: still fails.
    retried = asyncio.run(retry_failed_pushes(store, crm))
    assert retried == 0
    assert len(store.get_unpushed_leads()) == 1

    # Second retry: CRM recovered.
    crm.clear_failures()
    retried = asyncio.run(retry_failed_pushes(store, crm))
    assert retried == 1
    assert len(store.get_unpushed_leads()) == 0


# ---------------------------------------------------------------------------
# 4. State DB correctness after success/failure
# ---------------------------------------------------------------------------


def test_state_db_after_mixed_success_failure(
    store: StateStore, crm: FakeCRM
) -> None:
    """Verify state DB has correct pushed_crm flags after partial failures."""
    crm.set_fail_ids({"A1", "A3"})
    asyncio.run(process_leads(BATCH_A, store, crm))

    # All 3 are seen.
    for lid in ("A1", "A2", "A3"):
        assert store.is_seen(lid)

    # Only A2 is pushed.
    unpushed = store.get_unpushed_leads()
    unpushed_ids = {r["lead_id"] for r in unpushed}
    assert unpushed_ids == {"A1", "A3"}

    # Fix failures and retry.
    crm.clear_failures()
    retried = asyncio.run(retry_failed_pushes(store, crm))
    assert retried == 2
    assert len(store.get_unpushed_leads()) == 0


def test_state_db_crm_id_persisted(store: StateStore, crm: FakeCRM) -> None:
    """Verify the CRM ID assigned during push is stored in the state DB."""
    asyncio.run(process_leads(BATCH_A[:1], store, crm))

    # The lead should be marked as pushed with a non-empty crm_id.
    row = store._conn.execute(
        "SELECT pushed_crm, crm_id FROM seen_leads WHERE lead_id = ?", ("A1",)
    ).fetchone()
    assert row is not None
    assert row[0] == 1  # pushed_crm flag
    assert row[1].startswith("FCRM-")


# ---------------------------------------------------------------------------
# 5. Empty scrape results
# ---------------------------------------------------------------------------


def test_pipeline_empty_scrape(store: StateStore, crm: FakeCRM) -> None:
    """Pipeline with no scrape results should return empty and not touch CRM."""
    all_leads, pushed = asyncio.run(process_leads([], store, crm))
    assert all_leads == []
    assert pushed == []
    assert crm.push_calls == 0
    assert len(store.get_unpushed_leads()) == 0


# ---------------------------------------------------------------------------
# 6. All-duplicate leads (nothing new)
# ---------------------------------------------------------------------------


def test_pipeline_all_duplicates(store: StateStore, crm: FakeCRM) -> None:
    """When all leads are already seen, nothing should be pushed to CRM."""
    # Pre-seed the state store.
    store.mark_seen(BATCH_A)

    all_leads, pushed = asyncio.run(process_leads(BATCH_A, store, crm))
    assert len(all_leads) == 3
    assert len(pushed) == 0
    assert crm.push_calls == 0


def test_all_duplicates_no_extra_state_changes(
    store: StateStore, crm: FakeCRM
) -> None:
    """All-duplicate run should update last_seen but not change push status."""
    # First run: push everything.
    asyncio.run(process_leads(BATCH_A, store, crm))
    assert len(store.get_unpushed_leads()) == 0

    # Second run: all duplicates.
    crm2 = FakeCRM()
    all_leads, pushed = asyncio.run(process_leads(BATCH_A, store, crm2))
    assert len(pushed) == 0
    assert crm2.push_calls == 0

    # Push status should still be intact from first run.
    assert len(store.get_unpushed_leads()) == 0


# ---------------------------------------------------------------------------
# Extra edge cases
# ---------------------------------------------------------------------------


def test_multiple_failures_retry_only_unpushed(
    store: StateStore, crm: FakeCRM
) -> None:
    """retry_failed_pushes should only attempt leads that are unpushed."""
    # Push A1 successfully, A2 and A3 fail.
    crm.set_fail_ids({"A2", "A3"})
    asyncio.run(process_leads(BATCH_A, store, crm))
    assert crm.push_calls == 3  # all attempted

    # Retry: only A2 and A3 should be attempted.
    crm.clear_failures()
    crm.push_calls = 0
    retried = asyncio.run(retry_failed_pushes(store, crm))
    assert retried == 2
    assert crm.push_calls == 2


def test_retry_with_no_unpushed(store: StateStore, crm: FakeCRM) -> None:
    """retry_failed_pushes with nothing unpushed returns 0 immediately."""
    retried = asyncio.run(retry_failed_pushes(store, crm))
    assert retried == 0
    assert crm.push_calls == 0
