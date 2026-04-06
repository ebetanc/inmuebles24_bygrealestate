from __future__ import annotations

import os
from dataclasses import dataclass, field
from dotenv import load_dotenv


_DEFAULT_WEBHOOK_URL = (
    "https://n8n.srv856940.hstgr.cloud/webhook/"
    "63340e41-c487-4e66-86fe-c4ff710fbcdd"
)


@dataclass
class Settings:
    email: str
    password: str = field(repr=False)

    # Proxy (optional — disabled when host is empty)
    proxy_host: str = ""
    proxy_port: int = 0
    proxy_user: str = ""
    proxy_pass: str = field(default="", repr=False)

    # Webhook URLs
    webhook_url: str = _DEFAULT_WEBHOOK_URL
    heartbeat_url: str = ""

    # State file path
    state_dir: str = ""

    @property
    def proxy_enabled(self) -> bool:
        return bool(self.proxy_host)

    @property
    def proxy_server(self) -> str:
        """Formatted proxy URL for Playwright."""
        if not self.proxy_enabled:
            return ""
        return f"http://{self.proxy_host}:{self.proxy_port}"

    @property
    def proxy_username_mx(self) -> str:
        """Proxy username with Mexico country targeting for Bright Data."""
        if not self.proxy_user:
            return ""
        return f"{self.proxy_user}-country-mx"

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

        proxy_host = os.environ.get("PROXY_HOST", "").strip()
        proxy_port_str = os.environ.get("PROXY_PORT", "0").strip()
        proxy_port = int(proxy_port_str) if proxy_port_str.isdigit() else 0
        proxy_user = os.environ.get("PROXY_USER", "").strip()
        proxy_pass = os.environ.get("PROXY_PASS", "").strip()

        webhook_url = os.environ.get("WEBHOOK_URL", "").strip() or _DEFAULT_WEBHOOK_URL
        heartbeat_url = os.environ.get("HEARTBEAT_URL", "").strip()

        state_dir = os.environ.get(
            "STATE_DIR",
            os.path.expanduser("~/.inmuebles24"),
        ).strip()

        return cls(
            email=email,
            password=password,
            proxy_host=proxy_host,
            proxy_port=proxy_port,
            proxy_user=proxy_user,
            proxy_pass=proxy_pass,
            webhook_url=webhook_url,
            heartbeat_url=heartbeat_url,
            state_dir=state_dir,
        )
