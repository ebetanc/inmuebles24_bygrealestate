"""SQLite-backed conversation state persistence.

Stores the qualification bot's conversation state per phone number.
Supports concurrent access via WAL mode.
"""
from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Optional

from loguru import logger


class Step(str, Enum):
    """Qualification conversation steps."""
    NEW = "new"
    GREETING_SENT = "greeting_sent"
    AWAITING_INTENT = "awaiting_intent"
    AWAITING_BUDGET = "awaiting_budget"
    AWAITING_TIMELINE = "awaiting_timeline"
    AWAITING_ZONE = "awaiting_zone"
    QUALIFIED = "qualified"
    HANDED_OFF = "handed_off"
    COLD = "cold"
    FOLLOW_UP_SENT = "follow_up_sent"


@dataclass
class Conversation:
    """State for a single lead conversation."""
    phone: str
    lead_id: str = ""
    step: Step = Step.NEW
    name: str = ""
    property_info: str = ""
    intent: str = ""       # comprar / rentar
    budget: str = ""
    timeline: str = ""
    zone: str = ""
    crm_id: str = ""
    agent_phone: str = ""
    follow_up_count: int = 0
    last_message_at: str = ""
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    updated_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    def to_dict(self) -> dict:
        d = asdict(self)
        d["step"] = self.step.value
        return d

    @classmethod
    def from_dict(cls, d: dict) -> Conversation:
        d["step"] = Step(d.get("step", "new"))
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})


class ConversationStore:
    """SQLite-backed store for conversation state."""

    def __init__(self, db_path: Path) -> None:
        self._db_path = db_path
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(db_path), timeout=10)
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA busy_timeout=5000")
        self._create_tables()

    def _create_tables(self) -> None:
        self._conn.execute("""
            CREATE TABLE IF NOT EXISTS conversations (
                phone       TEXT PRIMARY KEY,
                data        TEXT NOT NULL,
                step        TEXT NOT NULL,
                updated_at  TEXT NOT NULL
            )
        """)
        self._conn.commit()

    def get(self, phone: str) -> Optional[Conversation]:
        """Get conversation by phone number."""
        row = self._conn.execute(
            "SELECT data FROM conversations WHERE phone = ?", (phone,)
        ).fetchone()
        if row:
            return Conversation.from_dict(json.loads(row[0]))
        return None

    def save(self, conv: Conversation) -> None:
        """Upsert conversation state."""
        conv.updated_at = datetime.now(timezone.utc).isoformat()
        self._conn.execute(
            """INSERT INTO conversations (phone, data, step, updated_at)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(phone) DO UPDATE SET
                   data = excluded.data,
                   step = excluded.step,
                   updated_at = excluded.updated_at""",
            (conv.phone, json.dumps(conv.to_dict()), conv.step.value, conv.updated_at),
        )
        self._conn.commit()

    def get_stale(self, timeout_hours: int = 24) -> list[Conversation]:
        """Get conversations that haven't had activity within timeout_hours.

        Only returns active conversations (not qualified, handed_off, or cold).
        """
        active_steps = (
            Step.GREETING_SENT.value,
            Step.AWAITING_INTENT.value,
            Step.AWAITING_BUDGET.value,
            Step.AWAITING_TIMELINE.value,
            Step.AWAITING_ZONE.value,
            Step.FOLLOW_UP_SENT.value,
        )
        placeholders = ",".join("?" for _ in active_steps)

        rows = self._conn.execute(
            f"""SELECT data FROM conversations
                WHERE step IN ({placeholders})
                AND datetime(updated_at) < datetime('now', '-{timeout_hours} hours')""",
            active_steps,
        ).fetchall()

        return [Conversation.from_dict(json.loads(r[0])) for r in rows]

    def get_by_step(self, step: Step) -> list[Conversation]:
        """Get all conversations at a specific step."""
        rows = self._conn.execute(
            "SELECT data FROM conversations WHERE step = ?", (step.value,)
        ).fetchall()
        return [Conversation.from_dict(json.loads(r[0])) for r in rows]

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> ConversationStore:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()
