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


class SessionStaleError(Exception):
    """Raised when the browser session has expired and needs re-authentication."""


# Must be set via WEBHOOK_URL env var in config.
_DEFAULT_WEBHOOK_URL = ""
INTERESADOS_URL = "https://www.inmuebles24.com/panel/interesados"

# Retry settings
MAX_RETRIES = 3
RETRY_BASE_DELAY = 2.0  # seconds, doubles each retry

# Stale session indicators (URL fragments that mean we got logged out).
_STALE_SESSION_URLS = ("login", "acceso", "ingresar")


# ---------------------------------------------------------------------------
# Screenshot helper — captures on any failure for post-mortem debugging
# ---------------------------------------------------------------------------

async def _screenshot_on_error(page: Page, label: str) -> str | None:
    """Capture a full-page screenshot for debugging. Returns the file path or None."""
    from pathlib import Path

    logs = Path("logs")
    logs.mkdir(exist_ok=True)
    from datetime import datetime, timezone

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    filename = f"error_{label}_{ts}.png"
    filepath = logs / filename
    try:
        await page.screenshot(path=str(filepath), full_page=True)
        logger.info("Error screenshot saved to {}", filepath)
        return str(filepath)
    except Exception as e:
        logger.warning("Failed to capture screenshot: {}", e)
        return None


# ---------------------------------------------------------------------------
# Session staleness detection
# ---------------------------------------------------------------------------

def _is_session_stale(url: str) -> bool:
    """Return True if the current URL indicates a logged-out / stale session."""
    lower = url.lower()
    return any(frag in lower for frag in _STALE_SESSION_URLS)


# ---------------------------------------------------------------------------
# SPA helper — wait for React to render meaningful content
# ---------------------------------------------------------------------------

async def _wait_for_spa(page: Page, timeout: int = 60_000) -> None:
    """Wait for the React SPA to render content inside #root."""
    try:
        await page.wait_for_function(
            """() => {
                const root = document.getElementById('root');
                return root && root.children.length > 0 && root.innerText.trim().length > 50;
            }""",
            timeout=timeout,
        )
    except Exception:
        # Capture debug screenshot and page info on failure.
        from pathlib import Path
        Path("logs").mkdir(exist_ok=True)
        await page.screenshot(path="logs/spa_timeout_debug.png", full_page=True)
        title = await page.title()
        url = page.url
        text = await page.evaluate("() => document.body?.innerText?.substring(0, 500) || ''")
        logger.error(
            "SPA timeout — title={!r}, url={!r}, body_preview={!r}",
            title, url, text,
        )
        raise
    # Extra settle time for async data fetching.
    await asyncio.sleep(random.uniform(2.0, 3.5))


async def _navigate_spa(
    page: Page, url: str, *, retries: int = MAX_RETRIES
) -> None:
    """Navigate to a URL and wait for the SPA to fully render.

    Retries with exponential backoff on page-load or SPA-render failures.
    """
    last_err: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            await page.goto(url, wait_until="domcontentloaded")
            await _wait_for_cloudflare(page)
            await _wait_for_spa(page)
            return
        except Exception as e:
            last_err = e
            if attempt < retries:
                delay = RETRY_BASE_DELAY * (2 ** (attempt - 1))
                logger.warning(
                    "Page load attempt {}/{} failed for {} — retrying in {:.1f}s: {}",
                    attempt, retries, url, delay, e,
                )
                await asyncio.sleep(delay)
            else:
                logger.error(
                    "Page load failed after {} attempts for {}: {}",
                    retries, url, e,
                )
    raise last_err  # type: ignore[misc]


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

        // Status. Brand-new rows can render WITHOUT a status chip for a while
        // (seen live 2026-07-03: fresh lead invisible to the Pendiente filter)
        // — report '' and let the caller treat chipless rows as pending.
        const isPendiente = text.includes('Pendiente');
        const isContactado = text.includes('Contactado');
        const isFinalizado = text.includes('Finalizado');
        const status = isPendiente ? 'Pendiente'
                     : isContactado ? 'Contactado'
                     : isFinalizado ? 'Finalizado' : '';

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

        # Chipless rows (status '') are brand-new leads whose status chip has
        # not rendered yet — include them as pending. Safety cap: if MANY rows
        # come back chipless it is a page-render glitch, not a wave of new
        # leads, and including them would re-push old attended inquiries.
        chipless = [l for l in leads if l.get("status") == "" and l.get("lead_id")]
        if chipless:
            if len(chipless) <= 3:
                logger.info(
                    "Tab '{}': treating {} chipless row(s) as Pendiente: {}",
                    tab_name, len(chipless),
                    ", ".join(f"{l.get('name','?')}({l.get('lead_id')})" for l in chipless),
                )
                pendiente.extend(chipless)
            else:
                logger.warning(
                    "Tab '{}': {} chipless rows — looks like a render glitch, skipping them",
                    tab_name, len(chipless),
                )

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

    // Phone — collect candidate numbers PER LINE, never spanning lines. The old
    // regex used \\s in the char class, so it jumped across the newline between the
    // two stacked numbers Inmuebles24 shows and glued them:
    // "525555067748\\n5555067748" -> "525555067748555" (3 junk digits appended).
    let phone = '';
    // Prefer the contact-panel links (wa.me / tel:) — they exist only inside
    // "Datos de contacto". A text regex over the whole page can capture numbers
    // typed inside chat messages instead (seen live 2026-07-03: an advisor's
    // own callback number in her reply was stored as the lead's phone).
    let phoneCands = [];
    for (const a of root.querySelectorAll('a[href*="wa.me"], a[href^="tel:"], a[href*="whatsapp"]')) {
        const digits = (a.getAttribute('href') || '').replace(/\\D/g, '');
        if (digits.length >= 10 && digits.length <= 13) phoneCands.push(digits);
    }
    if (phoneCands.length === 0) {
        const phoneSection = text.match(
            /(?:Datos de contacto|Tel[eé]fono|Tel)[\\s\\S]*?(?=\\n\\n|Acerca|$)/i
        );
        const scanArea = phoneSection ? phoneSection[0] : '';
        for (const line of scanArea.split(/\\n+/)) {
            const m = line.match(/\\d[\\d \\t-]{6,13}\\d/); // digits + spaces/dashes, NO newline
            if (m) {
                const digits = m[0].replace(/\\D/g, '');
                if (digits.length >= 10 && digits.length <= 13) phoneCands.push(digits);
            }
        }
    }
    if (phoneCands.length === 0) {
        // Last resort: whole-page scan. May hit chat-message numbers, so only
        // when the contact panel gave us nothing at all.
        phoneCands = (text.match(/\\d{10,13}/g) || []);
    }
    // Prefer a country-code number (12-13 digits), else a local 10-digit.
    phone = phoneCands.find(s => s.length >= 12)
         || phoneCands.find(s => s.length === 10)
         || phoneCands[0] || '';
    // Normalize to Mexico canonical: 52 + 10 digits (drop the mobile "1": 521->52).
    if (phone) {
        if (phone.length === 10) phone = '52' + phone;
        else if (phone.length === 13 && phone.startsWith('521')) phone = '52' + phone.slice(3);
        else if (phone.length === 11 && phone.startsWith('1')) phone = '52' + phone.slice(1);
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

    // EasyBroker advertiser code, e.g. "Cód. del anunciante: EB-VK1013".
    // Used to resolve the owner agent via EasyBroker tags (owner-first routing).
    // Empty if the page does not expose it -> downstream routes to manager.
    let propertyPublicId = '';
    const ebMatch = text.match(/EB-[A-Z0-9]{4,}/i);
    if (ebMatch) propertyPublicId = ebMatch[0].toUpperCase();

    return { name, email, phone, message, listing_id: listingId, status, property,
             property_public_id: propertyPublicId,
             page_text: text.substring(0, 1500) };
}
"""


async def extract_lead_detail(page: Page, lead_id: str) -> dict | None:
    """Navigate to a single lead's detail page and extract contact info."""
    url = f"{INTERESADOS_URL}/{lead_id}"
    logger.info("Opening lead detail: {}", url)

    await _navigate_spa(page, url)

    detail = await page.evaluate(_EXTRACT_LEAD_DETAIL_JS)
    if detail and not detail.get("phone") and not detail.get("email"):
        # The SPA sometimes paints a transient error banner ("No tienes
        # permisos...") before the contact panel loads, yielding a garbage
        # extraction. One reload recovers the real content.
        logger.warning(
            "Lead {} detail has no phone/email (transient page?) — reloading once",
            lead_id,
        )
        await page.reload(wait_until="domcontentloaded")
        await asyncio.sleep(10)
        retry = await page.evaluate(_EXTRACT_LEAD_DETAIL_JS)
        if retry and (retry.get("phone") or retry.get("email")):
            detail = retry
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
# 2b. Mark a lead as "Contactado" on the portal (remove it from Pendiente)
# ---------------------------------------------------------------------------
#
# The scraper's local SQLite dedup keeps us from re-sending a lead, but the
# lead stays *Pendiente* on the Inmuebles24 portal forever. Each inbox row has
# an "Estado de consulta" dropdown (Pendiente / Contactado / Finalizado) that
# changes the status IN PLACE — mark_lead_contacted() selects "Contactado"
# there. This does NOT message the prospect (unlike replying in the chat, the
# only other way to flip status). Gated by the MARK_CONTACTED env var.

# Dumps every plausibly-clickable control on the current page so we can find
# the real "mark as contactado" button/menu without live access.
_DUMP_CONTROLS_JS = """
() => {
    const root = document.getElementById('root') || document.body;
    if (!root) return [];
    const out = [];
    const els = root.querySelectorAll(
        'button, a, [role="button"], [data-qa], [onclick], select, textarea, input, [contenteditable], [class*="estado" i], [class*="status" i]'
    );
    const seen = new Set();
    for (const el of els) {
        const text = (el.innerText || el.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 80);
        const dq = el.getAttribute('data-qa') || '';
        const aria = el.getAttribute('aria-label') || '';
        const title = el.getAttribute('title') || '';
        const cls = (el.className && el.className.toString ? el.className.toString() : '').slice(0, 120);
        const key = el.tagName + '|' + dq + '|' + text + '|' + cls;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({
            tag: el.tagName.toLowerCase(),
            text,
            data_qa: dq,
            aria_label: aria,
            title,
            class: cls,
        });
        if (out.length >= 200) break;
    }

    // Second pass: status badges/toggles are often plain <span>/<div> whose
    // text is exactly the status word (no button/data-qa). Capture those plus
    // their nearest clickable ancestor so we can target the status control.
    const all = root.querySelectorAll('span, div, p, li');
    for (const el of all) {
        const t = (el.textContent || '').trim();
        if (t !== 'Pendiente' && t !== 'Contactado' && t !== 'Marcar como contactado'
            && t !== 'Marcar como pendiente') continue;
        if (el.children.length > 0) continue;  // leaf node only (the badge text itself)
        // Walk up to the nearest clickable ancestor.
        let clickable = el;
        for (let p = el; p && p !== root; p = p.parentElement) {
            if (p.tagName === 'BUTTON' || p.tagName === 'A' || p.onclick
                || p.getAttribute('role') === 'button'
                || getComputedStyle(p).cursor === 'pointer') {
                clickable = p;
                break;
            }
        }
        out.push({
            tag: el.tagName.toLowerCase(),
            text: t,
            data_qa: el.getAttribute('data-qa') || '',
            aria_label: el.getAttribute('aria-label') || '',
            title: '_STATUS_BADGE_',
            class: (el.className && el.className.toString ? el.className.toString() : '').slice(0, 120),
            clickable_tag: clickable.tagName.toLowerCase(),
            clickable_class: (clickable.className && clickable.className.toString ? clickable.className.toString() : '').slice(0, 120),
            clickable_data_qa: clickable.getAttribute('data-qa') || '',
        });
    }
    return out;
}
"""


async def dump_lead_controls(page: Page, lead_id: str) -> list[dict]:
    """Open a lead detail page and dump all clickable controls for inspection.

    Writes the controls to logs/lead_controls_<lead_id>.json and logs each one
    so the operator can identify the real "mark as Contactado" selector to put
    in MARK_CONTACTED_SELECTOR. Read-only — does not change anything.
    """
    import json
    from pathlib import Path

    await _navigate_spa(page, f"{INTERESADOS_URL}/{lead_id}")
    controls: list[dict] = await page.evaluate(_DUMP_CONTROLS_JS)

    Path("logs").mkdir(exist_ok=True)
    out_path = Path("logs") / f"lead_controls_{lead_id}.json"
    out_path.write_text(json.dumps(controls, ensure_ascii=False, indent=2), encoding="utf-8")

    logger.info("Dumped {} controls from lead {} -> {}", len(controls), lead_id, out_path)
    for c in controls:
        # Surface anything that looks status-related at the top of the log.
        blob = f"{c['text']} {c['data_qa']} {c['aria_label']} {c['title']} {c['class']}".lower()
        hot = any(k in blob for k in ("contact", "atend", "pendiente", "estado", "marcar", "gestion"))
        extra = ""
        if c.get("clickable_tag"):
            extra = " -> clickable <{}> class={!r} data-qa={!r}".format(
                c["clickable_tag"], c.get("clickable_class", ""), c.get("clickable_data_qa", ""),
            )
        logger.info(
            "{} <{}> text={!r} data-qa={!r} aria={!r} class={!r}{}",
            "**" if hot else "  ", c["tag"], c["text"], c["data_qa"], c["aria_label"], c["class"], extra,
        )
    return controls


# Finds the per-row status chip ("Pendiente v" dropdown) in the inbox list and
# the menu it opens. The inbox row exposes a status dropdown that changes the
# status IN PLACE without opening the lead or messaging the prospect — unlike
# the detail page, which only flips status on reply.
_FIND_STATUS_CHIPS_JS = """
() => {
    const root = document.getElementById('root') || document.body;
    if (!root) return [];
    const out = [];
    let idx = 0;
    for (const el of root.querySelectorAll('*')) {
        const t = (el.textContent || '').trim();
        if (t !== 'Pendiente') continue;
        if (el.children.length > 2) continue;  // chip leaf (label + maybe chevron)
        let trig = el;
        for (let p = el; p && p !== root; p = p.parentElement) {
            if (p.tagName === 'BUTTON' || p.getAttribute('role') === 'button'
                || p.onclick || getComputedStyle(p).cursor === 'pointer') { trig = p; break; }
        }
        out.push({
            idx,
            text: t,
            chip_tag: el.tagName.toLowerCase(),
            chip_class: (el.className && el.className.toString ? el.className.toString() : '').slice(0, 120),
            trig_tag: trig.tagName.toLowerCase(),
            trig_class: (trig.className && trig.className.toString ? trig.className.toString() : '').slice(0, 120),
            trig_dq: trig.getAttribute('data-qa') || '',
            trig_aria: trig.getAttribute('aria-label') || '',
        });
        idx++;
    }
    return out;
}
"""

# Clicks the Nth "Pendiente" chip trigger (to open its dropdown).
_CLICK_STATUS_CHIP_JS = """
(index) => {
    const root = document.getElementById('root') || document.body;
    let idx = 0;
    for (const el of root.querySelectorAll('*')) {
        const t = (el.textContent || '').trim();
        if (t !== 'Pendiente') continue;
        if (el.children.length > 2) continue;
        if (idx === index) {
            let trig = el;
            for (let p = el; p && p !== root; p = p.parentElement) {
                if (p.tagName === 'BUTTON' || p.getAttribute('role') === 'button'
                    || p.onclick || getComputedStyle(p).cursor === 'pointer') { trig = p; break; }
            }
            trig.click();
            return true;
        }
        idx++;
    }
    return false;
}
"""

# After opening the dropdown, dump the visible menu options (Contactado, etc).
_DUMP_MENU_JS = """
() => {
    const root = document.getElementById('root') || document.body;
    const out = [];
    const seen = new Set();
    for (const el of root.querySelectorAll('[role="menuitem"], [role="option"], li, button, a, span, div')) {
        const t = (el.textContent || '').trim();
        if (!t || t.length > 40) continue;
        // Status-menu candidates: short option-like text near status words.
        if (!/^(Contactado|Pendiente|Descartad|No contestó|No contesto|Cita|Visita|Cerrad|Atendid|Interesad|Apartad)/i.test(t)) continue;
        if (el.children.length > 1) continue;
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) continue;  // visible only
        const key = el.tagName + '|' + t;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({
            tag: el.tagName.toLowerCase(),
            text: t,
            role: el.getAttribute('role') || '',
            data_qa: el.getAttribute('data-qa') || '',
            class: (el.className && el.className.toString ? el.className.toString() : '').slice(0, 100),
        });
    }
    return out;
}
"""


async def dump_status_dropdown(page: Page) -> dict:
    """Inspect the inbox-row status dropdown ("Pendiente v") and its menu options.

    Navigates the Interesados inbox, scans every tab for a Pendiente status chip,
    clicks the first one to open its dropdown, and dumps the menu options that
    appear (e.g. "Contactado"). Read-only — opens the menu but does not select an
    option. Writes logs/status_dropdown.json.
    """
    import json
    from pathlib import Path

    await _navigate_spa(page, INTERESADOS_URL)
    await asyncio.sleep(30)

    result: dict = {"chips_by_tab": {}, "menu": [], "found_tab": None}

    for tab_name, tab_selector in _TABS:
        if tab_selector:
            clicked = await page.evaluate(_CLICK_TAB_JS, tab_selector)
            if not clicked:
                continue
            await asyncio.sleep(30)

        # Screenshot what the scraper actually sees in this tab (parity check
        # vs the operator's own panel — resolves "scraper sees 0 Pendiente").
        try:
            Path("logs").mkdir(exist_ok=True)
            await page.screenshot(path=f"logs/inbox_{tab_name}.png", full_page=True)
        except Exception:
            pass

        chips = await page.evaluate(_FIND_STATUS_CHIPS_JS)
        result["chips_by_tab"][tab_name] = chips
        logger.info("Tab '{}': {} Pendiente status chip(s)", tab_name, len(chips))
        for c in chips:
            logger.info(
                "  chip <{}> class={!r} -> trigger <{}> class={!r} data-qa={!r} aria={!r}",
                c["chip_tag"], c["chip_class"], c["trig_tag"], c["trig_class"], c["trig_dq"], c["trig_aria"],
            )

        if chips and result["found_tab"] is None:
            # Open the first Pendiente dropdown and dump the menu.
            ok = await page.evaluate(_CLICK_STATUS_CHIP_JS, 0)
            logger.info("Clicked first Pendiente chip in tab '{}': {}", tab_name, ok)
            await asyncio.sleep(random.uniform(1.5, 2.5))
            try:
                await page.screenshot(path="logs/status_menu_open.png", full_page=True)
            except Exception:
                pass
            menu = await page.evaluate(_DUMP_MENU_JS)
            result["menu"] = menu
            result["found_tab"] = tab_name
            logger.info("Dropdown menu options ({}):", len(menu))
            for m in menu:
                logger.info(
                    "  ** MENU <{}> text={!r} role={!r} data-qa={!r} class={!r}",
                    m["tag"], m["text"], m["role"], m["data_qa"], m["class"],
                )
            # Close the menu (Escape) so we don't accidentally change anything.
            try:
                await page.keyboard.press("Escape")
            except Exception:
                pass

    Path("logs").mkdir(exist_ok=True)
    (Path("logs") / "status_dropdown.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    logger.info("Wrote logs/status_dropdown.json")
    return result


# Reads the status chip text ("Pendiente"/"Contactado"/"Finalizado") of the
# inbox row whose lead link matches leadId. Read-only.
_READ_CHIP_JS = """
(leadId) => {
    const root = document.getElementById('root') || document.body;
    const re = new RegExp('interesados/' + leadId + '(?:[^0-9]|$)');
    for (const a of root.querySelectorAll('a')) {
        if (!re.test(a.getAttribute('href') || '')) continue;
        let row = a;
        for (let p = a; p && p !== root; p = p.parentElement) {
            if (p.tagName === 'TR' || p.tagName === 'LI' || p.getAttribute('role') === 'row'
                || p.getAttribute('data-qa') || p.getAttribute('data-panel')) { row = p; break; }
        }
        for (const el of row.querySelectorAll('*')) {
            const t = (el.textContent || '').trim();
            if ((t === 'Pendiente' || t === 'Contactado' || t === 'Finalizado')
                && el.children.length <= 2) return t;
        }
        return '_ROW_NO_CHIP_';
    }
    return '_LEAD_NOT_FOUND_';
}
"""

# Tags the status chip of the inbox row matching leadId with data-byg-click so
# Playwright can click the ELEMENT (page.click resolves fresh coordinates at
# click time). Clicking by pre-measured bbox coords mis-fired: the virtual list
# re-renders/scrolls between measuring and clicking, and the click landed on a
# DIFFERENT row's chip (seen live 2026-07-03: Roberto's flip opened Liliana's
# dropdown 6 rows up — screenshot logs/mark_unverified_261642856.png).
# el.click() alone does not open this React popover, hence tag + real click.
_TAG_CHIP_JS = """
(leadId) => {
    const root = document.getElementById('root') || document.body;
    for (const el of document.querySelectorAll('[data-byg-click]')) el.removeAttribute('data-byg-click');
    const re = new RegExp('interesados/' + leadId + '(?:[^0-9]|$)');
    for (const a of root.querySelectorAll('a')) {
        if (!re.test(a.getAttribute('href') || '')) continue;
        let row = a;
        for (let p = a; p && p !== root; p = p.parentElement) {
            if (p.tagName === 'TR' || p.tagName === 'LI' || p.getAttribute('role') === 'row'
                || p.getAttribute('data-qa') || p.getAttribute('data-panel')) { row = p; break; }
        }
        let chip = null;
        for (const el of row.querySelectorAll('*')) {
            const t = (el.textContent || '').trim();
            if ((t === 'Pendiente' || t === 'Contactado' || t === 'Finalizado')
                && el.children.length <= 2) { chip = el; break; }
        }
        if (!chip) return { found: false, reason: 'no_chip' };
        let target = chip;
        for (let p = chip; p && p !== row; p = p.parentElement) {
            if (p.tagName === 'BUTTON' || p.getAttribute('role') === 'button'
                || getComputedStyle(p).cursor === 'pointer') { target = p; break; }
        }
        target.setAttribute('data-byg-click', 'chip');
        return { found: true, text: (chip.textContent || '').trim() };
    }
    return { found: false, reason: 'no_lead' };
}
"""

# Tags the option labelled `label` inside the open "Estado de consulta" popover
# (the container that holds Pendiente + Contactado + Finalizado) with
# data-byg-click so Playwright can click the element itself.
_TAG_OPTION_JS = """
(label) => {
    for (const el of document.querySelectorAll('[data-byg-click]')) el.removeAttribute('data-byg-click');
    for (const c of document.querySelectorAll('div, ul, section, [role="menu"], [role="listbox"], [role="dialog"]')) {
        const txt = c.textContent || '';
        if (!/Estado de consulta/i.test(txt)
            && !(/Pendiente/.test(txt) && /Finalizado/.test(txt))) continue;
        const r0 = c.getBoundingClientRect();
        if (r0.width === 0 || r0.height === 0) continue;
        for (const el of c.querySelectorAll('*')) {
            if ((el.textContent || '').trim() !== label) continue;
            if (el.children.length > 1) continue;
            const r = el.getBoundingClientRect();
            if (r.width === 0 || r.height === 0) continue;
            el.setAttribute('data-byg-click', 'option');
            return { found: true };
        }
    }
    return { found: false };
}
"""


async def mark_lead_contacted(page: Page, lead: dict) -> bool:
    """Set a scraped lead's Inmuebles24 status to *Contactado* via the inbox
    row's "Estado de consulta" dropdown (Pendiente / Contactado / Finalizado).

    This changes the portal status WITHOUT messaging the prospect — it just
    selects the "Contactado" radio in the per-row status dropdown, exactly what
    a human does by hand. (The earlier reply-based approach was wrong: replying
    in the chat is the only OTHER way to flip status, but it contacts the lead.)

    Gated by the MARK_CONTACTED env var (set to 1) so it is a no-op until
    explicitly enabled. Never raises — a failure here must not break the run
    (the lead stays in local dedup regardless). Returns True if the lead is
    Contactado afterwards.
    """
    import os

    if os.environ.get("MARK_CONTACTED", "").strip().lower() not in ("1", "true", "yes"):
        logger.debug("MARK_CONTACTED not enabled — skipping portal status change")
        return False

    lead_id = str(lead.get("lead_id") or "").strip()
    if not lead_id:
        return False
    tab = lead.get("source_tab", "mensajes")
    tab_selector = dict(_TABS).get(tab)

    # The click sequence is flaky (~1 in 3 attempts leaves the chip unchanged —
    # the virtual list can re-render between measuring the chip and clicking).
    # Retry with a fresh navigation; a second attempt has been seen to succeed
    # where the first failed (lead 261605185, 2026-07-02).
    for attempt in (1, 2, 3):
        try:
            await _navigate_spa(page, INTERESADOS_URL)
            await asyncio.sleep(random.uniform(3.0, 5.0))

            # The lead lives under its source tab (mensajes/telefono/whatsapp).
            if tab_selector:
                await page.evaluate(_CLICK_TAB_JS, tab_selector)
                await asyncio.sleep(random.uniform(3.0, 5.0))

            current = await page.evaluate(_READ_CHIP_JS, lead_id)
            if current in ("Contactado", "Finalizado"):
                if attempt == 1:
                    logger.info("Lead {} already '{}' on portal — no change", lead_id, current)
                else:
                    logger.info("Lead {} status -> Contactado via dropdown: OK on attempt {}",
                                lead_id, attempt)
                return True
            if current != "Pendiente":
                # No chip to click (brand-new rows render without one for a
                # while). The cross-run retry in main() picks it up later.
                logger.warning("Lead {}: status chip not found ({}) — not marked", lead_id, current)
                return False

            # Open the status dropdown: tag THIS row's chip, then let Playwright
            # click the tagged element — it resolves the position at click time,
            # so a list re-render/scroll can no longer land the click on another
            # row (el.click() alone does not trigger this React popover).
            chip = await page.evaluate(_TAG_CHIP_JS, lead_id)
            if not chip.get("found"):
                logger.warning("Lead {}: status chip not located ({}) — attempt {}/3",
                               lead_id, chip.get("reason"), attempt)
                continue
            await page.click('[data-byg-click="chip"]', timeout=8_000)
            await asyncio.sleep(random.uniform(1.0, 1.6))

            # Click the "Contactado" option in the open popover (same tag trick).
            opt = await page.evaluate(_TAG_OPTION_JS, "Contactado")
            if not opt.get("found"):
                logger.warning("Lead {}: 'Contactado' option not visible after opening dropdown"
                               " — attempt {}/3", lead_id, attempt)
                try:
                    await page.screenshot(path=f"logs/mark_fail_{lead_id}.png", full_page=True)
                except Exception:
                    pass
                try:
                    await page.keyboard.press("Escape")
                except Exception:
                    pass
                continue
            await page.click('[data-byg-click="option"]', timeout=8_000)
            await asyncio.sleep(random.uniform(2.0, 3.0))

            # Verify the row chip now reads Contactado.
            after = await page.evaluate(_READ_CHIP_JS, lead_id)
            if after == "Contactado":
                logger.info("Lead {} status -> Contactado via dropdown: OK (attempt {})",
                            lead_id, attempt)
                return True
            logger.warning("Lead {} status -> Contactado via dropdown: UNVERIFIED"
                           " (now '{}', attempt {}/3)", lead_id, after, attempt)
            if attempt == 3:
                try:
                    await page.screenshot(path=f"logs/mark_unverified_{lead_id}.png", full_page=True)
                except Exception:
                    pass
        except Exception as e:
            logger.warning("Lead {}: failed to set Contactado via dropdown (attempt {}/3): {}",
                           lead_id, attempt, e)
    return False


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


async def send_to_webhook(leads: list[dict], webhook_url: str = "") -> None:
    """POST lead data to webhook with exponential backoff retry."""
    url = webhook_url or _DEFAULT_WEBHOOK_URL
    if not url:
        raise ValueError("WEBHOOK_URL not configured — set it in .env")
    last_err: Exception | None = None

    async with httpx.AsyncClient(timeout=30) as client:
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                resp = await client.post(url, json=leads)
                resp.raise_for_status()
                logger.info(
                    "Webhook response: {} {} (attempt {})",
                    resp.status_code, resp.reason_phrase, attempt,
                )
                return
            except Exception as e:
                last_err = e
                if attempt < MAX_RETRIES:
                    delay = RETRY_BASE_DELAY * (2 ** (attempt - 1))
                    logger.warning(
                        "Webhook attempt {}/{} failed: {} — retrying in {:.1f}s",
                        attempt, MAX_RETRIES, e, delay,
                    )
                    await asyncio.sleep(delay)

    logger.error("Webhook failed after {} attempts: {}", MAX_RETRIES, last_err)
    raise last_err  # type: ignore[misc]


# ---------------------------------------------------------------------------
# 5. Orchestrator
# ---------------------------------------------------------------------------


async def scrape_pendiente_leads(page: Page, *, limit: int = 0) -> list[dict]:
    """Extract all Pendiente leads (with full detail) from the Interesados inbox.

    Returns all extracted leads (before dedup). The caller handles dedup via
    StateStore and is responsible for sending only the new leads to the webhook —
    this keeps the scraper from re-posting a lead that stays Pendiente on the
    portal across runs.

    If ``limit`` > 0, only the first ``limit`` Pendiente leads are detail-scraped
    (useful for a controlled single-lead test run).
    Includes session staleness detection and screenshot capture on failures.
    """
    # Step 1: Get Pendiente leads from the inbox.
    pendiente_leads = await extract_leads_list(page)

    # Check for stale session after navigation.
    if _is_session_stale(page.url):
        await _screenshot_on_error(page, "stale_session")
        raise SessionStaleError(
            f"Session appears stale (url={page.url}). Re-authentication required."
        )

    if not pendiente_leads:
        logger.warning("No Pendiente leads found — nothing to extract")
        return []

    # The same lead shows up in several inbox tabs (mensajes / telefono /
    # whatsapp). Detail-scrape each lead_id only once: the duplicate open races
    # the SPA and can produce a half-loaded copy with no phone, which then wins
    # the downstream per-lead_id dedup and drops the good copy.
    seen_ids: set[str] = set()
    unique_leads: list[dict] = []
    for lead in pendiente_leads:
        lid = str(lead.get("lead_id") or "").strip()
        if lid:
            if lid in seen_ids:
                continue
            seen_ids.add(lid)
        unique_leads.append(lead)
    if len(unique_leads) < len(pendiente_leads):
        logger.info(
            "Deduped {} duplicate tab row(s) ({} unique leads)",
            len(pendiente_leads) - len(unique_leads), len(unique_leads),
        )
    pendiente_leads = unique_leads

    if limit and limit > 0 and len(pendiente_leads) > limit:
        logger.info(
            "Limiting to first {} of {} Pendiente lead(s)",
            limit, len(pendiente_leads),
        )
        pendiente_leads = pendiente_leads[:limit]

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
            try:
                detail = await extract_lead_detail(page, lead_id)
                if detail:
                    merged = {**lead, **detail}
                    results.append(merged)
            except Exception as e:
                await _screenshot_on_error(page, f"lead_{lead_id}")
                logger.error(
                    "Failed to extract detail for lead {} — skipping: {}",
                    lead_id, e,
                )
    else:
        # Strategy 2: click each Pendiente row
        logger.info("No lead URLs found — using click-based navigation")
        for i, lead in enumerate(pendiente_leads):
            click_idx = lead.get("_click_index", i)
            logger.info(
                "Clicking lead {}/{}: {}",
                i + 1, len(pendiente_leads), lead.get("name", "?"),
            )
            try:
                detail = await _extract_lead_by_click(page, click_idx)
                if detail:
                    merged = {**lead, **detail}
                    merged.pop("_click_index", None)
                    results.append(merged)
            except Exception as e:
                await _screenshot_on_error(page, f"click_{click_idx}")
                logger.error("Failed click-nav for lead index {} — skipping: {}", click_idx, e)

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

    return results
