"""Integration tests for CRM adapters.

Tests WebhookCRMAdapter and HubSpotAdapter end-to-end with mocked HTTP.
Covers push_lead, update_lead, check_duplicate, health_check, error
scenarios, retry logic, and Lead serialization through the full flow.
"""
from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from inmobiliaria24.crm.base import Lead
from inmobiliaria24.crm.webhook import WebhookCRMAdapter, MAX_RETRIES, RETRY_BASE_DELAY
from inmobiliaria24.crm.hubspot import HubSpotAdapter, HUBSPOT_API_BASE


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def sample_lead() -> Lead:
    return Lead(
        lead_id="L-001",
        name="María García López",
        email="maria@example.com",
        phone="5559876543",
        message="Me interesa la propiedad en Reforma",
        listing_id="PROP-42",
        property="Departamento en Reforma",
        address="Av. Reforma 500, CDMX",
        price="MN 3,200,000",
        listing_type="venta",
        status="Pendiente",
        source_tab="mensajes",
        time="10:15",
    )


@pytest.fixture
def webhook_adapter() -> WebhookCRMAdapter:
    return WebhookCRMAdapter("https://hooks.example.com/lead")


@pytest.fixture
def hubspot_adapter() -> HubSpotAdapter:
    return HubSpotAdapter("test-api-key-123")


def _mock_response(status_code: int = 200, json_data: dict | None = None) -> httpx.Response:
    """Create a mock httpx.Response."""
    resp = httpx.Response(
        status_code=status_code,
        json=json_data or {},
        request=httpx.Request("POST", "https://fake"),
    )
    return resp


# ===========================================================================
# WebhookCRMAdapter integration tests
# ===========================================================================

class TestWebhookPushLead:
    """push_lead end-to-end through WebhookCRMAdapter."""

    @pytest.mark.asyncio
    async def test_push_lead_success(self, webhook_adapter, sample_lead):
        mock_resp = _mock_response(200)
        mock_client = AsyncMock()
        mock_client.post.return_value = mock_resp

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            result = await webhook_adapter.push_lead(sample_lead)

        assert result == sample_lead.lead_id
        mock_client.post.assert_called_once()
        call_kwargs = mock_client.post.call_args
        payload = call_kwargs.kwargs.get("json") or call_kwargs[1].get("json")
        assert payload["lead_id"] == "L-001"
        assert payload["email"] == "maria@example.com"

    @pytest.mark.asyncio
    async def test_push_lead_serializes_full_lead(self, webhook_adapter, sample_lead):
        """Verify the complete Lead is serialized via to_dict in the POST body."""
        sample_lead.budget = "3M"
        sample_lead.qualified = True
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(200)

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            await webhook_adapter.push_lead(sample_lead)

        payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1]["json"]
        assert payload["budget"] == "3M"
        assert payload["qualified"] is True
        assert payload["scraped_at"]  # non-empty


class TestWebhookUpdateLead:

    @pytest.mark.asyncio
    async def test_update_lead_success(self, webhook_adapter):
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(200)

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            await webhook_adapter.update_lead("L-001", {"status": "Contactado"})

        payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1]["json"]
        assert payload["crm_id"] == "L-001"
        assert payload["update"]["status"] == "Contactado"

    @pytest.mark.asyncio
    async def test_update_lead_server_error(self, webhook_adapter):
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(500)

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            with pytest.raises(httpx.HTTPStatusError):
                await webhook_adapter.update_lead("L-001", {"status": "x"})


class TestWebhookCheckDuplicate:

    @pytest.mark.asyncio
    async def test_always_returns_none(self, webhook_adapter):
        result = await webhook_adapter.check_duplicate("a@b.com", "555")
        assert result is None


class TestWebhookHealthCheck:

    @pytest.mark.asyncio
    async def test_health_check_ok(self, webhook_adapter):
        mock_client = AsyncMock()
        mock_client.get.return_value = _mock_response(200)

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            assert await webhook_adapter.health_check() is True

    @pytest.mark.asyncio
    async def test_health_check_405_still_healthy(self, webhook_adapter):
        mock_client = AsyncMock()
        mock_client.get.return_value = _mock_response(405)

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            assert await webhook_adapter.health_check() is True

    @pytest.mark.asyncio
    async def test_health_check_500_unhealthy(self, webhook_adapter):
        mock_client = AsyncMock()
        mock_client.get.return_value = _mock_response(500)

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            assert await webhook_adapter.health_check() is False

    @pytest.mark.asyncio
    async def test_health_check_network_error(self, webhook_adapter):
        mock_client = AsyncMock()
        mock_client.get.side_effect = httpx.ConnectError("connection refused")

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            assert await webhook_adapter.health_check() is False


# ===========================================================================
# Webhook retry logic
# ===========================================================================

class TestWebhookRetry:

    @pytest.mark.asyncio
    async def test_retry_then_success(self, webhook_adapter, sample_lead):
        """First attempt fails, second succeeds."""
        mock_client = AsyncMock()
        mock_client.post.side_effect = [
            _mock_response(502),  # will raise on raise_for_status
            _mock_response(200),
        ]
        # The 502 response will raise HTTPStatusError on raise_for_status,
        # but our mock returns a real Response so raise_for_status works.

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient, \
             patch("inmobiliaria24.crm.webhook.asyncio.sleep", new_callable=AsyncMock) as mock_sleep:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            result = await webhook_adapter.push_lead(sample_lead)

        assert result == sample_lead.lead_id
        assert mock_client.post.call_count == 2
        mock_sleep.assert_called_once_with(RETRY_BASE_DELAY)

    @pytest.mark.asyncio
    async def test_all_retries_exhausted(self, webhook_adapter, sample_lead):
        """All MAX_RETRIES attempts fail, exception is raised."""
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(500)

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient, \
             patch("inmobiliaria24.crm.webhook.asyncio.sleep", new_callable=AsyncMock):
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            with pytest.raises(httpx.HTTPStatusError):
                await webhook_adapter.push_lead(sample_lead)

        assert mock_client.post.call_count == MAX_RETRIES

    @pytest.mark.asyncio
    async def test_retry_exponential_backoff(self, webhook_adapter, sample_lead):
        """Verify backoff delays double each attempt."""
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(503)

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient, \
             patch("inmobiliaria24.crm.webhook.asyncio.sleep", new_callable=AsyncMock) as mock_sleep:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            with pytest.raises(httpx.HTTPStatusError):
                await webhook_adapter.push_lead(sample_lead)

        # Retries = MAX_RETRIES - 1 sleeps (no sleep after last attempt)
        expected_delays = [RETRY_BASE_DELAY * (2 ** i) for i in range(MAX_RETRIES - 1)]
        actual_delays = [c.args[0] for c in mock_sleep.call_args_list]
        assert actual_delays == expected_delays

    @pytest.mark.asyncio
    async def test_retry_on_timeout(self, webhook_adapter, sample_lead):
        """Network timeout triggers retry."""
        mock_client = AsyncMock()
        mock_client.post.side_effect = [
            httpx.ReadTimeout("read timed out"),
            _mock_response(200),
        ]

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient, \
             patch("inmobiliaria24.crm.webhook.asyncio.sleep", new_callable=AsyncMock):
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            result = await webhook_adapter.push_lead(sample_lead)

        assert result == sample_lead.lead_id
        assert mock_client.post.call_count == 2


# ===========================================================================
# Webhook error scenarios
# ===========================================================================

class TestWebhookErrors:

    def test_empty_url_raises(self):
        with pytest.raises(ValueError, match="webhook_url is required"):
            WebhookCRMAdapter("")

    @pytest.mark.asyncio
    async def test_push_network_timeout_all_retries(self, webhook_adapter, sample_lead):
        mock_client = AsyncMock()
        mock_client.post.side_effect = httpx.ReadTimeout("timed out")

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient, \
             patch("inmobiliaria24.crm.webhook.asyncio.sleep", new_callable=AsyncMock):
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            with pytest.raises(httpx.ReadTimeout):
                await webhook_adapter.push_lead(sample_lead)


# ===========================================================================
# HubSpotAdapter integration tests
# ===========================================================================

class TestHubSpotPushLead:

    @pytest.mark.asyncio
    async def test_push_lead_success(self, hubspot_adapter, sample_lead):
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(201, {"id": "hs-12345"})

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            crm_id = await hubspot_adapter.push_lead(sample_lead)

        assert crm_id == "hs-12345"
        call_kwargs = mock_client.post.call_args
        assert call_kwargs.args[0] == f"{HUBSPOT_API_BASE}/crm/v3/objects/contacts"
        payload = call_kwargs.kwargs.get("json") or call_kwargs[1]["json"]
        props = payload["properties"]
        assert props["email"] == "maria@example.com"
        assert props["firstname"] == "María"
        assert props["lastname"] == "García López"
        assert props["phone"] == "5559876543"
        assert props["inmuebles24_lead_id"] == "L-001"

    @pytest.mark.asyncio
    async def test_push_lead_sends_auth_header(self, hubspot_adapter, sample_lead):
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(201, {"id": "1"})

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            await hubspot_adapter.push_lead(sample_lead)

        headers = mock_client.post.call_args.kwargs.get("headers") or mock_client.post.call_args[1]["headers"]
        assert headers["Authorization"] == "Bearer test-api-key-123"

    @pytest.mark.asyncio
    async def test_push_lead_single_name(self, hubspot_adapter):
        """Lead with single-word name: firstname only, no lastname."""
        lead = Lead(lead_id="X", name="Alejandro", email="a@b.com")
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(201, {"id": "99"})

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            await hubspot_adapter.push_lead(lead)

        payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1]["json"]
        assert payload["properties"]["firstname"] == "Alejandro"
        assert payload["properties"]["lastname"] == ""

    @pytest.mark.asyncio
    async def test_push_lead_401_auth_failure(self, hubspot_adapter, sample_lead):
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(401, {"message": "Invalid API key"})

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            with pytest.raises(httpx.HTTPStatusError):
                await hubspot_adapter.push_lead(sample_lead)

    @pytest.mark.asyncio
    async def test_push_lead_rate_limited(self, hubspot_adapter, sample_lead):
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(429, {"message": "Rate limit exceeded"})

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            with pytest.raises(httpx.HTTPStatusError):
                await hubspot_adapter.push_lead(sample_lead)

    @pytest.mark.asyncio
    async def test_push_lead_500_server_error(self, hubspot_adapter, sample_lead):
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(500)

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            with pytest.raises(httpx.HTTPStatusError):
                await hubspot_adapter.push_lead(sample_lead)

    @pytest.mark.asyncio
    async def test_push_lead_network_timeout(self, hubspot_adapter, sample_lead):
        mock_client = AsyncMock()
        mock_client.post.side_effect = httpx.ReadTimeout("read timed out")

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            with pytest.raises(httpx.ReadTimeout):
                await hubspot_adapter.push_lead(sample_lead)


class TestHubSpotUpdateLead:

    @pytest.mark.asyncio
    async def test_update_lead_success(self, hubspot_adapter):
        mock_client = AsyncMock()
        mock_client.patch.return_value = _mock_response(200)

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            await hubspot_adapter.update_lead("hs-100", {"hs_lead_status": "CONTACTED"})

        call_kwargs = mock_client.patch.call_args
        assert "hs-100" in call_kwargs.args[0]
        payload = call_kwargs.kwargs.get("json") or call_kwargs[1]["json"]
        assert payload["properties"]["hs_lead_status"] == "CONTACTED"

    @pytest.mark.asyncio
    async def test_update_lead_not_found(self, hubspot_adapter):
        mock_client = AsyncMock()
        mock_client.patch.return_value = _mock_response(404)

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            with pytest.raises(httpx.HTTPStatusError):
                await hubspot_adapter.update_lead("nonexistent", {})


class TestHubSpotCheckDuplicate:

    @pytest.mark.asyncio
    async def test_duplicate_found_by_email(self, hubspot_adapter):
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(200, {
            "results": [{"id": "hs-dup-1"}],
        })

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            result = await hubspot_adapter.check_duplicate("maria@example.com", "")

        assert result == "hs-dup-1"

    @pytest.mark.asyncio
    async def test_no_duplicate(self, hubspot_adapter):
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(200, {"results": []})

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            result = await hubspot_adapter.check_duplicate("nobody@test.com", "000")

        assert result is None

    @pytest.mark.asyncio
    async def test_no_email_no_phone_returns_none(self, hubspot_adapter):
        result = await hubspot_adapter.check_duplicate("", "")
        assert result is None

    @pytest.mark.asyncio
    async def test_duplicate_check_network_error_returns_none(self, hubspot_adapter):
        """Network errors are swallowed and return None (graceful degradation)."""
        mock_client = AsyncMock()
        mock_client.post.side_effect = httpx.ConnectError("connection refused")

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            result = await hubspot_adapter.check_duplicate("a@b.com", "555")

        assert result is None

    @pytest.mark.asyncio
    async def test_duplicate_check_search_payload(self, hubspot_adapter):
        """Verify correct filter groups are sent for both email and phone."""
        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(200, {"results": []})

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            await hubspot_adapter.check_duplicate("test@x.com", "12345")

        payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1]["json"]
        groups = payload["filterGroups"]
        assert len(groups) == 2
        assert groups[0]["filters"][0]["propertyName"] == "email"
        assert groups[0]["filters"][0]["value"] == "test@x.com"
        assert groups[1]["filters"][0]["propertyName"] == "phone"
        assert groups[1]["filters"][0]["value"] == "12345"


class TestHubSpotHealthCheck:

    @pytest.mark.asyncio
    async def test_health_check_ok(self, hubspot_adapter):
        mock_client = AsyncMock()
        mock_client.get.return_value = _mock_response(200)

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            assert await hubspot_adapter.health_check() is True

    @pytest.mark.asyncio
    async def test_health_check_401_returns_false(self, hubspot_adapter):
        mock_client = AsyncMock()
        mock_client.get.return_value = _mock_response(401)

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            assert await hubspot_adapter.health_check() is False

    @pytest.mark.asyncio
    async def test_health_check_network_error(self, hubspot_adapter):
        mock_client = AsyncMock()
        mock_client.get.side_effect = httpx.ConnectError("unreachable")

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            assert await hubspot_adapter.health_check() is False


class TestHubSpotErrors:

    def test_empty_api_key_raises(self):
        with pytest.raises(ValueError, match="API key is required"):
            HubSpotAdapter("")


# ===========================================================================
# Lead serialization through full adapter flow
# ===========================================================================

class TestLeadSerializationFlow:

    @pytest.mark.asyncio
    async def test_scraped_data_through_webhook(self, webhook_adapter):
        """from_scraped -> push_lead: verify full round-trip serialization."""
        raw = {
            "lead_id": "RAW-1",
            "name": "Carlos Ruiz",
            "email": "carlos@test.mx",
            "phone": "5550001111",
            "message_preview": "Quiero agendar visita",
            "listing_id": "LS-99",
            "property": "Casa en Polanco",
            "address": "Polanco 200",
            "price": "MN 8,000,000",
            "listing_type": "venta",
            "status": "Pendiente",
            "source_tab": "whatsapp",
            "time": "09:00",
        }
        lead = Lead.from_scraped(raw)
        lead.budget = "8M"
        lead.qualified = True
        lead.crm_pushed = False

        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(200)

        with patch("inmobiliaria24.crm.webhook.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            result = await webhook_adapter.push_lead(lead)

        assert result == "RAW-1"
        payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1]["json"]
        assert payload["message"] == "Quiero agendar visita"
        assert payload["budget"] == "8M"
        assert payload["qualified"] is True
        assert payload["crm_pushed"] is False
        assert payload["scraped_at"]  # auto-populated

    @pytest.mark.asyncio
    async def test_scraped_data_through_hubspot(self, hubspot_adapter):
        """from_scraped -> push_lead via HubSpot: verify property mapping."""
        raw = {
            "lead_id": "RAW-2",
            "name": "Ana Martínez Soto",
            "email": "ana@correo.com",
            "phone": "5552223333",
            "message": "Información por favor",
            "listing_id": "LS-50",
            "listing_type": "renta",
            "price": "MN 25,000/mes",
        }
        lead = Lead.from_scraped(raw)

        mock_client = AsyncMock()
        mock_client.post.return_value = _mock_response(201, {"id": "hs-new"})

        with patch("inmobiliaria24.crm.hubspot.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            MockClient.return_value.__aexit__ = AsyncMock(return_value=False)

            crm_id = await hubspot_adapter.push_lead(lead)

        assert crm_id == "hs-new"
        payload = mock_client.post.call_args.kwargs.get("json") or mock_client.post.call_args[1]["json"]
        props = payload["properties"]
        assert props["firstname"] == "Ana"
        assert props["lastname"] == "Martínez Soto"
        assert props["property_type"] == "renta"
        assert props["property_price"] == "MN 25,000/mes"
        assert props["lead_message"] == "Información por favor"
