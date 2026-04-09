"""End-to-end tests for the WhatsApp qualification bot.

Simulates complete conversations through the bot state machine
with a mocked WhatsApp client (no real API calls).
"""
from __future__ import annotations

from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Optional
from unittest.mock import AsyncMock, MagicMock

import pytest

from inmobiliaria24.crm.base import CRMAdapter, Lead
from inmobiliaria24.whatsapp.bot import BotConfig, QualificationBot
from inmobiliaria24.whatsapp.conversation_store import (
    Conversation, ConversationStore, Step,
)


# ------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------

class FakeCRM(CRMAdapter):
    """In-memory CRM for testing."""

    def __init__(self) -> None:
        self.leads: dict[str, dict] = {}
        self.updates: list[tuple[str, dict]] = []

    async def push_lead(self, lead: Lead) -> str:
        crm_id = f"crm_{lead.lead_id}"
        self.leads[crm_id] = lead.to_dict()
        return crm_id

    async def update_lead(self, crm_id: str, data: dict) -> None:
        self.updates.append((crm_id, data))

    async def check_duplicate(self, email: str, phone: str) -> Optional[str]:
        return None

    async def health_check(self) -> bool:
        return True


@pytest.fixture()
def wa_client() -> AsyncMock:
    """Mock WhatsApp client that records calls without making real API requests."""
    client = AsyncMock()
    client.send_template.return_value = "wamid_template_001"
    client.send_text.return_value = "wamid_text_001"
    client.send_interactive_buttons.return_value = "wamid_btn_001"
    client.mark_as_read.return_value = None
    return client


@pytest.fixture()
def crm() -> FakeCRM:
    return FakeCRM()


@pytest.fixture()
def bot(tmp_path: Path, wa_client: AsyncMock, crm: FakeCRM) -> QualificationBot:
    config = BotConfig(
        agent_phone="5550001111",
        agent_name="Carlos",
        db_path=tmp_path / "test_conv.db",
    )
    b = QualificationBot(wa_client, crm, config)
    yield b
    b.close()


def _make_lead(**overrides) -> Lead:
    defaults = dict(
        lead_id="lead_1",
        name="María López",
        phone="5551234567",
        property="Depto en Reforma 222",
        crm_id="crm_lead_1",
    )
    defaults.update(overrides)
    return Lead(**defaults)


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

def _get_conv(bot: QualificationBot, phone: str) -> Conversation:
    """Read conversation state from the bot's internal store."""
    return bot._store.get(phone)


# ------------------------------------------------------------------
# 1. Happy path: comprar flow
# ------------------------------------------------------------------

@pytest.mark.asyncio
async def test_happy_path_comprar(bot: QualificationBot, wa_client: AsyncMock, crm: FakeCRM):
    """Full qualification: greeting -> intent(comprar) -> budget(2M) ->
    timeline(inmediato) -> zone(Polanco) -> qualified -> agent handoff.
    """
    lead = _make_lead()

    # Step 1: Start conversation (sends greeting template)
    await bot.start_conversation(lead)

    wa_client.send_template.assert_called_once()
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.GREETING_SENT

    # Step 2: Lead replies to greeting -> bot asks intent
    await bot.handle_message(lead.phone, "Sí, me interesa", "msg_001")

    wa_client.mark_as_read.assert_called_with("msg_001")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_INTENT
    wa_client.send_interactive_buttons.assert_called_once()

    # Step 3: Lead says "comprar" -> bot asks budget
    await bot.handle_message(lead.phone, "comprar", "msg_002")

    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_BUDGET
    assert conv.intent == "comprar"

    # Step 4: Lead gives budget "2 millones" -> bot asks timeline
    await bot.handle_message(lead.phone, "2 millones", "msg_003")

    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_TIMELINE
    assert conv.budget == "2,000,000"

    # Step 5: Lead says "inmediato" -> bot asks zone
    await bot.handle_message(lead.phone, "inmediato", "msg_004")

    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_ZONE
    assert conv.timeline == "inmediato"

    # Step 6: Lead says "Polanco" -> qualified + handoff
    await bot.handle_message(lead.phone, "Polanco", "msg_005")

    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.HANDED_OFF
    assert conv.zone == "Polanco"

    # CRM should have been updated with qualification data
    assert len(crm.updates) > 0
    qual_update = crm.updates[0]
    assert qual_update[0] == "crm_lead_1"
    assert qual_update[1]["lead_intent"] == "comprar"
    assert qual_update[1]["lead_budget"] == "2,000,000"
    assert qual_update[1]["lead_zone"] == "Polanco"
    assert qual_update[1]["hs_lead_status"] == "QUALIFIED"

    # Agent should have been notified
    agent_texts = [
        call for call in wa_client.send_text.call_args_list
        if call[0][0] == "5550001111"
    ]
    assert len(agent_texts) == 1
    summary = agent_texts[0][0][1]
    assert "María López" in summary
    assert "Polanco" in summary


# ------------------------------------------------------------------
# 2. Rental path with different budget format
# ------------------------------------------------------------------

@pytest.mark.asyncio
async def test_rental_path_different_budget(bot: QualificationBot, wa_client: AsyncMock, crm: FakeCRM):
    """Rental flow with budget in 'mil' format."""
    lead = _make_lead(lead_id="lead_2", phone="5559876543", name="Juan Pérez")
    await bot.start_conversation(lead)

    # Reply to greeting
    await bot.handle_message(lead.phone, "Hola, sí")

    # Intent: rentar
    await bot.handle_message(lead.phone, "me interesa rentar")
    conv = _get_conv(bot, lead.phone)
    assert conv.intent == "rentar"
    assert conv.step == Step.AWAITING_BUDGET

    # Budget: 30 mil (rental budget)
    await bot.handle_message(lead.phone, "30 mil")
    conv = _get_conv(bot, lead.phone)
    assert conv.budget == "30,000"
    assert conv.step == Step.AWAITING_TIMELINE

    # Timeline: 1-3 meses
    await bot.handle_message(lead.phone, "en 2 meses")
    conv = _get_conv(bot, lead.phone)
    assert conv.timeline == "1-3 meses"
    assert conv.step == Step.AWAITING_ZONE

    # Zone
    await bot.handle_message(lead.phone, "colonia Roma Norte")
    conv = _get_conv(bot, lead.phone)
    assert conv.zone == "Roma Norte"
    assert conv.step == Step.HANDED_OFF


# ------------------------------------------------------------------
# 3. Off-script handling: gibberish -> re-prompt -> correct answer
# ------------------------------------------------------------------

@pytest.mark.asyncio
async def test_off_script_reprompt(bot: QualificationBot, wa_client: AsyncMock):
    """Bot re-prompts when it cannot parse, then continues on valid input."""
    lead = _make_lead(lead_id="lead_3", phone="5550003333")
    await bot.start_conversation(lead)

    # Reply to greeting to advance to AWAITING_INTENT
    await bot.handle_message(lead.phone, "ok")

    # Gibberish at intent step
    await bot.handle_message(lead.phone, "asdkjhasd lkjahsd")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_INTENT  # still at same step
    # Bot should have sent a re-prompt text
    wa_client.send_text.assert_called()
    last_text = wa_client.send_text.call_args[0][1]
    assert "comprar" in last_text.lower() or "rentar" in last_text.lower()

    # Now user answers correctly
    await bot.handle_message(lead.phone, "comprar")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_BUDGET
    assert conv.intent == "comprar"

    # Gibberish at budget step
    await bot.handle_message(lead.phone, "no sé todavía")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_BUDGET  # still waiting

    # Correct budget
    await bot.handle_message(lead.phone, "$1.5M")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_TIMELINE
    assert conv.budget == "1,500,000"

    # Gibberish at timeline step
    await bot.handle_message(lead.phone, "blah blah")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_TIMELINE  # still waiting

    # Correct timeline
    await bot.handle_message(lead.phone, "ya, lo antes posible")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_ZONE
    assert conv.timeline == "inmediato"

    # Very short zone (less than 2 chars) triggers re-prompt
    await bot.handle_message(lead.phone, "X")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_ZONE  # still waiting

    # Correct zone
    await bot.handle_message(lead.phone, "Santa Fe")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.HANDED_OFF
    assert conv.zone == "Santa Fe"


# ------------------------------------------------------------------
# 4. Agent request mid-flow
# ------------------------------------------------------------------

@pytest.mark.asyncio
async def test_agent_request_mid_flow(bot: QualificationBot, wa_client: AsyncMock):
    """User says 'quiero hablar con alguien' mid-flow -> immediate handoff."""
    lead = _make_lead(lead_id="lead_4", phone="5550004444")
    await bot.start_conversation(lead)

    # Reply to greeting
    await bot.handle_message(lead.phone, "sí")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_INTENT

    # User requests agent instead of answering
    await bot.handle_message(lead.phone, "quiero hablar con alguien")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.HANDED_OFF

    # Handoff template or text should have been sent to lead
    # Agent should have been notified
    agent_texts = [
        call for call in wa_client.send_text.call_args_list
        if call[0][0] == "5550001111"
    ]
    assert len(agent_texts) == 1


@pytest.mark.asyncio
async def test_agent_request_at_budget_step(bot: QualificationBot, wa_client: AsyncMock):
    """User requests agent at budget step -> immediate handoff."""
    lead = _make_lead(lead_id="lead_5", phone="5550005555")
    await bot.start_conversation(lead)
    await bot.handle_message(lead.phone, "ok")
    await bot.handle_message(lead.phone, "comprar")

    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_BUDGET

    await bot.handle_message(lead.phone, "pásame con un asesor")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.HANDED_OFF


# ------------------------------------------------------------------
# 5. Timeout flow
# ------------------------------------------------------------------

@pytest.mark.asyncio
async def test_timeout_followup_then_cold(bot: QualificationBot, wa_client: AsyncMock, crm: FakeCRM):
    """Simulate 24h timeout -> follow-up sent -> second timeout -> marked cold."""
    lead = _make_lead(lead_id="lead_6", phone="5550006666")
    await bot.start_conversation(lead)
    await bot.handle_message(lead.phone, "ok")

    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_INTENT

    # Simulate that the conversation is old (set updated_at to >24h ago)
    conv_raw = bot._store.get(lead.phone)
    old_time = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
    conv_raw.updated_at = old_time
    bot._store.save(conv_raw)
    # Force updated_at back to old time after save (save updates it)
    bot._store._conn.execute(
        "UPDATE conversations SET updated_at = ? WHERE phone = ?",
        (old_time, lead.phone),
    )
    bot._store._conn.commit()

    # First timeout -> follow-up sent
    wa_client.send_template.reset_mock()
    count = await bot.process_timeouts()
    assert count == 1

    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.FOLLOW_UP_SENT
    assert conv.follow_up_count == 1
    wa_client.send_template.assert_called_once()

    # Simulate second timeout (set updated_at to >24h ago again)
    old_time2 = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
    bot._store._conn.execute(
        "UPDATE conversations SET updated_at = ? WHERE phone = ?",
        (old_time2, lead.phone),
    )
    bot._store._conn.commit()

    # Second timeout -> marked cold
    count = await bot.process_timeouts()
    assert count == 1

    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.COLD

    # CRM should have been updated with cold status
    cold_updates = [u for u in crm.updates if u[1].get("hs_lead_status") == "COLD"]
    assert len(cold_updates) == 1


@pytest.mark.asyncio
async def test_followup_reply_reenters_flow(bot: QualificationBot, wa_client: AsyncMock):
    """After follow-up, lead replies and re-enters qualification flow."""
    lead = _make_lead(lead_id="lead_7", phone="5550007777")
    await bot.start_conversation(lead)
    await bot.handle_message(lead.phone, "ok")

    # Manually set to FOLLOW_UP_SENT to simulate timeout path
    conv = _get_conv(bot, lead.phone)
    conv.step = Step.FOLLOW_UP_SENT
    conv.follow_up_count = 1
    bot._store.save(conv)

    # Lead replies to follow-up -> re-enters at AWAITING_INTENT
    await bot.handle_message(lead.phone, "sí, aún me interesa")
    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.AWAITING_INTENT


# ------------------------------------------------------------------
# 6. Button reply handling
# ------------------------------------------------------------------

@pytest.mark.asyncio
async def test_button_reply_intent(bot: QualificationBot, wa_client: AsyncMock):
    """User replies via interactive button IDs instead of free text."""
    lead = _make_lead(lead_id="lead_8", phone="5550008888")
    await bot.start_conversation(lead)
    await bot.handle_message(lead.phone, "ok")

    # Button reply for intent
    await bot.handle_message(lead.phone, "btn_comprar")
    conv = _get_conv(bot, lead.phone)
    assert conv.intent == "comprar"
    assert conv.step == Step.AWAITING_BUDGET


@pytest.mark.asyncio
async def test_button_reply_full_flow(bot: QualificationBot, wa_client: AsyncMock):
    """Complete flow using button reply IDs for intent and timeline."""
    lead = _make_lead(lead_id="lead_9", phone="5550009999")
    await bot.start_conversation(lead)

    # Greeting reply
    await bot.handle_message(lead.phone, "Sí")

    # Intent via button
    await bot.handle_message(lead.phone, "btn_rentar")
    conv = _get_conv(bot, lead.phone)
    assert conv.intent == "rentar"
    assert conv.step == Step.AWAITING_BUDGET

    # Budget as text
    await bot.handle_message(lead.phone, "500k")
    conv = _get_conv(bot, lead.phone)
    assert conv.budget == "500,000"

    # Timeline via button
    await bot.handle_message(lead.phone, "btn_3_6")
    conv = _get_conv(bot, lead.phone)
    assert conv.timeline == "3-6 meses"
    assert conv.step == Step.AWAITING_ZONE

    # Zone as text
    await bot.handle_message(lead.phone, "por Condesa")
    conv = _get_conv(bot, lead.phone)
    assert conv.zone == "Condesa"
    assert conv.step == Step.HANDED_OFF


# ------------------------------------------------------------------
# Edge cases
# ------------------------------------------------------------------

@pytest.mark.asyncio
async def test_message_after_handoff_ignored(bot: QualificationBot, wa_client: AsyncMock):
    """Messages after handoff should be silently ignored (bot is silent)."""
    lead = _make_lead(lead_id="lead_10", phone="5550101010")
    await bot.start_conversation(lead)
    await bot.handle_message(lead.phone, "ok")
    await bot.handle_message(lead.phone, "quiero hablar con un asesor")

    conv = _get_conv(bot, lead.phone)
    assert conv.step == Step.HANDED_OFF

    # Reset mock to verify no new messages are sent
    wa_client.reset_mock()
    await bot.handle_message(lead.phone, "hola, siguen ahí?")

    wa_client.send_text.assert_not_called()
    wa_client.send_template.assert_not_called()
    wa_client.send_interactive_buttons.assert_not_called()


@pytest.mark.asyncio
async def test_no_phone_skips(bot: QualificationBot, wa_client: AsyncMock):
    """Lead without phone number should not start a conversation."""
    lead = _make_lead(phone="")
    await bot.start_conversation(lead)

    wa_client.send_template.assert_not_called()


@pytest.mark.asyncio
async def test_unknown_phone_ignored(bot: QualificationBot, wa_client: AsyncMock):
    """Message from unknown phone should be ignored."""
    wa_client.reset_mock()
    await bot.handle_message("9999999999", "hola")

    wa_client.send_text.assert_not_called()
    wa_client.send_template.assert_not_called()


@pytest.mark.asyncio
async def test_duplicate_start_skipped(bot: QualificationBot, wa_client: AsyncMock):
    """Starting conversation for an already-active lead should be skipped."""
    lead = _make_lead()
    await bot.start_conversation(lead)
    wa_client.send_template.reset_mock()

    # Try starting again — should be skipped
    await bot.start_conversation(lead)
    wa_client.send_template.assert_not_called()
