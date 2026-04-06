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
