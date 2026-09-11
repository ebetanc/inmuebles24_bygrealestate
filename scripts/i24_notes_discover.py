"""READ-ONLY discovery of the Inmuebles24 lead-detail "Notas" composer DOM.

Reuses the scraper's own Chrome/CDP launch path and persistent profile so
Cloudflare sees the same fingerprint and session as the production run.

Usage (on the Pi, with the timer stopped):
    cd /opt/inmobiliaria24
    PYTHONPATH=src .venv/bin/python scripts/i24_notes_discover.py <lead_id>

Never clicks "Anotar" and never changes a lead status. Screenshots and HTML
dumps land in /tmp.
"""
from __future__ import annotations

import asyncio
import json
import sys

from playwright.async_api import async_playwright

from inmobiliaria24.auth import INTERESADOS_URL, launch_chrome, load_or_login
from inmobiliaria24.config import Settings
from inmobiliaria24.scraper import _navigate_spa

CSS_PATH_JS = """el => {
    const parts = [];
    for (let n = el; n && n.nodeType === 1 && parts.length < 8; n = n.parentElement) {
        let s = n.tagName.toLowerCase();
        if (n.id) { parts.unshift(s + '#' + n.id); break; }
        const cls = (n.getAttribute('class') || '').trim().split(/\\s+/).filter(Boolean);
        if (cls.length) s += '.' + cls.join('.');
        const role = n.getAttribute('role');
        if (role) s += '[role=' + role + ']';
        parts.unshift(s);
    }
    return parts.join(' > ');
}"""

DUMP_JS = r"""() => {
    const head = el => el.outerHTML.slice(0, 300);
    const out = {textareas: [], inputs: [], anotar: [], notas_internas: [], tablist: []};
    for (const t of document.querySelectorAll('textarea')) {
        out.textareas.push({
            tag: t.tagName, id: t.id, name: t.name,
            placeholder: t.getAttribute('placeholder'),
            aria: t.getAttribute('aria-label'),
            disabled: t.disabled, readonly: t.readOnly,
            data: Object.fromEntries(Object.entries(t.dataset)),
            html: head(t),
        });
    }
    for (const t of document.querySelectorAll('[contenteditable="true"]')) {
        out.inputs.push({tag: t.tagName, html: head(t)});
    }
    for (const b of document.querySelectorAll('button, [role=button], input[type=submit]')) {
        if ((b.innerText || b.value || '').trim().toLowerCase().includes('anotar')) {
            out.anotar.push({
                text: (b.innerText || b.value || '').trim(),
                disabled: b.disabled, ariaDisabled: b.getAttribute('aria-disabled'),
                type: b.getAttribute('type'),
                data: Object.fromEntries(Object.entries(b.dataset)),
                html: head(b),
            });
        }
    }
    for (const el of document.querySelectorAll('*')) {
        if (el.children.length) continue;
        const txt = (el.innerText || el.textContent || '').trim();
        if (txt.includes('Nota interna')) {
            out.notas_internas.push({
                text: txt.slice(0, 200),
                html: head(el),
                parent: el.parentElement ? head(el.parentElement) : null,
            });
        }
    }
    for (const el of document.querySelectorAll('[role=tab], [role=tablist]')) {
        out.tablist.push({role: el.getAttribute('role'), text: (el.innerText || '').trim().slice(0, 80), html: head(el)});
    }
    return out;
}"""

FIND_NOTAS_JS = r"""() => {
    for (const el of document.querySelectorAll('*')) {
        if (el.children.length) continue;
        if ((el.innerText || '').trim() === 'Notas') {
            el.setAttribute('data-byg-notas', '1');
            return true;
        }
    }
    return false;
}"""


def report(title: str, payload) -> None:
    print(f"\n=== {title} ===")
    print(json.dumps(payload, indent=2, ensure_ascii=False))


async def main(lead_id: str) -> int:
    settings = Settings.load()
    async with async_playwright() as pw:
        context, proc = await launch_chrome(pw, headless=True)
        try:
            # ponytail: no retry here on purpose — a failed auth means
            # Cloudflare is blocking the egress IP, and retrying only deepens
            # the block. Stop the timer, run once, read the error.
            page = await load_or_login(context, settings)
            await _navigate_spa(page, f"{INTERESADOS_URL}/{lead_id}")
            try:
                await page.wait_for_load_state("networkidle", timeout=15_000)
            except Exception:
                pass
            await asyncio.sleep(3)

            await page.screenshot(path=f"/tmp/i24_notes_{lead_id}_1.png", full_page=True)
            with open(f"/tmp/i24_notes_{lead_id}_before.html", "w", encoding="utf-8") as fh:
                fh.write(await page.content())
            report("BEFORE tab click", await page.evaluate(DUMP_JS))

            # Click the "Notas" tab, trying the most stable strategy first.
            tab = None
            how = None
            for name, locator in (
                ("get_by_role(tab, Notas)", page.get_by_role("tab", name="Notas")),
                ("get_by_text(Notas, exact)", page.get_by_text("Notas", exact=True).first),
            ):
                try:
                    if await locator.count() > 0:
                        await locator.first.click(timeout=8_000)
                        tab, how = locator.first, name
                        break
                except Exception as exc:
                    print(f"strategy {name} failed: {exc}")
            if tab is None and await page.evaluate(FIND_NOTAS_JS):
                tab = page.locator('[data-byg-notas="1"]')
                await tab.click(timeout=8_000)
                how = "js innerText scan"
            print(f"\nNotas tab clicked via: {how}")
            if tab is not None:
                print("tab css path:", await tab.evaluate(CSS_PATH_JS))
                print("tab outerHTML:", (await tab.evaluate("el => el.outerHTML"))[:300])

            await asyncio.sleep(2)
            await page.screenshot(path=f"/tmp/i24_notes_{lead_id}_2.png", full_page=True)
            with open(f"/tmp/i24_notes_{lead_id}_after.html", "w", encoding="utf-8") as fh:
                fh.write(await page.content())
            report("AFTER tab click", await page.evaluate(DUMP_JS))

            # Type without submitting, to see whether Anotar unlocks.
            ta = page.locator("textarea")
            if await ta.count() > 0:
                await ta.first.fill("PRUEBA-NO-ENVIAR")
                await asyncio.sleep(0.5)
                report("AFTER typing (NOT submitted)", await page.evaluate(DUMP_JS))
                await page.screenshot(path=f"/tmp/i24_notes_{lead_id}_3.png", full_page=True)
                await ta.first.fill("")
            else:
                print("\nNo textarea found — nothing to type into.")
            return 0
        finally:
            await context.close()
            proc.terminate()
            proc.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1])))
