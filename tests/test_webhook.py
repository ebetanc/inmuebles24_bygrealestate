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

        files = list(tmp_path.glob("fallback_*.json"))
        assert len(files) == 1
