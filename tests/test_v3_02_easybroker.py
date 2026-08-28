"""Local V3-02 adapter contract; no HTTP or Supabase calls."""

from datetime import datetime, timezone

from easybroker.supa import (
    _checkpoint_due,
    normalize_e164,
    normalize_easybroker_phone_mx,
    sanitize_contact_request,
)


def test_phone_requires_explicit_country_code():
    assert normalize_e164("55 1111 2222") is None
    assert normalize_e164("55 1111 2222", "52") == "+525511112222"
    assert normalize_e164("+52 55 1111 2222") == "+525511112222"


def test_easybroker_mx_phone_variants_are_normalized_without_ambiguous_guesses():
    assert normalize_easybroker_phone_mx("55 1111 2222") == "+525511112222"
    assert normalize_easybroker_phone_mx("52 55 1111 2222") == "+525511112222"
    assert normalize_easybroker_phone_mx("+52 55 1111 2222") == "+525511112222"
    assert normalize_easybroker_phone_mx("12345678") is None
    assert normalize_easybroker_phone_mx("123456789012345678901") is None


def test_sanitized_request_separates_person_and_request_fields():
    result = sanitize_contact_request({
        "id": 123,
        "contact_id": 456,
        "property_id": " eb-x ",
        "email": " Lead@Example.com ",
        "phone": "55 1111 2222",
        "country_code": "52",
        "happened_at": "2026-08-27T12:00:00Z",
        "name": "must not be forwarded",
    })
    assert result["eb_request_id"] == 123
    assert result["eb_person_contact_id"] == 456
    assert result["normalized_email"] == "lead@example.com"
    assert result["e164_phone"] == "+525511112222"
    assert "name" not in result and "phone" not in result


def test_inbox_checkpoint_runs_at_most_every_five_minutes():
    now = datetime(2026, 8, 27, 15, 0, tzinfo=timezone.utc)
    assert not _checkpoint_due({"updated_at": "2026-08-27T14:56:00Z"}, now=now)
    assert _checkpoint_due({"updated_at": "2026-08-27T14:55:00Z"}, now=now)
