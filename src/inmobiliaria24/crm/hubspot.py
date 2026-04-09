"""HubSpot CRM adapter — template for when client provides API keys.

Implements the CRMAdapter interface for HubSpot's Contacts API.
Activate by setting CRM_ADAPTER=hubspot and CRM_API_KEY in .env.
"""
from __future__ import annotations

from typing import Optional

import httpx
from loguru import logger

from inmobiliaria24.crm.base import CRMAdapter, Lead

HUBSPOT_API_BASE = "https://api.hubapi.com"


class HubSpotAdapter(CRMAdapter):
    """HubSpot CRM integration via REST API v3."""

    def __init__(self, api_key: str, *, timeout: int = 30) -> None:
        if not api_key:
            raise ValueError("HubSpot API key is required")
        self._api_key = api_key
        self._timeout = timeout
        self._headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }

    async def push_lead(self, lead: Lead) -> str:
        """Create a HubSpot contact from lead data."""
        payload = {
            "properties": {
                "email": lead.email,
                "firstname": lead.name.split()[0] if lead.name else "",
                "lastname": " ".join(lead.name.split()[1:]) if lead.name else "",
                "phone": lead.phone,
                "address": lead.address,
                "hs_lead_status": "NEW",
                # Custom properties (must be created in HubSpot first)
                "inmuebles24_lead_id": lead.lead_id,
                "inmuebles24_listing_id": lead.listing_id,
                "property_type": lead.listing_type,
                "property_price": lead.price,
                "lead_source_tab": lead.source_tab,
                "lead_message": lead.message,
            }
        }

        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.post(
                f"{HUBSPOT_API_BASE}/crm/v3/objects/contacts",
                headers=self._headers,
                json=payload,
            )
            resp.raise_for_status()
            crm_id = resp.json().get("id", "")
            logger.info("HubSpot contact created: {} for lead {}", crm_id, lead.lead_id)
            return crm_id

    async def update_lead(self, crm_id: str, data: dict) -> None:
        """Update a HubSpot contact with qualification or status data."""
        payload = {"properties": data}
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.patch(
                f"{HUBSPOT_API_BASE}/crm/v3/objects/contacts/{crm_id}",
                headers=self._headers,
                json=payload,
            )
            resp.raise_for_status()
            logger.info("HubSpot contact {} updated", crm_id)

    async def check_duplicate(self, email: str, phone: str) -> Optional[str]:
        """Search HubSpot for existing contact by email or phone."""
        if not email and not phone:
            return None

        filters = []
        if email:
            filters.append({
                "propertyName": "email",
                "operator": "EQ",
                "value": email,
            })
        if phone:
            filters.append({
                "propertyName": "phone",
                "operator": "EQ",
                "value": phone,
            })

        payload = {
            "filterGroups": [{"filters": [f]} for f in filters],
            "limit": 1,
        }

        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                resp = await client.post(
                    f"{HUBSPOT_API_BASE}/crm/v3/objects/contacts/search",
                    headers=self._headers,
                    json=payload,
                )
                resp.raise_for_status()
                results = resp.json().get("results", [])
                if results:
                    return results[0]["id"]
        except Exception as e:
            logger.warning("HubSpot duplicate check failed: {}", e)

        return None

    async def health_check(self) -> bool:
        """Verify HubSpot API key is valid."""
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(
                    f"{HUBSPOT_API_BASE}/crm/v3/objects/contacts?limit=1",
                    headers=self._headers,
                )
                return resp.status_code == 200
        except Exception:
            return False
