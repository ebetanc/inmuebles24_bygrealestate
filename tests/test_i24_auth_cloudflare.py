import asyncio

from inmobiliaria24 import auth


def test_attention_required_is_a_cloudflare_page_and_hard_block():
    title = "Attention Required! | Cloudflare"
    assert auth._is_cloudflare_page(title) is True
    assert auth._is_hard_cloudflare_block(title) is True


def test_hard_block_rotates_immediately_and_returns_when_reload_clears(monkeypatch):
    calls = {"rotate": 0, "reload": 0, "wait": 0}

    async def no_sleep(_delay):
        return None

    def rotate():
        calls["rotate"] += 1
        return "203.0.113.10"

    class Page:
        current_title = "Attention Required! | Cloudflare"

        async def title(self):
            return self.current_title

        async def reload(self, **_kwargs):
            calls["reload"] += 1
            self.current_title = "Inmuebles24"

        async def wait_for_function(self, *_args, **_kwargs):
            calls["wait"] += 1

        async def wait_for_load_state(self, *_args, **_kwargs):
            return None

    monkeypatch.setattr(auth.asyncio, "sleep", no_sleep)
    monkeypatch.setattr(auth.random, "uniform", lambda *_args: 0)
    monkeypatch.setattr(auth, "_rotate_proxy_ip", rotate)
    monkeypatch.setattr(auth, "_rotation_used", False)

    asyncio.run(auth._wait_for_cloudflare(Page(), timeout_ms=1))

    assert calls == {"rotate": 1, "reload": 1, "wait": 0}
