import asyncio
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest

from inmobiliaria24 import scraper
from inmobiliaria24.state import StateStore


class _FakeRequest:
    method = "GET"

    async def all_headers(self):
        return {
            "accept": "application/json",
            "cookie": "must-not-be-replayed",
            "sessionid": "session-test",
            "x-panel": "panel-test",
        }


class _FakeResponse:
    status = 200

    def __init__(self, payload, *, limit=20):
        self.url = (
            "https://www.inmuebles24.com/avisos-api/panel/api/v2/postings"
            f"?page=1&limit={limit}&searchParameters=test"
        )
        self.request = _FakeRequest()
        self._payload = payload

    async def json(self):
        return self._payload


class _FakeResponseInfo:
    def __init__(self, response):
        self._response = response

    @property
    def value(self):
        async def resolve():
            return self._response

        return resolve()


class _FakeExpectedResponse:
    def __init__(self, response):
        self.info = _FakeResponseInfo(response)

    async def __aenter__(self):
        return self.info

    async def __aexit__(self, *_args):
        return None


class _FakePostingsPage:
    def __init__(self, pages, total, *, limit=20):
        self.pages = pages
        self.total = total
        self.response = _FakeResponse(
            {"numberOfPostings": total, "postings": pages[1]}, limit=limit
        )
        self.fetched_pages = []
        self.replay_headers = None

    def expect_response(self, predicate, *, timeout):
        assert timeout == 30_000
        assert predicate(self.response)
        return _FakeExpectedResponse(self.response)

    async def evaluate(self, script, params):
        assert script == scraper._FETCH_PROPERTY_POSTINGS_PAGE_JS
        page_number = int(parse_qs(urlsplit(params["url"]).query)["page"][0])
        self.fetched_pages.append(page_number)
        self.replay_headers = params["headers"]
        return {
            "status": 200,
            "payload": {
                "numberOfPostings": self.total,
                "postings": self.pages[page_number],
            },
        }


def _posting(number, code=None):
    return {"postingId": str(number), "internalCode": code or f"EB-P{number % 10000:04d}"}


def test_extract_property_map_uses_exact_posting_fields(monkeypatch):
    navigated = []
    page = _FakePostingsPage(
        {1: [_posting(150786154, "eb-wr4713"), _posting(150421528, "invalid")]},
        2,
    )

    async def fake_navigate(_page, url):
        navigated.append(url)

    monkeypatch.setattr(scraper, "_navigate_spa", fake_navigate)
    result = asyncio.run(scraper.extract_property_public_id_map(page))

    assert navigated == [scraper.AVISOS_URL]
    assert result == {"150786154": "EB-WR4713"}


def test_extract_property_map_reads_all_117_authenticated_api_rows(monkeypatch):
    postings = [_posting(150000000 + index) for index in range(117)]
    postings[-1] = _posting(150316179, "EB-TARGET")
    pages = {
        number: postings[(number - 1) * 20:number * 20]
        for number in range(1, 7)
    }
    page = _FakePostingsPage(pages, 117)

    async def fake_navigate(_page, _url):
        return None

    monkeypatch.setattr(scraper, "_navigate_spa", fake_navigate)
    result = asyncio.run(scraper.extract_property_public_id_map(page))

    assert len(result) == 117
    assert result["150316179"] == "EB-TARGET"
    assert page.fetched_pages == [2, 3, 4, 5, 6]
    assert page.replay_headers == {
        "accept": "application/json",
        "sessionid": "session-test",
        "x-panel": "panel-test",
    }


def test_extract_property_map_rejects_repeated_page_rows(monkeypatch):
    first = [_posting(150000000 + index) for index in range(20)]
    pages = {1: first, 2: [first[0], *[_posting(150000100 + index) for index in range(19)]]}
    page = _FakePostingsPage(pages, 40)

    async def fake_navigate(_page, _url):
        return None

    monkeypatch.setattr(scraper, "_navigate_spa", fake_navigate)
    with pytest.raises(RuntimeError, match="repeated postingId"):
        asyncio.run(scraper.extract_property_public_id_map(page))


def test_extract_property_map_rejects_omitted_page_rows(monkeypatch):
    pages = {
        1: [_posting(150000000 + index) for index in range(20)],
        2: [_posting(150000100 + index) for index in range(19)],
    }
    page = _FakePostingsPage(pages, 40)

    async def fake_navigate(_page, _url):
        return None

    monkeypatch.setattr(scraper, "_navigate_spa", fake_navigate)
    with pytest.raises(RuntimeError, match="returned 19 rows; expected 20"):
        asyncio.run(scraper.extract_property_public_id_map(page))


def test_enrichment_uses_mapping_without_overriding_detail_code():
    leads = [
        {"listing_id": "150786154", "property_public_id": ""},
        {"listing_id": "150421528", "property_public_id": "EB-EXIST1"},
        {"listing_id": "149991403"},
    ]
    result = scraper.enrich_property_public_ids(
        leads,
        {"150786154": "EB-WR4713", "150421528": "EB-OTHER1", "149991403": "bad"},
    )
    assert result[0]["property_public_id"] == "EB-WR4713"
    assert result[1]["property_public_id"] == "EB-EXIST1"
    assert "property_public_id" not in result[2]


def test_property_mapping_cache_is_persistent(tmp_path: Path):
    database = tmp_path / "state.db"
    with StateStore(database) as store:
        store.upsert_property_public_id_map({"150786154": "EB-WR4713"})
    with StateStore(database) as store:
        assert store.property_public_id_map() == {"150786154": "EB-WR4713"}


def test_property_mapping_cache_can_invalidate_conflicts(tmp_path: Path):
    database = tmp_path / "state.db"
    with StateStore(database) as store:
        store.upsert_property_public_id_map(
            {"150786154": "EB-WR4713", "150421528": "EB-OLD1"}
        )
        store.delete_property_public_id_mappings({"150421528"})
        assert store.property_public_id_map() == {"150786154": "EB-WR4713"}
