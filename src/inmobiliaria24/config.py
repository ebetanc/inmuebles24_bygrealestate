from __future__ import annotations
import os
from dataclasses import dataclass, field
from dotenv import load_dotenv


@dataclass
class Settings:
    email: str
    password: str = field(repr=False)  # never printed in logs or tracebacks

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

        return cls(email=email, password=password)
