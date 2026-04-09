"""WhatsApp message template definitions.

These must be submitted to Meta for approval before use.
Template names and structures are defined here for reference
and used by the bot to send initial outreach messages.

Meta approval typically takes 24-48 hours.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class TemplateConfig:
    """Configuration for a WhatsApp message template."""
    name: str
    language: str
    body: str  # Template body text with {{1}}, {{2}} placeholders
    variables: list[str]  # Variable names in order


# ------------------------------------------------------------------
# Template definitions — submit these to Meta for approval
# ------------------------------------------------------------------

LEAD_GREETING = TemplateConfig(
    name="lead_greeting",
    language="es_MX",
    body=(
        "Hola {{1}}, gracias por tu interés en {{2}}. "
        "Soy el asistente virtual de BYG Real Estate. "
        "¿Te gustaría que te ayude con información sobre esta propiedad?"
    ),
    variables=["name", "property"],
)

QUALIFICATION_START = TemplateConfig(
    name="qualification_start",
    language="es_MX",
    body=(
        "Para conectarte con el asesor ideal, me gustaría hacerte "
        "unas preguntas rápidas. ¿Estás interesado en comprar o rentar?"
    ),
    variables=[],
)

AGENT_HANDOFF = TemplateConfig(
    name="agent_handoff",
    language="es_MX",
    body=(
        "Perfecto, {{1}}. Te comunico con {{2}}, nuestro asesor "
        "especializado que te ayudará personalmente. ¡Gracias por tu interés!"
    ),
    variables=["name", "agent_name"],
)

FOLLOW_UP = TemplateConfig(
    name="follow_up",
    language="es_MX",
    body=(
        "Hola {{1}}, ¿sigues interesado en {{2}}? "
        "Si necesitas más información, estoy aquí para ayudarte."
    ),
    variables=["name", "property"],
)


def build_template_components(template: TemplateConfig, values: dict) -> list[dict]:
    """Build the components array for sending a template via the API.

    values: {"name": "Juan", "property": "Depto en Reforma"}
    """
    parameters = []
    for var in template.variables:
        parameters.append({
            "type": "text",
            "text": values.get(var, ""),
        })

    if not parameters:
        return []

    return [{
        "type": "body",
        "parameters": parameters,
    }]
