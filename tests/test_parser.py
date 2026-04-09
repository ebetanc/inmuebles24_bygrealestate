"""Tests for the WhatsApp NL parser."""
from inmobiliaria24.whatsapp.parser import (
    parse_budget, parse_intent, parse_timeline, parse_zone, wants_agent,
)


# --- Intent ---

def test_intent_comprar():
    assert parse_intent("quiero comprar") == "comprar"
    assert parse_intent("Compra") == "comprar"
    assert parse_intent("btn_comprar") == "comprar"

def test_intent_rentar():
    assert parse_intent("me interesa rentar") == "rentar"
    assert parse_intent("Renta") == "rentar"
    assert parse_intent("alquilar un depto") == "rentar"

def test_intent_unknown():
    assert parse_intent("hola que tal") is None


# --- Budget ---

def test_budget_millions():
    assert parse_budget("2 millones") == "2,000,000"
    assert parse_budget("$2M") == "2,000,000"
    assert parse_budget("1.5 millones") == "1,500,000"

def test_budget_thousands():
    assert parse_budget("500 mil") == "500,000"
    assert parse_budget("500k") == "500,000"

def test_budget_raw_number():
    assert parse_budget("2,500,000") == "2,500,000"

def test_budget_range():
    result = parse_budget("entre 1 y 2 millones")
    assert "1,000,000" in result
    assert "2,000,000" in result

def test_budget_unknown():
    assert parse_budget("no sé todavía") is None


# --- Timeline ---

def test_timeline_immediate():
    assert parse_timeline("ahora") == "inmediato"
    assert parse_timeline("ya") == "inmediato"
    assert parse_timeline("btn_inmediato") == "inmediato"

def test_timeline_short():
    assert parse_timeline("en 2 meses") == "1-3 meses"
    assert parse_timeline("btn_1_3") == "1-3 meses"

def test_timeline_medium():
    assert parse_timeline("6 meses") == "3-6 meses"

def test_timeline_exploring():
    assert parse_timeline("solo estoy explorando") == "explorando"

def test_timeline_unknown():
    assert parse_timeline("hola") is None


# --- Zone ---

def test_zone_cleanup():
    assert parse_zone("en Polanco") == "Polanco"
    assert parse_zone("colonia Roma Norte") == "Roma Norte"
    assert parse_zone("Reforma") == "Reforma"


# --- Agent detection ---

def test_wants_agent():
    assert wants_agent("quiero hablar con un asesor") is True
    assert wants_agent("pásame con alguien") is True
    assert wants_agent("hola") is False
