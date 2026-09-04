import asyncio

from inmobiliaria24 import scraper


def _run_extract(monkeypatch, rows_by_tab):
    """Drive extract_leads_list over a fake inbox, returning (leads, clicked_tabs)."""
    clicked: list[str] = []
    # Tab name for each CSS selector in _TABS, so the fake page can answer clicks.
    tab_of_selector = {sel: name for name, sel in scraper._TABS if sel}
    current = {"tab": "mensajes"}  # the default active tab needs no click

    class Page:
        async def evaluate(self, script, *args):
            if script == scraper._EXTRACT_LEADS_LIST_JS:
                return list(rows_by_tab.get(current["tab"], []))
            # Anything else is a tab click: args[0] is the CSS selector.
            name = tab_of_selector[args[0]]
            clicked.append(name)
            current["tab"] = name
            return True

    async def noop(*args, **kwargs):
        return None

    monkeypatch.setattr(scraper, "_navigate_spa", noop)
    monkeypatch.setattr(scraper.asyncio, "sleep", noop)

    leads = asyncio.run(scraper.extract_leads_list(Page()))
    return leads, clicked


def _row(lead_id, name):
    return {"lead_id": lead_id, "name": name, "listing_id": "L1", "status": "Pendiente"}


def test_only_the_mensajes_tab_is_scraped_or_routed(monkeypatch):
    """Only 'mensajes' carries a question the person wrote; the rest never route."""
    leads, clicked = _run_extract(monkeypatch, {
        "mensajes": [_row("1", "Ana")],
        "telefono": [_row("2", "Luis")],
        "whatsapp": [_row("3", "Milena")],
    })

    assert [(l["lead_id"], l["source_tab"]) for l in leads] == [("1", "mensajes")]
    # The tabs are not even opened, so the run does not pay for loading them.
    assert clicked == []


def test_lead_that_also_wrote_a_message_survives_the_filter(monkeypatch):
    """Same lead_id in several tabs stays: 'mensajes' is scraped first."""
    leads, _ = _run_extract(monkeypatch, {
        "mensajes": [_row("7", "Sofia")],
        "telefono": [_row("7", "Sofia")],
        "whatsapp": [_row("7", "Sofia")],
    })

    assert [(l["lead_id"], l["source_tab"]) for l in leads] == [("7", "mensajes")]
