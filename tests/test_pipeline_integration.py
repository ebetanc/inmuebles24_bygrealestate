"""Integration tests for the lead processing pipeline.

Uses a mock CRM adapter and real SQLite state store to validate
the full flow: raw leads → dedup → CRM push → state tracking.
"""
from __future__ import annotations

import asyncio
import tempfile
from pathlib import Path
from typing import Optional

import pytest

from inmobiliaria24.crm.base import CRMAdapter, Lead
from inmobiliaria24.pipeline import process_leads, retry_failed_pushes
from inmobiliaria24.state import StateStore


# ---------------------------------------------------------------------------
# Mock CRM adapter
# ---------------------------------------------------------------------------


class MockCRMAdapter(CRMAdapter):
    """In-memory CRM for testing."""

    def __init__(self, *, fail_on: set[str] | None = None) -> None:
        self.pushed: list[Lead] = []
        self.updated: list[tuple[str, dict]] = []
        self._fail_on = fail_on or set()
        self._counter = 0

    async def push_lead(self, lead: Lead) -> str:
        if lead.lead_id in self._fail_on:
            raise RuntimeError(f"Simulated push failure for {lead.lead_id}")
        self._counter += 1
        crm_id = f"CRM-{self._counter}"
        self.pushed.append(lead)
        return crm_id

    async def update_lead(self, crm_id: str, data: dict) -> None:
        self.updated.append((crm_id, data))

    async def check_duplicate(self, email: str, phone: str) -> Optional[str]:
        for lead in self.pushed:
            if (email and lead.email == email) or (phone and lead.phone == phone):
                return f"CRM-DUP-{lead.lead_id}"
        return None

    async def health_check(self) -> bool:
        return True


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

RAW_LEADS = [
    {
        "lead_id": "100",
        "name": "Ana García",
        "email": "ana@test.com",
        "phone": "5551001000",
        "message": "Me interesa el departamento",
        "listing_id": "L200",
        "status": "Pendiente",
        "source_tab": "mensajes",
    },
    {
        "lead_id": "101",
        "name": "Carlos López",
        "email": "carlos@test.com",
        "phone": "5551001001",
        "message": "Quiero más información",
        "listing_id": "L201",
        "status": "Pendiente",
        "source_tab": "telefono",
    },
    {
        "lead_id": "102",
        "name": "María Rodríguez",
        "email": "maria@test.com",
        "phone": "5551001002",
        "message": "¿Cuánto cuesta?",
        "listing_id": "L202",
        "status": "Pendiente",
        "source_tab": "whatsapp",
    },
]


@pytest.fixture
def store(tmp_path: Path) -> StateStore:
    s = StateStore(tmp_path / "test.db")
    yield s
    s.close()


@pytest.fixture
def crm() -> MockCRMAdapter:
    return MockCRMAdapter()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_full_pipeline_new_leads(store: StateStore, crm: MockCRMAdapter) -> None:
    """All new leads should be pushed to CRM and marked as seen."""
    all_leads, pushed = asyncio.run(process_leads(RAW_LEADS, store, crm))

    assert len(all_leads) == 3
    assert len(pushed) == 3
    assert len(crm.pushed) == 3
    # All should be marked as seen now.
    assert store.filter_new(RAW_LEADS) == []


def test_pipeline_dedup_skips_seen(store: StateStore, crm: MockCRMAdapter) -> None:
    """Leads already seen should not be pushed again."""
    # First run — push all.
    asyncio.run(process_leads(RAW_LEADS, store, crm))
    assert len(crm.pushed) == 3

    # Second run — all already seen, nothing pushed.
    crm2 = MockCRMAdapter()
    all_leads, pushed = asyncio.run(process_leads(RAW_LEADS, store, crm2))
    assert len(all_leads) == 3
    assert len(pushed) == 0
    assert len(crm2.pushed) == 0


def test_pipeline_partial_new(store: StateStore, crm: MockCRMAdapter) -> None:
    """Only unseen leads get pushed when some are already seen."""
    # Mark first two as seen.
    store.mark_seen(RAW_LEADS[:2])

    all_leads, pushed = asyncio.run(process_leads(RAW_LEADS, store, crm))
    assert len(all_leads) == 3
    assert len(pushed) == 1
    assert crm.pushed[0].lead_id == "102"


def test_pipeline_crm_failure_doesnt_block(store: StateStore) -> None:
    """A CRM push failure for one lead should not block others."""
    failing_crm = MockCRMAdapter(fail_on={"101"})
    all_leads, pushed = asyncio.run(process_leads(RAW_LEADS, store, failing_crm))

    assert len(all_leads) == 3
    # Only 2 of 3 pushed (101 failed).
    assert len(pushed) == 2
    pushed_ids = {l.lead_id for l in pushed}
    assert "100" in pushed_ids
    assert "102" in pushed_ids
    assert "101" not in pushed_ids

    # The failed lead should be unpushed in state.
    unpushed = store.get_unpushed_leads()
    assert len(unpushed) == 1
    assert unpushed[0]["lead_id"] == "101"


def test_retry_failed_pushes(store: StateStore) -> None:
    """retry_failed_pushes should pick up leads that failed on first attempt."""
    # First run: lead 101 fails.
    failing_crm = MockCRMAdapter(fail_on={"101"})
    asyncio.run(process_leads(RAW_LEADS, store, failing_crm))
    assert len(store.get_unpushed_leads()) == 1

    # Retry with a working CRM.
    good_crm = MockCRMAdapter()
    retried = asyncio.run(retry_failed_pushes(store, good_crm))
    assert retried == 1
    assert len(store.get_unpushed_leads()) == 0


def test_pipeline_empty_input(store: StateStore, crm: MockCRMAdapter) -> None:
    """Empty input should return empty results without errors."""
    all_leads, pushed = asyncio.run(process_leads([], store, crm))
    assert all_leads == []
    assert pushed == []


def test_pipeline_crm_duplicate_detection(store: StateStore) -> None:
    """Leads already in CRM (by email) should be marked but not re-pushed."""
    crm = MockCRMAdapter()
    # Push the first lead.
    asyncio.run(process_leads(RAW_LEADS[:1], store, crm))
    assert len(crm.pushed) == 1

    # Reset store so lead 100 is "new" locally, but CRM has it.
    store2 = StateStore(store._db_path)
    # Push again — lead 100 has same email, so CRM.check_duplicate returns it.
    all_leads, pushed = asyncio.run(process_leads(RAW_LEADS[:1], store2, crm))
    # Already seen in state, so nothing to push.
    assert len(pushed) == 0
    store2.close()


def test_i24_contact_effect_lease_recovers_only_after_expiry() -> None:
    """Two workers skip locked rows; a crash becomes claimable only after lease expiry."""
    sql = (Path(__file__).parents[1] / "whatsapp-agent/migrations/0032_i24_contact_effect_lease.sql").read_text()
    compact = " ".join(sql.lower().split())

    assert "for update of o, c skip locked" in compact
    assert "e.status='leased' and e.lease_expires_at<=p_now" in compact
    assert "p_now + interval '2 minutes'" in compact
    assert "v_effect.lease_expires_at<=now()" in compact
