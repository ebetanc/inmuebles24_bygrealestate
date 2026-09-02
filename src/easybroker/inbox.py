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
import unicodedata
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
    let first = '';
    for (const a of document.querySelectorAll('a')) {
        const h = a.getAttribute('href') || '';
        if (!/conversations\\/\\d+/.test(h)) continue;
        if (!first) first = h;                  // top of the filtered list
        for (let p = a; p && p.tagName !== 'BODY'; p = p.parentElement) {
            if (norm(p.innerText).endsWith(target)) return h;   // exact phone row
        }
    }
    // On a phone-filtered Buzón the rows show the contact's NAME (not the phone),
    // so digit-matching usually misses — fall back to the top (most recent)
    // result, which is this lead's active conversation.
    return first;
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

    # Filter the Buzón server-side via the search_criteria[query] URL param
    # (the EB conversation list is server-rendered with this param). This avoids
    # the visible/hidden search-input ambiguity — under xvfb's narrow viewport EB
    # renders the MOBILE layout, so the desktop search field is hidden.
    digits = re.sub(r"\D", "", phone or "")
    for query in (digits, target):
        url = f"{APP_URL}/agent/conversations?search_criteria%5Bquery%5D={query}&reset_page=true"
        if not await _navigate_render(page, url):
            continue
        await asyncio.sleep(random.uniform(1.5, 2.5))
        href = await page.evaluate(_FIND_CONV_HREF_JS, target)
        if href:
            return await _open_conv_href(page, href)

    # Fallback: type into the VISIBLE search field (mobile or desktop) and scan.
    try:
        box = page.get_by_placeholder(re.compile("Buscar por nombre", re.I)).filter(visible=True).first
        if await box.count() > 0:
            await box.fill(digits)
            await box.press("Enter")
            await asyncio.sleep(random.uniform(3.0, 4.0))
            href = await page.evaluate(_FIND_CONV_HREF_JS, target)
            if href:
                return await _open_conv_href(page, href)
    except Exception as e:
        logger.warning("Buzón input-search fallback failed: {}", e)
    return False


async def find_request_by_id(page: Page, request_id: int | str) -> bool:
    """Open one exact Buzón request by its EasyBroker contact request ID."""
    value = str(request_id).strip()
    if not value.isdigit():
        return False
    rendered = await _open_conv_href(page, f"/agent/conversations/{value}")
    return rendered and bool(re.search(rf"/conversations/{re.escape(value)}(?:[/?#]|$)", page.url))


_FIND_PROPERTY_HREFS_JS = """
(propertyId) => {
    const target = (propertyId || '').trim().toUpperCase();
    const matches = [];
    for (const a of document.querySelectorAll('a')) {
        const href = a.getAttribute('href') || '';
        if (!/conversations\\/\\d+/.test(href)) continue;
        const text = (a.innerText || '').toUpperCase();
        if (!text.includes(target)) continue;
        if (!matches.includes(href)) matches.push(href);
    }
    return matches;
}
"""


async def find_request_by_property_and_identity(
    page: Page, property_id: str, phone: str = "", email: str = "",
) -> bool:
    """Open the only recent Buzón row matching property and lead identity.

    Contact-request IDs returned by EasyBroker's public API are not Buzón
    conversation IDs. New API-created requests do expose the property public ID
    in the recent Buzón row, so resolve that row and verify the phone on its
    detail page. EasyBroker may show a linked contact's phone, so either exact
    email or exact phone is sufficient after the property match. Ambiguous or
    missing matches fail closed.
    """
    property_value = str(property_id or "").strip().upper()
    target_phone = _norm_phone(phone)
    target_email = str(email or "").strip().lower()
    if not property_value or not (target_phone or target_email):
        return False

    hrefs = await page.evaluate(_FIND_PROPERTY_HREFS_JS, property_value)
    verified: list[str] = []
    for href in hrefs:
        if not await _open_conv_href(page, href):
            continue
        body = await page.locator("body").inner_text()
        phone_match = bool(target_phone and target_phone in re.sub(r"\D", "", body))
        email_match = bool(target_email and target_email in body.lower())
        if phone_match or email_match:
            verified.append(href)

    if len(verified) != 1:
        logger.error(
            "Expected one recent Buzón row for property {}, verified {}",
            property_value,
            len(verified),
        )
        return False
    return await _open_conv_href(page, verified[0])


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

# Read the current EasyBroker assignee from the request details.  This is a
# separate source of truth from our timeline notes: a human can take a request
# in EasyBroker before the routing worker writes its note.
_READ_ASSIGNEE_JS = r"""
() => {
    const visible = (el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
    };
    const clean = (value) => (value || '').replace(/\s+/g, ' ').trim();
    const candidates = [];
    let labels = 0;
    let unassignedMarkers = 0;
    for (const el of document.querySelectorAll('span,div,p,label')) {
        if (el.children.length > 0 || clean(el.textContent) !== 'Asignada a' || !visible(el)) continue;
        labels += 1;
        let parent = el.parentElement;
        for (let depth = 0; parent && depth < 4; depth += 1, parent = parent.parentElement) {
            const lines = (parent.innerText || '').split('\n').map(clean).filter(Boolean);
            const index = lines.findIndex((line) => line === 'Asignada a');
            if (index >= 0 && index + 1 < lines.length) {
                const candidate = lines[index + 1];
                if (['Sin asignar','No asignada','Asignar','Asignar a','Asignada a'].includes(candidate)) {
                    unassignedMarkers += 1;
                } else if (!['Fuente','Estatus'].includes(candidate)) {
                    candidates.push(candidate);
                }
                break;
            }
        }
    }
    const unique = [...new Set(candidates)];
    if (unique.length === 1) return { verified: true, assignee: unique[0] };
    if (unique.length > 1) return { verified: false, assignee: null };
    const explicitlyUnassigned = [...document.querySelectorAll('a,button,[role="button"]')]
        .some((el) => visible(el) && ['Asignada a','Sin asignar','No asignada','Asignar','Asignar a']
            .includes(clean(el.textContent)));
    if (labels > 0 && (unassignedMarkers > 0 || explicitlyUnassigned)) {
        return { verified: true, assignee: '' };
    }
    return { verified: false, assignee: null };
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
    ok = await note_exists(page, note_text)
    logger.info("Note saved: {!r} (ok={})", note_text, ok)
    return ok


async def note_exists(page: Page, note_text: str) -> bool:
    """Return whether the exact bot note is already visible in this request."""
    try:
        return await page.get_by_text(note_text, exact=True).count() > 0
    except Exception as e:
        logger.warning("Could not verify existing EasyBroker note: {}", e)
        return False


async def read_easybroker_assignee(page: Page) -> str | None:
    """Return assignee name, ``""`` when unassigned, or ``None`` if unverifiable."""
    try:
        result = await page.evaluate(_READ_ASSIGNEE_JS)
        if not isinstance(result, dict) or result.get("verified") is not True:
            return None
        return str(result.get("assignee") or "").strip()
    except Exception as e:
        logger.warning("Could not verify EasyBroker assignee: {}", e)
        return None


def _normalized_first_name(value: str) -> str:
    compact = " ".join((value or "").split())
    decomposed = unicodedata.normalize("NFKD", compact)
    folded = "".join(char for char in decomposed if not unicodedata.combining(char)).casefold()
    return folded.split(" ", 1)[0] if folded else ""


_RESPONSIBLE_NOTE_RE = re.compile(r"^\s*RESPONSABLE\s*:\s*(\S(?:.*\S)?)\s*$", re.I)


def _responsible_from_note(note_text: str) -> str | None:
    match = _RESPONSIBLE_NOTE_RE.fullmatch(note_text or "")
    return " ".join(match.group(1).split()).casefold() if match else None


async def find_responsible_notes(page: Page) -> list[str] | None:
    """Return visible RESPONSABLE notes, or None when they cannot be verified."""
    try:
        texts = await page.get_by_text(_RESPONSIBLE_NOTE_RE).all_inner_texts()
        return sorted({text.strip() for text in texts if _responsible_from_note(text)})
    except Exception as e:
        logger.warning("Could not verify EasyBroker responsible notes: {}", e)
        return None


async def attend_lead(
    page: Page, *, request_id: int | str | None = None, phone: str = "",
    email: str = "", property_id: str = "",
    agent_name: str, note_text: str | None = None, note_done: bool = False,
    status_done: bool = False, allow_phone_fallback: bool = False,
    allow_legacy_note: bool = True,
) -> dict:
    """Full flow for one lead: open request, set Atendida, add the agent note.

    Exact request ID is primary. Phone fallback must be explicitly enabled.
    Completed steps are skipped so retries only repeat missing side effects.
    """
    note = note_text or f"RESPONSABLE: {agent_name}"
    legacy_note = f"Atendido por {agent_name}"
    if request_id is not None:
        legacy_note = f"{legacy_note} [BYG-EB:{str(request_id).strip()}]"
    result = {
        "found": False,
        "match_method": None,
        "status_ok": status_done,
        "note_ok": note_done,
        "status_changed": False,
        "note_changed": False,
    }

    if not await goto_buzon(page):
        await screenshot(page, "buzon_no_render")
        logger.error("Buzón did not render — skipping lead {} this run", phone)
        return result
    found = False
    if property_id:
        found = await find_request_by_property_and_identity(page, property_id, phone, email)
        if found:
            result["match_method"] = "property+identity"
    elif request_id is not None:
        found = await find_request_by_id(page, request_id)
        if found:
            result["match_method"] = "request_id"
    if not found and allow_phone_fallback:
        found = await find_request_by_phone(page, phone)
        if found:
            result["match_method"] = "phone_fallback"
    result["found"] = found
    if not found:
        await screenshot(page, f"request_not_found_{request_id or _norm_phone(phone)}")
        logger.error("Could not find Buzón request id={} (phone fallback={})", request_id, allow_phone_fallback)
        return result

    # EasyBroker auto-assigns the property's agent to every request, so the
    # assignee is evidence only: the V3 RESPONSABLE note always wins.
    result["easybroker_assignee"] = await read_easybroker_assignee(page)

    expected_responsible = _responsible_from_note(note)
    expected_responsible_key = _normalized_first_name(expected_responsible or "")
    existing_responsible_notes: list[str] | None = []
    if expected_responsible:
        existing_responsible_notes = await find_responsible_notes(page)
        if existing_responsible_notes is None:
            result.update(
                error_code="responsible_note_check_failed",
                expected_responsible_note=note,
                existing_responsible_notes=None,
            )
            return result
        conflicting_notes = [
            existing for existing in existing_responsible_notes
            if _normalized_first_name(_responsible_from_note(existing) or "")
            != expected_responsible_key
        ]
        if conflicting_notes:
            result.update(
                error_code="responsible_note_conflict",
                expected_responsible_note=note,
                existing_responsible_notes=existing_responsible_notes,
            )
            logger.error(
                "EasyBroker responsible conflict: expected={!r} existing={!r}; manual review required",
                note, existing_responsible_notes,
            )
            return result

    if not note_done:
        # The exact request page scopes idempotency. If the process died after
        # Guardar but before Supabase evidence, reconcile the visible note
        # without writing a duplicate.
        result["note_ok"] = bool(
            expected_responsible
            and any(_normalized_first_name(_responsible_from_note(existing) or "")
                    == expected_responsible_key
                    for existing in existing_responsible_notes)
        ) or await note_exists(page, note)
        if not result["note_ok"] and allow_legacy_note:
            # Reconcile any pre-migration note without adding a second one.
            result["note_ok"] = await note_exists(page, legacy_note)
        if not result["note_ok"]:
            result["note_ok"] = await add_note(page, note)
        result["note_changed"] = result["note_ok"]
    if result["note_ok"] and not status_done:
        result["status_ok"] = await set_status_atendida(page)
        result["status_changed"] = result["status_ok"]
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
