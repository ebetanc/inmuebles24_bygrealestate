"""FastAPI webhook server for WhatsApp Business API.

Receives incoming WhatsApp messages, verifies webhook signatures,
and routes them to the qualification bot.

Run with: uvicorn inmobiliaria24.server:app --host 0.0.0.0 --port 8000
"""
from __future__ import annotations

import hashlib
import hmac
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request, HTTPException, Query
from loguru import logger

from inmobiliaria24.config import Settings
from inmobiliaria24.crm import WebhookCRMAdapter
from inmobiliaria24.whatsapp.bot import BotConfig, QualificationBot
from inmobiliaria24.whatsapp.client import WhatsAppClient


# ---------------------------------------------------------------------------
# Global state — initialized at startup
# ---------------------------------------------------------------------------

_bot: QualificationBot | None = None
_settings: Settings | None = None


def _get_bot() -> QualificationBot:
    if _bot is None:
        raise RuntimeError("Bot not initialized")
    return _bot


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize bot and CRM on startup, cleanup on shutdown."""
    global _bot, _settings
    _settings = Settings.load()

    wa_client = WhatsAppClient(
        api_key=os.environ.get("WA_API_KEY", ""),
        phone_number_id=os.environ.get("WA_PHONE_NUMBER_ID", ""),
    )

    # Use webhook adapter as default — swap for HubSpot etc. when ready.
    webhook_url = _settings.webhook_url or os.environ.get("CRM_WEBHOOK_URL", "")
    crm = WebhookCRMAdapter(webhook_url) if webhook_url else None

    bot_config = BotConfig(
        agent_phone=os.environ.get("BOT_AGENT_PHONE", ""),
        agent_name=os.environ.get("BOT_AGENT_NAME", "un asesor"),
        timeout_hours=int(os.environ.get("BOT_TIMEOUT_HOURS", "24")),
        db_path=Path(os.environ.get("BOT_DB_PATH", "data/conversations.db")),
    )

    if crm:
        _bot = QualificationBot(wa_client, crm, bot_config)
        logger.info("WhatsApp bot initialized")
    else:
        logger.warning("No CRM/webhook URL configured — bot will not push to CRM")

    yield

    if _bot:
        _bot.close()


app = FastAPI(
    title="Inmobiliaria24 Webhook Server",
    version="1.0.0",
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------


@app.get("/health")
async def health():
    return {"status": "ok", "bot_active": _bot is not None}


# ---------------------------------------------------------------------------
# WhatsApp webhook — verification (GET) and messages (POST)
# ---------------------------------------------------------------------------

WA_VERIFY_TOKEN = os.environ.get("WA_WEBHOOK_VERIFY_TOKEN", "inmobiliaria24_verify")


@app.get("/webhook/whatsapp")
async def wa_verify(
    hub_mode: str = Query(None, alias="hub.mode"),
    hub_token: str = Query(None, alias="hub.verify_token"),
    hub_challenge: str = Query(None, alias="hub.challenge"),
):
    """Meta webhook verification challenge."""
    if hub_mode == "subscribe" and hub_token == WA_VERIFY_TOKEN:
        logger.info("Webhook verified")
        return int(hub_challenge) if hub_challenge else ""
    raise HTTPException(status_code=403, detail="Verification failed")


@app.post("/webhook/whatsapp")
async def wa_webhook(request: Request):
    """Receive incoming WhatsApp messages."""
    # Verify signature if secret is configured.
    wa_secret = os.environ.get("WA_WEBHOOK_SECRET", "")
    if wa_secret:
        signature = request.headers.get("x-hub-signature-256", "")
        body = await request.body()
        expected = "sha256=" + hmac.new(
            wa_secret.encode(), body, hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(signature, expected):
            raise HTTPException(status_code=403, detail="Invalid signature")

    data = await request.json()

    # Extract messages from the webhook payload.
    for entry in data.get("entry", []):
        for change in entry.get("changes", []):
            value = change.get("value", {})

            # Process incoming messages.
            for msg in value.get("messages", []):
                phone = msg.get("from", "")
                msg_type = msg.get("type", "")
                message_id = msg.get("id", "")

                # Extract text from different message types.
                text = ""
                if msg_type == "text":
                    text = msg.get("text", {}).get("body", "")
                elif msg_type == "interactive":
                    interactive = msg.get("interactive", {})
                    ir_type = interactive.get("type", "")
                    if ir_type == "button_reply":
                        text = interactive.get("button_reply", {}).get("id", "")
                    elif ir_type == "list_reply":
                        text = interactive.get("list_reply", {}).get("id", "")
                elif msg_type == "button":
                    text = msg.get("button", {}).get("payload", "")

                if text and phone:
                    bot = _get_bot()
                    try:
                        await bot.handle_message(phone, text, message_id)
                    except Exception as e:
                        logger.error("Bot error for {}: {}", phone, e)

            # Log status updates.
            for status in value.get("statuses", []):
                logger.debug(
                    "WA status: {} → {} ({})",
                    status.get("recipient_id"),
                    status.get("status"),
                    status.get("id"),
                )

    return {"status": "ok"}
