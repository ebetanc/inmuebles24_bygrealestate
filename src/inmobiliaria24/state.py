"""Deduplication state — tracks which lead IDs have already been sent."""
from __future__ import annotations

import json
import os
from pathlib import Path

from loguru import logger

_STATE_FILENAME = "seen_leads.json"


class SeenLeads:
    """Persists a set of lead IDs to a JSON file with atomic writes."""

    def __init__(self, state_dir: str | Path) -> None:
        self._dir = Path(state_dir)
        self._dir.mkdir(parents=True, exist_ok=True)
        self._path = self._dir / _STATE_FILENAME
        self._ids: set[str] = self._load()

    @property
    def ids(self) -> set[str]:
        return set(self._ids)

    def _load(self) -> set[str]:
        if not self._path.exists():
            return set()
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
            return set(data)
        except (json.JSONDecodeError, TypeError):
            logger.warning("Corrupt state file {} — starting fresh", self._path)
            return set()

    def _save(self) -> None:
        """Atomic write: write to .tmp then os.replace."""
        tmp_path = self._path.with_suffix(".tmp")
        tmp_path.write_text(
            json.dumps(sorted(self._ids), indent=2),
            encoding="utf-8",
        )
        os.replace(tmp_path, self._path)

    def filter_new(self, leads: list[dict]) -> list[dict]:
        """Return only leads whose lead_id is not in the seen set.

        Leads with empty lead_id are always included (cannot be deduped).
        """
        new: list[dict] = []
        for lead in leads:
            lid = lead.get("lead_id", "")
            if not lid or lid not in self._ids:
                new.append(lead)
        return new

    def mark_seen(self, lead_ids: list[str]) -> None:
        """Add IDs to the seen set and persist to disk."""
        self._ids.update(lid for lid in lead_ids if lid)
        self._save()
        logger.debug("Marked {} IDs as seen (total: {})", len(lead_ids), len(self._ids))
