"""Static checks for the local V3 workflow exports; never contacts n8n or Meta."""

import json
from pathlib import Path


ROOT = Path(__file__).parents[1]
PAIRS = {
    "WF21": ("whatsapp-agent/workflows/WF21_error_handler.json", "n8n-export/BYG_WF21_Error_Handler_.json"),
    "WF12": ("whatsapp-agent/workflows/WF12_owner_resolver.json", "n8n-export/WF12_-_Owner_Resolver__EB_owner_table__.json"),
    "WF13": ("whatsapp-agent/workflows/WF13_directed_notify.json", "n8n-export/WF13_-_Directed_Owner_Notify__Cloud_API__.json"),
    "WF1": ("whatsapp-agent/workflows/WF1_inbound_router.json", "n8n-export/WF1_-_Inbound_Router__Evolution__.json"),
    "WF3b": ("whatsapp-agent/workflows/WF3b_claim_handler.json", "n8n-export/WF3b_-_Claim_Handler__Evolution__.json"),
    "WF22": ("whatsapp-agent/workflows/WF22_delivery_status.json", "n8n-export/WF22_-_Delivery_Status_.json"),
    "WF23": ("whatsapp-agent/workflows/WF23_delivery_timeout_sweeper.json", "n8n-export/WF23_-_Delivery_Timeout_Sweeper_.json"),
    "WF3c": ("whatsapp-agent/workflows/WF3c_expiry_sweeper.json", "n8n-export/WF3c_-_Auction_Expiry_Sweeper__Tiered__.json"),
    "WF10": ("whatsapp-agent/workflows/WF10_scraper_intake.json", "n8n-export/WF10_-_Scraper_Lead_Intake_.json"),
}


def load(path):
    return json.loads((ROOT / path).read_text(encoding="utf-8"))


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def node(workflow, name):
    return next(n for n in workflow["nodes"] if n["name"] == name)


def test_canonical_and_mirror_have_the_same_contract_nodes():
    for canonical, mirror in PAIRS.values():
        assert {n["name"] for n in load(canonical)["nodes"]} == {n["name"] for n in load(mirror)["nodes"]}


def test_wf21_throttles_identical_error_emails():
    for path in PAIRS["WF21"]:
        code = node(load(path), "Armar mensaje")["parameters"]["jsCode"]
        assert "$getWorkflowStaticData('global')" in code
        assert "15*60*1000" in code
        assert "globalLimit=3" in code
        assert "errorGlobalWindow" in code
        assert "return []" in code


def test_workflow_exports_do_not_hide_duplicate_connection_keys():
    for canonical, mirror in PAIRS.values():
        for path in (canonical, mirror):
            json.loads(
                (ROOT / path).read_text(encoding="utf-8"),
                object_pairs_hook=reject_duplicate_keys,
            )


def test_wf12_requires_exactly_one_tag_before_sql_resolver():
    for path in PAIRS["WF12"]:
        workflow = load(path)
        extract = node(workflow, "Extract Tags")["parameters"]["jsCode"]
        assert "tag_count" in extract and "tag_cardinality_valid" in extract
        assert "Tag Count Exactly One?" in workflow["connections"]["Extract Tags"]["main"][0][0]["node"]


def test_wf13_is_owner_or_primary_and_uses_v3_offer():
    for path in PAIRS["WF13"]:
        workflow = load(path)
        build = node(workflow, "Build Owner Offer")["parameters"]["jsCode"]
        body = node(workflow, "Send Owner Offer")["parameters"]["jsonBody"]
        assert "primary_guard" in build and "backup_guard" not in build
        assert "claim:v3" in build and "lead_subasta_v3" in body
        assert body.count('"type": "text"') == 8


def test_wf13_and_wf23_process_buttonless_assigned_notices_durably():
    for path in PAIRS["WF13"]:
        workflow = load(path)
        validate = node(workflow, "Validate Assigned Notice")["parameters"]
        body = node(workflow, "Send Assigned Notice")["parameters"]["jsonBody"]
        assert validate["mode"] == "runOnceForEachItem"
        assert "$input.first()" not in validate["jsCode"]
        assert "const input=$json" in validate["jsCode"]
        assert "return {json:" in validate["jsCode"]
        assert "lead_asignado_v3" in body
        assert body.count('"type": "text"') == 8
        assert '"type": "button"' not in body
        assert "v3_record_provider_accepted" in node(
            workflow, "Bind Assigned Provider Message"
        )["parameters"]["query"]
    for path in PAIRS["WF23"]:
        workflow = load(path)
        assert "claim_v3_assigned_notices" in node(
            workflow, "Claim Assigned Notices"
        )["parameters"]["query"]
        assert node(workflow, "Call WF13 Assigned Notice")["parameters"]["workflowId"]["value"] == "Bo2YbbUpmBzRbhDa"


def test_wf1_has_typed_trigger_and_v3_context_parser():
    for path in PAIRS["WF1"]:
        workflow = load(path)
        assert node(workflow, "When Called by WF22")["type"] == "n8n-nodes-base.executeWorkflowTrigger"
        assert node(workflow, "WA Webhook").get("disabled") is True
        parser = node(workflow, "Parse Evolution Payload")["parameters"]["jsCode"]
        classifier = node(workflow, "Classify & Route")["parameters"]["jsCode"]
        assert "context_id" in parser and "message_type" in parser
        assert "claim:v3" in classifier and "v2_drain" in classifier


def test_wf3b_routes_v3_to_exact_claim_rpc_and_keeps_v2_drain():
    for path in PAIRS["WF3b"]:
        workflow = load(path)
        gate = node(workflow, "Is Routing V2 Claim?")["parameters"]["conditions"]["conditions"][0]["leftValue"]
        assert "v2_drain" in gate
        claim = node(workflow, "Claim V3 Delivery")
        assert "claim_v3_delivery" in claim["parameters"]["query"]
        assert all(token in claim["parameters"]["options"]["queryReplacement"] for token in ("opportunity_id", "attempt_id", "capture_event_id", "agent_phone"))
        assert "V3 Claim RPC Not Installed" not in {n["name"] for n in workflow["nodes"]}


def test_wf22_flattens_batches_and_fails_closed_with_http_branches():
    for path in PAIRS["WF22"]:
        workflow = load(path)
        verify = node(workflow, "Verify Meta Signature")["parameters"]["jsCode"]
        dispatch = node(workflow, "Dispatch Meta Payload")["parameters"]["jsCode"]
        webhook = node(workflow, "WA Status Webhook")["parameters"]
        assert "timingSafeEqual" in verify and "signature_valid: false" in verify
        assert "const incoming = $input.first()" in verify
        assert "incoming.binary?.data?.data" in verify
        assert "item.binary" not in verify
        assert "Array.isArray(body.entry)" in dispatch and "statuses" in dispatch and "messages" in dispatch
        assert webhook["responseMode"] == "responseNode"
        assert node(workflow, "WA Status Webhook").get("webhookId")
        assert "401" in str(node(workflow, "Reject Invalid Signature")["parameters"]["options"]["responseCode"])
        verify = node(workflow, "WA Verify Webhook")["parameters"]
        challenge = node(workflow, "Validate Meta Challenge")["parameters"]["jsCode"]
        assert verify["httpMethod"] == "GET"
        assert node(workflow, "WA Verify Webhook").get("webhookId")
        assert verify["path"] == webhook["path"]
        assert "$env.WA_VERIFY_TOKEN" in challenge
        assert "hub.verify_token" in challenge and "hub.challenge" in challenge
        assert node(workflow, "Reject Meta Challenge")["parameters"]["options"]["responseCode"] == 403


def test_wf22_acknowledges_ignored_events_and_reconciles_read_callbacks():
    for path in PAIRS["WF22"]:
        workflow = load(path)
        actionable = workflow["connections"]["Actionable Meta Event?"]["main"]
        assert actionable[0][0]["node"] == "Normalize V3 Inbox Event"
        assert actionable[1][0]["node"] == "Respond Accepted"
        parser = node(workflow, "Parse Whitelisted Status")["parameters"]["jsCode"]
        assert "'read'" in parser
        assert "v3_record_read_delivery" in node(workflow, "Record Read Delivery")["parameters"]["query"]
        read_route = workflow["connections"]["Read Status?"]["main"]
        assert read_route[0][0]["node"] == "Record Read Delivery"
        assert read_route[1][0]["node"] == "Record and Reconcile Callback"


def test_wf22_processing_failures_have_explicit_500_response_paths():
    for path in PAIRS["WF22"]:
        workflow = load(path)
        assert node(workflow, "Respond Processing Error")["parameters"]["options"]["responseCode"] == 500
        for name in (
            "Ingest V3 Meta Event",
            "Claim V3 Meta Events",
            "Record and Reconcile Callback",
            "Record Read Delivery",
            "Call WF1 Inbound Router",
            "Finish V3 Meta Event",
            "Finish V3 Meta Event Error",
        ):
            assert node(workflow, name)["onError"] == "continueErrorOutput"
            assert len(workflow["connections"][name]["main"]) == 2


def test_n8n_exports_do_not_embed_stale_active_versions():
    for _, mirror in (PAIRS["WF22"], PAIRS["WF23"]):
        assert load(mirror).get("activeVersion") is None


def test_wf23_is_the_30_second_two_minute_dispatcher():
    for path in PAIRS["WF23"]:
        workflow = load(path)
        schedules = [n for n in workflow["nodes"] if n["type"] == "n8n-nodes-base.scheduleTrigger"]
        assert len(schedules) == 1
        assert schedules[0]["parameters"]["rule"]["interval"][0]["expression"] == "*/30 * * * * *"
        timeout_query = node(workflow, "Sweep Delivery Timeouts")["parameters"]["query"]
        assert "INTERVAL '2 minutes'" in timeout_query
        assert "o.assigned_agent_id IS NULL" in timeout_query
        assert "o.current_delivery_attempt_id=a.attempt_id" in timeout_query
        assert "o.routing_tier=a.routing_tier" in timeout_query
        assert node(workflow, "Call WF3c Transition")["mode"] == "each"


def test_wf3c_has_no_schedule_and_only_execute_trigger():
    for path in PAIRS["WF3c"]:
        workflow = load(path)
        assert not any(n["type"] == "n8n-nodes-base.scheduleTrigger" for n in workflow["nodes"])
        assert [n for n in workflow["nodes"] if n["type"] == "n8n-nodes-base.executeWorkflowTrigger"]
        assigned_target = workflow["connections"]["Route Transition"]["main"][1][0]["node"]
        assert assigned_target == "V3 Sandy Assignment Durable"
        assert assigned_target != "WhatsApp Sandy Unassigned Alert"


def test_wf10_recurrent_notification_is_the_eight_field_v3_template():
    for path in PAIRS["WF10"]:
        body = node(load(path), "Notify Agent (Returning)")["parameters"]["jsonBody"]
        assert "lead_asignado_v3" in body
        assert body.count('"type": "text"') == 8
        assert '"type": "button"' not in body
