import inspect

from easybroker.supa import fetch_pending_attend
from inmobiliaria24.supa import fetch_claimed_i24_lead_ids, fetch_pending_i24_notes


def test_portal_side_effect_queries_require_a_genuine_claim():
    gate = "or=(claimed_via.is.null,claimed_via.neq.escalation,first_response_at.not.is.null)"
    for function in (fetch_pending_i24_notes, fetch_claimed_i24_lead_ids, fetch_pending_attend):
        assert gate in inspect.getsource(function)
