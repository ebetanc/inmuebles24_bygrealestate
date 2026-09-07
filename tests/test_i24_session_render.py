import asyncio
from types import SimpleNamespace

from inmobiliaria24 import auth


def test_public_homepage_is_not_a_valid_panel():
    page = SimpleNamespace(url=auth.HOME_URL)
    assert asyncio.run(auth._session_is_valid(page)) is False


def test_permissions_error_is_not_a_valid_panel():
    page = SimpleNamespace(url='https://www.inmuebles24.com/panel/permissionserror')
    assert asyncio.run(auth._session_is_valid(page)) is False


def test_broken_avisos_route_recovers_inbox_without_login(monkeypatch):
    class Page:
        url = ''

        async def goto(self, url, **kwargs):
            self.url = (auth.HOME_URL + 'panel/permissionserror'
                        if url == auth.AVISOS_URL else url)

    page = Page()

    async def new_page():
        return page

    async def cleared(_page):
        pass

    async def valid(candidate):
        return candidate.url == auth.INTERESADOS_URL

    async def no_login(*args):
        raise AssertionError('working inbox must not trigger login')

    monkeypatch.setattr(auth, '_wait_for_cloudflare', cleared)
    monkeypatch.setattr(auth, '_session_is_valid', valid)
    monkeypatch.setattr(auth, 'login', no_login)
    result = asyncio.run(auth.load_or_login(SimpleNamespace(new_page=new_page), None))
    assert result.url == auth.INTERESADOS_URL


def test_inbox_recovery_does_not_accept_login_redirect(monkeypatch):
    class Page:
        async def goto(self, url, **kwargs):
            self.url = auth.HOME_URL + 'login'

    async def cleared(_page):
        pass

    monkeypatch.setattr(auth, '_wait_for_cloudflare', cleared)
    assert asyncio.run(auth._recover_inbox_session(Page())) is False


def test_slow_panel_is_rechecked_before_relogin():
    class Locator:
        async def count(self):
            return 0

    class Page:
        url = 'https://www.inmuebles24.com/panel/avisos'
        rendered = False
        waits = 0

        async def title(self):
            return ''

        def locator(self, _selector):
            return Locator()

        async def evaluate(self, _script):
            return 'Mis avisos ' * 20 if self.rendered else ''

        async def wait_for_function(self, _script, **kwargs):
            assert kwargs['timeout'] == 15000
            self.waits += 1
            self.rendered = True

    page = Page()
    assert asyncio.run(auth._session_is_valid(page)) is True
    assert page.waits == 1


def test_rendered_logout_redirect_is_not_accepted_as_a_session():
    class Locator:
        async def count(self):
            return 0

    class Page:
        url = 'https://www.inmuebles24.com/panel/avisos'

        async def title(self):
            return ''

        def locator(self, _selector):
            return Locator()

        async def evaluate(self, _script):
            return ''

        async def wait_for_function(self, _script, **kwargs):
            self.url = 'https://www.inmuebles24.com/login'

    assert asyncio.run(auth._session_is_valid(Page())) is False


def test_authenticated_homepage_recovers_without_submitting_credentials(monkeypatch):
    visited = []

    class Menu:
        async def count(self):
            return 1

    class Page:
        async def goto(self, url, **kwargs):
            visited.append(url)

        def locator(self, selector):
            assert selector == auth.MENU_MIS_AVISOS
            return Menu()

    async def cleared(_page):
        pass

    async def navigate(_page):
        visited.append(auth.AVISOS_URL)

    async def valid(_page):
        return True

    monkeypatch.setattr(auth, '_wait_for_cloudflare', cleared)
    monkeypatch.setattr(auth, 'navigate_to_avisos', navigate)
    monkeypatch.setattr(auth, '_session_is_valid', valid)
    # No password property: any attempt to submit credentials fails the test.
    asyncio.run(auth.login(Page(), SimpleNamespace(email='synthetic@example.test')))
    assert visited == [auth.HOME_URL, auth.AVISOS_URL]
