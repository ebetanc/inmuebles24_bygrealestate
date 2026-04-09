"""Abstract CRM adapter and Lead data model.

All CRM integrations implement the CRMAdapter interface. This allows
swapping between webhook, HubSpot, Salesforce, etc. without changing
the pipeline logic.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Optional


@dataclass
class Lead:
    """Normalized lead record used across the pipeline."""

    lead_id: str
    name: str = ""
    email: str = ""
    phone: str = ""
    message: str = ""
    listing_id: str = ""
    property: str = ""
    address: str = ""
    price: str = ""
    listing_type: str = ""  # venta / renta
    status: str = ""        # Pendiente / Contactado
    source_tab: str = ""    # mensajes / telefono / whatsapp
    time: str = ""
    scraped_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    # Qualification data (filled by WhatsApp bot)
    budget: str = ""
    timeline: str = ""
    zone: str = ""
    qualified: bool = False

    # CRM tracking
    crm_id: str = ""
    crm_pushed: bool = False

    @classmethod
    def from_scraped(cls, data: dict) -> Lead:
        """Create a Lead from raw scraper output dict."""
        return cls(
            lead_id=data.get("lead_id", ""),
            name=data.get("name", ""),
            email=data.get("email", ""),
            phone=data.get("phone", ""),
            message=data.get("message", data.get("message_preview", "")),
            listing_id=data.get("listing_id", ""),
            property=data.get("property", ""),
            address=data.get("address", ""),
            price=data.get("price", ""),
            listing_type=data.get("listing_type", ""),
            status=data.get("status", ""),
            source_tab=data.get("source_tab", ""),
            time=data.get("time", ""),
        )

    def to_dict(self) -> dict:
        return asdict(self)


class CRMAdapter(ABC):
    """Interface for all CRM integrations."""

    @abstractmethod
    async def push_lead(self, lead: Lead) -> str:
        """Push a lead to the CRM. Returns CRM-assigned ID."""

    @abstractmethod
    async def update_lead(self, crm_id: str, data: dict) -> None:
        """Update an existing lead in the CRM with new data."""

    @abstractmethod
    async def check_duplicate(self, email: str, phone: str) -> Optional[str]:
        """Check if a lead already exists in CRM by email or phone.

        Returns the CRM ID if found, None otherwise.
        """

    @abstractmethod
    async def health_check(self) -> bool:
        """Return True if CRM connection is healthy."""
