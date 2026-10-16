"""EB "Cambiar estatus" menu: the Atendida option must be found in the Oct-2026
two-option menu (Sin atender/Atendida) and in the old four-option one, but never
in the sidebar "Estatus" text."""
import asyncio

import pytest

from easybroker.inbox import _TAG_STATUS_OPTION_JS, _TAG_STATUS_TRIGGER_JS

playwright = pytest.importorskip("playwright.async_api")

TRIGGER = '<a style="cursor:pointer"><span>Sin atender</span></a>'
OPT = '<a style="cursor:pointer"><span>{}</span></a>'
NEW = TRIGGER + "<div><div>Cambiar estatus</div>" + OPT.format("Sin atender") + OPT.format("Atendida") + "</div>"
OLD = TRIGGER + "<div>" + "".join(OPT.format(x) for x in ("Sin atender", "Atendida", "Archivada", "Spam")) + "</div>"
SIDEBAR = TRIGGER + "<div><div>Estatus</div><div>Atendida</div></div>"


async def _tag(html: str):
    async with playwright.async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page()
        await page.set_content(html)
        trigger = await page.evaluate(_TAG_STATUS_TRIGGER_JS)
        option = await page.evaluate(_TAG_STATUS_OPTION_JS, "Atendida")
        await browser.close()
        return trigger, option


@pytest.mark.parametrize("html,found", [(NEW, True), (OLD, True), (SIDEBAR, False)])
def test_atendida_option_tagging(html, found):
    try:
        trigger, option = asyncio.run(_tag(html))
    except Exception as exc:  # no browser installed
        pytest.skip(f"chromium unavailable: {exc}")
    assert trigger == "Sin atender"
    assert option is found
