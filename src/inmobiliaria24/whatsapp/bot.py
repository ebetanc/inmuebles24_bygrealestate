"""WhatsApp qualification bot — conversation state machine.

Handles incoming messages from leads and guides them through a
qualification flow: intent → budget → timeline → zone → handoff.

State transitions:
    NEW → GREETING_SENT → AWAITING_INTENT → AWAITING_BUDGET →
    AWAITING_TIMELINE → AWAITING_ZONE → QUALIFIED → HANDED_OFF

Side branches:
    Any step → HANDED_OFF  (if lead requests agent)
    Any step → FOLLOW_UP_SENT → COLD  (on timeout)
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from loguru import logger

from inmobiliaria24.crm.base import CRMAdapter, Lead
from inmobiliaria24.whatsapp.client import WhatsAppClient
from inmobiliaria24.whatsapp.conversation_store import (
    Conversation, ConversationStore, Step,
)
from inmobiliaria24.whatsapp.parser import (
    parse_budget, parse_intent, parse_timeline, parse_zone, wants_agent,
)
from inmobiliaria24.whatsapp.templates import (
    AGENT_HANDOFF, FOLLOW_UP, LEAD_GREETING,
    build_template_components,
)


@dataclass
class BotConfig:
    """Runtime configuration for the bot."""
    agent_phone: str = ""
    agent_name: str = "un asesor"
    business_hours_start: int = 8
    business_hours_end: int = 22
    timeout_hours: int = 24
    db_path: Path = Path("data/conversations.db")


class QualificationBot:
    """Stateful qualification bot that processes incoming WA messages."""

    def __init__(
        self,
        wa_client: WhatsAppClient,
        crm: CRMAdapter,
        config: BotConfig,
    ) -> None:
        self._wa = wa_client
        self._crm = crm
        self._config = config
        self._store = ConversationStore(config.db_path)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def start_conversation(self, lead: Lead) -> None:
        """Initiate a qualification conversation with a new lead.

        Called when the pipeline processes a new lead that has a phone number.
        """
        if not lead.phone:
            logger.warning("Cannot start WA conversation — lead {} has no phone", lead.lead_id)
            return

        existing = self._store.get(lead.phone)
        if existing and existing.step not in (Step.COLD, Step.HANDED_OFF):
            logger.info("Conversation already active for {} — skipping", lead.phone)
            return

        # Send greeting template.
        components = build_template_components(LEAD_GREETING, {
            "name": lead.name or "amigo/a",
            "property": lead.property or "la propiedad",
        })
        await self._wa.send_template(
            lead.phone, LEAD_GREETING.name,
            components=components,
        )

        conv = Conversation(
            phone=lead.phone,
            lead_id=lead.lead_id,
            step=Step.GREETING_SENT,
            name=lead.name,
            property_info=lead.property,
            crm_id=lead.crm_id,
        )
        self._store.save(conv)
        logger.info("Started qualification for lead {} ({})", lead.lead_id, lead.phone)

    async def handle_message(self, phone: str, text: str, message_id: str = "") -> None:
        """Process an incoming message from a lead.

        This is called by the webhook handler when a WA message arrives.
        """
        # Mark as read.
        if message_id:
            await self._wa.mark_as_read(message_id)

        conv = self._store.get(phone)
        if not conv:
            logger.info("No active conversation for {} — ignoring", phone)
            return

        # Check if already handed off — bot should not respond.
        if conv.step in (Step.HANDED_OFF, Step.QUALIFIED, Step.COLD):
            logger.debug("Conversation {} is {} — bot silent", phone, conv.step.value)
            return

        # Check if lead wants a human.
        if wants_agent(text):
            await self._handoff(conv)
            return

        conv.last_message_at = text

        # Route to current step handler.
        handlers = {
            Step.GREETING_SENT: self._handle_greeting_reply,
            Step.AWAITING_INTENT: self._handle_intent,
            Step.AWAITING_BUDGET: self._handle_budget,
            Step.AWAITING_TIMELINE: self._handle_timeline,
            Step.AWAITING_ZONE: self._handle_zone,
            Step.FOLLOW_UP_SENT: self._handle_greeting_reply,  # re-enter flow
        }

        handler = handlers.get(conv.step)
        if handler:
            await handler(conv, text)
        else:
            logger.warning("No handler for step {} (phone={})", conv.step, phone)

    async def process_timeouts(self) -> int:
        """Check for stale conversations and send follow-ups or mark as cold.

        Returns number of conversations processed.
        """
        stale = self._store.get_stale(self._config.timeout_hours)
        count = 0

        for conv in stale:
            if conv.follow_up_count == 0:
                # First timeout — send follow-up.
                components = build_template_components(FOLLOW_UP, {
                    "name": conv.name or "amigo/a",
                    "property": conv.property_info or "la propiedad",
                })
                try:
                    await self._wa.send_template(
                        conv.phone, FOLLOW_UP.name,
                        components=components,
                    )
                    conv.step = Step.FOLLOW_UP_SENT
                    conv.follow_up_count = 1
                    self._store.save(conv)
                    count += 1
                    logger.info("Follow-up sent to {}", conv.phone)
                except Exception as e:
                    logger.error("Failed to send follow-up to {}: {}", conv.phone, e)
            else:
                # Already followed up — mark as cold.
                conv.step = Step.COLD
                self._store.save(conv)
                # Update CRM.
                if conv.crm_id:
                    try:
                        await self._crm.update_lead(
                            conv.crm_id, {"hs_lead_status": "COLD", "lead_qualification_status": "cold"}
                        )
                    except Exception as e:
                        logger.error("Failed to update CRM for cold lead {}: {}", conv.lead_id, e)
                count += 1
                logger.info("Marked {} as cold", conv.phone)

        return count

    # ------------------------------------------------------------------
    # Step handlers
    # ------------------------------------------------------------------

    async def _handle_greeting_reply(self, conv: Conversation, text: str) -> None:
        """Lead responded to greeting — ask for intent."""
        conv.step = Step.AWAITING_INTENT
        self._store.save(conv)

        await self._wa.send_interactive_buttons(
            conv.phone,
            "Para atenderte mejor, ¿estás interesado en comprar o rentar?",
            [
                {"id": "btn_comprar", "title": "Comprar"},
                {"id": "btn_rentar", "title": "Rentar"},
            ],
        )

    async def _handle_intent(self, conv: Conversation, text: str) -> None:
        """Parse buy/rent intent."""
        intent = parse_intent(text)
        if not intent:
            await self._wa.send_text(
                conv.phone,
                "No entendí tu respuesta. ¿Buscas comprar o rentar?",
            )
            return

        conv.intent = intent
        conv.step = Step.AWAITING_BUDGET
        self._store.save(conv)

        await self._wa.send_text(
            conv.phone,
            "¿Cuál es tu presupuesto aproximado? "
            "(Ejemplo: 2 millones, 500 mil, $1.5M)",
        )

    async def _handle_budget(self, conv: Conversation, text: str) -> None:
        """Parse budget."""
        budget = parse_budget(text)
        if not budget:
            await self._wa.send_text(
                conv.phone,
                "No logré entender el monto. ¿Podrías indicarme tu presupuesto "
                "en números? (Ejemplo: 2 millones, 500 mil)",
            )
            return

        conv.budget = budget
        conv.step = Step.AWAITING_TIMELINE
        self._store.save(conv)

        await self._wa.send_interactive_buttons(
            conv.phone,
            "¿En qué periodo estás buscando?",
            [
                {"id": "btn_inmediato", "title": "Inmediato"},
                {"id": "btn_1_3", "title": "1-3 meses"},
                {"id": "btn_3_6", "title": "3-6 meses"},
            ],
            footer="También puedes escribir tu respuesta",
        )

    async def _handle_timeline(self, conv: Conversation, text: str) -> None:
        """Parse timeline."""
        timeline = parse_timeline(text)
        if not timeline:
            await self._wa.send_text(
                conv.phone,
                "¿Podrías indicarme tu plazo? Ejemplo: inmediato, 3 meses, solo explorando.",
            )
            return

        conv.timeline = timeline
        conv.step = Step.AWAITING_ZONE
        self._store.save(conv)

        await self._wa.send_text(
            conv.phone,
            "¿Qué zona o colonia prefieres?",
        )

    async def _handle_zone(self, conv: Conversation, text: str) -> None:
        """Parse zone and complete qualification."""
        zone = parse_zone(text)
        if not zone or len(zone) < 2:
            await self._wa.send_text(
                conv.phone,
                "¿Podrías indicarme la zona o colonia que te interesa?",
            )
            return

        conv.zone = zone
        conv.step = Step.QUALIFIED
        self._store.save(conv)

        # Update CRM with qualification data.
        if conv.crm_id:
            try:
                await self._crm.update_lead(conv.crm_id, {
                    "lead_intent": conv.intent,
                    "lead_budget": conv.budget,
                    "lead_timeline": conv.timeline,
                    "lead_zone": conv.zone,
                    "hs_lead_status": "QUALIFIED",
                })
            except Exception as e:
                logger.error("Failed to update CRM with qualification: {}", e)

        # Hand off to agent.
        await self._handoff(conv)

    # ------------------------------------------------------------------
    # Handoff
    # ------------------------------------------------------------------

    async def _handoff(self, conv: Conversation) -> None:
        """Notify the agent and tell the lead they're being connected."""
        agent_name = self._config.agent_name

        # Send handoff message to lead.
        components = build_template_components(AGENT_HANDOFF, {
            "name": conv.name or "amigo/a",
            "agent_name": agent_name,
        })
        try:
            await self._wa.send_template(
                conv.phone, AGENT_HANDOFF.name,
                components=components,
            )
        except Exception as e:
            # Fall back to free-form if template not approved yet.
            logger.warning("Template send failed, using free-form: {}", e)
            await self._wa.send_text(
                conv.phone,
                f"Perfecto, te comunico con {agent_name}. ¡Gracias por tu interés!",
            )

        # Notify agent via WhatsApp.
        if self._config.agent_phone:
            summary = self._build_agent_summary(conv)
            try:
                await self._wa.send_text(self._config.agent_phone, summary)
            except Exception as e:
                logger.error("Failed to notify agent: {}", e)

        conv.step = Step.HANDED_OFF
        self._store.save(conv)
        logger.info(
            "Lead {} handed off to agent (qualified={})",
            conv.lead_id, conv.step == Step.QUALIFIED,
        )

    def _build_agent_summary(self, conv: Conversation) -> str:
        """Build a summary message for the agent."""
        lines = [
            f"*Nuevo lead calificado*",
            f"Nombre: {conv.name}",
            f"Teléfono: {conv.phone}",
            f"Propiedad: {conv.property_info}",
        ]
        if conv.intent:
            lines.append(f"Interés: {conv.intent}")
        if conv.budget:
            lines.append(f"Presupuesto: ${conv.budget}")
        if conv.timeline:
            lines.append(f"Plazo: {conv.timeline}")
        if conv.zone:
            lines.append(f"Zona: {conv.zone}")
        if conv.crm_id:
            lines.append(f"CRM ID: {conv.crm_id}")

        return "\n".join(lines)

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    def close(self) -> None:
        self._store.close()
