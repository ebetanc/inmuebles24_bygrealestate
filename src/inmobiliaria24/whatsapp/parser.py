"""Natural language parser for WhatsApp bot responses.

Handles free-text responses in Spanish for budget, timeline, intent,
and zone extraction. Designed for Mexican Spanish conventions.
"""
from __future__ import annotations

import re


# ------------------------------------------------------------------
# Intent: comprar / rentar
# ------------------------------------------------------------------

_BUY_KEYWORDS = {"comprar", "compra", "venta", "adquirir", "compro", "buy"}
_RENT_KEYWORDS = {"rentar", "renta", "alquilar", "alquiler", "arrendar", "rent"}


def parse_intent(text: str) -> str | None:
    """Parse buy/rent intent from free text.

    Returns 'comprar', 'rentar', or None if unrecognized.
    """
    lower = text.lower().strip()
    for kw in _BUY_KEYWORDS:
        if kw in lower:
            return "comprar"
    for kw in _RENT_KEYWORDS:
        if kw in lower:
            return "rentar"
    # Check for button reply IDs.
    if lower in ("comprar", "btn_comprar", "1"):
        return "comprar"
    if lower in ("rentar", "btn_rentar", "2"):
        return "rentar"
    return None


# ------------------------------------------------------------------
# Budget
# ------------------------------------------------------------------

_MULTIPLIERS = {
    "mil": 1_000,
    "k": 1_000,
    "millon": 1_000_000,
    "millones": 1_000_000,
    "millón": 1_000_000,
    "m": 1_000_000,
    "mdp": 1_000_000,
}


def parse_budget(text: str) -> str | None:
    """Parse budget from free text.

    Examples:
        "2 millones" → "2,000,000"
        "$2M" → "2,000,000"
        "como 500 mil" → "500,000"
        "2,500,000" → "2,500,000"
        "entre 1 y 2 millones" → "1,000,000 - 2,000,000"

    Returns formatted string or None if unparseable.
    """
    lower = text.lower().strip().replace("$", "").replace("mn", "").strip()

    # Range: "entre X y Y"
    range_match = re.search(
        r"entre\s+([\d.,]+)\s*(\w*)\s*y\s*([\d.,]+)\s*(\w*)", lower
    )
    if range_match:
        lo = _parse_number(range_match.group(1), range_match.group(2))
        hi = _parse_number(range_match.group(3), range_match.group(4))
        if lo and hi:
            return f"{lo:,.0f} - {hi:,.0f}"

    # Single number with optional multiplier.
    num_match = re.search(r"([\d.,]+)\s*(\w*)", lower)
    if num_match:
        val = _parse_number(num_match.group(1), num_match.group(2))
        if val:
            return f"{val:,.0f}"

    return None


def _parse_number(num_str: str, unit: str) -> float | None:
    """Parse a numeric string with optional unit multiplier."""
    clean = num_str.replace(",", "").replace(" ", "")
    try:
        value = float(clean)
    except ValueError:
        return None

    unit = unit.strip().lower().rstrip("es").rstrip(".")
    if unit in _MULTIPLIERS:
        value *= _MULTIPLIERS[unit]
    elif value < 100:
        # Assume "2" means "2 million" in Mexican real estate context.
        value *= 1_000_000

    return value


# ------------------------------------------------------------------
# Timeline
# ------------------------------------------------------------------

_IMMEDIATE = {"ahora", "ya", "inmediato", "inmediata", "urgente", "hoy", "cuanto antes", "lo antes posible"}
_SHORT = {"1 mes", "un mes", "2 meses", "dos meses", "3 meses", "tres meses", "próximo mes", "proximo mes"}
_MEDIUM = {"4 meses", "5 meses", "6 meses", "medio año", "medio ano", "semestre"}
_EXPLORING = {"explorando", "viendo", "solo veo", "no tengo prisa", "sin prisa", "no sé", "no se"}


def parse_timeline(text: str) -> str | None:
    """Parse timeline from free text.

    Returns one of: 'inmediato', '1-3 meses', '3-6 meses', 'explorando', or None.
    """
    lower = text.lower().strip()

    # Button reply IDs.
    if lower in ("btn_inmediato", "1", "inmediato"):
        return "inmediato"
    if lower in ("btn_1_3", "2"):
        return "1-3 meses"
    if lower in ("btn_3_6", "3"):
        return "3-6 meses"
    if lower in ("btn_explorando", "4", "explorando"):
        return "explorando"

    for kw in _IMMEDIATE:
        if kw in lower:
            return "inmediato"
    for kw in _SHORT:
        if kw in lower:
            return "1-3 meses"
    for kw in _MEDIUM:
        if kw in lower:
            return "3-6 meses"
    for kw in _EXPLORING:
        if kw in lower:
            return "explorando"

    # Try extracting a number of months.
    month_match = re.search(r"(\d+)\s*mes", lower)
    if month_match:
        months = int(month_match.group(1))
        if months <= 1:
            return "inmediato"
        elif months <= 3:
            return "1-3 meses"
        elif months <= 6:
            return "3-6 meses"
        else:
            return "explorando"

    return None


# ------------------------------------------------------------------
# Zone (pass-through — just clean up)
# ------------------------------------------------------------------

def parse_zone(text: str) -> str:
    """Extract zone preference. Mostly pass-through since zones are free-form."""
    cleaned = text.strip()
    # Remove common filler.
    for prefix in ("en ", "por ", "zona ", "colonia ", "col "):
        if cleaned.lower().startswith(prefix):
            cleaned = cleaned[len(prefix):]
            break
    return cleaned.strip().title()


# ------------------------------------------------------------------
# Agent request detection
# ------------------------------------------------------------------

_AGENT_KEYWORDS = {
    "hablar con alguien", "hablar con un asesor", "hablar con una persona",
    "agente", "asesor", "humano", "persona real", "quiero hablar",
    "comunícame", "comunicame", "pásame", "pasame",
}


def wants_agent(text: str) -> bool:
    """Detect if the user wants to talk to a human agent."""
    lower = text.lower().strip()
    return any(kw in lower for kw in _AGENT_KEYWORDS)
