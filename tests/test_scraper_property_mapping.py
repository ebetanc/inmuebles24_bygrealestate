import asyncio
from pathlib import Path

from inmobiliaria24 import scraper
from inmobiliaria24.state import StateStore


def test_extract_property_map_uses_mis_avisos_and_rejects_conflicts(monkeypatch):
    navigated = []
    conflicts = set()

    async def fake_navigate(_page, url):
        navigated.append(url)

    class Page:
        async def wait_for_function(self, *_args, **_kwargs):
            return None

        async def evaluate(self, _script):
            return [
                {"listing_id": "150786154", "property_public_id": "eb-wr4713"},
                {"listing_id": "150786154", "property_public_id": "EB-WR4713"},
                {"listing_id": "150421528", "property_public_id": "EB-ONE1"},
                {"listing_id": "150421528", "property_public_id": "EB-TWO2"},
                {"listing_id": "bad", "property_public_id": "EB-BAD1"},
            ]

    monkeypatch.setattr(scraper, "_navigate_spa", fake_navigate)
    result = asyncio.run(
        scraper.extract_property_public_id_map(Page(), conflicts_out=conflicts)
    )

    assert navigated == [scraper.AVISOS_URL]
    assert result == {"150786154": "EB-WR4713"}
    assert conflicts == {"150421528"}


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
