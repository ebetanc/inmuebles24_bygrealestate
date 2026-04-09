"""WhatsApp Business API client.

Wraps the WhatsApp Cloud API (via BSP like 360dialog or direct Meta).
Handles sending template messages, free-form messages within the 24h
window, and media messages.
"""
from __future__ import annotations

from dataclasses import dataclass

import httpx
from loguru import logger


@dataclass
class MessageStatus:
    """Tracks delivery status of a sent message."""
    message_id: str
    status: str  # sent / delivered / read / failed
    phone: str
    timestamp: str = ""


class WhatsAppClient:
    """Client for the WhatsApp Business API."""

    def __init__(
        self,
        api_key: str,
        phone_number_id: str,
        *,
        api_base: str = "https://graph.facebook.com/v21.0",
        timeout: int = 30,
    ) -> None:
        self._api_key = api_key
        self._phone_number_id = phone_number_id
        self._api_base = api_base
        self._timeout = timeout
        self._headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }

    @property
    def _messages_url(self) -> str:
        return f"{self._api_base}/{self._phone_number_id}/messages"

    async def send_template(
        self,
        to: str,
        template_name: str,
        language: str = "es_MX",
        components: list[dict] | None = None,
    ) -> str:
        """Send an approved template message. Returns message ID."""
        payload: dict = {
            "messaging_product": "whatsapp",
            "to": to,
            "type": "template",
            "template": {
                "name": template_name,
                "language": {"code": language},
            },
        }
        if components:
            payload["template"]["components"] = components

        return await self._send(payload, to)

    async def send_text(self, to: str, text: str) -> str:
        """Send a free-form text message (only within 24h conversation window).

        Returns message ID.
        """
        payload = {
            "messaging_product": "whatsapp",
            "to": to,
            "type": "text",
            "text": {"body": text},
        }
        return await self._send(payload, to)

    async def send_interactive_buttons(
        self,
        to: str,
        body_text: str,
        buttons: list[dict],
        header: str = "",
        footer: str = "",
    ) -> str:
        """Send an interactive message with reply buttons (max 3).

        Each button: {"id": "btn_1", "title": "Option 1"}
        """
        action_buttons = [
            {"type": "reply", "reply": {"id": b["id"], "title": b["title"]}}
            for b in buttons[:3]
        ]
        payload: dict = {
            "messaging_product": "whatsapp",
            "to": to,
            "type": "interactive",
            "interactive": {
                "type": "button",
                "body": {"text": body_text},
                "action": {"buttons": action_buttons},
            },
        }
        if header:
            payload["interactive"]["header"] = {"type": "text", "text": header}
        if footer:
            payload["interactive"]["footer"] = {"text": footer}

        return await self._send(payload, to)

    async def send_interactive_list(
        self,
        to: str,
        body_text: str,
        button_text: str,
        sections: list[dict],
        header: str = "",
        footer: str = "",
    ) -> str:
        """Send an interactive list message.

        sections: [{"title": "Section", "rows": [{"id": "1", "title": "Row 1"}]}]
        """
        payload: dict = {
            "messaging_product": "whatsapp",
            "to": to,
            "type": "interactive",
            "interactive": {
                "type": "list",
                "body": {"text": body_text},
                "action": {
                    "button": button_text,
                    "sections": sections,
                },
            },
        }
        if header:
            payload["interactive"]["header"] = {"type": "text", "text": header}
        if footer:
            payload["interactive"]["footer"] = {"text": footer}

        return await self._send(payload, to)

    async def mark_as_read(self, message_id: str) -> None:
        """Mark an incoming message as read."""
        payload = {
            "messaging_product": "whatsapp",
            "status": "read",
            "message_id": message_id,
        }
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            await client.post(self._messages_url, headers=self._headers, json=payload)

    async def _send(self, payload: dict, to: str) -> str:
        """Send a message and return the WA message ID."""
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.post(
                self._messages_url, headers=self._headers, json=payload,
            )
            resp.raise_for_status()
            data = resp.json()
            msg_id = data.get("messages", [{}])[0].get("id", "")
            logger.info("WA message sent to {}: id={}", to, msg_id)
            return msg_id
