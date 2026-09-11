"""Write the internal note in the Inmuebles24 conversation after the auction outcome.

The team used to type "Nota interna: <nombre>" by hand once a lead had an owner.
`i24_note_ledger` (migration 20260913100000) turns that into a leased job; this
worker is the hand that types it, once per scraper run, on the same logged-in
browser that already flips the status to Contactado.

Selectors are provisional until docs/i24-notas-selectors.md is written from a
real DOM dump — keep every one of them in this block so the fix is one edit.
"""
from __future__ import annotations

import re

from loguru import logger

from .scraper import INTERESADOS_URL, _navigate_spa

NOTES_TAB_SELECTORS = ("role=tab[name='Notas']", "text=/^\\s*Notas\\s*$/")
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


async def run_v3_i24_note_worker(page, supa, *, evidence=None, limit: int = 10) -> int:
    """Drain the leased note queue on this run's browser. Returns notes written."""
    written = 0
    for claim in await supa.claim_v3_i24_notes(limit):
        lead_id = str(claim.get("i24_lead_id") or "")
        try:
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
