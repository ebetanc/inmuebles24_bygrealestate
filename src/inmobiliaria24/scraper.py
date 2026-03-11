"""Scraper for the Interesados (leads) inbox on Inmuebles24.

Navigates to the centralized Interesados page, extracts all Pendiente
leads from the inbox, opens each one to collect full contact details,
and sends everything to an n8n webhook.

Important: Inmuebles24's panel is a React SPA — all content renders
dynamically inside <div id="root">. We must wait for React to render
before extracting any data.
"""
from __future__ import annotations

import asyncio
import random

import httpx
from loguru import logger
from playwright.async_api import Page

from inmobiliaria24.auth import _wait_for_cloudflare


WEBHOOK_URL = (
    "https://n8n.srv856940.hstgr.cloud/webhook/"
    "63340e41-c487-4e66-86fe-c4ff710fbcdd"
)
INTERESADOS_URL = "https://www.inmuebles24.com/panel/interesados"


# ---------------------------------------------------------------------------
# SPA helper — wait for React to render meaningful content
# ---------------------------------------------------------------------------

async def _wait_for_spa(page: Page, timeout: int = 30_000) -> None:
    """Wait for the React SPA to render content inside #root."""
    await page.wait_for_function(
        """() => {
            const root = document.getElementById('root');
            return root && root.children.length > 0 && root.innerText.trim().length > 50;
        }""",
        timeout=timeout,
    )
    # Extra settle time for async data fetching.
    await asyncio.sleep(random.uniform(2.0, 3.5))


async def _navigate_spa(page: Page, url: str) -> None:
    """Navigate to a URL and wait for the SPA to fully render."""
    await page.goto(url, wait_until="domcontentloaded")
    await _wait_for_cloudflare(page)
    await _wait_for_spa(page)


# ---------------------------------------------------------------------------
# 1. Extract lead rows from the Interesados inbox
# ---------------------------------------------------------------------------

_EXTRACT_LEADS_LIST_JS = """
() => {
    const root = document.getElementById('root');
    if (!root) return [];

    const results = [];
    const seen = new Set();

    // Strategy 1: find <a> links pointing to /panel/interesados/{id}
    const allAnchors = root.querySelectorAll('a');
    for (const a of allAnchors) {
        const href = a.getAttribute('href') || '';
        const match = href.match(/\\/(?:panel\\/)?interesados\\/(\\d+)/);
        if (!match) continue;

        const leadId = match[1];
        if (seen.has(leadId)) continue;
        seen.add(leadId);

        // Walk up to find the row container
        let row = a;
        for (let p = a; p && p !== root; p = p.parentElement) {
            if (p.tagName === 'TR' || p.tagName === 'LI'
                || p.getAttribute('role') === 'row'
                || p.getAttribute('data-qa')
                || p.getAttribute('data-panel')) {
                row = p;
                break;
            }
        }

        const text = row.innerText || '';

        // Status
        const isPendiente = text.includes('Pendiente');
        const isContactado = text.includes('Contactado');
        const status = isPendiente ? 'Pendiente' : isContactado ? 'Contactado' : '';

        // Listing ID (e.g., "ID: 147450070")
        const idMatch = text.match(/ID:\\s*(\\d+)/);
        const listingId = idMatch ? idMatch[1] : '';

        // Name — first non-empty line
        const lines = text.split('\\n').map(l => l.trim()).filter(l => l.length > 0);
        const name = lines[0] || '';

        // Message preview — find a line that looks like message content
        const msgLine = lines.find(l =>
            l.length > 5 && l !== name && !l.startsWith('ID:')
            && !l.includes('Pendiente') && !l.includes('Contactado')
            && !/^(venta|Renta)$/i.test(l) && !l.match(/^MN\\s/)
            && !l.match(/^\\d{1,2}:\\d{2}$/)
        );
        const messagePreview = msgLine ? msgLine.substring(0, 120) : '';

        // Address
        const addrMatch = text.match(/ID:\\s*\\d+\\n(.+)/);
        const address = addrMatch ? addrMatch[1].trim().substring(0, 200) : '';

        // Price
        const priceMatch = text.match(/MN\\s*[\\d.,]+/);
        const price = priceMatch ? priceMatch[0].trim() : '';

        // Type (venta/Renta)
        const typeMatch = text.match(/\\b(venta|Renta|renta)\\b/i);
        const listingType = typeMatch ? typeMatch[1] : '';

        // Time
        const timeMatch = text.match(/\\b(\\d{1,2}:\\d{2})\\b/);
        const time = timeMatch ? timeMatch[1] : '';

        results.push({
            lead_id: leadId,
            name,
            message_preview: messagePreview,
            listing_id: listingId,
            address,
            price,
            listing_type: listingType,
            status,
            time,
        });
    }

    // Strategy 2: if no links found, fall back to finding rows by status text
    if (results.length === 0) {
        const allSpans = root.querySelectorAll('span, div, p');
        let index = 0;
        for (const el of allSpans) {
            const t = el.textContent.trim();
            if (t !== 'Pendiente' && t !== 'Contactado') continue;

            // Walk up to find the row
            let row = el;
            for (let p = el; p && p !== root; p = p.parentElement) {
                if (p.tagName === 'TR' || p.tagName === 'LI'
                    || p.getAttribute('data-qa') || p.getAttribute('data-panel')
                    || (p.onclick || getComputedStyle(p).cursor === 'pointer')) {
                    row = p;
                    break;
                }
            }
            const text = row.innerText || '';
            const lines = text.split('\\n').map(l => l.trim()).filter(Boolean);

            const idMatch = text.match(/ID:\\s*(\\d+)/);

            results.push({
                lead_id: '',
                name: lines[0] || '',
                message_preview: '',
                listing_id: idMatch ? idMatch[1] : '',
                address: '',
                price: '',
                listing_type: '',
                status: t,
                time: '',
                _click_index: index,
            });
            index++;
        }
    }

    return results;
}
"""


_CLICK_TAB_JS = """
(selector) => {
    const btn = document.querySelector(selector);
    if (!btn) return false;
    btn.click();
    return true;
}
"""

# Tab CSS selectors and human-readable names.
_TABS = [
    ("mensajes",  None),                   # default active tab — no click needed
    ("telefono",  "button.phoneCall"),      # "Consultaron tu teléfono"
    ("whatsapp",  "button.whatsapp"),       # "Contactaron por WhatsApp"
]


async def extract_leads_list(page: Page) -> list[dict]:
    """Navigate to the Interesados inbox and extract Pendiente leads from all tabs."""
    await _navigate_spa(page, INTERESADOS_URL)
    # The inbox loads lead rows asynchronously after the shell renders.
    await asyncio.sleep(30)

    all_pendiente: list[dict] = []

    for tab_name, tab_selector in _TABS:
        # Click the tab (skip for the default Mensajes tab).
        if tab_selector:
            clicked = await page.evaluate(_CLICK_TAB_JS, tab_selector)
            if not clicked:
                logger.warning("Could not click tab '{}' — skipping", tab_name)
                continue
            # Wait for the tab content to load.
            await asyncio.sleep(30)

        leads: list[dict] = await page.evaluate(_EXTRACT_LEADS_LIST_JS)
        pendiente = [l for l in leads if l.get("status") == "Pendiente"]
        other = len(leads) - len(pendiente)

        logger.info(
            "Tab '{}': {} leads, {} Pendiente, {} other",
            tab_name, len(leads), len(pendiente), other,
        )

        # Tag each lead with its source tab.
        for lead in pendiente:
            lead["source_tab"] = tab_name

        all_pendiente.extend(pendiente)

    logger.info("Total Pendiente across all tabs: {}", len(all_pendiente))
    for lead in all_pendiente:
        logger.info(
            "  Pendiente [{}]: {} (lead_id={}, listing={})",
            lead.get("source_tab"), lead.get("name", "?"),
            lead.get("lead_id"), lead.get("listing_id"),
        )

    return all_pendiente


# ---------------------------------------------------------------------------
# 2. Extract contact details from a single lead's detail page
# ---------------------------------------------------------------------------

_EXTRACT_LEAD_DETAIL_JS = """
() => {
    const root = document.getElementById('root');
    if (!root) return null;
    const text = root.innerText;

    // Name — from "Acerca de [name]" section or header
    let name = '';
    const aboutMatch = text.match(/Acerca de\\s+(.+?)(?:\\n|$)/);
    if (aboutMatch) name = aboutMatch[1].trim();
    if (!name) {
        const h = root.querySelector('h1, h2, h3, [class*="name" i]');
        if (h) name = h.textContent.trim();
    }

    // Email
    let email = '';
    const emailMatch = text.match(/[\\w.+-]+@[\\w.-]+\\.[a-zA-Z]{2,}/);
    if (emailMatch) email = emailMatch[0];

    // Phone — look in contact section first, then fallback
    let phone = '';
    const phoneSection = text.match(
        /(?:Datos de contacto|Tel[eé]fono|Tel)[\\s\\S]*?(?=\\n\\n|Acerca|$)/i
    );
    if (phoneSection) {
        const phoneMatch = phoneSection[0].match(/(\\d[\\d\\s-]{7,15})/);
        if (phoneMatch) phone = phoneMatch[1].replace(/[\\s-]/g, '');
    }
    if (!phone) {
        const allPhones = text.match(/\\b(\\d{10,13})\\b/g);
        if (allPhones) phone = allPhones[0];
    }

    // Message — the lead's inquiry text
    let message = '';
    const msgPatterns = [
        /(Hola[^\\n]*(?:contacten|inmueble|interesa|informaci[oó]n|comunicar)[^\\n]*)/i,
        /(Soy\\s[^\\n]+)/i,
        /Envi[oó] consulta[\\s\\S]*?\\n\\n([^\\n]+)/,
    ];
    for (const pat of msgPatterns) {
        const m = text.match(pat);
        if (m) { message = (m[1] || m[0]).trim(); break; }
    }
    if (!message) {
        const lines = text.split('\\n').map(l => l.trim()).filter(l => l.length > 20);
        for (const line of lines) {
            if (!line.includes('Acerca de') && !line.includes('Datos de contacto')
                && !line.includes('Pedir') && !line.includes('calificaci')
                && !line.includes('Nota Interna') && !line.includes('Pendiente')
                && !line.includes('Contactado') && !line.includes('inmuebles24')) {
                message = line;
                break;
            }
        }
    }

    // Listing ID
    let listingId = '';
    const idMatch = text.match(/ID:\\s*(\\d+)/);
    if (idMatch) listingId = idMatch[1];

    // Status
    let status = '';
    const statusMatch = text.match(/\\b(Pendiente|Contactado)\\b/);
    if (statusMatch) status = statusMatch[1];

    // Property info
    let property = '';
    const propMatch = text.match(
        /(?:Departamento|Casa en condominio|Casa|Terreno|Oficina|Local)[^\\n]*/
    );
    if (propMatch) property = propMatch[0].trim();

    return { name, email, phone, message, listing_id: listingId, status, property,
             page_text: text.substring(0, 1500) };
}
"""


async def extract_lead_detail(page: Page, lead_id: str) -> dict | None:
    """Navigate to a single lead's detail page and extract contact info."""
    url = f"{INTERESADOS_URL}/{lead_id}"
    logger.info("Opening lead detail: {}", url)

    await _navigate_spa(page, url)

    detail = await page.evaluate(_EXTRACT_LEAD_DETAIL_JS)
    if detail:
        logger.info(
            "Lead detail: name={}, email={}, phone={}, status={}",
            detail.get("name"), detail.get("email"),
            detail.get("phone"), detail.get("status"),
        )
        # Log full page text for debugging on first runs
        logger.debug("Detail page text: {}", detail.pop("page_text", ""))
    else:
        logger.warning("Could not extract detail for lead {}", lead_id)

    return detail


# ---------------------------------------------------------------------------
# 3. Fallback: click-based navigation when no href links are found
# ---------------------------------------------------------------------------

_CLICK_PENDIENTE_JS = """
(index) => {
    const root = document.getElementById('root');
    if (!root) return false;

    let count = 0;
    const allEls = root.querySelectorAll('span, div, p');
    for (const el of allEls) {
        if (el.textContent.trim() === 'Pendiente') {
            if (count === index) {
                let clickable = el;
                for (let p = el; p && p !== root; p = p.parentElement) {
                    if (p.tagName === 'A' || p.onclick
                        || getComputedStyle(p).cursor === 'pointer') {
                        clickable = p;
                        break;
                    }
                    if (p.tagName === 'LI' || p.getAttribute('data-qa')
                        || p.getAttribute('data-panel')) {
                        clickable = p;
                        break;
                    }
                }
                clickable.click();
                return true;
            }
            count++;
        }
    }
    return false;
}
"""


async def _extract_lead_by_click(
    page: Page, click_index: int,
) -> dict | None:
    """Click the Nth Pendiente row and extract detail from the resulting page."""
    clicked = await page.evaluate(_CLICK_PENDIENTE_JS, click_index)
    if not clicked:
        logger.warning("Could not click Pendiente lead at index {}", click_index)
        return None

    await asyncio.sleep(random.uniform(2.0, 3.5))
    await _wait_for_spa(page)

    # Capture the lead_id from the URL after navigation
    lead_id = ""
    url = page.url
    import re
    m = re.search(r"/interesados/(\d+)", url)
    if m:
        lead_id = m.group(1)


    detail = await page.evaluate(_EXTRACT_LEAD_DETAIL_JS)
    if detail:
        detail["lead_id"] = lead_id
        logger.debug("Detail page text: {}", detail.pop("page_text", ""))

    return detail


# ---------------------------------------------------------------------------
# 4. Webhook
# ---------------------------------------------------------------------------


async def send_to_webhook(leads: list[dict], webhook_url: str = WEBHOOK_URL) -> None:
    """POST lead data to an n8n webhook."""
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(webhook_url, json=leads)
        resp.raise_for_status()
        logger.info(
            "Webhook response: {} {}",
            resp.status_code, resp.reason_phrase,
        )


# ---------------------------------------------------------------------------
# 5. Orchestrator
# ---------------------------------------------------------------------------


async def scrape_and_send(page: Page) -> list[dict]:
    """Full flow: Interesados inbox -> detail per Pendiente lead -> webhook."""
    # Step 1: Get Pendiente leads from the inbox.
    pendiente_leads = await extract_leads_list(page)
    if not pendiente_leads:
        logger.warning("No Pendiente leads found — nothing to send")
        return []

    results: list[dict] = []

    # Check if we got lead_id links (Strategy 1) or need click-based nav (Strategy 2).
    has_links = any(l.get("lead_id") for l in pendiente_leads)

    if has_links:
        # Strategy 1: direct navigation via URL
        for i, lead in enumerate(pendiente_leads):
            lead_id = lead["lead_id"]
            logger.info(
                "Processing lead {}/{}: {} ({})",
                i + 1, len(pendiente_leads), lead.get("name", "?"), lead_id,
            )
            detail = await extract_lead_detail(page, lead_id)
            if detail:
                merged = {**lead, **detail}
                results.append(merged)
    else:
        # Strategy 2: click each Pendiente row
        logger.info("No lead URLs found — using click-based navigation")
        for i, lead in enumerate(pendiente_leads):
            click_idx = lead.get("_click_index", i)
            logger.info(
                "Clicking lead {}/{}: {}",
                i + 1, len(pendiente_leads), lead.get("name", "?"),
            )
            detail = await _extract_lead_by_click(page, click_idx)
            if detail:
                merged = {**lead, **detail}
                merged.pop("_click_index", None)
                results.append(merged)

            # Navigate back to inbox for next lead
            await page.go_back()
            await asyncio.sleep(random.uniform(1.5, 2.5))
            try:
                await _wait_for_spa(page)
            except Exception:
                logger.debug("go_back didn't render — navigating directly")
                await _navigate_spa(page, INTERESADOS_URL)

    if not results:
        logger.warning("No lead details extracted — nothing to send")
        return []

    # Step 2: Send to webhook.
    logger.info("Sending {} Pendiente leads to webhook", len(results))
    await send_to_webhook(results)

    return results
