"""Tests for monitoring module — stale-run detection and daily summary."""
from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch

import pytest

from inmobiliaria24.monitor import (
    check_stale_runs,
    send_daily_summary,
    send_heartbeat,
)


@pytest.fixture(autouse=True)
def _mock_telegram():
    """Intercept all Telegram HTTP calls — return success."""
    with patch("inmobiliaria24.monitor.httpx.AsyncClient") as mock_cls:
        mock_client = AsyncMock()
        mock_resp = AsyncMock()
        mock_resp.status_code = 200
        mock_resp.raise_for_status = AsyncMock()
        mock_client.post.return_value = mock_resp
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=False)
        mock_cls.return_value = mock_client
        yield mock_client


# ---------------------------------------------------------------------------
# Stale-run detection
# ---------------------------------------------------------------------------


def test_stale_runs_no_previous_run(_mock_telegram) -> None:
    """Alert should fire when there's no previous successful run."""
    sent = asyncio.run(check_stale_runs("tok", "chat", None))
    assert sent is True
    _mock_telegram.post.assert_called_once()


def test_stale_runs_recent_success(_mock_telegram) -> None:
    """No alert when last success was recent."""
    recent = datetime.now(timezone.utc).isoformat()
    sent = asyncio.run(check_stale_runs("tok", "chat", recent))
    assert sent is False
    _mock_telegram.post.assert_not_called()


def test_stale_runs_old_success(_mock_telegram) -> None:
    """Alert should fire when last success is older than threshold."""
    old = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
    sent = asyncio.run(check_stale_runs("tok", "chat", old, max_hours=24))
    assert sent is True


def test_stale_runs_custom_threshold(_mock_telegram) -> None:
    """Custom threshold should be respected."""
    # 5 hours ago — within 24h but outside 4h threshold.
    ts = (datetime.now(timezone.utc) - timedelta(hours=5)).isoformat()
    sent = asyncio.run(check_stale_runs("tok", "chat", ts, max_hours=4))
    assert sent is True


# ---------------------------------------------------------------------------
# Daily summary
# ---------------------------------------------------------------------------


def test_daily_summary_sends(_mock_telegram) -> None:
    sent = asyncio.run(
        send_daily_summary(
            "tok", "chat",
            total_runs=10,
            successful_runs=9,
            failed_runs=1,
            total_leads_scraped=50,
            new_leads=12,
            leads_pushed_crm=10,
        )
    )
    assert sent is True
    call_args = _mock_telegram.post.call_args
    payload = call_args.kwargs.get("json") or call_args[1].get("json")
    assert "Daily Summary" in payload["text"]
    assert "50" in payload["text"]


# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------


def test_heartbeat_ok(_mock_telegram) -> None:
    sent = asyncio.run(
        send_heartbeat("tok", "chat", total_leads=5, new_leads=2, status="ok")
    )
    assert sent is True


def test_heartbeat_skipped_no_config() -> None:
    """Heartbeat should be skipped (not error) when token is empty."""
    sent = asyncio.run(send_heartbeat("", "", total_leads=0))
    assert sent is False
