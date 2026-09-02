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


def test_wf10_and_wf12_preserve_and_require_real_easybroker_property_context():
    for path in PAIRS["WF10"]:
        workflow = load(path)
        normalize = node(workflow, "Split & Normalize Leads")["parameters"]["jsCode"]
        prepare = node(workflow, "Prepare V3 Owner Notify")["parameters"]["jsCode"]
        for field in ("operation_type", "property_zone", "property_price", "easybroker_url"):
            assert field in normalize
            assert field in prepare
        assert "owner.property_title" in prepare
        assert "easybroker_public_url_required" in prepare
        assert "easybroker\\.com" in prepare

    for path in PAIRS["WF12"]:
        workflow = load(path)
        extract = node(workflow, "Extract Tags")["parameters"]["jsCode"]
        shape = node(workflow, "Shape Output")["parameters"]["jsCode"]
        for api_field in ("resp.public_url", "resp.public_id", "resp.title", "resp.location", "resp.operations"):
            assert api_field in extract
        assert "easybroker_public_url_missing" in extract
        assert "resolution_ready" in extract
        assert "throw new Error('easybroker_public_url_required')" not in extract
        for field in ("property_title", "operation_type", "property_zone", "property_price", "easybroker_url"):
            assert field in shape


def test_wf10_and_wf12_fail_closed_without_email_storm_or_whatsapp():
    for path in PAIRS["WF12"]:
        workflow = load(path)
        invalid_code_target = workflow["connections"]["Valid EB Code?"]["main"][1][0]["node"]
        assert invalid_code_target == "Extract Tags"
        gate = node(workflow, "Tag Count Exactly One?")["parameters"]["conditions"]["conditions"][0]["leftValue"]
        assert "resolution_ready" in gate
        extract = node(workflow, "Extract Tags")["parameters"]["jsCode"]
        assert "property_public_id_required" in extract
        assert "easybroker_public_url_missing" in extract

    for path in PAIRS["WF10"]:
        workflow = load(path)
        resolved = workflow["connections"]["Owner Resolved?"]["main"]
        assert resolved[0][0]["node"] == "Prepare V3 Owner Notify"
        assert resolved[1][0]["node"] == "Route Missing Owner Data"
        manual = node(workflow, "Route Missing Owner Data")["parameters"]["query"]
        assert "route_dispatch_status='manual_review'" in manual
        assert "easybroker_public_url_missing" in manual


def test_wf13_is_owner_or_primary_and_uses_v3_offer():
    for path in PAIRS["WF13"]:
        workflow = load(path)
        build = node(workflow, "Build Owner Offer")["parameters"]["jsCode"]
        body = node(workflow, "Send Owner Offer")["parameters"]["jsonBody"]
        assert "primary_guard" in build and "backup_guard" not in build
        assert "claim:v3" in build and "lead_subasta_v3" in body
        assert body.count('"type": "text"') == 8
        ordered_fields = (
            "lead_name", "lead_phone", "property_title", "operation_type",
            "property_zone", "property_price", "property_public_id", "easybroker_url",
        )
        positions = [body.index(f"$json.{field}") for field in ordered_fields]
        assert positions == sorted(positions)
        assert "No disponible" not in body[positions[-1]:body.find("}\n        ]", positions[-1])]
        request_query = node(workflow, "Request V3 Route")["parameters"]["query"]
        route_query = node(workflow, "Route Ready V3")["parameters"]["query"]
        route_replacements = node(workflow, "Route Ready V3")["parameters"]["options"]["queryReplacement"]
        assert workflow["connections"]["Build Owner Offer"]["main"][0][0]["node"] == "Request V3 Route"
        assert workflow["connections"]["Request V3 Route"]["main"][0][0]["node"] == "Route Ready V3"
        assert "v3_route_ready_opportunity" in request_query
        assert "$4::bigint IS NOT NULL" in request_query
        assert "a.lease_token=$5" in request_query
        assert "$4::bigint IS NULL" in request_query
        assert "JOIN public.lead_routing_delivery_attempts a ON a.attempt_id=(r.route->>'attempt_id')" not in request_query
        assert "v3_route_ready_opportunity" not in route_query
        assert "$1::jsonb->>'attempt_id'" in route_query
        assert "existing_delivery_requested" in route_query
        assert "a.lease_token=$14" in route_query
        assert "enriched_capture AS (UPDATE public.i24_capture_events" in route_query
        assert "enriched_opportunity AS (UPDATE public.lead_routing_opportunities" in route_query
        assert "'easybroker_url',NULLIF($12::text,'')" in route_query
        assert "offer_context=COALESCE(c0.offer_context,'{}'::jsonb)" in route_query
        assert "v3_offer_context=COALESCE(o1.v3_offer_context,'{}'::jsonb)" in route_query
        assert "c0.opportunity_id=$2::bigint" in route_query
        assert "c0.capture_event_id=$3::bigint" in route_query
        assert "FROM selected s" in route_query
        assert "JOIN public.agents" not in route_query
        assert "JSON.stringify($json.route || {})" in route_replacements
        assert "$('Build Owner Offer').first().json" in route_replacements
        assert "$('Build Owner Offer').item.json" not in route_replacements


def test_wf10_created_new_offer_ack_requires_bound_provider_acceptance():
    for path in PAIRS["WF10"]:
        query = node(load(path), "Verify V3 Dispatch Durable")["parameters"]["query"]
        assert "a.delivery_kind = 'offer'" in query
        assert "NULLIF(a.provider_message_id,'') IS NOT NULL" in query
        assert "a.provider_accepted_at IS NOT NULL" in query
        assert "a.bound_at IS NOT NULL" in query
        assert "a.status IN ('sent','delivered')" in query
        assert "a.delivery_kind IN ('offer','assigned_notice')" not in query


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
        assigned_branches = workflow["connections"]["Is Assigned Notice?"]["main"]
        assert assigned_branches[0][0]["node"] == "Validate Assigned Notice"
        assert assigned_branches[1][0]["node"] == "Build Owner Offer"
        assert workflow["connections"]["Send Assigned Notice"]["main"][1][0]["node"] == "Release Assigned Notice Failure"
        accepted_branches = workflow["connections"]["Assigned Provider Accepted?"]["main"]
        assert accepted_branches[0][0]["node"] == "Bind Assigned Provider Message"
        assert accepted_branches[1][0]["node"] == "Release Assigned Notice Failure"
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
        assert "webhook_event_id: item.webhook_event_id || null" in parser
        assert "claim:v3" in classifier and "v2_drain" in classifier
        assert "const v3ClaimMatch = String(parsed.interactive_id || '')" in classifier
        assert r"/^claim:v3:(\d+):(\d+)$/" in classifier
        assert "webhook_event_id: Number(parsed.webhook_event_id)" in classifier
        assert classifier.index("const v3ClaimMatch") < classifier.index("reason: 'duplicate_message'")


def test_wf3b_routes_v3_to_exact_claim_rpc_and_keeps_v2_drain():
    for path in PAIRS["WF3b"]:
        workflow = load(path)
        condition = node(workflow, "Is Routing V2 Claim?")["parameters"]["conditions"]["conditions"][0]
        gate = condition["leftValue"]
        assert "v2_drain" in gate
        assert condition["rightValue"] == "v2_drain"
        assert condition["operator"] == {"type": "string", "operation": "equals"}
        assert workflow["connections"]["Is Routing V2 Claim?"]["main"][1][0]["node"] == "Claim V3 Delivery"
        claim = node(workflow, "Claim V3 Delivery")
        assert "claim_v3_delivery_from_webhook($1::bigint)" in claim["parameters"]["query"]
        assert "now()" not in claim["parameters"]["query"].lower()
        assert "webhook_event_id" in claim["parameters"]["options"]["queryReplacement"]
        assert claim["credentials"]["postgres"]["id"]
        result_builder = node(workflow, "Build V3 Claim Result")["parameters"]["jsCode"]
        assert "claimed: 'Prospecto asignado. Ya puedes atenderlo.'" in result_builder
        send = node(workflow, "Send Routing V2 Claim Result")
        assert send["continueOnFail"] is False
        assert send["retryOnFail"] is True and send["maxTries"] == 3
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
    for _, mirror in (PAIRS["WF1"], PAIRS["WF3b"], PAIRS["WF22"], PAIRS["WF23"]):
        assert load(mirror).get("activeVersion") is None


def test_repaired_workflow_mirrors_match_canonical_parameters_and_connections():
    for canonical_path, mirror_path in (
        PAIRS["WF1"],
        PAIRS["WF3b"],
        PAIRS["WF10"],
        PAIRS["WF13"],
    ):
        canonical = load(canonical_path)
        mirror = load(mirror_path)
        canonical_parameters = {
            item["name"]: item.get("parameters") for item in canonical["nodes"]
        }
        mirror_parameters = {
            item["name"]: item.get("parameters") for item in mirror["nodes"]
        }
        assert mirror_parameters == canonical_parameters
        assert mirror["connections"] == canonical["connections"]


def test_wf23_is_the_30_second_two_minute_dispatcher():
    for path in PAIRS["WF23"]:
        workflow = load(path)
        if "active" in workflow:
            assert workflow["active"] is False
        schedules = [n for n in workflow["nodes"] if n["type"] == "n8n-nodes-base.scheduleTrigger"]
        assert len(schedules) == 1
        assert schedules[0]["parameters"]["rule"]["interval"][0]["expression"] == "*/30 * * * * *"
        assert workflow["settings"]["executionTimeout"] == 20
        timeout_node = node(workflow, "Sweep Delivery Timeouts")
        assert timeout_node["parameters"]["options"] == {"connectionTimeout": 8}
        timeout_query = timeout_node["parameters"]["query"]
        assert timeout_query.startswith("SET LOCAL statement_timeout = '8s';")
        assert "SELECT * FROM public.v3_claim_delivery_attempts" in timeout_query
        assert timeout_node.get("retryOnFail") is not True
        assert "INTERVAL '2 minutes'" in timeout_query
        assert "o.assigned_agent_id IS NULL" in timeout_query
        assert "o.current_delivery_attempt_id=a.attempt_id" in timeout_query
        assert "o.routing_tier=a.routing_tier" in timeout_query
        assert "a.status='delivered'" in timeout_query
        assert "INTERVAL '5 minutes'" in timeout_query
        # Contract 5.2: a lead without an EasyBroker URL must still expire and reach guard/Sandy.
        assert "easybroker_url" not in timeout_query
        assigned_node = node(workflow, "Claim Assigned Notices")
        assert assigned_node["parameters"]["options"] == {"connectionTimeout": 8}
        assigned_query = assigned_node["parameters"]["query"]
        assert assigned_query.startswith("SET LOCAL statement_timeout = '8s';")
        assert "SELECT * FROM public.claim_v3_assigned_notices" in assigned_query
        assert assigned_node.get("retryOnFail") is not True
        assert "easybroker_url" in assigned_query
        assert "easybroker" in assigned_query
        assert workflow["connections"]["Sweep Delivery Timeouts"]["main"][0][0]["node"] == "Has Timeout Candidate?"
        assert workflow["connections"]["Has Timeout Candidate?"]["main"][0][0]["node"] == "Call WF3c Transition"
        assert workflow["connections"]["Claim Assigned Notices"]["main"][0][0]["node"] == "Has Assigned Notice?"
        assert workflow["connections"]["Has Assigned Notice?"]["main"][0][0]["node"] == "Call WF13 Assigned Notice"
        assert node(workflow, "Call WF3c Transition")["parameters"]["mode"] == "each"
        assert node(workflow, "Call WF13 Assigned Notice")["parameters"]["mode"] == "each"


def test_wf20_watchdog_database_checks_are_bounded():
    payload = load("n8n-export/BYG_WF20_Watchdog_.json")
    assert isinstance(payload, list) and len(payload) == 1
    workflow = payload[0]
    assert workflow["id"] == "pYV88ntxI0Lc4NCB"
    assert workflow["settings"]["executionTimeout"] == 30

    expected = {
        "Check scraper health",
        "Revisar Fallos de Routing",
        "Revisar Casos Sin Asignar",
    }
    postgres = {
        item["name"]: item
        for item in workflow["nodes"]
        if item["name"] in expected
    }
    assert set(postgres) == expected
    for item in postgres.values():
        parameters = item["parameters"]
        assert parameters["options"]["connectionTimeout"] == 8
        assert parameters["query"].startswith("SET LOCAL statement_timeout = '8s'; ")
        assert item.get("retryOnFail") is not True


def test_wf3c_has_no_schedule_and_only_execute_trigger():
    for path in PAIRS["WF3c"]:
        workflow = load(path)
        assert not any(n["type"] == "n8n-nodes-base.scheduleTrigger" for n in workflow["nodes"])
        assert [n for n in workflow["nodes"] if n["type"] == "n8n-nodes-base.executeWorkflowTrigger"]
        assigned_target = workflow["connections"]["Route Transition"]["main"][1][0]["node"]
        assert assigned_target == "V3 Sandy Assignment Durable"
        assert assigned_target != "WhatsApp Sandy Unassigned Alert"
        transition_query = node(workflow, "Advance Expired Tiers")["parameters"]["query"]
        hydrate_query = node(workflow, "Hydrate Transition Attempt")["parameters"]["query"]
        assert workflow["connections"]["Advance Expired Tiers"]["main"][0][0]["node"] == "Hydrate Transition Attempt"
        assert workflow["connections"]["Hydrate Transition Attempt"]["main"][0][0]["node"] == "Route Transition"
        assert "a.attempt_id=ctx.attempt_id" in hydrate_query
        assert "COALESCE(a.capture_event_id,ctx.capture_event_id)" in hydrate_query
        for required_context in (
            "attempt_id",
            "capture_event_id",
            "recipient_number",
            "lease_token",
            "property_public_id",
            "easybroker_url",
        ):
            assert required_context in hydrate_query
        assert "attempt_id" in transition_query
        assert "capture_event_id" in transition_query
        assert "lead_routing_delivery_attempts" not in transition_query


def test_wf10_recurrent_notification_is_the_eight_field_v3_template():
    for path in PAIRS["WF10"]:
        body = node(load(path), "Notify Agent (Returning)")["parameters"]["jsonBody"]
        assert "lead_asignado_v3" in body
        assert body.count('"type": "text"') == 8
        assert '"type": "button"' not in body
