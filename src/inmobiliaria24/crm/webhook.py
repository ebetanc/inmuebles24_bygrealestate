"""Generic webhook CRM adapter.

Posts leads as JSON to any webhook URL. Used as the default adapter
and as an interim solution while the client decides on a CRM.
Also works as a permanent adapter for n8n/Zapier/Make pipelines.
"""
from __future__ import annotations

import asyncio
from typing import Optional

import httpx
from loguru import logger

from inmobiliaria24.crm.base import CRMAdapter, Lead

MAX_RETRIES = 3
RETRY_BASE_DELAY = 2.0


class WebhookCRMAdapter(CRMAdapter):
    """Push leads to an arbitrary webhook URL."""

    def __init__(self, webhook_url: str, *, timeout: int = 30) -> None:
        if not webhook_url:
            raise ValueError("webhook_url is required for WebhookCRMAdapter")
        self._url = webhook_url
        self._timeout = timeout

    async def push_lead(self, lead: Lead) -> str:
        """POST lead data to the webhook. Returns lead_id as pseudo-CRM ID."""
        payload = lead.to_dict()
        last_err: Exception | None = None

        async with httpx.AsyncClient(timeout=self._timeout) as client:
            for attempt in range(1, MAX_RETRIES + 1):
                try:
                    resp = await client.post(self._url, json=payload)
                    resp.raise_for_status()
                    logger.info(
                        "Webhook push OK for lead {} (attempt {})",
                        lead.lead_id, attempt,
                    )
                    return lead.lead_id
                except Exception as e:
                    last_err = e
                    if attempt < MAX_RETRIES:
                        delay = RETRY_BASE_DELAY * (2 ** (attempt - 1))
                        logger.warning(
                            "Webhook push attempt {}/{} failed: {} — retry in {:.1f}s",
                            attempt, MAX_RETRIES, e, delay,
                        )
                        await asyncio.sleep(delay)

        logger.error("Webhook push failed after {} attempts: {}", MAX_RETRIES, last_err)
        raise last_err  # type: ignore[misc]

    async def update_lead(self, crm_id: str, data: dict) -> None:
        """Webhooks are fire-and-forget — re-push full payload."""
        payload = {"crm_id": crm_id, "update": data}
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.post(self._url, json=payload)
            resp.raise_for_status()

    async def check_duplicate(self, email: str, phone: str) -> Optional[str]:
        """Webhook adapter cannot check for duplicates — always returns None."""
        return None

    async def health_check(self) -> bool:
        """Check if the webhook endpoint is reachable."""
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(self._url)
                # Most webhooks return 200 or 405 on GET — both mean it's alive.
                return resp.status_code < 500
        except Exception:
            return False
