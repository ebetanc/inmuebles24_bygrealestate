"""EasyBroker login + session lifecycle.

EB's login form selectors are discovered live (use `--inspect-login`); the login
flow below targets them with resilient fallbacks (input type / name / placeholder
and submit-button text) so a minor markup change does not break it outright.
"""
from __future__ import annotations

import asyncio
import random
import re

from loguru import logger
from playwright.async_api import Page

from easybroker.browser import screenshot, wait_for_spa

# EB serves the broker CRM under www.easybroker.com (app.easybroker.com root is
# the per-tenant public-site landing — "Sitio web inactivo" — NOT the CRM).
APP_URL = "https://www.easybroker.com"
# Two-step login: email page -> submit -> password. WAF returns 403 to headless
# browsers; this flow must run headful (or under xvfb on a headless host).
LOGIN_URL = f"{APP_URL}/mx/account/authentication/new"
# EB redirects unauthenticated requests here. Kept broad on purpose.
_LOGGED_OUT_URL_FRAGMENTS = ("authentication", "sign_in", "users/sign_in", "sessions", "/login")

# Resilient candidate selectors (first that matches wins).
_EMAIL_SELECTORS = [
    'input[name="authentication[email]"]',
    'input#authentication_email',
    'input[type="email"]',
    'input[name="email"]',
    'input[name="user[email]"]',
    'input[name="session[email]"]',
    'input[placeholder*="orreo" i]',  # "Correo"
    'input[placeholder*="mail" i]',
]
_PASSWORD_SELECTORS = [
    'input[type="password"]',
    'input[name="password"]',
    'input[name="user[password]"]',
    'input[name="session[password]"]',
]
_SUBMIT_SELECTORS = [
    'button[type="submit"]',
    'input[type="submit"]',
    'button:has-text("Iniciar")',
    'button:has-text("Ingresar")',
    'button:has-text("Entrar")',
]


class AuthenticationError(Exception):
    """Raised when authentication fails for any reason."""


def _is_logged_out_url(url: str) -> bool:
    lower = url.lower()
    return any(frag in lower for frag in _LOGGED_OUT_URL_FRAGMENTS)


async def _first_visible(page: Page, selectors: list[str], timeout_ms: int = 12_000):
    """Return the first locator from `selectors` that becomes visible, else None."""
    deadline = timeout_ms
    step = 500
    while deadline > 0:
        for sel in selectors:
            loc = page.locator(sel).first
            try:
                if await loc.count() > 0 and await loc.is_visible():
                    return loc
            except Exception:
                continue
        await asyncio.sleep(step / 1000)
        deadline -= step
    return None


async def session_is_valid(page: Page) -> bool:
    """True only if we are on a real logged-in EB page (Buzón nav present)."""
    if _is_logged_out_url(page.url):
        return False
    # A logged-in EB page renders the top nav with "Buzón"; the login page does
    # not. Presence of a visible password field is a definitive logged-out tell.
    try:
        if await page.locator('input[type="password"]').first.is_visible():
            return False
    except Exception:
        pass
    try:
        body = await page.evaluate("() => (document.body && document.body.innerText) || ''")
    except Exception:
        body = ""
    if "Buzón" in body or "Buzon" in body or "Tablero" in body:
        return True
    return len(body.strip()) > 200 and not _is_logged_out_url(page.url)


async def login(page: Page, settings) -> None:
    """Perform a fresh EB login (email + password)."""
    logger.info("Starting EB login for {}", settings.email)
    await page.goto(LOGIN_URL, wait_until="domcontentloaded")
    await wait_for_spa(page)
    await asyncio.sleep(random.uniform(1.0, 2.0))

    # The login screen first offers social + email choices ("Continuar con
    # Facebook/Google/Apple/email"). The email/password fields only render after
    # choosing "Continuar con email".
    try:
        choose_email = page.get_by_text(re.compile("Continuar con email", re.I)).first
        if await choose_email.count() > 0 and await choose_email.is_visible():
            await choose_email.click()
            await asyncio.sleep(random.uniform(0.8, 1.5))
            logger.info("Clicked 'Continuar con email'")
    except Exception:
        pass

    email_input = await _first_visible(page, _EMAIL_SELECTORS, timeout_ms=20_000)
    if email_input is None:
        await screenshot(page, "login_no_email_field")
        raise AuthenticationError(
            "Could not find the email field on the EB login page "
            "(run with --inspect-login to dump the form)."
        )
    await email_input.fill(settings.email)
    await asyncio.sleep(random.uniform(0.4, 1.0))

    password_input = await _first_visible(page, _PASSWORD_SELECTORS, timeout_ms=12_000)
    if password_input is None:
        # Some flows reveal the password field only after submitting the email.
        submit = await _first_visible(page, _SUBMIT_SELECTORS, timeout_ms=4_000)
        if submit is not None:
            await submit.click()
            await asyncio.sleep(random.uniform(1.0, 2.0))
            password_input = await _first_visible(page, _PASSWORD_SELECTORS, timeout_ms=12_000)
    if password_input is None:
        await screenshot(page, "login_no_password_field")
        raise AuthenticationError(
            "Could not find the password field on the EB login page "
            "(run with --inspect-login to dump the form)."
        )
    await password_input.fill(settings.password)
    await asyncio.sleep(random.uniform(0.4, 1.0))

    submit = await _first_visible(page, _SUBMIT_SELECTORS, timeout_ms=8_000)
    if submit is None:
        await password_input.press("Enter")
    else:
        await submit.click()

    await page.wait_for_load_state("domcontentloaded")
    await asyncio.sleep(random.uniform(2.0, 4.0))
    await wait_for_spa(page)

    if not await session_is_valid(page):
        await screenshot(page, "login_failed")
        raise AuthenticationError(
            f"EB login failed — not on a logged-in page after submit (url={page.url}). "
            f"May be a wrong password or a new-device verification challenge."
        )
    logger.info("EB login successful (url={})", page.url)


async def load_or_login(context, settings) -> Page:
    """Ensure the context is authenticated; return a Page on a logged-in EB page."""
    page = await context.new_page()
    logger.info("Checking if persistent EB session is still valid")
    try:
        # Probe the login URL: if already authenticated, EB redirects away from
        # /authentication to the CRM dashboard.
        await page.goto(LOGIN_URL, wait_until="domcontentloaded")
        await wait_for_spa(page)
        if await session_is_valid(page):
            logger.info("Persistent EB session is valid — skipping login")
            return page
        logger.warning("EB session not valid (url={}) — performing fresh login", page.url)
    except Exception as e:
        logger.warning("EB session check error ({}): performing fresh login", e)

    await login(page, settings)
    return page


async def dump_login_form(page: Page) -> list[dict]:
    """Diagnostic: dump every input + submit control on the EB login page."""
    import json
    from pathlib import Path

    await page.goto(LOGIN_URL, wait_until="domcontentloaded")
    await wait_for_spa(page)
    await asyncio.sleep(2)
    controls = await page.evaluate(
        """() => {
            const out = [];
            for (const el of document.querySelectorAll('input, button, [type=submit]')) {
                const r = el.getBoundingClientRect();
                out.push({
                    tag: el.tagName.toLowerCase(),
                    type: el.getAttribute('type') || '',
                    name: el.getAttribute('name') || '',
                    id: el.id || '',
                    placeholder: el.getAttribute('placeholder') || '',
                    text: (el.textContent || '').trim().slice(0, 40),
                    visible: r.width > 0 && r.height > 0,
                });
            }
            return out;
        }"""
    )
    Path("logs").mkdir(exist_ok=True)
    Path("logs/eb_login_form.json").write_text(
        json.dumps(controls, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    await screenshot(page, "login_form")
    logger.info("Dumped {} login controls -> logs/eb_login_form.json", len(controls))
    return controls
