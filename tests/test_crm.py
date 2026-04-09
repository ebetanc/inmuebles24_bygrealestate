"""Tests for CRM adapter layer."""
import pytest
from inmobiliaria24.crm.base import Lead


def test_lead_from_scraped():
    raw = {
        "lead_id": "123",
        "name": "Juan Pérez",
        "email": "juan@test.com",
        "phone": "5551234567",
        "message": "Me interesa",
        "listing_id": "L100",
        "property": "Depto en Reforma",
        "address": "Av. Reforma 123",
        "price": "MN 2,500,000",
        "listing_type": "venta",
        "status": "Pendiente",
        "source_tab": "mensajes",
        "time": "14:30",
    }
    lead = Lead.from_scraped(raw)
    assert lead.lead_id == "123"
    assert lead.name == "Juan Pérez"
    assert lead.email == "juan@test.com"
    assert lead.qualified is False
    assert lead.crm_pushed is False


def test_lead_to_dict():
    lead = Lead(lead_id="1", name="Test")
    d = lead.to_dict()
    assert d["lead_id"] == "1"
    assert "scraped_at" in d


def test_lead_from_scraped_with_preview():
    """message_preview should map to message field."""
    raw = {"lead_id": "5", "message_preview": "Hola, me interesa"}
    lead = Lead.from_scraped(raw)
    assert lead.message == "Hola, me interesa"
