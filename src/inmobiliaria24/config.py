from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv


@dataclass
class Settings:
    email: str
    password: str = field(repr=False)  # never printed in logs or tracebacks

    # Scraper
    state_db_path: Path = Path("data/state.db")

    # Webhook (interim CRM adapter)
    webhook_url: str = ""

    # Monitoring — Telegram (errors only)
    telegram_bot_token: str = ""
    telegram_alert_chat_id: str = ""

    # Webhook health-check URL (used by monitor to verify server is up)
    webhook_health_url: str = "http://localhost:8000/health"

    @classmethod
    def load(cls, env_file: str = ".env") -> "Settings":
        """Load settings from environment variables, failing fast on missing values."""
        load_dotenv(env_file, override=False)

        missing: list[str] = []
        email = os.environ.get("INMUEBLES24_EMAIL", "").strip()
        password = os.environ.get("INMUEBLES24_PASSWORD", "").strip()

        if not email:
            missing.append("INMUEBLES24_EMAIL")
        if not password:
            missing.append("INMUEBLES24_PASSWORD")

        if missing:
            raise ValueError(
                f"Missing required environment variable(s): {', '.join(missing)}. "
                f"Copy .env.example to .env and fill in your credentials."
            )

        return cls(
            email=email,
            password=password,
            state_db_path=Path(
                os.environ.get("STATE_DB_PATH", "data/state.db")
            ),
            webhook_url=os.environ.get("WEBHOOK_URL", "").strip(),
            telegram_bot_token=os.environ.get("TELEGRAM_BOT_TOKEN", "").strip(),
            telegram_alert_chat_id=os.environ.get("TELEGRAM_ALERT_CHAT_ID", "").strip(),
            webhook_health_url=os.environ.get(
                "WEBHOOK_HEALTH_URL", "http://localhost:8000/health"
            ).strip(),
        )
