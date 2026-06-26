"""Buzón actions: set a contact_request to "Atendida" and add an agent note.

Selectors are label/text based (derived from the live Buzón UI) because EB's
markup carries few stable data attributes. `dump_buzon` captures the action bar,
status menu and note modal so selectors can be re-confirmed after any UI change.
"""
from __future__ import annotations

import asyncio
import json
import random
import re
from pathlib import Path

from loguru import logger
from playwright.async_api import Page

from easybroker.auth import APP_URL, _navigate_render
from easybroker.browser import screenshot, wait_for_spa

BUZON_URL = f"{APP_URL}/agent/conversations?reset_page=true"

# Status options in the "Cambiar estatus" dropdown.
STATUS_LABELS = ("Sin atender", "Atendida", "Archivada", "Spam")


def _norm_phone(phone: str) -> str:
    """Keep digits only, drop a leading Mexico country code for loose matching."""
    digits = re.sub(r"\D", "", phone or "")
    if len(digits) > 10 and digits.startswith("52"):
        digits = digits[-10:]
    return digits[-10:] if len(digits) >= 10 else digits


async def goto_buzon(page: Page) -> bool:
    """Navigate to the Buzón inbox (/agent/conversations). Returns True if it rendered."""
    ok = await _navigate_render(page, BUZON_URL)
    await asyncio.sleep(random.uniform(1.0, 2.0))
    return ok


# Find a conversation anchor whose row digits end with the target (last 10).
# Digit-normalised so "55 4185 3995", "+52 55…", etc. all match.
_FIND_CONV_HREF_JS = """
(target) => {
    const norm = (s) => (s || '').replace(/\\D/g, '');
    for (const a of document.querySelectorAll('a')) {
        const h = a.getAttribute('href') || '';
        if (!/conversations\\/\\d+/.test(h)) continue;
        for (let p = a; p && p.tagName !== 'BODY'; p = p.parentElement) {
            if (norm(p.innerText).endsWith(target)) return h;
        }
    }
    return '';
}
"""


async def _open_conv_href(page: Page, href: str) -> bool:
    url = href if href.startswith("http") else f"{APP_URL}{href}"
    rendered = await _navigate_render(page, url)
    await asyncio.sleep(random.uniform(1.0, 2.0))
    return rendered


async def find_request_by_phone(page: Page, phone: str) -> bool:
    """Open the Buzón conversation for `phone`. Returns True if opened.

    The Buzón holds tens of thousands of conversations, so a target lead is
    almost never on the default (recent) page. Use the Buzón search field
    ("Busca por nombre, email o teléfono") to filter to the match, then open it.
    Falls back to scanning the currently-visible rows.
    """
    target = _norm_phone(phone)
    if not target:
        return False

    # Search first (the visible list only holds recent conversations).
    digits = re.sub(r"\D", "", phone or "")
    for query in (digits, target):
        try:
            box = page.get_by_placeholder(re.compile("Busca por", re.I)).first
            if await box.count() == 0:
                break
            await box.fill("")
            await box.fill(query)
            await box.press("Enter")
            await asyncio.sleep(random.uniform(3.0, 4.0))
            href = await page.evaluate(_FIND_CONV_HREF_JS, target)
            if href:
                return await _open_conv_href(page, href)
        except Exception as e:
            logger.warning("Buzón search for {!r} failed: {}", query, e)

    # Fallback: scan whatever rows are currently rendered.
    href = await page.evaluate(_FIND_CONV_HREF_JS, target)
    if href:
        return await _open_conv_href(page, href)
    return False


# The action-bar controls are <a>/<span> (not <button>) and the status options
# live in a hidden "Cambiar estatus" dropdown that only renders visible after the
# trigger is clicked. We tag the precise target in JS, then click it with a real
# Playwright input event (more reliable than el.click() against React handlers).

_BOT_ATTR = "data-eb-bot"

# Find the VISIBLE action-bar status control (its text is the current status).
# The dropdown options are hidden (width/height 0) so the visible filter selects
# only the trigger.
_TAG_STATUS_TRIGGER_JS = """
() => {
    const labels = ['Sin atender','Atendida','Archivada','Spam'];
    for (const el of document.querySelectorAll('span,div,a,button')) {
        if (el.children.length > 0) continue;           // leaf text node
        const t = (el.textContent || '').trim();
        if (!labels.includes(t)) continue;
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) continue;  // visible -> the trigger
        let c = el;
        for (let p = el; p && p !== document.body; p = p.parentElement) {
            const cs = getComputedStyle(p);
            if (p.tagName === 'A' || p.tagName === 'BUTTON' || p.onclick || cs.cursor === 'pointer') { c = p; break; }
        }
        c.setAttribute('data-eb-bot', 'status-trigger');
        return t;                                       // current status label
    }
    return null;
}
"""

# After the dropdown opens, tag the option inside the "Cambiar estatus" menu.
_TAG_STATUS_OPTION_JS = """
(label) => {
    for (const el of document.querySelectorAll('span,div,a,button')) {
        if (el.children.length > 0) continue;
        if ((el.textContent || '').trim() !== label) continue;
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) continue;  // now-visible menu option
        let inMenu = false;
        for (let p = el.parentElement; p; p = p.parentElement) {
            const tc = p.textContent || '';
            if (tc.includes('Sin atender') && tc.includes('Archivada') && tc.includes('Spam')) { inMenu = true; break; }
        }
        if (!inMenu) continue;                          // skip the trigger itself
        let c = el;
        for (let p = el; p && p !== document.body; p = p.parentElement) {
            const cs = getComputedStyle(p);
            if (p.tagName === 'A' || p.tagName === 'BUTTON' || p.onclick || cs.cursor === 'pointer') { c = p; break; }
        }
        c.setAttribute('data-eb-bot', 'status-option');
        return true;
    }
    return false;
}
"""

# Tag the visible "Agregar nota" action (span.conv-action-name), not the hidden
# dropdown-item duplicate inside the "Opciones" menu.
_TAG_AGREGAR_NOTA_JS = """
() => {
    for (const el of document.querySelectorAll('span,a,button,div')) {
        if ((el.textContent || '').trim() !== 'Agregar nota') continue;
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) continue;  // the visible action only
        let c = el;
        for (let p = el; p && p !== document.body; p = p.parentElement) {
            const cs = getComputedStyle(p);
            if (p.tagName === 'A' || p.tagName === 'BUTTON' || p.onclick || cs.cursor === 'pointer') { c = p; break; }
        }
        c.setAttribute('data-eb-bot', 'agregar-nota');
        return true;
    }
    return false;
}
"""


async def _clear_tag(page: Page, value: str) -> None:
    await page.evaluate(
        "(v) => document.querySelectorAll('['+'data-eb-bot'+'=\"'+v+'\"]').forEach(e => e.removeAttribute('data-eb-bot'))",
        value,
    )


async def _current_status(page: Page) -> str | None:
    """Return the status label currently shown on the action-bar status control."""
    try:
        return await page.evaluate(_TAG_STATUS_TRIGGER_JS)
    finally:
        await _clear_tag(page, "status-trigger")


async def set_status_atendida(page: Page) -> bool:
    """Open the 'Cambiar estatus' dropdown and select 'Atendida'. Idempotent."""
    current = await page.evaluate(_TAG_STATUS_TRIGGER_JS)
    if current is None:
        await screenshot(page, "status_trigger_not_found")
        logger.error("Could not find the action-bar status control")
        return False
    if current == "Atendida":
        await _clear_tag(page, "status-trigger")
        logger.info("Status already 'Atendida' — skipping")
        return True

    await page.locator(f'[{_BOT_ATTR}="status-trigger"]').first.click()
    await _clear_tag(page, "status-trigger")
    await asyncio.sleep(random.uniform(0.6, 1.2))

    tagged = await page.evaluate(_TAG_STATUS_OPTION_JS, "Atendida")
    if not tagged:
        await screenshot(page, "status_atendida_option_missing")
        logger.error("Could not find 'Atendida' option in the open dropdown")
        return False
    await page.locator(f'[{_BOT_ATTR}="status-option"]').first.click()
    await _clear_tag(page, "status-option")

    await asyncio.sleep(random.uniform(1.0, 2.0))
    new_status = await _current_status(page)
    ok = new_status == "Atendida"
    logger.info("Status after set: {!r} (ok={})", new_status, ok)
    return ok


async def add_note(page: Page, note_text: str) -> bool:
    """Click 'Agregar nota', type the note, and save."""
    tagged = await page.evaluate(_TAG_AGREGAR_NOTA_JS)
    if not tagged:
        await screenshot(page, "agregar_nota_button_missing")
        logger.error("Could not find the 'Agregar nota' action")
        return False
    await page.locator(f'[{_BOT_ATTR}="agregar-nota"]').first.click()
    await _clear_tag(page, "agregar-nota")
    await asyncio.sleep(random.uniform(0.7, 1.3))

    # Modal textarea (placeholder "Escribe una nota").
    try:
        area = page.get_by_placeholder(re.compile("Escribe una nota", re.I)).first
        if await area.count() == 0:
            area = page.locator("textarea").first
        await area.wait_for(state="visible", timeout=6_000)
        await area.fill(note_text)
    except Exception as e:
        await screenshot(page, "nota_textarea_missing")
        logger.error("Could not fill the note textarea: {}", e)
        return False

    await asyncio.sleep(random.uniform(0.4, 0.9))
    try:
        save = page.get_by_role("button", name=re.compile("^Guardar$", re.I)).first
        if await save.count() == 0:
            save = page.get_by_text(re.compile("^Guardar$", re.I)).first
        await save.wait_for(state="visible", timeout=6_000)
        await save.click()
    except Exception as e:
        await screenshot(page, "nota_guardar_missing")
        logger.error("Could not click 'Guardar' on the note: {}", e)
        return False

    await asyncio.sleep(random.uniform(1.0, 2.0))
    logger.info("Note saved: {!r}", note_text)
    return True


async def attend_lead(
    page: Page, *, phone: str, agent_name: str, note_text: str | None = None
) -> dict:
    """Full flow for one lead: open request, set Atendida, add the agent note.

    Returns {found, status_ok, note_ok}. The caller should treat the lead as
    attended only when status_ok AND note_ok are both True.
    """
    note = note_text or f"Atendido por {agent_name}"
    result = {"found": False, "status_ok": False, "note_ok": False}

    if not await goto_buzon(page):
        await screenshot(page, "buzon_no_render")
        logger.error("Buzón did not render — skipping lead {} this run", phone)
        return result
    found = await find_request_by_phone(page, phone)
    result["found"] = found
    if not found:
        await screenshot(page, f"request_not_found_{_norm_phone(phone)}")
        logger.error("Could not find Buzón request for phone {}", phone)
        return result

    result["status_ok"] = await set_status_atendida(page)
    result["note_ok"] = await add_note(page, note)
    return result


# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

async def dump_buzon(page: Page, phone: str | None = None) -> dict:
    """Open the Buzón (optionally select a phone's request) and dump controls.

    Writes logs/eb_buzon_controls.json + a screenshot so the action-bar buttons,
    status menu and note modal selectors can be confirmed. Read-only.
    """
    await goto_buzon(page)
    selected = False
    if phone:
        selected = await find_request_by_phone(page, phone)
        logger.info("dump_buzon: request for {} selected={}", phone, selected)

    controls = await page.evaluate(
        """() => {
            const out = [];
            const root = document.querySelector('#root') || document.body;
            for (const el of root.querySelectorAll('button, a, [role="button"], [role="menuitem"], textarea, input, select')) {
                const r = el.getBoundingClientRect();
                if (r.width === 0 || r.height === 0) continue;
                const t = (el.innerText || el.value || '').trim().slice(0, 50);
                out.push({
                    tag: el.tagName.toLowerCase(),
                    role: el.getAttribute('role') || '',
                    type: el.getAttribute('type') || '',
                    placeholder: el.getAttribute('placeholder') || '',
                    data_qa: el.getAttribute('data-qa') || '',
                    text: t,
                });
            }
            return out;
        }"""
    )
    Path("logs").mkdir(exist_ok=True)
    Path("logs/eb_buzon_controls.json").write_text(
        json.dumps({"selected": selected, "controls": controls}, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    await screenshot(page, "buzon")
    logger.info("Dumped {} Buzón controls -> logs/eb_buzon_controls.json", len(controls))
    return {"selected": selected, "count": len(controls)}
