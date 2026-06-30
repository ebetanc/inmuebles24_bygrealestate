"""Write an internal advisor note on an Inmuebles24 lead (Notas tab).

EasyBroker has its own note-back bot (src/easybroker); this is the Inmuebles24
equivalent. The lead's "Notas" tab holds INTERNAL notes (not shared with the
prospect), so this is how we record which advisor was assigned to a scraped lead.

Selectors validated live 2026-06-30 against panel/interesados/<id>:
  - tab button text  "Notas"
  - textarea         placeholder "Escribí una nota interna. No será compartida con tu contacto"
  - save button text "Anotar"

Standalone test:
    python -m inmobiliaria24.notes <lead_id> "<note text>"
"""
from __future__ import annotations

import asyncio
import sys

from loguru import logger
from playwright.async_api import Page, async_playwright

from inmobiliaria24.scraper import _navigate_spa, _screenshot_on_error, INTERESADOS_URL

# Returns the viewport-center coords of the first leaf element whose trimmed text
# equals `want`, walking up to its clickable ancestor (button/role=button/pointer).
_COORD_BY_TEXT_JS = r"""
(want) => {
  const root = document.getElementById('root') || document.body;
  for (const el of root.querySelectorAll('button,[role=button],span,div,a')) {
    const t = (el.textContent || '').trim();
    if (t !== want || el.children.length > 1) continue;
    let trig = el;
    for (let p = el; p && p !== root; p = p.parentElement) {
      if (p.tagName === 'BUTTON' || p.getAttribute('role') === 'button'
          || getComputedStyle(p).cursor === 'pointer') { trig = p; break; }
    }
    const r = trig.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  }
  return null;
}
"""


async def _click_text(page: Page, want: str) -> bool:
    """Click the first visible element whose text == want, using real mouse coords."""
    coord = await page.evaluate(_COORD_BY_TEXT_JS, want)
    if not coord:
        return False
    await page.mouse.click(coord["x"], coord["y"])
    return True


async def add_lead_note(page: Page, lead_id: str, note_text: str) -> bool:
    """Open lead `lead_id`, switch to the Notas tab, write `note_text`, save.

    Returns True only if the note text is visible on the page after saving.
    Best-effort: screenshots + returns False on any missing control.
    """
    if not lead_id or not note_text:
        logger.warning("add_lead_note: missing lead_id or note_text")
        return False

    await _navigate_spa(page, f"{INTERESADOS_URL}/{lead_id}")
    await page.wait_for_timeout(1500)

    if not await _click_text(page, "Notas"):
        logger.error("add_lead_note: 'Notas' tab not found for lead {}", lead_id)
        await _screenshot_on_error(page, f"note_tab_missing_{lead_id}")
        return False
    await page.wait_for_timeout(1200)

    textarea = page.locator('textarea[placeholder*="nota interna" i]').first
    try:
        await textarea.wait_for(state="visible", timeout=8000)
    except Exception:
        logger.error("add_lead_note: note textarea not found for lead {}", lead_id)
        await _screenshot_on_error(page, f"note_textarea_missing_{lead_id}")
        return False

    await textarea.fill(note_text)
    await page.wait_for_timeout(300)

    if not await _click_text(page, "Anotar"):
        logger.error("add_lead_note: 'Anotar' save button not found for lead {}", lead_id)
        await _screenshot_on_error(page, f"note_save_missing_{lead_id}")
        return False
    await page.wait_for_timeout(1800)

    body = await page.evaluate(
        "() => ((document.getElementById('root') || document.body).innerText || '')"
    )
    ok = note_text[:30] in body
    if ok:
        logger.info("add_lead_note: note saved on lead {}", lead_id)
    else:
        logger.warning("add_lead_note: note not visible after save on lead {}", lead_id)
        await _screenshot_on_error(page, f"note_unverified_{lead_id}")
    return ok


async def write_pending_for_page(page: Page, limit: int = 20) -> int:
    """Using an ALREADY logged-in i24 page, write the advisor note for every
    assigned i24 lead that has none yet, and flip i24_note_added. Returns count.

    Designed to be called at the end of a normal scraper run so it reuses the
    same Chrome profile/session (the i24 note tab shares port 9222 with the
    scraper — a separate process would fight over the profile lock)."""
    from datetime import date

    from inmobiliaria24.supa import fetch_pending_i24_notes, mark_i24_note_added

    rows = await fetch_pending_i24_notes(limit)
    if not rows:
        logger.info("No i24 leads pending an advisor note")
        return 0

    today = date.today().isoformat()
    written = 0
    for r in rows:
        lead_id = r.get("i24_lead_id")
        agent = r.get("agent_name") or r.get("assigned_agent_id")
        note = f"Asignado a {agent} via BYG ({today})"
        try:
            ok = await add_lead_note(page, lead_id, note)
        except Exception as e:
            logger.warning("i24 note error for lead {}: {}", lead_id, str(e))
            ok = False
        if ok:
            await mark_i24_note_added(r["conversation_id"])
            written += 1
            logger.info("i24 note written for lead {} -> {}", lead_id, agent)
        else:
            logger.warning("i24 note FAILED for lead {} (will retry next run)", lead_id)
    logger.info("write_pending_for_page: {}/{} notes written", written, len(rows))
    return written


async def run_pending(limit: int = 20) -> int:
    """Standalone: launch Chrome, log in, then write pending i24 notes."""
    from inmobiliaria24.auth import launch_chrome, load_or_login
    from inmobiliaria24.config import Settings

    settings = Settings.load()
    async with async_playwright() as pw:
        context, proc = await launch_chrome(pw, headless=False)
        try:
            page = await load_or_login(context, settings)
            return await write_pending_for_page(page, limit)
        finally:
            await context.close()
            proc.terminate()


async def _test(lead_id: str, note_text: str) -> int:
    from inmobiliaria24.auth import launch_chrome, load_or_login
    from inmobiliaria24.config import Settings

    settings = Settings.load()
    async with async_playwright() as pw:
        context, proc = await launch_chrome(pw, headless=False)
        try:
            page = await load_or_login(context, settings)
            ok = await add_lead_note(page, lead_id, note_text)
            try:
                await page.screenshot(path=f"logs/note_test_{lead_id}.png")
            except Exception:
                pass
            print(f"add_lead_note -> {'OK' if ok else 'FAILED'} (lead {lead_id})")
            return 0 if ok else 1
        finally:
            await context.close()
            proc.terminate()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--run":
        n = asyncio.run(run_pending())
        print(f"run_pending wrote {n} note(s)")
        sys.exit(0)
    lid = sys.argv[1] if len(sys.argv) > 1 else ""
    txt = sys.argv[2] if len(sys.argv) > 2 else "[PRUEBA BYG] nota de prueba — ignorar"
    sys.exit(asyncio.run(_test(lid, txt)))
