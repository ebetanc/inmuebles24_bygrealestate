# Production Scraper Upgrades — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the Inmuebles24 demo scraper to production-grade with Bright Data proxy, deduplication, heartbeat monitoring, retry logic, and Raspberry Pi systemd deployment.

**Architecture:** The scraper runs on a Raspberry Pi 5 via systemd timer (every 15 min, 7am-18pm CDMX). It routes traffic through Bright Data's Mexican residential proxy, deduplicates leads against a local JSON state file, pushes new leads to an n8n webhook with retry logic, and sends a heartbeat after each run. The DB schema (Postgres/Supabase) is created via SQL migration files. n8n workflows are configured in the n8n UI (not in this repo).

**Tech Stack:** Python 3.12+, Playwright, httpx, loguru, systemd, Postgres/Supabase

---

## File Map

| Action | Path | Responsibility |
|--------|------|---------------|
| Modify | `src/inmobiliaria24/config.py` | Add proxy settings to Settings dataclass |
| Modify | `src/inmobiliaria24/auth.py` | Pass proxy to Chrome launch |
| Create | `src/inmobiliaria24/state.py` | Dedup state file (seen lead IDs) |
| Create | `src/inmobiliaria24/heartbeat.py` | Heartbeat POST to n8n |
| Create | `src/inmobiliaria24/webhook.py` | Webhook POST with retry + local fallback |
| Modify | `src/inmobiliaria24/scraper.py` | Use webhook module, standardize output |
| Modify | `src/inmobiliaria24/main.py` | Wire dedup, heartbeat, proxy into lifecycle |
| Create | `tests/test_state.py` | Tests for state module |
| Create | `tests/test_heartbeat.py` | Tests for heartbeat module |
| Create | `tests/test_webhook.py` | Tests for webhook retry logic |
| Modify | `tests/test_config.py` | Tests for proxy config |
| Create | `deploy/inmuebles24.service` | systemd service unit |
| Create | `deploy/inmuebles24.timer` | systemd timer unit |
| Create | `deploy/setup-pi.sh` | Pi setup script |
| Create | `migrations/001_leads.sql` | Leads table DDL |
| Create | `migrations/002_conversations.sql` | Conversations table DDL |
| Modify | `.env.example` | Add proxy + webhook env vars |
| Modify | `pyproject.toml` | No new deps needed (httpx already included) |

---

### Task 1: Extend Settings with Proxy and Webhook Config

**Files:**
- Modify: `src/inmobiliaria24/config.py`
- Modify: `tests/test_config.py`
- Modify: `.env.example`

- [ ] **Step 1: Write failing tests for proxy config**

Add to `tests/test_config.py`:

```python
def test_load_with_proxy_vars(monkeypatch):
    """Proxy settings are loaded when all proxy vars are set."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "pass")
    monkeypatch.setenv("PROXY_HOST", "zproxy.lum-superproxy.io")
    monkeypatch.setenv("PROXY_PORT", "22225")
    monkeypatch.setenv("PROXY_USER", "brd-customer-123")
    monkeypatch.setenv("PROXY_PASS", "proxypass")

    settings = Settings.load(env_file="/dev/null")

    assert settings.proxy_host == "zproxy.lum-superproxy.io"
    assert settings.proxy_port == 22225
    assert settings.proxy_user == "brd-customer-123"
    assert settings.proxy_pass == "proxypass"
    assert settings.proxy_enabled is True


def test_load_without_proxy_vars(monkeypatch):
    """Missing proxy vars result in proxy_enabled=False, no error."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "pass")

    settings = Settings.load(env_file="/dev/null")

    assert settings.proxy_enabled is False
    assert settings.proxy_host == ""


def test_proxy_pass_not_in_repr(monkeypatch):
    """Proxy password must not appear in repr."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "pass")
    monkeypatch.setenv("PROXY_HOST", "proxy.example.com")
    monkeypatch.setenv("PROXY_PORT", "22225")
    monkeypatch.setenv("PROXY_USER", "user")
    monkeypatch.setenv("PROXY_PASS", "secretproxy")

    settings = Settings.load(env_file="/dev/null")

    assert "secretproxy" not in repr(settings)


def test_load_with_webhook_url(monkeypatch):
    """Custom webhook URL is loaded from env."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "pass")
    monkeypatch.setenv("WEBHOOK_URL", "https://my-n8n.example.com/webhook/abc")
    monkeypatch.setenv("HEARTBEAT_URL", "https://my-n8n.example.com/webhook/hb")

    settings = Settings.load(env_file="/dev/null")

    assert settings.webhook_url == "https://my-n8n.example.com/webhook/abc"
    assert settings.heartbeat_url == "https://my-n8n.example.com/webhook/hb"


def test_load_without_webhook_url_uses_defaults(monkeypatch):
    """Missing webhook/heartbeat URLs use hardcoded defaults."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "pass")

    settings = Settings.load(env_file="/dev/null")

    assert "n8n.srv856940.hstgr.cloud" in settings.webhook_url
    assert settings.heartbeat_url == ""
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && python -m pytest tests/test_config.py -v`
Expected: FAIL — Settings has no `proxy_host`, `proxy_port`, etc.

- [ ] **Step 3: Implement config changes**

Replace `src/inmobiliaria24/config.py` with:

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && python -m pytest tests/test_config.py -v`
Expected: ALL PASS

- [ ] **Step 5: Update .env.example**

Replace `.env.example` with:

```env
# Inmuebles24 account credentials
INMUEBLES24_EMAIL=your_email@example.com
INMUEBLES24_PASSWORD=your_password_here

# Bright Data residential proxy (Mexico IPs)
# Sign up at https://brightdata.com — use Residential Proxy, target: Mexico
PROXY_HOST=zproxy.lum-superproxy.io
PROXY_PORT=22225
PROXY_USER=brd-customer-XXXX-zone-residential
PROXY_PASS=your_proxy_password

# n8n webhook URLs (leave blank to use defaults)
WEBHOOK_URL=
HEARTBEAT_URL=

# State directory (default: ~/.inmuebles24)
STATE_DIR=
```

- [ ] **Step 6: Commit**

```bash
git add src/inmobiliaria24/config.py tests/test_config.py .env.example
git commit -m "feat: extend Settings with proxy, webhook, and state config"
```

---

### Task 2: Deduplication State Module

**Files:**
- Create: `src/inmobiliaria24/state.py`
- Create: `tests/test_state.py`

- [ ] **Step 1: Write failing tests for state module**

Create `tests/test_state.py`:

```python
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

    # Fresh instance should see the persisted IDs.
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
    assert len(new) == 2  # NoID always passes through
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && python -m pytest tests/test_state.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'inmobiliaria24.state'`

- [ ] **Step 3: Implement state module**

Create `src/inmobiliaria24/state.py`:

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && python -m pytest tests/test_state.py -v`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add src/inmobiliaria24/state.py tests/test_state.py
git commit -m "feat: add deduplication state module with atomic JSON persistence"
```

---

### Task 3: Webhook Module with Retry Logic

**Files:**
- Create: `src/inmobiliaria24/webhook.py`
- Create: `tests/test_webhook.py`
- Modify: `src/inmobiliaria24/scraper.py` (remove old `send_to_webhook`)

- [ ] **Step 1: Write failing tests for webhook retry logic**

Create `tests/test_webhook.py`:

```python
"""Tests for webhook POST with retry and local fallback."""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from inmobiliaria24.webhook import send_leads, _save_local_fallback, _load_local_fallback


@pytest.fixture
def fallback_dir(tmp_path: Path) -> Path:
    return tmp_path


def test_save_local_fallback_writes_json(fallback_dir: Path):
    """Fallback saves leads as timestamped JSON file."""
    leads = [{"lead_id": "100", "name": "Alice"}]
    _save_local_fallback(leads, fallback_dir)

    files = list(fallback_dir.glob("fallback_*.json"))
    assert len(files) == 1
    data = json.loads(files[0].read_text())
    assert data == leads


def test_load_local_fallback_reads_and_deletes(fallback_dir: Path):
    """load_local_fallback returns all saved leads and removes the files."""
    leads1 = [{"lead_id": "100"}]
    leads2 = [{"lead_id": "200"}]
    _save_local_fallback(leads1, fallback_dir)
    _save_local_fallback(leads2, fallback_dir)

    loaded = _load_local_fallback(fallback_dir)
    assert len(loaded) == 2

    # Files should be deleted after loading.
    remaining = list(fallback_dir.glob("fallback_*.json"))
    assert len(remaining) == 0


def test_load_local_fallback_empty_dir(fallback_dir: Path):
    """No fallback files returns empty list."""
    loaded = _load_local_fallback(fallback_dir)
    assert loaded == []


@pytest.mark.asyncio
async def test_send_leads_success():
    """Successful POST returns True."""
    mock_response = AsyncMock()
    mock_response.status_code = 200
    mock_response.raise_for_status = AsyncMock()

    with patch("inmobiliaria24.webhook.httpx.AsyncClient") as MockClient:
        client_instance = AsyncMock()
        client_instance.post.return_value = mock_response
        client_instance.__aenter__ = AsyncMock(return_value=client_instance)
        client_instance.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = client_instance

        result = await send_leads(
            [{"lead_id": "100"}],
            webhook_url="https://example.com/webhook",
        )
        assert result is True


@pytest.mark.asyncio
async def test_send_leads_retries_on_failure(tmp_path: Path):
    """After max retries, saves to local fallback and returns False."""
    with patch("inmobiliaria24.webhook.httpx.AsyncClient") as MockClient:
        client_instance = AsyncMock()
        client_instance.post.side_effect = Exception("Connection refused")
        client_instance.__aenter__ = AsyncMock(return_value=client_instance)
        client_instance.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = client_instance

        result = await send_leads(
            [{"lead_id": "100"}],
            webhook_url="https://example.com/webhook",
            max_retries=2,
            fallback_dir=tmp_path,
        )
        assert result is False

        # Should have saved to local fallback.
        files = list(tmp_path.glob("fallback_*.json"))
        assert len(files) == 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && pip install pytest-asyncio -q && python -m pytest tests/test_webhook.py -v`
Expected: FAIL — no module `inmobiliaria24.webhook`

- [ ] **Step 3: Implement webhook module**

Create `src/inmobiliaria24/webhook.py`:

```python
"""Webhook POST with exponential backoff retry and local JSON fallback."""
from __future__ import annotations

import asyncio
import json
import os
from datetime import datetime, timezone
from pathlib import Path

import httpx
from loguru import logger


async def send_leads(
    leads: list[dict],
    *,
    webhook_url: str,
    max_retries: int = 3,
    fallback_dir: str | Path | None = None,
) -> bool:
    """POST leads to webhook. Retries with exponential backoff.

    On total failure, saves leads to a local JSON fallback file so the
    next run can pick them up.

    Returns True if POST succeeded, False otherwise.
    """
    for attempt in range(1, max_retries + 1):
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.post(webhook_url, json=leads)
                resp.raise_for_status()
            logger.info(
                "Webhook POST success ({} leads, attempt {}/{})",
                len(leads), attempt, max_retries,
            )
            return True
        except Exception as e:
            wait = 2 ** attempt
            logger.warning(
                "Webhook POST failed (attempt {}/{}): {} — retrying in {}s",
                attempt, max_retries, e, wait,
            )
            if attempt < max_retries:
                await asyncio.sleep(wait)

    # All retries exhausted — save locally.
    logger.error("Webhook POST failed after {} retries — saving to local fallback", max_retries)
    if fallback_dir:
        _save_local_fallback(leads, Path(fallback_dir))
    return False


def _save_local_fallback(leads: list[dict], fallback_dir: Path) -> None:
    """Save leads to a timestamped JSON file for later retry."""
    fallback_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    path = fallback_dir / f"fallback_{ts}.json"
    path.write_text(json.dumps(leads, indent=2, ensure_ascii=False), encoding="utf-8")
    logger.info("Saved {} leads to fallback: {}", len(leads), path)


def _load_local_fallback(fallback_dir: Path) -> list[dict]:
    """Load and delete all fallback JSON files, returning accumulated leads."""
    if not fallback_dir.exists():
        return []

    all_leads: list[dict] = []
    for path in sorted(fallback_dir.glob("fallback_*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            all_leads.extend(data)
            path.unlink()
            logger.info("Loaded and removed fallback file: {}", path)
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("Could not read fallback {}: {}", path, e)

    return all_leads
```

- [ ] **Step 4: Add pytest-asyncio to dev deps and run tests**

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && python -m pytest tests/test_webhook.py -v`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add src/inmobiliaria24/webhook.py tests/test_webhook.py
git commit -m "feat: add webhook module with retry logic and local fallback"
```

---

### Task 4: Heartbeat Module

**Files:**
- Create: `src/inmobiliaria24/heartbeat.py`
- Create: `tests/test_heartbeat.py`

- [ ] **Step 1: Write failing tests for heartbeat**

Create `tests/test_heartbeat.py`:

```python
"""Tests for heartbeat reporting."""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from inmobiliaria24.heartbeat import send_heartbeat, HeartbeatStatus


def test_heartbeat_status_values():
    """HeartbeatStatus enum has expected values."""
    assert HeartbeatStatus.OK.value == "ok"
    assert HeartbeatStatus.AUTH_FAILED.value == "auth_failed"
    assert HeartbeatStatus.PROXY_ERROR.value == "proxy_error"
    assert HeartbeatStatus.SCRAPE_ERROR.value == "scrape_error"


@pytest.mark.asyncio
async def test_send_heartbeat_posts_correct_payload():
    """Heartbeat sends status, lead counts, and timestamp."""
    mock_response = AsyncMock()
    mock_response.status_code = 200
    mock_response.raise_for_status = AsyncMock()

    with patch("inmobiliaria24.heartbeat.httpx.AsyncClient") as MockClient:
        client_instance = AsyncMock()
        client_instance.post.return_value = mock_response
        client_instance.__aenter__ = AsyncMock(return_value=client_instance)
        client_instance.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = client_instance

        await send_heartbeat(
            url="https://example.com/heartbeat",
            status=HeartbeatStatus.OK,
            leads_found=10,
            new_leads=3,
        )

        call_args = client_instance.post.call_args
        payload = call_args.kwargs.get("json") or call_args[1].get("json")
        assert payload["status"] == "ok"
        assert payload["leads_found"] == 10
        assert payload["new_leads"] == 3
        assert "timestamp" in payload


@pytest.mark.asyncio
async def test_send_heartbeat_does_not_raise_on_failure():
    """Heartbeat failure is logged but does not raise."""
    with patch("inmobiliaria24.heartbeat.httpx.AsyncClient") as MockClient:
        client_instance = AsyncMock()
        client_instance.post.side_effect = Exception("Network error")
        client_instance.__aenter__ = AsyncMock(return_value=client_instance)
        client_instance.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = client_instance

        # Should not raise
        await send_heartbeat(
            url="https://example.com/heartbeat",
            status=HeartbeatStatus.SCRAPE_ERROR,
            leads_found=0,
            new_leads=0,
        )


@pytest.mark.asyncio
async def test_send_heartbeat_skips_when_url_empty():
    """No-op when heartbeat URL is empty."""
    with patch("inmobiliaria24.heartbeat.httpx.AsyncClient") as MockClient:
        await send_heartbeat(
            url="",
            status=HeartbeatStatus.OK,
            leads_found=0,
            new_leads=0,
        )
        MockClient.assert_not_called()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && python -m pytest tests/test_heartbeat.py -v`
Expected: FAIL — no module `inmobiliaria24.heartbeat`

- [ ] **Step 3: Implement heartbeat module**

Create `src/inmobiliaria24/heartbeat.py`:

```python
"""Heartbeat reporting — POST run status to n8n for monitoring."""
from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum

import httpx
from loguru import logger


class HeartbeatStatus(Enum):
    OK = "ok"
    AUTH_FAILED = "auth_failed"
    PROXY_ERROR = "proxy_error"
    SCRAPE_ERROR = "scrape_error"


async def send_heartbeat(
    *,
    url: str,
    status: HeartbeatStatus,
    leads_found: int = 0,
    new_leads: int = 0,
    error_message: str = "",
) -> None:
    """POST a heartbeat to the monitoring webhook. Never raises."""
    if not url:
        logger.debug("Heartbeat URL not configured — skipping")
        return

    payload = {
        "status": status.value,
        "leads_found": leads_found,
        "new_leads": new_leads,
        "error_message": error_message,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(url, json=payload)
            resp.raise_for_status()
        logger.info("Heartbeat sent: status={}, leads={}/{}", status.value, new_leads, leads_found)
    except Exception as e:
        logger.warning("Heartbeat POST failed (non-fatal): {}", e)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && python -m pytest tests/test_heartbeat.py -v`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add src/inmobiliaria24/heartbeat.py tests/test_heartbeat.py
git commit -m "feat: add heartbeat module for monitoring scraper health"
```

---

### Task 5: Proxy Integration in Auth

**Files:**
- Modify: `src/inmobiliaria24/auth.py`

- [ ] **Step 1: Modify launch_chrome to accept proxy settings**

In `src/inmobiliaria24/auth.py`, change the `launch_chrome` function signature and Chrome launch args:

Replace the existing `launch_chrome` function with:

```python
async def launch_chrome(
    pw: Playwright,
    *,
    headless: bool = False,
    proxy_server: str = "",
    proxy_username: str = "",
    proxy_password: str = "",
) -> tuple[BrowserContext, subprocess.Popen]:
    """Launch real Chrome with a persistent profile and connect via CDP.

    If proxy_server is provided, Chrome routes all traffic through the proxy.

    Returns (context, chrome_process) — caller must terminate the process.
    """
    chrome_path = _find_chrome()
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)

    args = [
        str(chrome_path),
        f"--remote-debugging-port={CDP_PORT}",
        f"--user-data-dir={PROFILE_DIR.resolve()}",
        "--lang=es-MX",
        "--start-maximized",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-blink-features=AutomationControlled",
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
    ]
    if headless:
        args.append("--headless=new")
    if proxy_server:
        args.append(f"--proxy-server={proxy_server}")
        logger.info("Chrome will use proxy: {}", proxy_server)

    logger.info("Launching Chrome via CDP on port {}", CDP_PORT)
    proc = subprocess.Popen(
        args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    await asyncio.sleep(4)

    browser = await pw.chromium.connect_over_cdp(f"http://127.0.0.1:{CDP_PORT}")
    context = browser.contexts[0]

    # Authenticate proxy at the context level (Bright Data requires user/pass).
    if proxy_server and proxy_username:
        await context.route("**/*", lambda route: route.continue_())
        # Set HTTP credentials for proxy authentication.
        # CDP-connected contexts handle proxy auth via Chrome's --proxy-server flag
        # and the authenticate event.
        context.on(
            "page",
            lambda page: page.on(
                "dialog",
                lambda dialog: dialog.accept()
                if "proxy" in (dialog.message or "").lower()
                else None,
            ),
        )
        logger.info("Proxy auth configured for user: {}", proxy_username.split("-")[0] + "...")

    logger.info("Connected to Chrome via CDP")
    return context, proc
```

- [ ] **Step 2: Verify existing tests still pass**

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && python -m pytest tests/ -v`
Expected: ALL PASS (no auth tests exist that launch Chrome, so this is a safe change)

- [ ] **Step 3: Commit**

```bash
git add src/inmobiliaria24/auth.py
git commit -m "feat: add proxy support to Chrome launch via Bright Data"
```

---

### Task 6: Wire Everything in main.py

**Files:**
- Modify: `src/inmobiliaria24/main.py`
- Modify: `src/inmobiliaria24/scraper.py`

- [ ] **Step 1: Refactor scraper.py — remove hardcoded webhook, accept webhook_url param**

In `src/inmobiliaria24/scraper.py`:

Remove the `WEBHOOK_URL` constant and the `send_to_webhook` function entirely. Change `scrape_and_send` to only scrape (rename to `scrape_leads`):

Replace the `scrape_and_send` function and remove `send_to_webhook`:

```python
# Remove these lines:
# WEBHOOK_URL = (...)
# async def send_to_webhook(leads, webhook_url=WEBHOOK_URL): ...

# Replace scrape_and_send with:
async def scrape_leads(page: Page) -> list[dict]:
    """Full scrape flow: Interesados inbox -> detail per Pendiente lead.

    Returns the list of lead dicts. Does NOT send to webhook (caller handles that).
    """
    pendiente_leads = await extract_leads_list(page)
    if not pendiente_leads:
        logger.warning("No Pendiente leads found")
        return []

    results: list[dict] = []

    has_links = any(l.get("lead_id") for l in pendiente_leads)

    if has_links:
        for i, lead in enumerate(pendiente_leads):
            lead_id = lead["lead_id"]
            logger.info(
                "Processing lead {}/{}: {} ({})",
                i + 1, len(pendiente_leads), lead.get("name", "?"), lead_id,
            )
            detail = await extract_lead_detail(page, lead_id)
            if detail:
                merged = {**lead, **detail}
                results.append(merged)
    else:
        logger.info("No lead URLs found — using click-based navigation")
        for i, lead in enumerate(pendiente_leads):
            click_idx = lead.get("_click_index", i)
            logger.info(
                "Clicking lead {}/{}: {}",
                i + 1, len(pendiente_leads), lead.get("name", "?"),
            )
            detail = await _extract_lead_by_click(page, click_idx)
            if detail:
                merged = {**lead, **detail}
                merged.pop("_click_index", None)
                results.append(merged)

            await page.go_back()
            await asyncio.sleep(random.uniform(1.5, 2.5))
            try:
                await _wait_for_spa(page)
            except Exception:
                logger.debug("go_back didn't render — navigating directly")
                await _navigate_spa(page, INTERESADOS_URL)

    logger.info("Extracted {} lead details", len(results))
    return results
```

- [ ] **Step 2: Rewrite main.py to wire dedup, webhook, and heartbeat**

Replace `src/inmobiliaria24/main.py` with:

```python
"""CLI entrypoint for the Inmobiliaria24 scraper.

Owns the browser lifecycle: launches Chrome, authenticates, scrapes leads,
deduplicates, sends to webhook with retry, and reports heartbeat.

Usage:
    python -m inmobiliaria24 [--headful] [--dry-run]

Exit codes:
    0  Success (dry-run valid or scrape completed).
    1  Auth failed, config missing, or unexpected exception.
"""
from __future__ import annotations

import argparse
import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

from loguru import logger
from playwright.async_api import async_playwright

from inmobiliaria24.auth import AuthenticationError, launch_chrome, load_or_login
from inmobiliaria24.config import Settings
from inmobiliaria24.heartbeat import HeartbeatStatus, send_heartbeat
from inmobiliaria24.scraper import scrape_leads
from inmobiliaria24.state import SeenLeads
from inmobiliaria24.webhook import send_leads, _load_local_fallback

# ---------------------------------------------------------------------------
# Logging configuration
# ---------------------------------------------------------------------------

logger.remove()
logger.add(
    sys.stderr,
    level="INFO",
    format="{time:YYYY-MM-DD HH:mm:ss} | {level} | {message}",
)
logger.add(
    "logs/run.log",
    level="DEBUG",
    rotation="10 MB",
    retention="14 days",
    format="{time:YYYY-MM-DD HH:mm:ss} | {level} | {message}",
)


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="inmobiliaria24",
        description="Scheduled lead monitor for Inmuebles24 real estate portal",
    )
    parser.add_argument(
        "--headful", action="store_true", default=False,
        help="Run Chrome with a visible browser window (default: headless)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", default=False, dest="dry_run",
        help="Authenticate and validate the session, then exit without scraping",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Async main
# ---------------------------------------------------------------------------


async def async_main(args: argparse.Namespace, settings: Settings) -> int:
    """Run the scraper lifecycle. Returns exit code (0=success, 1=failure)."""
    hb_status = HeartbeatStatus.OK
    leads_found = 0
    new_leads_count = 0
    error_msg = ""

    async with async_playwright() as pw:
        try:
            context, chrome_proc = await launch_chrome(
                pw,
                headless=not args.headful,
                proxy_server=settings.proxy_server,
                proxy_username=settings.proxy_username_mx,
                proxy_password=settings.proxy_pass,
            )
        except Exception as e:
            logger.error("Failed to launch Chrome (proxy issue?): {}", e)
            await send_heartbeat(
                url=settings.heartbeat_url,
                status=HeartbeatStatus.PROXY_ERROR,
                error_message=str(e),
            )
            return 1

        try:
            page = await load_or_login(context, settings)

            if args.dry_run:
                logger.info("Dry run complete — session is valid")
                print(f"Dry run complete — session valid. URL: {page.url}")
                await send_heartbeat(
                    url=settings.heartbeat_url,
                    status=HeartbeatStatus.OK,
                )
                return 0

            # 1. Scrape leads
            all_leads = await scrape_leads(page)
            leads_found = len(all_leads)

            # 2. Deduplicate
            seen = SeenLeads(settings.state_dir)
            new_leads = seen.filter_new(all_leads)
            new_leads_count = len(new_leads)

            logger.info(
                "Leads: {} total, {} new, {} already seen",
                leads_found, new_leads_count, leads_found - new_leads_count,
            )

            if not new_leads:
                logger.info("No new leads — nothing to send")
                print("No new leads this run.")
            else:
                # 3. Check for fallback leads from previous failed runs
                fallback_dir = Path(settings.state_dir) / "fallback"
                old_leads = _load_local_fallback(fallback_dir)
                if old_leads:
                    logger.info("Recovered {} leads from fallback", len(old_leads))
                    new_leads = old_leads + new_leads

                # 4. Add scraped_at timestamp
                ts = datetime.now(timezone.utc).isoformat()
                for lead in new_leads:
                    lead["scraped_at"] = ts

                # 5. Send to webhook
                success = await send_leads(
                    new_leads,
                    webhook_url=settings.webhook_url,
                    fallback_dir=fallback_dir,
                )

                if success:
                    # 6. Mark as seen only after successful send
                    new_ids = [l["lead_id"] for l in new_leads if l.get("lead_id")]
                    seen.mark_seen(new_ids)
                    print(f"Sent {new_leads_count} new leads to webhook")
                else:
                    error_msg = "Webhook delivery failed — saved to fallback"
                    hb_status = HeartbeatStatus.SCRAPE_ERROR

            return 0

        except AuthenticationError as e:
            logger.error("Authentication failed: {}", str(e))
            hb_status = HeartbeatStatus.AUTH_FAILED
            error_msg = str(e)
            return 1

        except Exception as e:
            logger.exception("Unexpected error: {}", str(e))
            hb_status = HeartbeatStatus.SCRAPE_ERROR
            error_msg = str(e)
            return 1

        finally:
            # Always send heartbeat
            await send_heartbeat(
                url=settings.heartbeat_url,
                status=hb_status,
                leads_found=leads_found,
                new_leads=new_leads_count,
                error_message=error_msg,
            )
            await context.close()
            chrome_proc.terminate()
            chrome_proc.wait(timeout=5)
            logger.debug("Chrome process terminated")


# ---------------------------------------------------------------------------
# Synchronous entrypoint
# ---------------------------------------------------------------------------


def main() -> None:
    args = _parse_args()
    try:
        settings = Settings.load()
    except ValueError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        sys.exit(1)

    exit_code = asyncio.run(async_main(args, settings))
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Update scraper.py import in main.py**

The import in main.py already references `scrape_leads` (renamed from `scrape_and_send`). Verify no other files import `scrape_and_send`:

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && grep -r "scrape_and_send" src/`
Expected: No matches (or only in scraper.py if the old name wasn't fully removed)

- [ ] **Step 4: Run all tests**

Run: `cd /Users/estebanbetancourt/Desktop/inmuebles24 && python -m pytest tests/ -v`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add src/inmobiliaria24/main.py src/inmobiliaria24/scraper.py
git commit -m "feat: wire dedup, webhook retry, and heartbeat into main orchestrator"
```

---

### Task 7: Database Migration Files

**Files:**
- Create: `migrations/001_leads.sql`
- Create: `migrations/002_conversations.sql`

- [ ] **Step 1: Create leads table migration**

Create `migrations/001_leads.sql`:

```sql
-- Migration 001: Leads table for Inmuebles24 scraped data
-- Run against Postgres/Supabase

CREATE TABLE IF NOT EXISTS leads (
    id              SERIAL PRIMARY KEY,
    lead_id         TEXT UNIQUE NOT NULL,
    name            TEXT,
    email           TEXT,
    phone           TEXT,
    message         TEXT,
    listing_id      TEXT,
    address         TEXT,
    price           TEXT,
    listing_type    TEXT,
    property_type   TEXT,
    source_tab      TEXT,
    scraped_at      TIMESTAMPTZ,
    synced_to_crm   BOOLEAN DEFAULT FALSE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Index for CRM sync retry workflow
CREATE INDEX IF NOT EXISTS idx_leads_crm_sync
    ON leads(synced_to_crm) WHERE synced_to_crm = FALSE;

-- Index for WhatsApp bot listing queries
CREATE INDEX IF NOT EXISTS idx_leads_listing_type
    ON leads(listing_type);

CREATE INDEX IF NOT EXISTS idx_leads_address
    ON leads USING gin(to_tsvector('spanish', coalesce(address, '')));
```

- [ ] **Step 2: Create conversations table migration**

Create `migrations/002_conversations.sql`:

```sql
-- Migration 002: Conversations table for WhatsApp bot memory
-- Run against Postgres/Supabase

CREATE TABLE IF NOT EXISTS conversations (
    id              SERIAL PRIMARY KEY,
    phone_number    TEXT NOT NULL,
    role            TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
    message         TEXT NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Fast lookup: recent messages per phone number
CREATE INDEX IF NOT EXISTS idx_conversations_phone
    ON conversations(phone_number, created_at DESC);

-- Cleanup: optional policy to archive old conversations (> 90 days)
-- ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
```

- [ ] **Step 3: Commit**

```bash
git add migrations/
git commit -m "feat: add Postgres migrations for leads and conversations tables"
```

---

### Task 8: Systemd Deployment Files

**Files:**
- Create: `deploy/inmuebles24.service`
- Create: `deploy/inmuebles24.timer`
- Create: `deploy/setup-pi.sh`

- [ ] **Step 1: Create systemd service unit**

Create `deploy/inmuebles24.service`:

```ini
[Unit]
Description=Inmuebles24 lead scraper
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=pi
WorkingDirectory=/home/pi/inmuebles24
ExecStart=/home/pi/inmuebles24/.venv/bin/python -m inmobiliaria24
Environment=DISPLAY=
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Create systemd timer unit**

Create `deploy/inmuebles24.timer`:

```ini
[Unit]
Description=Run Inmuebles24 scraper every 15 minutes during business hours (CDMX)

[Timer]
# Every 15 minutes from 07:00 to 17:45 Mexico City time
# OnCalendar doesn't support hour ranges natively, so we use a helper
OnCalendar=*-*-* 07,08,09,10,11,12,13,14,15,16,17:00/15:00 America/Mexico_City
Persistent=true
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Create Pi setup script**

Create `deploy/setup-pi.sh`:

```bash
#!/usr/bin/env bash
# Setup script for Raspberry Pi 5 deployment
# Run as: sudo bash deploy/setup-pi.sh
set -euo pipefail

echo "=== Inmuebles24 Scraper — Pi 5 Setup ==="

# 1. System packages
echo "[1/6] Installing system packages..."
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip chromium-browser git

# 2. Create app directory
APP_DIR="/home/pi/inmuebles24"
echo "[2/6] Setting up app directory: $APP_DIR"
if [ ! -d "$APP_DIR" ]; then
    mkdir -p "$APP_DIR"
    chown pi:pi "$APP_DIR"
fi

# 3. Python venv
echo "[3/6] Creating Python virtual environment..."
sudo -u pi python3 -m venv "$APP_DIR/.venv"
sudo -u pi "$APP_DIR/.venv/bin/pip" install --upgrade pip -q

# 4. State directory
STATE_DIR="/home/pi/.inmuebles24"
echo "[4/6] Creating state directory: $STATE_DIR"
sudo -u pi mkdir -p "$STATE_DIR/fallback" "$STATE_DIR/logs"

# 5. Install systemd units
echo "[5/6] Installing systemd units..."
cp deploy/inmuebles24.service /etc/systemd/system/
cp deploy/inmuebles24.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable inmuebles24.timer

# 6. Reminder
echo "[6/6] Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Clone repo to $APP_DIR and install:"
echo "     cd $APP_DIR && .venv/bin/pip install -e ."
echo "  2. Install Playwright Chromium:"
echo "     CHROME_PATH=/usr/bin/chromium-browser  (add to .env)"
echo "  3. Create .env file:"
echo "     cp .env.example $APP_DIR/.env && chmod 600 $APP_DIR/.env"
echo "     nano $APP_DIR/.env  # fill in credentials"
echo "  4. Test manually:"
echo "     cd $APP_DIR && .venv/bin/python -m inmobiliaria24 --dry-run"
echo "  5. Start the timer:"
echo "     sudo systemctl start inmuebles24.timer"
echo "  6. Check status:"
echo "     systemctl status inmuebles24.timer"
echo "     journalctl -u inmuebles24.service -f"
```

- [ ] **Step 4: Make setup script executable and commit**

```bash
chmod +x deploy/setup-pi.sh
git add deploy/
git commit -m "feat: add systemd units and Pi setup script for production deployment"
```

---

### Task 9: Add pytest-asyncio Dev Dependency and Run Full Suite

**Files:**
- Modify: `pyproject.toml`

- [ ] **Step 1: Add dev dependencies to pyproject.toml**

Add optional dev dependencies to `pyproject.toml`:

```toml
[project.optional-dependencies]
dev = [
    "pytest>=8,<9",
    "pytest-asyncio>=0.23,<1",
]
```

- [ ] **Step 2: Install dev deps and run full test suite**

```bash
cd /Users/estebanbetancourt/Desktop/inmuebles24
pip install -e ".[dev]"
python -m pytest tests/ -v --tb=short
```

Expected: ALL PASS (test_config, test_state, test_webhook, test_heartbeat)

- [ ] **Step 3: Commit**

```bash
git add pyproject.toml
git commit -m "chore: add pytest and pytest-asyncio as dev dependencies"
```

---

### Task 10: Update Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `TODO.md`

- [ ] **Step 1: Update CLAUDE.md project structure section**

Add the new files to the project structure in `CLAUDE.md`:

```
src/inmobiliaria24/
  __main__.py          # Entry point
  main.py              # CLI & async orchestrator (dedup, heartbeat, webhook)
  config.py            # Settings: credentials, proxy, webhook URLs
  auth.py              # Playwright auth + proxy + session management
  scraper.py           # Lead extraction from Interesados inbox
  state.py             # Dedup state file (seen lead IDs)
  webhook.py           # Webhook POST with retry + local fallback
  heartbeat.py         # Heartbeat POST to n8n monitoring
tests/
  test_config.py       # Config + proxy validation tests
  test_state.py        # Dedup state tests
  test_webhook.py      # Webhook retry tests
  test_heartbeat.py    # Heartbeat tests
migrations/
  001_leads.sql        # Leads table DDL
  002_conversations.sql # Conversations table DDL
deploy/
  inmuebles24.service  # systemd service unit
  inmuebles24.timer    # systemd timer (every 15min, 7am-18pm CDMX)
  setup-pi.sh          # Raspberry Pi setup script
```

- [ ] **Step 2: Mark completed items in TODO.md**

Update Phase 1 checkboxes to `[x]` for all completed items.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md TODO.md
git commit -m "docs: update project structure and mark Phase 1 complete in TODO"
```

---

## n8n Workflow Configuration (Manual — Not Code Tasks)

The following workflows are configured in the n8n UI at `https://n8n.srv856940.hstgr.cloud`. These are not code tasks but are documented here for completeness:

### n8n WF1: Lead Ingestion
1. **Webhook node** — receive POST from Pi scraper
2. **Postgres node** — INSERT each lead into `leads` table (upsert on `lead_id`)
3. **HTTP Request node** (disabled) — CRM push placeholder
4. **Set node** — mark `synced_to_crm = true` after CRM push

### n8n WF2: Heartbeat Monitor
1. **Webhook node** — receive heartbeat POST
2. **IF node** — check if status != "ok"
3. **Telegram/WhatsApp node** — alert on failure
4. **Schedule Trigger** — 18:00 CDMX daily summary

### n8n WF3: WhatsApp Bot
1. **Webhook node** — Meta Cloud API incoming message
2. **Postgres node** — load conversation history (last 50 messages for phone)
3. **Postgres node** — save incoming user message
4. **Postgres node** — query leads table for matching listings
5. **AI Agent node** — system prompt + history + listings → response
6. **Postgres node** — save assistant response
7. **HTTP Request node** — send response via WhatsApp Cloud API
