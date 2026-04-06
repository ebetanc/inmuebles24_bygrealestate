"""Tests for the deduplication state module."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from inmobiliaria24.state import SeenLeads


@pytest.fixture
def state_dir(tmp_path: Path) -> Path:
    return tmp_path


def test_new_state_file_returns_empty(state_dir: Path):
    """First load with no existing file returns empty set."""
    seen = SeenLeads(state_dir)
    assert seen.ids == set()


def test_filter_new_returns_only_unseen(state_dir: Path):
    """filter_new returns leads not in the seen set."""
    seen = SeenLeads(state_dir)
    leads = [
        {"lead_id": "100", "name": "Alice"},
        {"lead_id": "200", "name": "Bob"},
    ]
    new = seen.filter_new(leads)
    assert len(new) == 2
    assert new[0]["lead_id"] == "100"
    assert new[1]["lead_id"] == "200"


def test_mark_seen_persists_to_disk(state_dir: Path):
    """mark_seen writes IDs to JSON file, loadable by a fresh instance."""
    seen = SeenLeads(state_dir)
    seen.mark_seen(["100", "200"])

    seen2 = SeenLeads(state_dir)
    assert seen2.ids == {"100", "200"}


def test_filter_new_excludes_already_seen(state_dir: Path):
    """After marking IDs as seen, filter_new excludes them."""
    seen = SeenLeads(state_dir)
    seen.mark_seen(["100"])

    leads = [
        {"lead_id": "100", "name": "Alice"},
        {"lead_id": "300", "name": "Charlie"},
    ]
    new = seen.filter_new(leads)
    assert len(new) == 1
    assert new[0]["lead_id"] == "300"


def test_mark_seen_is_additive(state_dir: Path):
    """Calling mark_seen multiple times adds IDs, never removes."""
    seen = SeenLeads(state_dir)
    seen.mark_seen(["100"])
    seen.mark_seen(["200"])

    assert seen.ids == {"100", "200"}

    seen2 = SeenLeads(state_dir)
    assert seen2.ids == {"100", "200"}


def test_state_file_is_atomic(state_dir: Path):
    """No .tmp file left behind after mark_seen."""
    seen = SeenLeads(state_dir)
    seen.mark_seen(["100"])

    tmp_files = list(state_dir.glob("*.tmp"))
    assert len(tmp_files) == 0


def test_leads_without_lead_id_are_skipped(state_dir: Path):
    """Leads missing lead_id are always returned (cannot be deduped)."""
    seen = SeenLeads(state_dir)
    leads = [
        {"lead_id": "", "name": "NoID"},
        {"lead_id": "100", "name": "Alice"},
    ]
    new = seen.filter_new(leads)
    assert len(new) == 2
