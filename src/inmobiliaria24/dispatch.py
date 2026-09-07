"""Drain verified V3 captures without opening or authenticating a browser.

Run every minute via inmobiliaria24-dispatch.timer. The scraper can also drain
the queue immediately after Contactado: database leases arbitrate both workers.
"""
from __future__ import annotations

import asyncio

from inmobiliaria24.config import Settings
from inmobiliaria24.main import _run_v3_route_dispatch
from inmobiliaria24.state import StateStore


async def dispatch_once(settings: Settings) -> int:
    with StateStore(settings.state_db_path) as store:
        dispatched = await _run_v3_route_dispatch(settings, store)
    return len(dispatched)


def main() -> None:
    count = asyncio.run(dispatch_once(Settings.load()))
    print(f"V3 standalone dispatch completed: {count} capture(s) dispatched")


if __name__ == "__main__":
    main()
