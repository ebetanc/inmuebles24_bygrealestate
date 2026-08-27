"""V3 contract/fixture sanity checks; no production or live execution."""
import json
from pathlib import Path

import pytest


ROOT = Path(__file__).parents[1]
FIXTURES = ROOT / "tests" / "fixtures" / "v3"


def load_json(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def test_dispositions_cover_contract_boundaries():
    cases = load_json("dispositions.json")
    assert {case["disposition"] for case in cases} == {
        "created_new", "active_duplicate", "returning_assigned", "non_routable"
    }
    assert {case["reason"] for case in cases if "reason" in case} == {
        "missing_external_id", "missing_prospect_identity", "missing_property_identity"
    }
    assert next(c for c in cases if c["name"] == "missing_description_is_allowed")["disposition"] == "created_new"


def test_delivery_timeline_never_equates_accepted_with_delivered():
    cases = load_json("delivery_timeline.json")
    accepted = next(c for c in cases if c["name"] == "accepted_without_delivery")
    assert accepted["events"] == ["accepted"]
    assert accepted["expected"] == "technical_timeout_only"
    assert all(c["expected"] != "delivered" for c in cases if c["events"] == ["accepted"])


def test_correlation_has_exact_outcomes_and_no_guessing():
    cases = load_json("easybroker_correlation.json")
    assert {c["expected"] for c in cases} >= {
        "linked", "awaiting_eb_request", "manual_review:no_eb_request",
        "manual_review:ambiguous", "already_linked"
    }
    linked = [c for c in cases if c["expected"] == "linked"]
    assert len(linked) == 1
    assert linked[0]["candidates"] == 1
    assert linked[0]["property_exact"] is True
    assert linked[0]["identity"] == "compatible"
    assert linked[0]["contradiction"] is False
    assert linked[0]["effect_allowed"] is True
    assert all(c["effect_allowed"] is False for c in cases if c["expected"] != "linked")
    conflict = next(c for c in cases if c["name"] == "identity_contradiction")
    assert conflict["expected"] == "manual_review"
    assert conflict["reason"] == "identity_contradiction"


def test_meta_fixture_is_sanitized_and_has_invalid_signature_case():
    cases = load_json("meta_webhook.json")
    assert any(c["signature"] == "invalid" and c["expected"] == "reject_without_mutation" for c in cases)
    assert any(c.get("status") == "accepted" and c["expected"] == "not_delivered" for c in cases)
    raw = json.dumps(cases)
    assert not any(token in raw.lower() for token in ("phone", "email", "token", "secret", "credential"))


def test_sql_fixtures_are_transactional_and_use_proposed_operations():
    expected = {
        "intake_dispositions.sql": "upsert_routing_opportunity",
        "claim_concurrency.sql": "claim_ready_delivery",
        "effect_leases.sql": "finish_delivery_lease",
        "easybroker_correlation.sql": "correlate_easybroker_request",
    }
    for name, operation in expected.items():
        sql = (FIXTURES / name).read_text(encoding="utf-8").lower()
        assert sql.startswith("-- proposed / no aplicado")
        assert "begin;" in sql and "rollback;" in sql
        assert operation in sql


@pytest.mark.xfail(strict=True, reason="V3-02 proposed exact EasyBroker correlation RPC not implemented")
def test_proposed_exact_correlation_rpc_exists():
    sql = "\n".join(p.read_text(encoding="utf-8") for p in (ROOT / "whatsapp-agent" / "migrations").glob("*.sql"))
    assert "correlate_easybroker_request" in sql


@pytest.mark.xfail(strict=True, reason="V3-04 proposed durable V3 state machine not implemented")
def test_proposed_v3_state_machine_operation_exists():
    sql = "\n".join(p.read_text(encoding="utf-8") for p in (ROOT / "whatsapp-agent" / "migrations").glob("*.sql"))
    assert "enqueue_ready_delivery" in sql and "close_delivery_timeout" in sql
