"""SQLite-backed state store for lead deduplication.

Tracks which leads have been seen/processed to avoid sending duplicates
to the CRM or WhatsApp bot on subsequent scraper runs.

Thread-safe via SQLite's built-in locking. Uses WAL mode for concurrent reads.
"""
from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

from loguru import logger

DEFAULT_DB_PATH = Path("data/state.db")


class StateStore:
    """Persistent lead state backed by SQLite."""

    def __init__(self, db_path: Path = DEFAULT_DB_PATH) -> None:
        self._db_path = db_path
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(db_path), timeout=10)
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA busy_timeout=5000")
        self._create_tables()
        logger.debug("StateStore opened at {}", db_path)

    def _create_tables(self) -> None:
        self._conn.executescript("""
            CREATE TABLE IF NOT EXISTS seen_leads (
                lead_id     TEXT PRIMARY KEY,
                listing_id  TEXT,
                name        TEXT,
                source_tab  TEXT,
                first_seen  TEXT NOT NULL,
                last_seen   TEXT NOT NULL,
                pushed_crm  INTEGER DEFAULT 0,
                crm_id      TEXT DEFAULT ''
            );

            CREATE TABLE IF NOT EXISTS run_log (
                run_id      INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at  TEXT NOT NULL,
                finished_at TEXT,
                total_leads INTEGER DEFAULT 0,
                new_leads   INTEGER DEFAULT 0,
                status      TEXT DEFAULT 'running'
            );

            CREATE TABLE IF NOT EXISTS property_public_id_map (
                listing_id         TEXT PRIMARY KEY,
                property_public_id TEXT NOT NULL,
                last_seen          TEXT NOT NULL
            );
        """)
        self._conn.commit()

    def upsert_property_public_id_map(self, mapping: dict[str, str]) -> None:
        """Persist validated listing-id -> EB-code mappings from Mis avisos."""
        now = datetime.now(timezone.utc).isoformat()
        self._conn.executemany(
            """INSERT INTO property_public_id_map(listing_id, property_public_id, last_seen)
               VALUES (?, ?, ?)
               ON CONFLICT(listing_id) DO UPDATE SET
                 property_public_id=excluded.property_public_id,
                 last_seen=excluded.last_seen""",
            [(listing_id, public_id, now) for listing_id, public_id in mapping.items()],
        )
        self._conn.commit()

    def property_public_id_map(self) -> dict[str, str]:
        """Return all cached listing-id -> EB-code mappings."""
        return dict(self._conn.execute(
            "SELECT listing_id, property_public_id FROM property_public_id_map"
        ).fetchall())

    def delete_property_public_id_mappings(self, listing_ids: set[str]) -> None:
        """Remove ambiguous mappings so stale EB codes cannot be reused."""
        self._conn.executemany(
            "DELETE FROM property_public_id_map WHERE listing_id = ?",
            [(listing_id,) for listing_id in listing_ids],
        )
        self._conn.commit()

    # ------------------------------------------------------------------
    # Lead deduplication
    # ------------------------------------------------------------------

    def is_seen(self, lead_id: str) -> bool:
        """Return True if this lead_id has been processed before."""
        row = self._conn.execute(
            "SELECT 1 FROM seen_leads WHERE lead_id = ?", (lead_id,)
        ).fetchone()
        return row is not None

    def filter_new(self, leads: list[dict]) -> list[dict]:
        """Return only leads whose lead_id has NOT been seen before."""
        new = []
        for lead in leads:
            lid = lead.get("lead_id", "")
            if lid and not self.is_seen(lid):
                new.append(lead)
        logger.info(
            "Dedup: {} total leads, {} new, {} already seen",
            len(leads), len(new), len(leads) - len(new),
        )
        return new

    def mark_seen(self, leads: list[dict]) -> None:
        """Record leads as seen. Updates last_seen if already exists."""
        now = datetime.now(timezone.utc).isoformat()
        for lead in leads:
            lid = lead.get("lead_id", "")
            if not lid:
                continue
            self._conn.execute(
                """INSERT INTO seen_leads (lead_id, listing_id, name, source_tab, first_seen, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?)
                   ON CONFLICT(lead_id) DO UPDATE SET last_seen = excluded.last_seen""",
                (
                    lid,
                    lead.get("listing_id", ""),
                    lead.get("name", ""),
                    lead.get("source_tab", ""),
                    now,
                    now,
                ),
            )
        self._conn.commit()

    def mark_crm_pushed(self, lead_id: str, crm_id: str = "") -> None:
        """Record that a lead was successfully pushed to the CRM."""
        self._conn.execute(
            "UPDATE seen_leads SET pushed_crm = 1, crm_id = ? WHERE lead_id = ?",
            (crm_id, lead_id),
        )
        self._conn.commit()

    def get_unpushed_leads(self) -> list[dict]:
        """Return leads that were seen but NOT yet pushed to CRM."""
        rows = self._conn.execute(
            "SELECT lead_id, listing_id, name, source_tab FROM seen_leads WHERE pushed_crm = 0"
        ).fetchall()
        return [
            {"lead_id": r[0], "listing_id": r[1], "name": r[2], "source_tab": r[3]}
            for r in rows
        ]

    # ------------------------------------------------------------------
    # Run log
    # ------------------------------------------------------------------

    def start_run(self) -> int:
        """Record the start of a scraper run. Returns the run_id."""
        now = datetime.now(timezone.utc).isoformat()
        cur = self._conn.execute(
            "INSERT INTO run_log (started_at) VALUES (?)", (now,)
        )
        self._conn.commit()
        return cur.lastrowid  # type: ignore[return-value]

    def finish_run(
        self, run_id: int, *, total: int = 0, new: int = 0, status: str = "ok"
    ) -> None:
        """Record the end of a scraper run."""
        now = datetime.now(timezone.utc).isoformat()
        self._conn.execute(
            """UPDATE run_log
               SET finished_at = ?, total_leads = ?, new_leads = ?, status = ?
               WHERE run_id = ?""",
            (now, total, new, status, run_id),
        )
        self._conn.commit()

    def last_successful_run(self) -> str | None:
        """Return ISO timestamp of the last successful run, or None."""
        row = self._conn.execute(
            "SELECT finished_at FROM run_log WHERE status = 'ok' ORDER BY run_id DESC LIMIT 1"
        ).fetchone()
        return row[0] if row else None

    def daily_stats(self, hours: int = 24) -> dict:
        """Return aggregated stats for the last `hours` hours.

        Returns dict with keys: total_runs, successful_runs, failed_runs,
        total_leads_scraped, new_leads, leads_pushed_crm.
        """
        cutoff = (
            datetime.now(timezone.utc) - timedelta(hours=hours)
        ).isoformat()

        row = self._conn.execute(
            """SELECT
                   COUNT(*) AS total_runs,
                   SUM(CASE WHEN status = 'ok' THEN 1 ELSE 0 END) AS ok_runs,
                   SUM(CASE WHEN status NOT IN ('ok', 'dry_run', 'running') THEN 1 ELSE 0 END) AS fail_runs,
                   COALESCE(SUM(total_leads), 0) AS total_leads,
                   COALESCE(SUM(new_leads), 0) AS new_leads
               FROM run_log
               WHERE started_at >= ?""",
            (cutoff,),
        ).fetchone()

        pushed = self._conn.execute(
            "SELECT COUNT(*) FROM seen_leads WHERE pushed_crm = 1 AND first_seen >= ?",
            (cutoff,),
        ).fetchone()

        return {
            "total_runs": row[0],
            "successful_runs": row[1],
            "failed_runs": row[2],
            "total_leads_scraped": row[3],
            "new_leads": row[4],
            "leads_pushed_crm": pushed[0] if pushed else 0,
        }

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> StateStore:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()
