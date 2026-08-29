from __future__ import annotations

import os
from dataclasses import dataclass, field

from dotenv import load_dotenv


@dataclass
class EBSettings:
    """Settings for the EasyBroker Buzón bot.

    EB UI login (email + password) is SEPARATE from EASYBROKER_API_KEY: the API
    key drives the read-only contact_requests API, while these credentials log
    into app.easybroker.com to perform the Buzón actions the API can't.
    """

    email: str
    password: str = field(repr=False)  # never printed in logs or tracebacks

    # Account API key for contact request creation and GET reconciliation.
    api_key: str = field(default="", repr=False)

    # Supabase (poll for assigned EB leads needing the Atendida + note actions)
    supabase_url: str = ""
    supabase_service_key: str = field(default="", repr=False)

    # V3 request-level inbox is opt-in until its migration is applied.
    v3_inbox_enabled: bool = False
    # POST creation requires its separate explicit gate; it is off by default.
    easybroker_create_requests: bool = False
    account_key: str = "default"

    @classmethod
    def load(cls, env_file: str = ".env") -> "EBSettings":
        load_dotenv(env_file, override=False)

        email = os.environ.get("EASYBROKER_EMAIL", "").strip()
        password = os.environ.get("EASYBROKER_PASSWORD", "").strip()

        missing: list[str] = []
        if not email:
            missing.append("EASYBROKER_EMAIL")
        if not password:
            missing.append("EASYBROKER_PASSWORD")
        if missing:
            raise ValueError(
                f"Missing required environment variable(s): {', '.join(missing)}. "
                f"Add EASYBROKER_EMAIL and EASYBROKER_PASSWORD to .env."
            )

        return cls(
            email=email,
            password=password,
            api_key=os.environ.get("EASYBROKER_API_KEY", "").strip(),
            supabase_url=os.environ.get("SUPABASE_URL", "").strip(),
            supabase_service_key=os.environ.get("SUPABASE_SERVICE_KEY", "").strip(),
            v3_inbox_enabled=os.environ.get("EASYBROKER_V3_INBOX", "").strip().lower() in {"1", "true", "yes"},
            easybroker_create_requests=os.environ.get("EASYBROKER_CREATE_REQUESTS", "").strip().lower() in {"1", "true", "yes"},
            account_key=os.environ.get("EASYBROKER_ACCOUNT_KEY", "default").strip() or "default",
        )
