"""Write the internal note in the Inmuebles24 conversation after the auction outcome.

Since 2026-10-13 the queue holds only Tokko leads taken with TOMO: the worker first
flips the conversation to Contactado, then types the note.

The team used to type "Nota interna: <nombre>" by hand once a lead had an owner.
`i24_note_ledger` (migration 20260913100000) turns that into a leased job; this
worker is the hand that types it, once per scraper run, on the same logged-in
browser that already flips the status to Contactado.

Selectors verified against the live DOM on 2026-09-11 (docs/i24-notas-selectors.md);
keep every one of them in this block so a portal change is one edit.
"""
from __future__ import annotations

import re

from loguru import logger

from .scraper import INTERESADOS_URL, _navigate_spa, mark_lead_contacted

# The tab is a plain <button><div><span>Notas</span></div></button>: no role, no id.
NOTES_TAB_SELECTORS = ("text=/^\\s*Notas\\s*$/",)
NOTE_INPUT = "textarea[placeholder^='Escribí una nota interna']"
NOTE_SUBMIT = "button:has-text('Anotar')"
NOTE_ROW_TEMPLATE = "text=/^\\s*Nota interna:\\s*{text}\\s*$/"


async def write_internal_note(
    page, lead_id: str, text: str, *, evidence=None
) -> dict:
    """Type one internal note on a lead's conversation and verify it rendered.

    Portal errors propagate: the worker owns the retry budget, not this helper.
    """
    url = f"{INTERESADOS_URL}/{lead_id}"
    result = {"ok": False, "already": False, "reason": None, "url": url}

    async def fail(reason: str) -> dict:
        result["reason"] = reason
        if evidence is not None:
            result["screenshot_path"] = await evidence(page, lead_id)
        return result

    await _navigate_spa(page, url)

    row = NOTE_ROW_TEMPLATE.format(text=re.escape(text))
    if await page.locator(row).count() > 0:
        # The lease can be replayed after a crash; the portal has no undo.
        result.update(ok=True, already=True)
        return result

    for selector in NOTES_TAB_SELECTORS:
        if await page.locator(selector).count() > 0:
            await page.click(selector)
            break
    else:
        return await fail("notes_tab_not_found")

    await page.fill(NOTE_INPUT, text)
    await page.wait_for_timeout(500)
    if await page.is_disabled(NOTE_SUBMIT):
        return await fail("submit_disabled")

    await page.click(NOTE_SUBMIT)
    await page.wait_for_timeout(1_500)
    if await page.locator(row).count() == 0:
        return await fail("note_not_visible")

    result["ok"] = True
    return result


def _digits10(value) -> str:
    return re.sub(r"\D", "", str(value or ""))[-10:]


def pair_tokko_leads(opportunities: list[dict], rows: list[dict]) -> list[tuple[int, str]]:
    """Pair each Tokko opportunity with exactly one i24 inbox conversation.

    Same listing (i24 id or EB code) AND same email or 10-digit phone. Zero or
    several candidates pair nothing: a missing mark beats marking the wrong lead.
    """
    pairs = []
    for opp in opportunities:
        email = str(opp.get("email") or "").strip().lower()
        phone = _digits10(opp.get("phone"))
        listing = str(opp.get("listing_id") or "")
        code = str(opp.get("property_public_id") or "").strip().upper()
        hits = {
            str(row["lead_id"]) for row in rows
            if ((listing and str(row.get("listing_id") or "") == listing)
                or (code and str(row.get("property_public_id") or "").upper() == code))
            and ((email and str(row.get("email") or "").strip().lower() == email)
                 or (len(phone) == 10 and _digits10(row.get("phone")) == phone))
        }
        if len(hits) == 1:
            pairs.append((int(opp["opportunity_id"]), hits.pop()))
    return pairs


async def run_v3_i24_note_worker(page, supa, *, evidence=None, limit: int = 10) -> int:
    """Drain the leased queue: Contactado first, then the note. Returns notes written."""
    written = 0
    for claim in await supa.claim_v3_i24_notes(limit):
        lead_id = str(claim.get("i24_lead_id") or "")
        try:
            status: dict = {}
            # A Finalizado conversation was closed by hand: keep it, still note it.
            contacted = await mark_lead_contacted(page, {"lead_id": lead_id}, evidence=status)
            if not contacted and status.get("error_code") != "unexpected_terminal_status":
                result = {"ok": False, "reason": f"contactado:{status.get('error_code')}"}
            else:
                result = await write_internal_note(
                    page, lead_id, str(claim.get("note_text") or ""), evidence=evidence
                )
        except Exception as exc:
            result = {"ok": False, "reason": f"{type(exc).__name__}: {exc}"[:300]}
        logger.info(
            "V3 nota interna lead {} (opp {}, intento {}): ok={} {}",
            lead_id, claim.get("opportunity_id"), claim.get("attempt"),
            result["ok"], result.get("reason") or "",
        )
        await supa.finish_v3_i24_note(
            claim["opportunity_id"], claim["lease_token"], bool(result["ok"]), result
        )
        written += bool(result["ok"])
    return written
