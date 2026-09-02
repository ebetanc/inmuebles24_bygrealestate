"""Executable SQL contract for routing-v2 scenarios S-01 through S-12."""
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest


MIGRATIONS = Path(__file__).parents[1] / "whatsapp-agent" / "migrations"
WORKFLOWS = Path(__file__).parents[1] / "whatsapp-agent" / "workflows"
EXPORTS = Path(__file__).parents[1] / "n8n-export"


def migration(name: str) -> str:
    path = MIGRATIONS / name
    assert path.exists(), f"missing routing-v2 implementation: {name}"
    return path.read_text(encoding="utf-8")


def without_comments(sql: str) -> str:
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    return re.sub(r"--[^\n]*", " ", sql)


def normalized(sql: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"\bpublic\.", "", sql, flags=re.I)).strip().lower()


def extract_function(sql: str, name: str) -> str:
    clean = without_comments(sql)
    pattern = re.compile(
        rf"create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?{re.escape(name)}"
        rf"\s*\(.*?\)\s*returns\b.*?\bas\s+(?P<tag>\$[a-zA-Z_0-9]*\$)"
        rf"(?P<body>.*?)(?P=tag)\s*language\b",
        re.IGNORECASE | re.DOTALL,
    )
    match = pattern.search(clean)
    assert match, f"missing CREATE FUNCTION body: {name}"
    return normalized(match.group("body"))


def extract_statement(sql: str, start_pattern: str) -> str:
    match = re.search(rf"{start_pattern}\b.*?;", without_comments(sql), re.I | re.S)
    assert match, f"missing SQL statement: {start_pattern}"
    return normalized(match.group(0))


def extract_index(sql: str, index_name: str) -> str:
    return extract_statement(
        sql,
        rf"create\s+unique\s+index(?:\s+if\s+not\s+exists)?\s+{re.escape(index_name)}",
    )


def requires(sql: str, *rules: str) -> None:
    for rule in rules:
        assert re.search(rule, sql), f"missing executable SQL rule: {rule}"


def load_single_workflow_export(path: Path) -> dict:
    raw = json.loads(path.read_text(encoding="utf-8-sig"))
    if isinstance(raw, list):
        assert len(raw) == 1, f"expected one workflow in export: {path.name}"
        raw = raw[0]
    assert isinstance(raw, dict), f"invalid workflow export: {path.name}"
    return raw


def published_workflow_editions(workflow: dict) -> tuple[dict, ...]:
    editions = [workflow]
    embedded = workflow.get("activeVersion")
    if workflow.get("active") is True:
        assert workflow.get("activeVersionId") == workflow.get("versionId"), (
            "active export must identify its current version as published"
        )
    if embedded is not None:
        assert isinstance(embedded, dict)
        editions.append(embedded)
    return tuple(editions)


def assert_connections_equivalent(actual: dict, expected: dict) -> None:
    """Treat only omitted trailing empty n8n outputs as serialization noise."""
    assert set(actual) == set(expected)
    for node_name in expected:
        actual_main = list(actual[node_name]["main"])
        expected_main = list(expected[node_name]["main"])
        while actual_main and actual_main[-1] == []:
            actual_main.pop()
        while expected_main and expected_main[-1] == []:
            expected_main.pop()
        assert actual_main == expected_main, f"connection drift at {node_name!r}"


def test_s01_owner_offer_starts_five_minute_sla_only_on_delivery():
    body = extract_function(migration("0021_lead_routing_v2.sql"), "mark_offer_delivered")
    event = extract_statement(body, r"insert\s+into\s+lead_routing_events")
    update = extract_statement(body, r"update\s+lead_routing_opportunities")
    requires(
        update,
        r"state\s*=\s*'owner_open'",
        r"delivery_status\s*=\s*'delivered'",
        r"delivered_at\s*=\s*[^,;]+",
        r"expires_at\s*=\s*[^,;]*delivered_at[^,;]*\+\s*interval\s*'5 minutes'",
    )
    requires(
        body,
        r"idempotency_key\s+is\s+null\s+or\s+btrim\s*\(\s*p_idempotency_key\s*\)\s*=\s*''",
        r"on\s+conflict\s*\(\s*idempotency_key\s*\)\s+do\s+nothing\s+returning\s+event_id",
        r"v_existing_opportunity_id\s+is\s+distinct\s+from\s+p_opportunity_id",
        r"v_existing_event_type\s+is\s+distinct\s+from\s*'delivery_confirmed'",
    )
    assert body.index(event) < body.index(update), "event insert must precede opportunity mutation"


def test_lrv2_008_offer_delivery_workflows_are_correlated_and_idempotent():
    wf1 = json.loads((WORKFLOWS / "WF1_inbound_router.json").read_text(encoding="utf-8"))
    wf13 = json.loads((WORKFLOWS / "WF13_directed_notify.json").read_text(encoding="utf-8"))
    wf22 = json.loads((WORKFLOWS / "WF22_delivery_status.json").read_text(encoding="utf-8"))
    wf23 = json.loads((WORKFLOWS / "WF23_delivery_timeout_sweeper.json").read_text(encoding="utf-8"))
    raw1, raw13, raw22 = map(normalized, map(json.dumps, (wf1, wf13, wf22)))

    assert "claim:" in raw1 and "interactive_id" in raw1
    requires(raw13, r"lead_subasta_v3", r"claim:v3", r"v3_route_ready_opportunity", r"v3_record_provider_accepted", r"should send\?", r"should_send")
    wf13_queries = "\n".join(
        normalized(node.get("parameters", {}).get("query", "")) for node in wf13["nodes"]
    )
    assert "mark_offer_delivered" not in raw13
    assert not re.search(
        r"\bupdate\s+(?:public\.)?lead_routing_opportunities\s+set\b[^;]*\bexpires_at\s*=",
        wf13_queries,
    )
    requires(raw22, r"record_delivery_callback", r"x-hub-signature-256", r"createhmac", r"status.*delivered")
    requires(
        raw1,
        r"n8n-nodes-base\.webhook",
        r"rawbody",
        r"x-hub-signature-256",
        r"verify meta signature",
        r"record and reconcile callback",
        r"parse evolution payload",
    )
    requires(raw22, r"binary.*data.*data", r"buffer.from.*base64", r"timingsafeequal", r"wf1_workflow_id")
    requires(normalized(json.dumps(wf23)), r"v3_claim_delivery_attempts", r"interval '2 minutes'")
    assert wf23["connections"]["Sweep Delivery Timeouts"]["main"][0][0]["node"] == "Has Timeout Candidate?"
    assert wf23["connections"]["Has Timeout Candidate?"]["main"][0][0]["node"] == "Call WF3c Transition"
    assert wf23["connections"]["Has Timeout Candidate?"]["main"][1] == []
    assert wf23["settings"]["saveDataSuccessExecution"] == "none"
    delivery_sql = normalized(migration("0030_delivery_attempts.sql"))
    requires(
        delivery_sql,
        r"create table if not exists lead_routing_delivery_attempts",
        r"provider_message_id text unique",
        r"create table if not exists lead_routing_delivery_callbacks",
        r"unique \(provider_message_id, delivery_status\)",
        r"create function create_delivery_attempt\(",
        r"returns table \([^)]*should_send boolean",
        r"create or replace function claim_pending_guard_deliveries\(",
        r"event_type is distinct from \(case when v_tier is null then 'unassigned_alerted' else 'escalated' end\)",
        r"lease_token is distinct from p_lease_token.*lease_expires_at<=now\(\)",
        r"v_tier:='backup_guard'",
        r"gen_random_uuid\(\)::text",
        r"status='requested' and v_attempt.provider_message_id is null and v_attempt.lease_expires_at<=now\(\)",
        r"guard delivery request collision",
        r"guard delivery event collision",
        r"order by case delivery_status when 'delivered' then 3 when 'failed' then 2 when 'sent' then 1 end desc, received_at desc, callback_id desc",
        r"target_number is not null and coalesce\(delivered_at,failed_at,bound_at,requested_at,created_at\)<p_before",
        r"received_at\+interval '5 minutes'",
    )
    assert "status in ('delivered','failed') and coalesce(delivered_at,failed_at,created_at)<p_before" not in delivery_sql
    assert "md5(random()::text||clock_timestamp()::text)" not in delivery_sql
    create_attempt = extract_function(migration("0030_delivery_attempts.sql"), "create_delivery_attempt")
    requires(
        create_attempt,
        r"from lead_routing_opportunities o where o\.opportunity_id=p_opportunity_id",
        r"from lead_routing_events e where e\.idempotency_key=",
        r"from lead_routing_delivery_attempts a where a\.client_request_id=p_client_request_id",
    )
    guard_claim = extract_function(migration("0030_delivery_attempts.sql"), "claim_pending_guard_deliveries")
    assert guard_claim.index("guard delivery event collision") < guard_claim.index("insert into lead_routing_delivery_attempts")
    assert not re.search(r"update lead_routing_opportunities set routing_tier=v_tier", guard_claim)
    fail_unbound = extract_function(migration("0030_delivery_attempts.sql"), "fail_unbound_delivery_attempt")
    requires(
        fail_unbound,
        r"status<>'requested' or v_attempt\.provider_message_id is not null then return v_opp",
        r"current_delivery_attempt_id is distinct from v_attempt\.attempt_id",
        r"lease_token=p_lease_token and lease_expires_at>now\(\) returning \* into v_attempt",
    )
    assert fail_unbound.index("returning * into v_attempt") < fail_unbound.index("fallback_failed_owner_delivery")
    delivery_sweeper = extract_function(migration("0030_delivery_attempts.sql"), "sweep_owner_delivery_no_callback")
    requires(
        delivery_sweeper,
        r"status='requested' and a\.provider_message_id is null and a\.lease_expires_at is not null and a\.lease_expires_at<=now\(\)",
        r"current_delivery_attempt_id=a\.attempt_id",
        r"return next fallback_failed_owner_delivery\(v_attempt\.attempt_id",
        r"for update of a skip locked",
    )
    assert "routing_tier=" not in delivery_sweeper
    assert wf13["connections"]["Route Ready V3"]["main"][0][0]["node"] == "Should Send?"
    assert wf13["connections"]["Should Send?"]["main"][0][0]["node"] == "Send Owner Offer"
    assert wf13["connections"]["Should Send?"]["main"][1][0]["node"] == "End (Already Handled)"
    for function in (
        "create_delivery_attempt",
        "bind_delivery_message",
        "fail_unbound_delivery_attempt",
    ):
        assert extract_function(migration("0030_delivery_attempts.sql"), function)
    for workflow in (wf1, wf13, wf22, wf23):
        names = [node["name"] for node in workflow["nodes"]]
        ids = [node["id"] for node in workflow["nodes"]]
        assert len(names) == len(set(names))
        assert len(ids) == len(set(ids))
        for connection in workflow["connections"].values():
            assert isinstance(connection["main"], list)
            assert all(isinstance(branch, list) for branch in connection["main"])

    fixture = json.loads((Path(__file__).parent / "fixtures/routing_v2/delivery_status_callbacks.json").read_text())
    statuses = [case["status"] for case in fixture]
    assert statuses.count("delivered") >= 2
    assert {"sent", "delivered", "failed"}.issubset(statuses)
    assert {"owner_without_primary_uses_backup", "stale_lease_token_rejected", "purge_redacts_target_number"}.issubset(
        {case["name"] for case in fixture}
    )

    for source, export_name in (
        (wf1, "WF1_-_Inbound_Router__Evolution__.json"),
        (wf13, "WF13_-_Directed_Owner_Notify__Cloud_API__.json"),
        (wf22, "WF22_-_Delivery_Status_.json"),
        (wf23, "WF23_-_Delivery_Timeout_Sweeper_.json"),
    ):
        export = json.loads((EXPORTS / export_name).read_text(encoding="utf-8"))
        source_nodes = {node["name"]: node for node in source["nodes"]}
        # Current top-level exports carry the V3 contract; historical activeVersion
        # snapshots may still contain retired pre-V3 UI wiring.
        for edition in (export,):
            assert edition is not None, f"{export_name} needs a current export"
            export_nodes = {node["name"]: node for node in edition["nodes"]}
            if export_name == "WF23_-_Delivery_Timeout_Sweeper_.json":
                assert {"Sweep Delivery Timeouts", "Has Timeout Candidate?", "Call WF3c Transition"}.issubset(export_nodes)
                mirror_query = export_nodes["Sweep Delivery Timeouts"]["parameters"]["query"].lower()
                assert "2 minutes" in mirror_query
                assert export_nodes["Call WF3c Transition"]["parameters"]["workflowId"]
            else:
                assert export_nodes == source_nodes
            if export_name == "WF23_-_Delivery_Timeout_Sweeper_.json":
                # An empty query result must stop at the explicit gate; only a
                # real timeout candidate may enter WF3c.
                assert edition["connections"]["Sweep Delivery Timeouts"]["main"][0][0]["node"] == "Has Timeout Candidate?"
                assert edition["connections"]["Has Timeout Candidate?"]["main"][0][0]["node"] == "Call WF3c Transition"
                assert edition["connections"]["Has Timeout Candidate?"]["main"][1] == []
            else:
                assert edition["connections"] == source["connections"]


def test_s02_s03_active_identity_is_unique_per_person_and_property():
    sql = migration("0021_lead_routing_v2.sql")
    index = extract_index(sql, "lead_routing_opportunities_active_identity_uniq")
    requires(
        index,
        r"on\s+lead_routing_opportunities\s*\(\s*identity_key\s*,\s*property_id\s*\)",
        r"where\s+state\s+not\s+in\s*\(\s*'closed_won'\s*,\s*'closed_lost'\s*\)",
    )
    requires(index, r"identity_key\s+is\s+not\s+null", r"property_id\s+is\s+not\s+null")


def test_s04_night_window_and_0805_drain_are_central_and_idempotent():
    sql = migration("0023_routing_business_time.sql")
    daytime = extract_function(sql, "is_daytime_at")
    claim = extract_function(sql, "claim_night_queue")
    ack = extract_function(sql, "ack_night_queue_handoff")
    requires(
        daytime,
        r"america/mexico_city",
        r"cdmx_time\s*>=\s*time\s*'08:00:00'",
        r"cdmx_time\s*<\s*time\s*'20:00:00'",
    )
    requires(
        claim,
        r"08:05",
        r"p_batch_size\s+is\s+null",
        r"where\s+[^;]*processed\s*=\s*false",
        r"for\s+update\s+skip\s+locked",
        r"order\s+by\s+[^;]*queued_at\s*,\s*[^;]*id",
        r"processing_status\s*=\s*'processing'",
        r"lease_token\s*=\s*gen_random_uuid\s*\(\s*\)",
        r"lease_expires_at\s*=\s*p_now\s*\+\s*p_lease_duration",
        r"p_lease_duration\s*>\s*interval\s*'15 minutes'",
    )
    assert "processed = true" not in claim
    assert "insert into lead_routing_events" not in claim
    requires(
        ack,
        r"insert\s+into\s+lead_routing_events\b[^;]*'night_queue_activated'",
        r"on\s+conflict\s*\(\s*idempotency_key\s*\)\s+do\s+nothing",
        r"lease_token\s*=\s*p_lease_token",
        r"processing_status\s*=\s*'processed'",
        r"processed\s*=\s*true",
        r"v_status\s*=\s*'processed'.*processed handoff replay does not match durable event.*return true",
        r"v_status\s+is\s+distinct\s+from\s*'processing'",
        r"v_lease_expires_at\s*<=\s*now\s*\(\s*\)",
        r"processing_status\s*=\s*'processing'[^;]*lease_expires_at\s*>\s*now\s*\(\s*\)",
    )
    assert ack.index("insert into lead_routing_events") < ack.index("update night_queue")

    wf7_raw = (WORKFLOWS / "WF7_morning_report.json").read_text(encoding="utf-8")
    wf10_raw = (WORKFLOWS / "WF10_scraper_intake.json").read_text(encoding="utf-8")
    wf7 = json.loads(wf7_raw)
    wf10 = json.loads(wf10_raw)
    wf7_sql = normalized(wf7_raw)
    wf10_sql = normalized(wf10_raw)
    requires(wf7_sql, r"select\s+\*\s+from\s+claim_night_queue\s*\(")
    requires(wf7_sql, r"select\s+ack_night_queue_handoff\s*\(")
    assert not re.search(r"update\s+night_queue\s+set\s+processed", wf7_sql)
    assert wf7["connections"]["Trigger 8:00 AM CDMX (Report)"]["main"] == [[{
        "node": "Fetch Pending Night Queue", "type": "main", "index": 0,
    }]]
    assert wf7["connections"]["Trigger 8:05 AM CDMX (Process Queue)"]["main"] == [[{
        "node": "Release V3 Night Queue 08:05", "type": "main", "index": 0,
    }]]
    assert wf7["connections"]["Release V3 Night Queue 08:05"]["main"] == [[{
        "node": "Fetch Queue for Processing", "type": "main", "index": 0,
    }]]
    assert wf7["connections"]["Fetch Pending Night Queue"]["main"] == [[{
        "node": "Fetch Night Stats", "type": "main", "index": 0,
    }]]
    assert wf7["connections"]["Fetch Night Stats"]["main"] == [[{
        "node": "Build Morning Report", "type": "main", "index": 0,
    }]]
    assert wf7["connections"]["Process One by One"]["main"][0][0]["node"] == "Build Confirmation Message"
    assert wf7["connections"]["Process One by One"]["main"][1][0]["node"] == "Check Routing Safe Mode"
    assert "Call WF3a: Auction Launcher" not in {node["name"] for node in wf7["nodes"]}
    nodes = {node["name"]: node for node in wf7["nodes"]}
    assert nodes["Resolve Owner (WF12)"]["parameters"]["workflowId"] == {
        "__rl": True, "value": "w7yJr7naWoxPq6Pw", "mode": "id"
    }
    assert nodes["Notify Owner (WF13)"]["parameters"]["workflowId"] == {
        "__rl": True, "value": "Bo2YbbUpmBzRbhDa", "mode": "id"
    }
    assert wf7["connections"]["Safe Mode Active?"]["main"][0][0]["node"] == "Route Direct To Guard (Safe Mode)"
    assert wf7["connections"]["Safe Mode Active?"]["main"][1][0]["node"] == "Restore Night Routing Context"
    assert wf7["connections"]["Owner Resolved?"]["main"][0][0]["node"] == "Prepare Owner Notify"
    assert wf7["connections"]["Owner Resolved?"]["main"][1][0]["node"] == "Route Missing Owner Data"
    assert wf7["connections"]["Notify Owner (WF13)"]["main"][0][0]["node"] == "Acknowledge Durable Handoff"
    assert wf7["connections"]["Route Missing Owner Data"]["main"][0][0]["node"] == "Acknowledge Durable Handoff"
    assert wf7["connections"]["Route Direct To Guard (Safe Mode)"]["main"][0][0]["node"] == "Acknowledge Durable Handoff"
    assert wf7["connections"]["Acknowledge Durable Handoff"]["main"][0][0]["node"] == "Process One by One"

    requires(wf10_sql, r"select\s+is_daytime\s*\(\s*\)")
    route_code = next(n["parameters"]["jsCode"] for n in wf10["nodes"] if n["name"] == "Route Decision")
    assert route_code.index("if (!isDay)") < route_code.index("if (isReturning && sameProperty)")
    night_sql = normalized(next(n["parameters"]["query"] for n in wf10["nodes"] if n["name"] == "Create Night Conversation"))
    enqueue_sql = normalized(next(n["parameters"]["query"] for n in wf10["nodes"] if n["name"] == "Insert Night Queue"))
    requires(night_sql, r"upsert_i24_lead_opportunity_recovering\s*\(", r"'queued_night'")
    assert "insert into lead_routing_opportunities" not in night_sql
    requires(enqueue_sql, r"where\s+\$7::bigint\s+is\s+not\s+null")
    requires(
        enqueue_sql,
        r"on\s+conflict\s*\(\s*opportunity_id\s*\)\s+where\s+opportunity_id\s+is\s+not\s+null\s+do\s+nothing",
    )

    wf7_export = json.loads(
        (EXPORTS / "WF7_-_Morning_Report___Night_Queue_Processing_.json").read_text(encoding="utf-8")
    )
    wf10_export = json.loads(
        (EXPORTS / "WF10_-_Scraper_Lead_Intake_.json").read_text(encoding="utf-8")
    )
    critical_wf7_nodes = {
        "Fetch Queue for Processing",
        "Process One by One",
        "Check Routing Safe Mode",
        "Resolve Owner (WF12)",
        "Notify Owner (WF13)",
        "Route Missing Owner Data",
        "Acknowledge Durable Handoff",
    }
    critical_wf10_nodes = {
        "Check Returning Lead + Time",
        "Route Decision",
        "Create Night Conversation",
        "Insert Night Queue",
        "Persist Non-routable Opportunity",
    }
    source_wf7_nodes = {n["name"]: n for n in wf7["nodes"]}
    source_wf10_nodes = {n["name"]: n for n in wf10["nodes"]}
    wf7_editions = [wf7_export]
    if isinstance(wf7_export.get("activeVersion"), dict):
        wf7_editions.append(wf7_export["activeVersion"])
    for edition in wf7_editions:
        export_sql = normalized(json.dumps(edition))
        requires(export_sql, r"claim_night_queue", r"ack_night_queue_handoff")
        assert "update night_queue set processed" not in export_sql
        export_nodes = {n["name"]: n for n in edition["nodes"]}
        for name in critical_wf7_nodes:
            assert export_nodes[name] == source_wf7_nodes[name]
        for name in critical_wf7_nodes:
            if name in wf7["connections"]:
                assert edition["connections"][name] == wf7["connections"][name]
        for name in (
            "Trigger 8:00 AM CDMX (Report)",
            "Fetch Pending Night Queue",
            "Fetch Night Stats",
        ):
            assert edition["connections"][name] == wf7["connections"][name]
    # Validate the current top-level export; activeVersion is a historical snapshot.
    wf10_editions = [wf10_export]
    for edition in wf10_editions:
        export_sql = normalized(json.dumps(edition))
        requires(
            export_sql,
            r"upsert_i24_lead_opportunity_recovering",
            r"where \$7::bigint is not null",
        )
        assert "insert into lead_routing_opportunities" not in export_sql
        export_nodes = {n["name"]: n for n in edition["nodes"]}
        for name in critical_wf10_nodes:
            assert export_nodes[name] == source_wf10_nodes[name]
        for name in ("Route", "Create Night Conversation", "Persist Non-routable Opportunity"):
            assert edition["connections"][name] == wf10["connections"][name]


def test_s05_s06_s07_tiers_are_sequential_and_end_unassigned():
    sql = migration("0027_advance_routing_tier.sql")
    body = extract_function(sql, "advance_routing_tier")
    requires(
        body,
        r"for\s+update",
        r"owner_open.*primary_guard_open.*backup_guard_open",
        r"when\s+'owner'\s+then\s+'primary_guard'",
        r"when\s+'primary_guard'\s+then\s+'backup_guard'",
        r"guard_delivery_pending",
        r"unassigned_alerted",
        r"assigned_agent_id\s*=\s*null",
        r"insert\s+into\s+lead_routing_events",
        r"lease_token\s*=\s*null",
        r"expires_at\s*=\s*null",
        r"tier transition event collision",
    )
    assert body.index("insert into lead_routing_events") < body.index("update lead_routing_opportunities")
    assert "agent_manager" not in body
    assert "mark_assigned" not in body

    sweep = extract_function(sql, "sweep_expired_routing_tiers")
    requires(sweep, r"for\s+update\s+skip\s+locked", r"expires_at<=p_now", r"advance_routing_tier")
    queue = extract_function(sql, "queue_guard_routing")
    requires(queue, r"for\s+update", r"guard_delivery_pending", r"coverage_role.*primary.*backup", r"guard routing event collision")

    wf3c = json.loads((WORKFLOWS / "WF3c_expiry_sweeper.json").read_text(encoding="utf-8"))
    raw = normalized(json.dumps(wf3c))
    requires(raw, r"v3_advance_routing_tier", r"claim_pending_guard_deliveries", r"bo2ybbupmbzrbhda")
    requires(raw, r"lease_token", r"target_agent_id")
    assert "assign manager" not in raw
    assert "fetch agent pool" not in raw
    assert wf3c["connections"]["Route Transition"]["main"][0][0]["node"] == "Call Directed Guard Offer"
    assert wf3c["connections"]["Route Transition"]["main"][1][0]["node"] == "V3 Sandy Assignment Durable"
    assert wf3c["connections"]["Route Transition"]["main"][2][0]["node"] == "Reject Unexpected Transition State"
    assert not any(node["type"] == "n8n-nodes-base.scheduleTrigger" for node in wf3c["nodes"])
    assert wf3c["connections"]["When Called by WF23"]["main"][0][0]["node"] == "Advance Expired Tiers"
    nodes = {node["name"]: node for node in wf3c["nodes"]}
    assert wf3c["connections"]["Advance Expired Tiers"]["main"][0][0]["node"] == "Hydrate Transition Attempt"
    assert wf3c["connections"]["Hydrate Transition Attempt"]["main"][0][0]["node"] == "Route Transition"
    assert "a.attempt_id=ctx.attempt_id" in nodes["Hydrate Transition Attempt"]["parameters"]["query"]
    assert "V3 Sandy Alert Target" not in nodes
    assert "V3 Sandy Alert Target" not in wf3c["connections"]
    route_options = nodes["Route Transition"]["parameters"]["options"]
    assert route_options == {
        "fallbackOutput": "extra",
        "renameFallbackOutput": "unexpected_state",
    }
    assert "unexpected_routing_transition_state" in nodes[
        "Reject Unexpected Transition State"
    ]["parameters"]["jsCode"]
    assert nodes["Call Directed Guard Offer"]["parameters"]["workflowId"] == {
        "__rl": True, "value": "Bo2YbbUpmBzRbhDa", "mode": "id",
    }
    alert = nodes["WhatsApp Sandy Unassigned Alert"]
    assert not alert.get("continueOnFail", False)
    assert alert["type"] == "n8n-nodes-base.httpRequest"
    assert "alerta_routing_v3" in alert["parameters"]["jsonBody"]
    assert "$json.manager_phone" in alert["parameters"]["jsonBody"]
    claim_alert = normalized(json.dumps(nodes["Claim Unassigned Alert Lease"]))
    requires(claim_alert, r"agent_manager", r"manager_phone", r"lead_name", r"lead_phone")
    assert "record_unassigned_alert" in normalized(json.dumps(nodes["Record Retryable Unassigned Alert"]))
    assert "claim_unassigned_alerts" in normalized(json.dumps(nodes["Claim Unassigned Alert Lease"]))
    assert "complete_unassigned_alert_notification" in normalized(json.dumps(nodes["Acknowledge Unassigned Alert"]))
    assert "'whatsapp'" in json.dumps(nodes["Acknowledge Unassigned Alert"])
    assert "Record Retryable Unassigned Alert" not in wf3c["connections"]
    assert wf3c["connections"]["Claim Unassigned Alert Lease"]["main"][0][0]["node"] == "WhatsApp Sandy Unassigned Alert"
    assert wf3c["connections"]["WhatsApp Sandy Unassigned Alert"]["main"][0][0]["node"] == "Acknowledge Unassigned Alert"

    lease_sql = migration("0035_unassigned_alert_effect_lease.sql")
    alert_schema = normalized(migration("0029_routing_v2_metrics.sql"))
    assert "first_alerted_at timestamptz not null default now()" in alert_schema
    assert "first_alerted_at" in normalized(lease_sql)
    assert "routing_v2_unassigned_alerts (acknowledged, lease_expires_at, created_at" not in normalized(lease_sql)
    claim = extract_function(lease_sql, "claim_unassigned_alerts")
    requires(
        claim,
        r"for\s+update\s+of\s+a\s+skip\s+locked",
        r"lease_token\s*=\s*gen_random_uuid\s*\(\s*\)",
        r"lease_expires_at\s*=\s*p_now\s*\+\s*p_lease_duration",
        r"lease_token\s+is\s+null\s+or\s+a\.lease_expires_at\s*<=\s*p_now",
        r"order\s+by\s+a\.first_alerted_at\s*,\s*a\.alert_id",
    )
    complete = extract_function(lease_sql, "complete_unassigned_alert_delivery")
    requires(
        complete,
        r"lease_token\s*=\s*p_lease_token",
        r"lease_expires_at\s*>\s*now\s*\(\s*\)",
        r"acknowledged_by\s*=\s*'wf3c:whatsapp:'\s*\|\|\s*p_provider_message_id",
        r"stale or missing unassigned alert lease",
    )

    notification_sql = migration("0043_email_unassigned_alert_ack.sql")
    notification = extract_function(notification_sql, "complete_unassigned_alert_notification")
    requires(
        notification,
        r"v_channel\s+not\s+in\s*\(\s*'email'\s*,\s*'whatsapp'\s*\)",
        r"lease_token\s*=\s*p_lease_token",
        r"lease_expires_at\s*>\s*now\s*\(\s*\)",
        r"acknowledged_by\s*=\s*'wf3c:'\s*\|\|\s*v_channel\s*\|\|\s*':'\s*\|\|\s*v_external_id",
        r"stale or missing unassigned alert lease",
    )

    export = json.loads((EXPORTS / "WF3c_-_Auction_Expiry_Sweeper__Tiered__.json").read_text(encoding="utf-8-sig"))
    source_nodes = {node["name"]: node for node in wf3c["nodes"]}
    assert {node["name"]: node for node in export["nodes"]} == source_nodes
    assert export["connections"] == wf3c["connections"]
    assert export.get("activeVersion") is None

    wf13 = json.loads((WORKFLOWS / "WF13_directed_notify.json").read_text(encoding="utf-8"))
    wf13_raw = normalized(json.dumps(wf13))
    requires(wf13_raw, r"v3_record_provider_accepted", r"target_agent_id.*\$json\.target_agent_id", r"v3_route_ready_opportunity")

    # Every canonical intake consumer must avoid the retired fan-out launcher.
    consumers = (
        ("WF2_lead_intake.json", "WF2_-_Lead_Intake__Evolution__.json"),
        ("WF10_scraper_intake.json", "WF10_-_Scraper_Lead_Intake_.json"),
    )
    for source_name, export_name in consumers:
        source = json.loads((WORKFLOWS / source_name).read_text(encoding="utf-8-sig"))
        source_raw = normalized(json.dumps(source))
        assert "wf3a_workflow_id" not in source_raw
        assert "call wf3a" not in source_raw
        if source_name == "WF2_lead_intake.json":
            requires(source_raw, r"queue_guard_routing", r"queue directed guard routing")
        edition_export = json.loads((EXPORTS / export_name).read_text(encoding="utf-8-sig"))
        for edition in (edition_export, edition_export.get("activeVersion")):
            if edition is None:
                continue
            edition_raw = normalized(json.dumps(edition))
            assert "wf3a_workflow_id" not in edition_raw
            assert "call wf3a" not in edition_raw

    wf3a = json.loads((WORKFLOWS / "WF3a_auction_launcher.json").read_text(encoding="utf-8"))
    wf3a_raw = normalized(json.dumps(wf3a))
    requires(wf3a_raw, r"legacy auction disabled", r"sequential routing only")
    for forbidden in ("fetch agent pool", "build fan-out", "agent_manager", "insert into auctions"):
        assert forbidden not in wf3a_raw


def test_wf3c_whatsapp_alert_records_channel_aware_delivery_evidence():
    workflow = json.loads(
        (WORKFLOWS / "WF3c_expiry_sweeper.json").read_text(encoding="utf-8")
    )
    nodes = {node["name"]: node for node in workflow["nodes"]}
    alert = nodes["WhatsApp Sandy Unassigned Alert"]
    assert workflow["settings"]["saveDataSuccessExecution"] == "none"

    assert alert["type"] == "n8n-nodes-base.httpRequest"
    assert alert["parameters"]["url"] == (
        "={{ $env.WA_CLOUD_API_BASE_URL + '/' + $env.WA_API_VERSION + '/' + "
        "$env.WA_PHONE_NUMBER_ID + '/messages' }}"
    )
    assert alert["parameters"]["headerParameters"]["parameters"][0]["value"] == (
        "=Bearer {{ $env.WA_ACCESS_TOKEN }}"
    )
    assert alert["parameters"]["jsonBody"].startswith("={")
    assert not alert["parameters"]["jsonBody"].startswith("==")
    assert "alerta_routing_v3" in alert["parameters"]["jsonBody"]
    body = alert["parameters"]["jsonBody"]
    assert body.index("$json.alert_kind") < body.index("$json.opportunity_id")
    assert body.index("$json.opportunity_id") < body.index("$json.state")
    assert "$json.manager_phone" in alert["parameters"]["jsonBody"]
    assert "V3 Sandy Alert Target" not in nodes
    assert "V3 Sandy Alert Target" not in workflow["connections"]
    assert workflow["connections"]["Claim Unassigned Alert Lease"]["main"][0][0]["node"] == "WhatsApp Sandy Unassigned Alert"
    assert workflow["connections"]["WhatsApp Sandy Unassigned Alert"]["main"][0][0]["node"] == "Acknowledge Unassigned Alert"

    acknowledge = normalized(json.dumps(nodes["Acknowledge Unassigned Alert"]))
    requires(acknowledge, r"complete_unassigned_alert_notification", r"'whatsapp'")
    query_replacement = nodes["Acknowledge Unassigned Alert"]["parameters"]["options"][
        "queryReplacement"
    ]
    assert query_replacement.startswith("={{")
    assert not query_replacement.startswith("==")

    notification = extract_function(
        migration("0043_email_unassigned_alert_ack.sql"),
        "complete_unassigned_alert_notification",
    )
    requires(
        notification,
        r"v_channel\s+not\s+in\s*\(\s*'email'\s*,\s*'whatsapp'\s*\)",
        r"lease_token\s*=\s*p_lease_token",
        r"lease_expires_at\s*>\s*now\s*\(\s*\)",
        r"acknowledged_by\s*=\s*'wf3c:'\s*\|\|\s*v_channel\s*\|\|\s*':'\s*\|\|\s*v_external_id",
    )

    export = json.loads(
        (EXPORTS / "WF3c_-_Auction_Expiry_Sweeper__Tiered__.json").read_text(
            encoding="utf-8-sig"
        )
    )
    assert {node["name"]: node for node in export["nodes"]} == nodes
    assert export["connections"] == workflow["connections"]


def test_owner_delivery_chain_uses_the_shared_error_workflow():
    for source_name, export_name in (
        ("WF2_lead_intake.json", "WF2_-_Lead_Intake__Evolution__.json"),
        ("WF10_scraper_intake.json", "WF10_-_Scraper_Lead_Intake_.json"),
        ("WF12_owner_resolver.json", "WF12_-_Owner_Resolver__EB_owner_table__.json"),
        ("WF13_directed_notify.json", "WF13_-_Directed_Owner_Notify__Cloud_API__.json"),
        ("WF22_delivery_status.json", "WF22_-_Delivery_Status_.json"),
        ("WF23_delivery_timeout_sweeper.json", "WF23_-_Delivery_Timeout_Sweeper_.json"),
        ("WF3c_expiry_sweeper.json", "WF3c_-_Auction_Expiry_Sweeper__Tiered__.json"),
    ):
        source = json.loads((WORKFLOWS / source_name).read_text(encoding="utf-8-sig"))
        export = json.loads((EXPORTS / export_name).read_text(encoding="utf-8-sig"))
        assert source["settings"]["errorWorkflow"] == "He95yJflKVspGFyb"
        assert export["settings"]["errorWorkflow"] == "He95yJflKVspGFyb"


def test_s08_s09_claim_rpc_is_atomic_and_late_claim_cannot_reassign():
    sql = migration("0026_claim_lead_opportunity.sql")
    body = extract_function(sql, "claim_lead_opportunity")
    assignment_updates = re.findall(
        r"update\s+lead_routing_opportunities\s+set\s+[^;]*assigned_agent_id\s*=.*?;",
        body,
    )
    assert len(assignment_updates) == 1, "claim must have one assignment mutation"
    update = assignment_updates[0]
    requires(
        update,
        r"where\s+[^;]*routing_tier\s*=\s*p_tier",
        r"(?:authorized_agent_id\s*=\s*p_agent_id|p_agent_id\s*=\s*any\s*\([^)]*authorized)",
        r"delivered_at\s+is\s+not\s+null",
        r"expires_at\s*(?:>=|>)\s*now\s*\(\s*\)",
        r"assigned_agent_id\s+is\s+null",
    )
    requires(body, r"insert\s+into\s+lead_routing_events[^;]*'late_claim_rejected'")
    rejection_match = re.search(
        r"insert\s+into\s+lead_routing_events[^;]*'late_claim_rejected'[^;]*;",
        body,
    )
    assert rejection_match, "missing late-claim event INSERT"
    rejection = rejection_match.group(0)
    assert "assigned_agent_id=" not in rejection
    requires(
        body,
        r"select\s+o\.\*\s+into\s+v_opp[^;]*for\s+update",
        r"status='delivered'",
        r"current_delivery_attempt_id",
        r"'accepted'",
        r"'already_assigned'",
        r"'expired'",
        r"'not_authorized'",
        r"'delivery_pending'",
        r"expires_at<=now\(\)",
        r"claim idempotency event collision",
        r"claim event collision",
        r"digest\(a\.whatsapp_number,'sha256'\)",
        r"a\.agent_id=p_agent_id and a\.is_available",
        r"claim actor authentication failed",
        r"jsonb_typeof\(v_event\.metadata->'result'\) is distinct from 'string'",
        r"metadata - array\['result','actor_phone_hash','assigned_agent_id'\] <> '\{\}'::jsonb",
        r"event_type='claim_accepted'.*result' is distinct from 'accepted'.*assigned_agent_id' is distinct from p_agent_id",
        r"event_type='late_claim_rejected'.*not coalesce\(v_event\.metadata->>'result' in \('already_assigned','expired','not_authorized','delivery_pending'\),false\)",
        r"result'='already_assigned' and v_event\.metadata->>'assigned_agent_id' is null",
    )
    event_insert = extract_statement(body, r"insert\s+into\s+lead_routing_events")
    assert body.index(event_insert) < body.index(update)
    assert body.index("select e.* into v_event") < body.index("digest(a.whatsapp_number,'sha256')")
    assert "lead_phone" not in normalized(sql) and "lead_name" not in normalized(sql)
    requires(
        normalized(sql),
        r"revoke\s+all\s+on\s+function\s+claim_lead_opportunity\(bigint,text,text,text,text\)\s+from\s+public,anon,authenticated",
        r"grant\s+execute\s+on\s+function\s+claim_lead_opportunity\(bigint,text,text,text,text\)\s+to\s+service_role",
        r"revoke\s+all\s+on\s+table\s+conversations\s+from\s+service_role",
        r"grant\s+select,update\s+on\s+table\s+conversations\s+to\s+service_role",
        r"revoke\s+all\s+on\s+table\s+agents\s+from\s+service_role",
        r"grant\s+select\s+on\s+table\s+agents\s+to\s+service_role",
    )

    wf1 = json.loads((WORKFLOWS / "WF1_inbound_router.json").read_text(encoding="utf-8"))
    wf3b = json.loads((WORKFLOWS / "WF3b_claim_handler.json").read_text(encoding="utf-8"))
    wf1_raw = normalized(json.dumps(wf1))
    wf3b_raw = normalized(json.dumps(wf3b))
    wf1_code = "\n".join(
        node.get("parameters", {}).get("jsCode", "") for node in wf1["nodes"]
    )
    assert "const v3ClaimMatch = String(parsed.interactive_id || '')" in wf1_code
    assert r"/^claim:v3:(\d+):(\d+)$/" in wf1_code
    assert "claim_version: 'v3'" in wf1_code
    assert "attempt_id: attemptId" in wf1_code
    assert "context_id: parsed.context_id || null" in wf1_code
    assert "reply_to_wamid: parsed.context_id || null" in wf1_code
    assert "wamid: messageId" in wf1_code
    capture = next(node for node in wf1["nodes"] if node["name"] == "Attach V3 Capture Context")
    assert "capture_event_id" in capture["parameters"]["jsCode"]
    assert wf1["connections"]["Classify & Route"]["main"][0][0]["node"] == "Attach V3 Capture Context"
    assert r"/^claim:(\d+):(owner|primary_guard|backup_guard)$/" in wf1_code
    assert r"/^TOMO-V2-(\d+)-(O|P|B)$/i" in wf1_code
    requires(wf3b_raw, r"claim_lead_opportunity", r"claim_status", r"is routing v2 claim\?")
    requires(
        wf3b_raw,
        r"not exists.*lead_routing_opportunities",
        r"extensions\.digest\(\$4,'sha256'\)",
        r"recover_delivery_from_authenticated_claim",
        r"recovered as materialized",
    )
    assert wf3b["settings"]["saveExecutionProgress"] is False
    assert wf3b["settings"]["saveManualExecutions"] is False
    assert wf3b["connections"]["When Called by WF1"]["main"][0][0]["node"] == "Is Routing V2 Claim?"
    assert wf3b["connections"]["Is Routing V2 Claim?"]["main"][0][0]["node"] == "Claim Routing V2 Opportunity"
    assert wf3b["connections"]["Is Routing V2 Claim?"]["main"][1][0]["node"] == "Claim V3 Delivery"
    export = json.loads((EXPORTS / "WF3b_-_Claim_Handler__Evolution__.json").read_text(encoding="utf-8-sig"))
    source_nodes = {node["name"]: node for node in wf3b["nodes"]}
    # The top-level export is the current import candidate. activeVersion is a
    # historical snapshot and is verified against production by version/hash,
    # not rewritten to impersonate the current draft.
    assert {node["name"]: node for node in export["nodes"]} == source_nodes
    assert export["connections"] == wf3b["connections"]


def _run_wf1_classifier(code: str, parsed: dict, db: dict) -> dict:
    """Execute WF1's classifier under Node with the two n8n inputs it reads."""
    wrapped = "function returnValue() {\n" + code + "\n}\n"
    wrapped += "const parsed = " + json.dumps(parsed) + ";\n"
    wrapped += "const db = " + json.dumps(db) + ";\n"
    wrapped += "const $ = () => ({ first: () => ({ json: parsed }) });\n"
    wrapped += "const $input = { first: () => ({ json: db }) };\n"
    wrapped += "console.log(JSON.stringify(returnValue()[0].json));\n"

    with tempfile.TemporaryDirectory() as tmp:
        script_path = Path(tmp) / "wf1_classifier.js"
        script_path.write_text(wrapped, encoding="utf-8")
        result = subprocess.run(
            ["node", str(script_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
        )
    assert result.returncode == 0, f"node execution failed: {result.stderr}"
    return json.loads(result.stdout.strip().splitlines()[-1])


def test_wf1_routes_real_meta_interactive_button_reply_to_v3_claim():
    if shutil.which("node") is None:
        pytest.skip("node not on PATH")

    wf1 = json.loads((WORKFLOWS / "WF1_inbound_router.json").read_text(encoding="utf-8"))
    code = next(
        node["parameters"]["jsCode"]
        for node in wf1["nodes"]
        if node["name"] == "Classify & Route"
    )
    base_parsed = {
        "phone": "5215523007051",
        "text": "Tomo",
        "pushName": "Paty",
        "messageId": "wamid.test-real-meta-button",
        "webhook_event_id": 369,
        "interactive_id": "claim:v3:679:249",
        "context_id": "wamid.test-offer",
    }
    db = {
        "new_message_id": 1221,
        "is_agent": True,
        "agent_id": "agent_paty",
        "agent_name": "Paty",
    }

    for message_type in ("interactive", "button"):
        routed = _run_wf1_classifier(code, {**base_parsed, "message_type": message_type}, db)
        assert routed["route"] == "agent_claim"
        assert routed["claim_version"] == "v3"
        assert routed["opportunity_id"] == 679
        assert routed["attempt_id"] == 249
        assert routed["webhook_event_id"] == 369
        assert routed["agent_id"] == "agent_paty"
        assert routed["reply_to_wamid"] == "wamid.test-offer"

    replay = _run_wf1_classifier(
        code,
        {**base_parsed, "message_type": "interactive"},
        {**db, "new_message_id": None},
    )
    assert replay["route"] == "agent_claim"
    assert replay["claim_version"] == "v3"
    assert replay["webhook_event_id"] == 369

    non_button = _run_wf1_classifier(
        code,
        {**base_parsed, "message_type": "text", "interactive_id": ""},
        db,
    )
    assert non_button["route"] == "agent_followup_reply"


def test_wf3b_claimed_outcome_builds_success_confirmation():
    if shutil.which("node") is None:
        pytest.skip("node not on PATH")

    wf3b = json.loads((WORKFLOWS / "WF3b_claim_handler.json").read_text(encoding="utf-8"))
    code = next(
        node["parameters"]["jsCode"]
        for node in wf3b["nodes"]
        if node["name"] == "Build V3 Claim Result"
    )
    trigger = {
        "agent_phone": "5215523007051",
        "opportunity_id": 679,
    }
    raw = {
        "result": {
            "ok": True,
            "outcome": "claimed",
            "opportunity_id": 679,
            "assigned_agent_id": "agent_paty",
        }
    }
    wrapped = "function returnValue() {\n" + code + "\n}\n"
    wrapped += "const trigger = " + json.dumps(trigger) + ";\n"
    wrapped += "const raw = " + json.dumps(raw) + ";\n"
    wrapped += "const $ = () => ({ first: () => ({ json: trigger }) });\n"
    wrapped += "const $input = { first: () => ({ json: raw }) };\n"
    wrapped += "console.log(JSON.stringify(returnValue()[0].json));\n"

    with tempfile.TemporaryDirectory() as tmp:
        script_path = Path(tmp) / "wf3b_claim_result.js"
        script_path.write_text(wrapped, encoding="utf-8")
        result = subprocess.run(
            ["node", str(script_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
        )
    assert result.returncode == 0, f"node execution failed: {result.stderr}"
    payload = json.loads(result.stdout.strip().splitlines()[-1])
    assert payload == {
        "number": "5215523007051",
        "text": "Prospecto asignado. Ya puedes atenderlo.",
        "claim_status": "claimed",
        "opportunity_id": 679,
    }


def test_s10_delivery_failure_records_event_without_starting_sla():
    body = extract_function(migration("0021_lead_routing_v2.sql"), "mark_offer_delivery_failed")
    event = extract_statement(body, r"insert\s+into\s+lead_routing_events")
    update = extract_statement(body, r"update\s+lead_routing_opportunities")
    requires(
        body,
        r"insert\s+into\s+lead_routing_events\b[^;]*'delivery_failed'",
        r"idempotency_key\s+is\s+null\s+or\s+btrim\s*\(\s*p_idempotency_key\s*\)\s*=\s*''",
        r"v_existing_opportunity_id\s+is\s+distinct\s+from\s+p_opportunity_id",
        r"v_existing_event_type\s+is\s+distinct\s+from\s*'delivery_failed'",
    )
    assert body.index(event) < body.index(update), "event insert must precede opportunity mutation"
    assert not re.search(r"(?:delivered_at|expires_at)\s*=", body)


def test_routing_events_are_append_only_and_server_only():
    sql = normalized(migration("0021_lead_routing_v2.sql"))
    requires(
        sql,
        r"create\s+or\s+replace\s+function\s+reject_lead_routing_event_mutation\b",
        r"raise\s+exception\s+'lead_routing_events is append-only'",
        r"security\s+invoker\s+set\s+search_path\s*=\s*pg_catalog",
        r"create\s+or\s+replace\s+trigger\s+lead_routing_events_append_only\s+before\s+update\s+or\s+delete\s+on\s+lead_routing_events",
        r"revoke\s+all\s+on\s+table\s+lead_routing_opportunities\s*,\s*lead_routing_events\s+from\s+public\s*,\s*anon\s*,\s*authenticated",
        r"revoke\s+all\s+on\s+table\s+lead_routing_opportunities\s*,\s*lead_routing_events\s+from\s+service_role",
        r"grant\s+select\s*,\s*insert\s+on\s+table\s+lead_routing_events\s+to\s+service_role",
        r"revoke\s+all\s+on\s+sequence\b[^;]+from\s+service_role",
        r"grant\s+usage\s*,\s*select\s+on\s+sequence\b[^;]+to\s+service_role",
    )


def test_s11_first_tag_is_strict_and_missing_owner_falls_back_to_guards():
    sql = migration("0025_resolve_first_property_tag.sql")
    resolver = extract_function(sql, "resolve_first_property_tag")
    fallback = extract_function(sql, "route_missing_owner_data")
    fixtures = json.loads(
        (Path(__file__).parent / "fixtures" / "routing_v2" / "easybroker_owner_resolution.json").read_text(encoding="utf-8")
    )
    assert set(fixtures) == {
        "known_first_tag", "unknown_first_tag", "empty_tags", "inactive_agent",
        "missing_phone", "second_tag_ignored",
    }
    assert fixtures["second_tag_ignored"]["tags"][1] == fixtures["known_first_tag"]["tags"][0]
    assert fixtures["second_tag_ignored"]["expected"] == "missing_alias"
    requires(resolver, r"p_tags\s*\[\s*1\s*\]")
    assert "unnest" not in resolver
    for invalid_case in ("missing_code", "missing_tag", "missing_alias", "inactive_agent", "missing_phone"):
        requires(resolver, rf"'{invalid_case}'")
    requires(
        resolver,
        r"reason\s*[:=]+\s*'missing_owner_data'",
        r"(?:resolved\s*[:=]+\s*false|owner_agent_id\s*[:=]+\s*null)",
    )
    requires(
        fallback,
        r"(?:p_reason|reason)\s*=\s*'missing_owner_data'",
        r"case\s+v_coverage\.coverage_role\s+when\s+'primary'\s+then\s+'primary_guard_open'\s+when\s+'backup'\s+then\s+'backup_guard_open'\s+else\s+'unassigned_alerted'\s+end",
    )
    assert "agent_manager" not in fallback
    assert "mark_assigned" not in fallback
    requires(
        resolver,
        r"role\s*=\s*'manager'",
    )
    requires(
        fallback,
        r"for\s+update",
        r"state\s+not\s+in\s*\(\s*'captured'\s*,\s*'resolved'\s*\)",
        r"insert\s+into\s+lead_routing_events.*update\s+lead_routing_opportunities",
        r"event_type\s*<>\s*'missing_owner_data'",
        r"metadata\s+is\s+distinct\s+from\s+v_metadata",
        r"coverage_role.*'primary'.*'backup'",
        r"'unassigned_alerted'",
        r"metadata->>'agent_number'",
    )

    migration_sql = normalized(sql)
    assert fallback.count("security invoker") == 0  # attributes live outside extracted AS body
    assert len(re.findall(r"security\s+invoker", migration_sql)) >= 2
    assert len(re.findall(r"set\s+search_path\s*=\s*pg_catalog\s*,\s*public", migration_sql)) >= 2
    requires(
        migration_sql,
        r"revoke\s+all\s+on\s+function\s+resolve_first_property_tag[^;]+from\s+public\s*,\s*anon\s*,\s*authenticated",
        r"grant\s+execute\s+on\s+function\s+route_missing_owner_data[^;]+to\s+service_role",
        r"drop\s+policy\s+if\s+exists\s+alias_read\s+on\s+property_agent_alias",
        r"revoke\s+all\s+on\s+table\s+property_agent_alias\s+from\s+public\s*,\s*anon\s*,\s*authenticated",
        r"revoke\s+all\s+on\s+table\s+property_agent_alias\s+from\s+service_role",
        r"grant\s+select\s*,\s*insert\s*,\s*update\s*,\s*delete\s+on\s+table\s+property_agent_alias\s+to\s+service_role",
    )

    wf12 = json.loads((WORKFLOWS / "WF12_owner_resolver.json").read_text(encoding="utf-8"))
    wf10 = json.loads((WORKFLOWS / "WF10_scraper_intake.json").read_text(encoding="utf-8"))
    wf12_nodes = {n["name"]: n["parameters"] for n in wf12["nodes"]}
    wf10_nodes = {n["name"]: n["parameters"] for n in wf10["nodes"]}
    assert "tags[0]" in wf12_nodes["Extract Tags"]["jsCode"]
    assert "resolve_first_property_tag" in wf12_nodes["Resolve Owner Agent"]["query"]
    assert wf12_nodes["Resolve Owner Agent"]["options"]["queryReplacement"] == (
        "={{ [$json.property_public_id || '__MISSING_PROPERTY__', $json.tags_pg || '{}'] }}"
    )
    owner_lookup = next(n for n in wf12["nodes"] if n["name"] == "Fetch EasyBroker Property")
    assert owner_lookup["retryOnFail"] is True
    assert owner_lookup["maxTries"] == 3
    assert owner_lookup["waitBetweenTries"] == 5000
    assert owner_lookup["onError"] == "continueErrorOutput"
    assert "continueOnFail" not in owner_lookup
    lookup_outputs = wf12["connections"]["Fetch EasyBroker Property"]["main"]
    assert lookup_outputs[0][0]["node"] == "Extract Tags"
    assert lookup_outputs[1][0]["node"] == "Record Owner Lookup Failure"
    lookup_failure = next(
        n for n in wf12["nodes"] if n["name"] == "Record Owner Lookup Failure"
    )
    lookup_failure_raw = normalized(json.dumps(lookup_failure))
    requires(
        lookup_failure_raw,
        r"lead_routing_events",
        r"owner_lookup_failed",
        r"easybroker_lookup_failed_after_retries",
        r"on conflict.*idempotency_key",
    )
    assert lookup_failure["parameters"]["options"]["queryReplacement"].startswith("={{ [")
    assert "valid_eb_code" in wf12_nodes["Validate EB Code"]["jsCode"]
    assert wf12["connections"]["Valid EB Code?"]["main"][0][0]["node"] == "Fetch EasyBroker Property"
    assert wf12["connections"]["Valid EB Code?"]["main"][1][0]["node"] == "Extract Tags"
    assert "route_missing_owner_data" in wf10_nodes["Route Missing Owner Data"]["query"]
    assert "Set Manager Tier" not in wf10_nodes
    assert "Notify Manager (Unresolved)" not in wf10_nodes
    assert wf10["connections"]["Owner Resolved?"]["main"][1][0]["node"] == "Route Missing Owner Data"
    webhook = next(n for n in wf10["nodes"] if n["name"] == "Scraper Webhook")
    assert webhook["parameters"]["authentication"] == "headerAuth"
    assert webhook["parameters"]["responseMode"] == "responseNode"
    assert webhook["credentials"]["httpHeaderAuth"]["id"] == "REPLACE_WITH_I24_WEBHOOK_HEADER_AUTH_CREDENTIAL_ID"
    assert wf10["connections"]["Scraper Webhook"]["main"][0][0]["node"] == "Split & Normalize Leads"
    # The historical activeVersion is intentionally not treated as current V3 wiring.

    for source, export_name in (
        (wf12, "WF12_-_Owner_Resolver__EB_owner_table__.json"),
        (wf10, "WF10_-_Scraper_Lead_Intake_.json"),
    ):
        export = json.loads((EXPORTS / export_name).read_text(encoding="utf-8"))
        source_params = {n["name"]: n["parameters"] for n in source["nodes"]}
        # The activeVersion snapshot is historical and can retain pre-V3
        # wiring; only the current top-level mirror is contractual here.
        for edition in (export,):
            if edition is None:
                continue
            export_params = {n["name"]: n["parameters"] for n in edition["nodes"]}
            for name in source_params:
                assert export_params[name] == source_params[name]
            assert edition["connections"] == source["connections"]
            if export_name == "WF10_-_Scraper_Lead_Intake_.json":
                export_webhook = next(n for n in edition["nodes"] if n["name"] == "Scraper Webhook")
                assert export_params["Scraper Webhook"]["authentication"] == "headerAuth"
                assert export_params["Scraper Webhook"]["responseMode"] == "responseNode"
                assert export_webhook["credentials"]["httpHeaderAuth"]["id"] == "REPLACE_WITH_I24_WEBHOOK_HEADER_AUTH_CREDENTIAL_ID"


def test_exact_manager_property_alias_resolves_with_owner_safety_checks():
    previous = extract_function(
        migration("0025_resolve_first_property_tag.sql"),
        "resolve_first_property_tag",
    )
    sql = migration("0044_allow_manager_property_alias_resolution.sql")
    resolver = extract_function(sql, "resolve_first_property_tag")

    requires(previous, r"v_agent\.role\s*=\s*'manager'")
    assert not re.search(r"v_agent\.role\s*=\s*'manager'", resolver)
    assert "agent_manager" not in resolver
    assert "unnest" not in resolver
    requires(
        resolver,
        r"p_tags\s*\[\s*1\s*\]",
        r"alias\.tag_normalized\s*=\s*v_tag",
        r"not\s+v_agent\.is_available",
        r"regexp_replace\s*\(\s*btrim\s*\(\s*v_agent\.whatsapp_number",
        r"failure_detail\s*:=\s*'missing_phone'",
        r"resolved\s*:=\s*true",
        r"owner_agent_id\s*:=\s*v_agent\.agent_id",
        r"owner_number\s*:=\s*regexp_replace",
    )

    aliases = normalized(migration("0011_owner_routing.sql"))
    roles = normalized(migration("0013_agent_roles.sql"))
    requires(
        aliases,
        r"\('sandy'\s*,\s*'agent_manager'\)",
        r"\('sandra'\s*,\s*'agent_manager'\)",
    )
    requires(
        roles,
        r"set\s+role\s*=\s*'manager'\s+where\s+agent_id\s*=\s*'agent_manager'",
    )

    migration_sql = normalized(sql)
    requires(
        migration_sql,
        r"language\s+plpgsql\s+stable\s+security\s+invoker\s+set\s+search_path\s*=\s*pg_catalog\s*,\s*public",
        r"revoke\s+all\s+on\s+function\s+resolve_first_property_tag[^;]+from\s+public\s*,\s*anon\s*,\s*authenticated",
        r"grant\s+execute\s+on\s+function\s+resolve_first_property_tag[^;]+to\s+service_role",
    )


def test_wf13_provider_send_failure_uses_explicit_error_output():
    wf13 = json.loads((WORKFLOWS / "WF13_directed_notify.json").read_text(encoding="utf-8"))
    send = next(node for node in wf13["nodes"] if node["name"] == "Send Owner Offer")
    assert send["onError"] == "continueErrorOutput"
    assert "continueOnFail" not in send
    outputs = wf13["connections"]["Send Owner Offer"]["main"]
    assert outputs[0][0]["node"] == "Provider Accepted Send?"
    assert outputs[1][0]["node"] == "Fail Unbound Attempt"

    export = json.loads(
        (EXPORTS / "WF13_-_Directed_Owner_Notify__Cloud_API__.json").read_text(
            encoding="utf-8-sig"
        )
    )
    for edition in (export, export.get("activeVersion")):
        if edition is None:
            continue
        edition_send = next(
            node for node in edition["nodes"] if node["name"] == "Send Owner Offer"
        )
        assert edition_send["onError"] == "continueErrorOutput"
        assert "continueOnFail" not in edition_send
        assert edition["connections"]["Send Owner Offer"]["main"] == outputs


def test_wf10_returning_notification_failure_is_not_swallowed():
    wf10 = json.loads((WORKFLOWS / "WF10_scraper_intake.json").read_text(encoding="utf-8"))
    notify = next(node for node in wf10["nodes"] if node["name"] == "Notify Agent (Returning)")
    assert "continueOnFail" not in notify
    assert notify["retryOnFail"] is True
    assert notify["maxTries"] == 3
    assert notify["waitBetweenTries"] == 5000
    assert notify["onError"] == "stopWorkflow"

    export = json.loads(
        (EXPORTS / "WF10_-_Scraper_Lead_Intake_.json").read_text(encoding="utf-8-sig")
    )
    for edition in (export, export.get("activeVersion")):
        if edition is None:
            continue
        edition_notify = next(
            node for node in edition["nodes"] if node["name"] == "Notify Agent (Returning)"
        )
        for key in ("retryOnFail", "maxTries", "waitBetweenTries", "onError"):
            assert edition_notify[key] == notify[key]
        assert "continueOnFail" not in edition_notify


def test_s12_missing_all_identity_signals_creates_manual_case():
    body = extract_function(
        migration("0024_upsert_lead_opportunity.sql"), "upsert_lead_opportunity"
    )
    requires(
        body,
        r"v_identity_key\s+is\s+null\s+or\s+v_property_id\s+is\s+null",
        r"insert\s+into\s+lead_routing_opportunities[^;]*'manual_non_deduplicable'",
        r"v_identity_reason\s*:=\s*'missing_identity'",
    )


def test_wf10_normalizes_digits_only_i24_phone_to_e164():
    wf10 = json.loads((WORKFLOWS / "WF10_scraper_intake.json").read_text(encoding="utf-8"))
    normalize = next(
        node["parameters"]["jsCode"]
        for node in wf10["nodes"]
        if node["name"] == "Split & Normalize Leads"
    )
    assert "/^[1-9]\\d{7,14}$/.test(rawPhone)" in normalize
    assert "'+' + rawPhone" in normalize


def test_wf10_backfills_easybroker_code_without_overwriting_existing():
    for path in (
        WORKFLOWS / "WF10_scraper_intake.json",
        EXPORTS / "WF10_-_Scraper_Lead_Intake_.json",
    ):
        workflow = json.loads(path.read_text(encoding="utf-8-sig"))
        params = {node["name"]: node["parameters"] for node in workflow["nodes"]}

        returning = params["Update Existing Conversation"]
        assert (
            "property_public_id = COALESCE(property_public_id, NULLIF($2, ''))"
            in returning["query"]
        )
        assert returning["options"]["queryReplacement"] == (
            "={{ [$json.existing_conv_id, $json.property_public_id] }}"
        )

        for node_name in ("Create Day Conversation", "Create Night Conversation"):
            query = params[node_name]["query"]
            assert (
                "property_public_id = COALESCE("
                "conversations.property_public_id, EXCLUDED.property_public_id)"
                in query
            )


def test_wf10_i24_conflict_target_is_owned_by_a_repo_migration():
    index_sql = normalized(migration("0043_ensure_i24_lead_id_unique.sql"))
    requires(
        index_sql,
        r"create\s+unique\s+index\s+if\s+not\s+exists\s+conversations_i24_lead_id_uniq",
        r"on\s+conversations\s*\(\s*i24_lead_id\s*\)",
        r"where\s+i24_lead_id\s+is\s+not\s+null",
    )


def test_wf10_preserves_every_day_lead_through_routing_preparation():
    wf10 = json.loads((WORKFLOWS / "WF10_scraper_intake.json").read_text(encoding="utf-8"))
    prepare = next(
        node["parameters"]["jsCode"]
        for node in wf10["nodes"]
        if node["name"] == "Prepare Routing Data"
    )
    requires(
        normalized(prepare),
        r"const conversations = \$input\.all\(\)",
        r"const leads = \$\('route decision'\)\.all\(\)",
        r"return conversations\.map\(\(item, index\)",
        r"paireditem: \{ item: index \}",
    )
    assert ".item.json" not in prepare


def test_wf10_recovers_legacy_manual_intake_without_duplicate_routing():
    body = extract_function(
        migration("0038_recover_legacy_i24_intake.sql"),
        "upsert_i24_lead_opportunity_recovering",
    )
    requires(
        body,
        r"from\s+upsert_lead_opportunity\s*\(",
        r"sqlerrm\s+not\s+like\s+'intake idempotency key collision:%'",
        r"state\s+is\s+distinct\s+from\s+'manual_non_deduplicable'",
        r"v_promoted\s*:=\s*v_identity_key\s+is\s+not\s+null\s+and\s+v_property_id\s+is\s+not\s+null",
        r"'identity_recovered'",
        r"false\s*,\s*v_promoted",
    )
    wf10 = json.loads((WORKFLOWS / "WF10_scraper_intake.json").read_text(encoding="utf-8"))
    wf10_sql = normalized(json.dumps(wf10))
    assert wf10_sql.count("upsert_i24_lead_opportunity_recovering") == 3
    assert "public.upsert_lead_opportunity(" not in wf10_sql


def test_canonical_opportunity_upsert_is_concurrent_safe_and_auditable():
    body = extract_function(migration("0024_upsert_lead_opportunity.sql"), "upsert_lead_opportunity")
    requires(
        body,
        r"v_portal_person_id\s+is\s+not\s+null.*v_normalized_email\s+is\s+not\s+null.*v_e164_phone\s+is\s+not\s+null",
        r"on\s+conflict\s*\(\s*identity_key\s*,\s*property_id\s*\)[^;]*do\s+nothing",
        r"state\s+not\s+in\s*\(\s*'closed_won'\s*,\s*'closed_lost'\s*\)",
        r"v_event_type\s*:=\s*case\s+when\s+v_created\s+then\s+'detected'\s+else\s+'deduplicated'\s+end",
        r"insert\s+into\s+lead_routing_events",
        r"on\s+conflict\s*\(\s*idempotency_key\s*\)\s+do\s+nothing",
        r"v_created\s+and\s+v_opportunity.state\s*<>\s*'manual_non_deduplicable'",
        r"v_source\s+in\s*\(\s*'easybroker'\s*,\s*'inmuebles24'\s*\)",
        r"'portal:'\s*\|\|\s*v_source\s*\|\|\s*':'\s*\|\|\s*v_portal_person_id",
        r"\^\\\+\[0-9\]\{8,15\}\$",
        r"external_evidence\s+is\s+distinct\s+from\s+v_external_evidence",
        r"raise\s+exception\s+'intake idempotency key collision",
        r"event_type\s+not\s+in\s*\(\s*'detected'\s*,\s*'deduplicated'\s*\)",
    )

    for filename in (
        "WF2_lead_intake.json",
        "WF8_easybroker_polling.json",
        "WF10_scraper_intake.json",
    ):
        workflow = json.loads((WORKFLOWS / filename).read_text(encoding="utf-8"))
        workflow_sql = normalized(json.dumps(workflow))
        if filename == "WF10_scraper_intake.json":
            requires(workflow_sql, r"upsert_i24_lead_opportunity_recovering\s*\(")
        else:
            requires(workflow_sql, r"upsert_lead_opportunity\s*\(")

    wf2 = json.loads((WORKFLOWS / "WF2_lead_intake.json").read_text(encoding="utf-8"))
    wf8 = json.loads((WORKFLOWS / "WF8_easybroker_polling.json").read_text(encoding="utf-8"))
    wf10 = json.loads((WORKFLOWS / "WF10_scraper_intake.json").read_text(encoding="utf-8"))
    wf8_sql = normalized(json.dumps(wf8))
    wf10_sql = normalized(json.dumps(wf10))
    assert "identity_phone" in wf8_sql and "identity_phone" in wf10_sql
    requires(wf8_sql, r"upsert_lead_opportunity\s*\([^;]+\$5[^;]+captured", r"upsert_lead_opportunity\s*\([^;]+\$7[^;]+queued_night")
    requires(wf10_sql, r"upsert_i24_lead_opportunity_recovering\s*\([^;]+\$11[^;]+captured", r"upsert_i24_lead_opportunity_recovering\s*\([^;]+\$7[^;]+queued_night")
    wf8_filter_js = next(n for n in wf8["nodes"] if n["name"] == "Filter New Contacts")["parameters"]["jsCode"]
    wf10_normalize_js = next(n for n in wf10["nodes"] if n["name"] == "Split & Normalize Leads")["parameters"]["jsCode"]
    assert r"/^\+[1-9]\d{7,14}$/" in wf8_filter_js
    assert r"/^\+[1-9]\d{7,14}$/" in wf10_normalize_js
    requires(wf8_sql, r"upsert_lead_opportunity\s*\([^,]+,\s*\$2,\s*null,")
    requires(wf10_sql, r"upsert_i24_lead_opportunity_recovering\s*\([^,]+,\s*\$2,\s*null,")
    assert wf10_sql.count("upsert_i24_lead_opportunity_recovering") >= 3
    assert "insert into lead_routing_opportunities" not in wf10_sql
    assert wf2["connections"]["Prepare Routing Data"]["main"][0][0]["node"] == "Upsert Canonical Opportunity"
    assert wf8["connections"]["Prepare Auction Data"]["main"][0][0]["node"] == "Upsert Canonical Opportunity"
    assert wf10["connections"]["Prepare Routing Data"]["main"][0][0]["node"] == "V3 Intake Durable"
    for workflow in (wf2, wf8):
        for connection in workflow["connections"].values():
            assert isinstance(connection["main"], list)
            assert all(isinstance(branch, list) for branch in connection["main"])
        assert workflow["connections"]["Upsert Canonical Opportunity"]["main"][0][0]["node"] == "Should Route?"
        gate = workflow["connections"]["Should Route?"]["main"]
        assert gate[0]
        assert gate[1][0]["node"] == "Stop Duplicate Intake"
    for connection in wf10["connections"].values():
        assert isinstance(connection["main"], list)
        assert all(isinstance(branch, list) for branch in connection["main"])
    assert wf10["connections"]["V3 Intake Durable"]["main"][0][0]["node"] == "Should Route?"
    assert wf10["connections"]["Should Route?"]["main"][1][0]["node"] == "Stop Duplicate Intake"
    for workflow in (wf8, wf10):
        assert workflow["connections"]["Create Night Conversation"]["main"][0][0]["node"] == "Should Route Night?"
        assert workflow["connections"]["Should Route Night?"]["main"][1][0]["node"] == "Stop Duplicate Night Intake"

    exports = (
        (wf2, "WF2_-_Lead_Intake__Evolution__.json"),
        (wf8, "WF8b_-_EasyBroker_Lead_Intake_.json"),
        (wf10, "WF10_-_Scraper_Lead_Intake_.json"),
    )
    for source, export_name in exports:
        export = json.loads((EXPORTS / export_name).read_text(encoding="utf-8"))
        source_nodes = {n["name"]: n["parameters"] for n in source["nodes"]}
        editions = (export,) if source is wf10 else (export, export.get("activeVersion"))
        for edition in editions:
            if edition is None:
                continue
            export_nodes = {n["name"]: n["parameters"] for n in edition["nodes"]}
            if source is not wf10:
                assert export_nodes["Upsert Canonical Opportunity"] == source_nodes["Upsert Canonical Opportunity"]
            else:
                assert export_nodes["V3 Intake Durable"] == source_nodes["V3 Intake Durable"]
            for critical_name in (
                "Filter New Contacts",
                "Normalize Lead Data",
                "Prepare Auction Data",
                "Split & Normalize Leads",
                "Prepare Routing Data",
                "Create Night Conversation",
            ):
                if critical_name in source_nodes:
                    assert export_nodes[critical_name] == source_nodes[critical_name]
            assert edition["connections"] == source["connections"]
            for connection in edition["connections"].values():
                assert isinstance(connection["main"], list)
                assert all(isinstance(branch, list) for branch in connection["main"])


def test_s13_two_failures_within_five_minutes_trip_safe_mode_once():
    sql = migration("0028_routing_safe_mode.sql")
    report = extract_function(sql, "report_routing_failure")
    requires(
        report,
        r"invalid routing failure report input",
        r"on\s+conflict\s*\(\s*idempotency_key\s*\)\s+do\s+nothing\s+returning\s+event_id",
        r"idempotency_key already belongs to another routing safe mode event",
        r"v_state\.status\s*=\s*'normal'",
        r"count\s*\(\s*\*\s*\)\s+into\s+v_failure_count",
        r"event_type\s*=\s*'failure_recorded'",
        r"occurred_at\s*>\s*p_occurred_at\s*-\s*interval\s*'5 minutes'",
        r"occurred_at\s*<=\s*p_occurred_at",
        r"v_failure_count\s*>=\s*2",
        r"'safe_mode_entered'",
        r"p_idempotency_key\s*\|\|\s*':entered'",
        r"status\s*=\s*'safe_mode'",
        r"operational_owner\s*=\s*'manager'",
        r"v_just_entered\s*:=\s*true",
        r"for\s+update",
    )
    # A repeated idempotency key must short-circuit before the trip evaluation.
    assert report.index("returning event_id into v_event_id") < report.index("if v_event_id is null")
    assert "select * into v_state from routing_safe_mode_state where id = 1 for update" in report

    normalized_sql = normalized(sql)
    requires(
        normalized_sql,
        r"create table if not exists routing_safe_mode_state",
        r"status text not null default 'normal' check \(status in \('normal', 'safe_mode'\)\)",
        r"create table if not exists routing_safe_mode_events",
        r"event_type text not null check \(event_type in \(",
        r"idempotency_key text not null unique",
        r"create or replace trigger routing_safe_mode_events_append_only\s+before update or delete on routing_safe_mode_events\s+for each row execute function reject_lead_routing_event_mutation\s*\(\s*\)",
        r"revoke all on function report_routing_failure\(text, text, timestamptz\) from public, anon, authenticated",
        r"grant execute on function report_routing_failure\(text, text, timestamptz\) to service_role",
    )
    # The append-only guard is reused from 0021, not redefined here.
    assert "reject_lead_routing_event_mutation" in normalized_sql
    assert "create or replace function reject_lead_routing_event_mutation" not in normalized_sql

    fixture_path = Path(__file__).parent / "fixtures" / "routing_v2" / "test_safe_mode.sql"
    fixture = fixture_path.read_text(encoding="utf-8")
    assert "third failure must not re-trip safe mode" in fixture
    assert "failures more than 5 minutes apart must not trip safe mode" in fixture
    assert fixture.strip().startswith("-- LRV2-013")
    assert fixture.strip().endswith("ROLLBACK;")


def test_s14_manual_recovery_requires_actor_and_green_health_and_preserves_history():
    sql = migration("0028_routing_safe_mode.sql")
    exit_fn = extract_function(sql, "exit_routing_safe_mode")
    requires(
        exit_fn,
        r"routing safe mode exit requires an explicit actor",
        r"p_health_check_ok\s+is\s+distinct\s+from\s+true",
        r"routing safe mode exit requires a green health check",
        r"v_state\.status\s*<>\s*'safe_mode'",
        r"return\s+v_state",
        r"'safe_mode_exited'",
        r"on\s+conflict\s*\(\s*idempotency_key\s*\)\s+do\s+nothing",
        r"status\s*=\s*'normal'",
        r"exited_at\s*=\s*p_now",
        r"exited_by\s*=\s*p_actor_id",
        r"for\s+update",
    )
    # Exit never deletes or updates prior events — it only appends.
    assert "delete from" not in exit_fn
    assert "update routing_safe_mode_events" not in exit_fn
    # No-op exit (already normal) returns before any insert, so it cannot fabricate history.
    assert exit_fn.index("v_state.status <> 'safe_mode'") < exit_fn.index("insert into routing_safe_mode_events")

    get_fn = extract_function(sql, "get_routing_safe_mode")
    requires(get_fn, r"select\s+\*\s+into\s+v_state\s+from\s+routing_safe_mode_state\s+where\s+id\s*=\s*1")

    normalized_sql = normalized(sql)
    requires(
        normalized_sql,
        r"revoke all on function exit_routing_safe_mode\(text, boolean, text, timestamptz\) from public, anon, authenticated",
        r"grant execute on function exit_routing_safe_mode\(text, boolean, text, timestamptz\) to service_role",
        r"revoke all on function get_routing_safe_mode\(\) from public, anon, authenticated",
        r"grant execute on function get_routing_safe_mode\(\) to service_role",
    )

    fixture = (Path(__file__).parent / "fixtures" / "routing_v2" / "test_safe_mode.sql").read_text(encoding="utf-8")
    for marker in (
        "exit without actor must fail",
        "exit with a red health check must fail",
        "manual exit did not persist",
        "replayed exit changed durable state",
        "safe mode history must be preserved across exit",
        "re-entry after exit must trip a fresh incident",
        "append-only trigger did not reject UPDATE",
    ):
        assert marker in fixture


def test_lrv2_013_watchdog_reports_routing_failures_idempotently():
    wf20 = json.loads((WORKFLOWS / "WF20_watchdog.json").read_text(encoding="utf-8"))
    raw = normalized(json.dumps(wf20))
    requires(
        raw,
        r"report_routing_failure",
        r"event_type in \('delivery_failed', 'unassigned_alerted'\)",
        r"wf20:'\s*\|\|\s*r\.event_id",
        r"just_entered",
    )
    names = [n["name"] for n in wf20["nodes"]]
    ids = [n["id"] for n in wf20["nodes"]]
    assert len(names) == len(set(names))
    assert len(ids) == len(set(ids))
    for connection in wf20["connections"].values():
        assert isinstance(connection["main"], list)
        assert all(isinstance(branch, list) for branch in connection["main"])

    report_node = next(n for n in wf20["nodes"] if "report_routing_failure" in n.get("parameters", {}).get("query", ""))
    schedule_triggers = [n for n in wf20["nodes"] if n["type"] == "n8n-nodes-base.scheduleTrigger"]
    assert len(schedule_triggers) == 1, "multiple schedule nodes caused the routing watchdog cadence to disappear live"
    schedule = schedule_triggers[0]
    assert schedule["parameters"]["rule"]["interval"][0]["expression"] == "*/5 * * * *"
    scheduled_targets = {
        edge["node"] for edge in wf20["connections"][schedule["name"]]["main"][0]
    }
    assert scheduled_targets == {
        "Run scraper check?",
        report_node["name"],
        "Revisar Casos Sin Asignar",
    }
    assert wf20["connections"]["Run scraper check?"]["main"][0][0]["node"] == "Check scraper health"
    alert_node = next(
        n for n in wf20["nodes"]
        if n["type"] == "n8n-nodes-base.gmail" and n["name"] != "Enviar alerta (Gmail)"
    )
    assert "modo seguro" in json.dumps(alert_node).lower()

    if_node = next(
        n for n in wf20["nodes"]
        if n["type"] == "n8n-nodes-base.if"
        and "just_entered" in json.dumps(n.get("parameters", {}))
    )
    branch = wf20["connections"][if_node["name"]]["main"]
    assert branch[0][0]["node"] == alert_node["name"]

    assert report_node["name"] in scheduled_targets, "the shared schedule must feed routing-failure reporting"


def test_lrv2_013_wf20_safe_mode_watchdog_matches_export():
    wf20 = json.loads((WORKFLOWS / "WF20_watchdog.json").read_text(encoding="utf-8"))
    export = load_single_workflow_export(EXPORTS / "BYG_WF20_Watchdog_.json")

    safe_mode_node_names = [
        "Cada 5 min (routing watchdog)",
        "Run scraper check?",
        "Revisar Fallos de Routing",
        "Modo Seguro Activo?",
        "Alertar Modo Seguro (Gmail)",
    ]
    source_params = {n["name"]: n["parameters"] for n in wf20["nodes"]}

    for edition in published_workflow_editions(export):
        export_params = {n["name"]: n["parameters"] for n in edition["nodes"]}
        for name in safe_mode_node_names:
            assert name in export_params, f"{name} missing from export"
            assert export_params[name] == source_params[name]
        assert_connections_equivalent(edition["connections"], wf20["connections"])
        for name in safe_mode_node_names:
            assert name in edition["connections"] or name == "Alertar Modo Seguro (Gmail)"

    export_ids = [n["id"] for n in export["nodes"]]
    assert len(export_ids) == len(set(export_ids))


def test_lrv2_wf20_full_parity():
    """WF20 source and export must be in full lockstep: no drifted nodes.

    2026-08-13 reconciliation: source previously lacked the 2026-07-07
    off-hours fix (i24_active_window DB-time gate replacing the naive
    "8-20" cron) and the 2026-07-15 EB_ENABLED=false gate on "Check
    scraper health" / "Evaluar estado" / "Cada 30 min (8-20 MX)". Those
    were adopted into source verbatim from export/production. This test
    asserts full parity so any future drift on ANY node fails loudly,
    not just the 4 safe-mode nodes checked above.
    """
    wf20 = json.loads((WORKFLOWS / "WF20_watchdog.json").read_text(encoding="utf-8"))
    export = load_single_workflow_export(EXPORTS / "BYG_WF20_Watchdog_.json")

    source_names = [n["name"] for n in wf20["nodes"]]
    assert len(source_names) == len(set(source_names))

    for edition in published_workflow_editions(export):
        edition_by_name = {n["name"]: n for n in edition["nodes"]}
        assert set(edition_by_name) == set(source_names), (
            "node name set diverged between source and export"
        )
        for node in wf20["nodes"]:
            edition_node = edition_by_name[node["name"]]
            for field in ("parameters", "type", "typeVersion", "position", "id"):
                assert edition_node.get(field) == node.get(field), (
                    f"{node['name']!r} field {field!r} drifted between "
                    "source and export"
                )
        assert_connections_equivalent(edition["connections"], wf20["connections"])
        for key, value in wf20["settings"].items():
            assert edition["settings"].get(key) == value

    embedded_active = export.get("activeVersion")
    if embedded_active is not None:
        assert_connections_equivalent(
            export["connections"], embedded_active["connections"]
        )


def test_lrv2_013_v3_intake_uses_the_durable_owner_guard_sandy_router():
    wf10 = json.loads((WORKFLOWS / "WF10_scraper_intake.json").read_text(encoding="utf-8"))
    node_params = {n["name"]: n["parameters"] for n in wf10["nodes"]}

    # V2 safe-mode nodes remain as legacy definitions, but live V3 never enters
    # them. Only created_new opens owner resolution; non-new dispositions use
    # their idempotent route-ready transition and then the durable response gate.
    assert "Check V3 Routing Safe Mode" in node_params
    assert "get_routing_safe_mode" in json.dumps(node_params["Check V3 Routing Safe Mode"])
    assert "Safe Mode Active?" in node_params
    conn = wf10["connections"]
    assert conn["Scraper Webhook"]["main"][0][0]["node"] == "Split & Normalize Leads"
    assert conn["Split & Normalize Leads"]["main"][0][0]["node"] == "Restore V3 Dispatch Context"
    assert conn["Restore V3 Dispatch Context"]["main"][0][0]["node"] == "Created New V3?"
    assert conn["Created New V3?"]["main"][0][0]["node"] == "Resolve Owner (WF12)"
    assert conn["Created New V3?"]["main"][1][0]["node"] == "Handle V3 Non-New Disposition"
    assert conn["Handle V3 Non-New Disposition"]["main"][0][0]["node"] == "Verify V3 Dispatch Durable"
    assert conn["Resolve Owner (WF12)"]["main"][0][0]["node"] == "Owner Resolved?"
    assert conn["Owner Resolved?"]["main"][0][0]["node"] == "Prepare V3 Owner Notify"
    assert conn["Owner Resolved?"]["main"][1][0]["node"] == "Route Missing Owner Data"
    assert conn["Prepare V3 Owner Notify"]["main"][0][0]["node"] == "Notify Owner (WF13)"

    names = [n["name"] for n in wf10["nodes"]]
    ids = [n["id"] for n in wf10["nodes"]]
    assert len(names) == len(set(names))
    assert len(ids) == len(set(ids))
    for connection in wf10["connections"].values():
        assert isinstance(connection["main"], list)
        assert all(isinstance(branch, list) for branch in connection["main"])


def test_lrv2_016_owner_fallback_enters_durable_guard_delivery_queue_before_ack_or_end():
    sql = migration("0036_route_missing_owner_delivery_pending.sql")
    fallback = normalized(extract_function(sql, "route_missing_owner_data"))
    requires(
        fallback,
        r"p_reason in \('missing_owner_data', 'routing_safe_mode'\)",
        r"coverage_role in \('primary', 'backup'\) then 'guard_delivery_pending'",
        r"else 'unassigned_alerted'",
        r"event_type <> 'missing_owner_data'",
        r"metadata->>'state'",
        r"on conflict \(idempotency_key\) do nothing",
        r"record_unassigned_alert",
    )
    assert "primary_guard_open" not in fallback
    assert "backup_guard_open" not in fallback
    normalized_sql = normalized(sql)
    requires(
        normalized_sql,
        r"language plpgsql volatile security invoker set search_path = pg_catalog, public",
        r"grant select \(schedule_date, shift, agent_id, coverage_role\) on agent_schedule to service_role",
        r"grant select \(agent_id, name, whatsapp_number, is_available\) on agents to service_role",
        r"revoke select \(schedule_date, shift, agent_id, coverage_role\) on agent_schedule from public, anon, authenticated",
        r"revoke select \(agent_id, name, whatsapp_number, is_available\) on agents from public, anon, authenticated",
        r"revoke all on function route_missing_owner_data\(bigint,text,text\) from public, anon, authenticated",
        r"grant execute on function route_missing_owner_data\(bigint,text,text\) to service_role",
    )

    fixture = (Path(__file__).parent / "fixtures" / "routing_v2" / "test_missing_owner_delivery_queue.sql").read_text(encoding="utf-8")
    fixture_norm = normalized(fixture)
    requires(
        fixture_norm,
        r"array\['missing_owner_data','routing_safe_mode'\]",
        r"guard_delivery_pending",
        r"claim_pending_guard_deliveries\(10\)",
        r"target_agent_id is distinct from 'fallback_primary_test'",
        r"v_attempt_count <> 1",
        r"v_replay_count <> 0",
        r"set local role service_role",
        r"claim_unassigned_alerts\(10, now\(\), interval '2 minutes'\)",
        r"v_alert_count <> 1 or v_second_claim_count <> 0",
        r"unassigned_alerted",
        r"rollback;",
    )

    wf7 = json.loads((WORKFLOWS / "WF7_morning_report.json").read_text(encoding="utf-8"))
    wf10 = json.loads((WORKFLOWS / "WF10_scraper_intake.json").read_text(encoding="utf-8"))
    for workflow, target in ((wf7, "Acknowledge Durable Handoff"), (wf10, "End (Owner Fallback)")):
        by_name = {node["name"]: node for node in workflow["nodes"]}
        for route_name in ("Route Direct To Guard (Safe Mode)", "Route Missing Owner Data"):
            route = by_name[route_name]
            assert "route_missing_owner_data" in route["parameters"]["query"]
            assert not route.get("continueOnFail", False)
            assert route.get("onError") in (None, "stopWorkflow")
        assert workflow["connections"][route_name]["main"] == [[{
                "node": target, "type": "main", "index": 0,
        }]]


def test_owner_first_state_machine_accepts_day_and_night_intake_states():
    sql = normalized(migration("0039_allow_owner_first_from_night_queue.sql"))
    requires(
        sql,
        r"v_opp.state not in \('captured', 'resolved', 'queued_night'\)",
        r"p_tier='owner'.+o.state in \('captured','resolved','queued_night'\)",
        r"language plpgsql volatile security invoker set search_path = pg_catalog, public",
        r"revoke all on function route_missing_owner_data\(bigint,text,text\) from public, anon, authenticated",
        r"revoke all on function create_delivery_attempt\(bigint,text,text,text,text\) from public, anon, authenticated",
    )
    fixture = (
        Path(__file__).parent
        / "fixtures"
        / "routing_v2"
        / "test_owner_first_night_queue.sql"
    ).read_text(encoding="utf-8")
    fixture_norm = normalized(fixture)
    requires(
        fixture_norm,
        r"array\['captured','queued_night'\]",
        r"create_delivery_attempt",
        r"route_missing_owner_data",
        r"guard_delivery_pending",
        r"v_count <> 1",
        r"set local role service_role",
        r"rollback;",
    )


def test_wf3c_serializes_guard_delivery_effects():
    workflow = json.loads(
        (WORKFLOWS / "WF3c_expiry_sweeper.json").read_text(encoding="utf-8")
    )
    nodes = {node["name"]: node for node in workflow["nodes"]}
    query = nodes["Claim Pending Guard Deliveries"]["parameters"]["query"]
    assert "claim_pending_guard_deliveries(1)" in query
    assert "v3_advance_routing_tier" in nodes["Advance Expired Tiers"]["parameters"]["query"]
    assert not any(node["type"] == "n8n-nodes-base.scheduleTrigger" for node in workflow["nodes"])
    assert workflow["connections"]["When Called by WF23"]["main"][0][0]["node"] == (
        "Advance Expired Tiers"
    )
    assert workflow["connections"]["Advance Expired Tiers"]["main"][0][0]["node"] == (
        "Hydrate Transition Attempt"
    )
    assert workflow["connections"]["Hydrate Transition Attempt"]["main"][0][0]["node"] == (
        "Route Transition"
    )


def test_authenticated_claim_can_confirm_a_timed_out_meta_delivery():
    raw_sql = migration("0041_claim_as_delivery_proof.sql")
    sql = normalized(raw_sql)
    body = extract_function(raw_sql, "recover_delivery_from_authenticated_claim")
    requires(
        body,
        r"a\.agent_id=p_agent_id and a\.is_available",
        r"claim actor authentication failed",
        r"v_opp\.state<>'unassigned_alerted'",
        r"v_attempt\.status<>'failed' or v_attempt\.provider_message_id is null",
        r"v_fallback\.metadata->>'reason'<>'delivery_callback_timeout'",
        r"delivery_confirmed_by_claim",
        r"status='delivered'",
        r"expires_at=now\(\)\+interval '5 minutes'",
    )
    requires(
        sql,
        r"language plpgsql volatile security invoker",
        r"set search_path=pg_catalog,public,extensions",
        r"revoke all on function recover_delivery_from_authenticated_claim\(bigint,text,text,text\)\s+from public, anon, authenticated",
        r"grant execute on function recover_delivery_from_authenticated_claim\(bigint,text,text,text\)\s+to service_role",
    )


# --- LRV2-014: observability (0029_routing_v2_metrics.sql) --------------------------


def test_lrv2_014_ops_view_uses_only_db_state_and_delivered_at_for_sla():
    sql = migration("0029_routing_v2_metrics.sql")
    clean = without_comments(sql)
    match = re.search(
        r"create\s+or\s+replace\s+view\s+public\.routing_v2_ops_view.*?;",
        clean, re.I | re.S,
    )
    assert match, "missing routing_v2_ops_view definition"
    view = normalized(match.group(0))
    requires(
        view,
        r"security_invoker\s*=\s*true",
        r"from\s+lead_routing_opportunities\s+o",
        r"where\s+o\.state\s+not\s+in\s+\('closed_won',\s*'closed_lost'\)",
    )
    # SLA-remaining is gated on delivered_at, not created_at/detected_at/assigned_at.
    sla_clause = re.search(r"case.*?end\s+as\s+sla_remaining_seconds", view, re.S)
    assert sla_clause, "missing sla_remaining_seconds derivation"
    assert "delivered_at" in sla_clause.group(0)
    assert "created_at" not in sla_clause.group(0)
    requires(
        view,
        r"is_unassigned",
        r"state\s*=\s*'unassigned_alerted'\s+and\s+o\.assigned_agent_id\s+is\s+null",
    )
    requires(normalized(sql), r"revoke all on table routing_v2_ops_view from public, anon, authenticated",
             r"grant select on table routing_v2_ops_view to service_role")


def test_lrv2_014_kpi_function_uses_delivered_at_never_created_at_for_sla_spans():
    sql = migration("0029_routing_v2_metrics.sql")
    body = extract_function(sql, "get_routing_v2_kpis")
    # plpgsql, not sql: 0029 applies lexically before 0030-0033, so the
    # embedded queries (e.g. conversations.eb_effect_last_error from 0033)
    # must not be validated against the catalog at CREATE FUNCTION time.
    requires(
        normalized(sql),
        r"create\s+or\s+replace\s+function\s+get_routing_v2_kpis\(p_days_back\s+int\s+default\s+7\)\s*returns\s+jsonb\s+as",
        r"language\s+plpgsql\s+stable\s+security\s+invoker\s+set\s+search_path\s*=\s*pg_catalog,\s*public",
    )
    requires(
        body,
        r"delivered_at\s*-\s*detected_at",
        r"accepted_at\s*-\s*delivered_at",
        r"coalesce\(assigned_at,\s*closed_at\)\s*-\s*detected_at",
        r"acceptance_rate_by_tier",
        r"escalations",
        r"late_claims",
        r"failures_by_integration",
        r"unassigned_cases_open",
        r"unassigned_cases_in_window",
    )
    # Never the wrong clock base for an SLA/timing span.
    assert "created_at" not in body
    requires(normalized(sql), r"revoke all on function get_routing_v2_kpis\(int\) from public, anon, authenticated",
             r"grant execute on function get_routing_v2_kpis\(int\) to service_role")


def test_lrv2_014_unassigned_alert_dedupe_and_acknowledge_are_idempotent():
    sql = migration("0029_routing_v2_metrics.sql")
    requires(
        normalized(sql),
        r"create\s+table\s+if\s+not\s+exists\s+routing_v2_unassigned_alerts",
        r"incident_key\s+text\s+not\s+null\s+unique",
        r"acknowledged\s+boolean\s+not\s+null\s+default\s+false",
    )
    record = extract_function(sql, "record_unassigned_alert")
    requires(
        record,
        r"'unassigned:'\s*\|\|\s*p_opportunity_id::text",
        r"on\s+conflict\s*\(incident_key\)\s*do\s+nothing",
    )
    requires(normalized(sql), r"record_unassigned_alert\(.*?\)\s*returns\s+table\s*\(alert_id\s+bigint,\s*is_new\s+boolean,\s*acknowledged\s+boolean\)")
    ack = extract_function(sql, "acknowledge_unassigned_alert")
    requires(
        ack,
        r"set\s+acknowledged\s*=\s*true,\s*acknowledged_at\s*=\s*now\(\),\s*acknowledged_by\s*=\s*p_actor_id",
        r"where\s+incident_key\s*=\s*v_incident\s+and\s+not\s+acknowledged",
    )
    requires(
        normalized(sql),
        r"revoke all on function record_unassigned_alert\(bigint, text\) from public, anon, authenticated",
        r"grant execute on function record_unassigned_alert\(bigint, text\) to service_role",
        r"revoke all on function acknowledge_unassigned_alert\(bigint, text\) from public, anon, authenticated",
        r"grant execute on function acknowledge_unassigned_alert\(bigint, text\) to service_role",
    )


def test_lrv2_014_weekly_report_is_additive_and_keeps_prior_keys():
    sql = migration("0029_routing_v2_metrics.sql")
    body = extract_function(sql, "weekly_lead_report")
    prior_keys = [
        "'generated_at'", "'days'", "'recibidos'", "'reclamados'", "'no_atendidos'",
        "'en_curso'", "'por_fuente'", "'reclamados_por_asesor'", "'asesores_en_turno'",
        "'tasa_reclamo_por_asesor'", "'no_atendidos_lista'",
    ]
    for key in prior_keys:
        assert key in body, f"0020 key dropped from weekly_lead_report: {key}"
    assert "'routing_v2'" in body
    assert "get_routing_v2_kpis(days_back)" in body


def test_lrv2_014_wf20_alerts_unassigned_cases_via_dedupe_rpc():
    wf20 = json.loads((WORKFLOWS / "WF20_watchdog.json").read_text(encoding="utf-8"))
    raw = normalized(json.dumps(wf20))
    requires(
        raw,
        r"routing_v2_ops_view",
        r"is_unassigned",
        r"record_unassigned_alert",
        r"wf20-unassigned:'\s*\|\|\s*u\.opportunity_id::text",
    )
    node_names = [n["name"] for n in wf20["nodes"]]
    node_ids = [n["id"] for n in wf20["nodes"]]
    assert len(node_names) == len(set(node_names))
    assert len(node_ids) == len(set(node_ids))
    for connection in wf20["connections"].values():
        assert isinstance(connection["main"], list)
        assert all(isinstance(branch, list) for branch in connection["main"])

    assert "Revisar Casos Sin Asignar" in node_names
    assert "Caso Nuevo Sin Asignar?" in node_names
    assert "Alertar Caso Sin Asignar (Gmail)" in node_names

    conn = wf20["connections"]
    # The single proven schedule feeds both routing checks.
    scheduled_targets = {
        edge["node"] for edge in conn["Cada 5 min (routing watchdog)"]["main"][0]
    }
    assert "Revisar Fallos de Routing" in scheduled_targets
    assert conn["Revisar Fallos de Routing"]["main"][0][0]["node"] == "Modo Seguro Activo?"
    assert conn["Modo Seguro Activo?"]["main"][0][0]["node"] == "Alertar Modo Seguro (Gmail)"
    assert "Revisar Casos Sin Asignar" in scheduled_targets
    assert conn["Revisar Casos Sin Asignar"]["main"][0][0]["node"] == "Caso Nuevo Sin Asignar?"
    branch = conn["Caso Nuevo Sin Asignar?"]["main"]
    assert branch[0][0]["node"] == "Alertar Caso Sin Asignar (Gmail)"
    assert branch[1] == []

    if_node = next(n for n in wf20["nodes"] if n["name"] == "Caso Nuevo Sin Asignar?")
    assert "is_new" in json.dumps(if_node["parameters"])


def test_lrv2_014_wf20_unassigned_branch_matches_export():
    wf20 = json.loads((WORKFLOWS / "WF20_watchdog.json").read_text(encoding="utf-8"))
    export = load_single_workflow_export(EXPORTS / "BYG_WF20_Watchdog_.json")

    unassigned_node_names = [
        "Revisar Casos Sin Asignar",
        "Caso Nuevo Sin Asignar?",
        "Alertar Caso Sin Asignar (Gmail)",
    ]
    source_params = {n["name"]: n["parameters"] for n in wf20["nodes"]}

    for edition in published_workflow_editions(export):
        export_params = {n["name"]: n["parameters"] for n in edition["nodes"]}
        for name in unassigned_node_names:
            assert name in export_params, f"{name} missing from export"
            assert export_params[name] == source_params[name]
        assert_connections_equivalent(edition["connections"], wf20["connections"])

    export_ids = [n["id"] for n in export["nodes"]]
    assert len(export_ids) == len(set(export_ids))


def test_lrv2_014_wf17_build_html_adds_routing_v2_section_additively():
    wf17_source = WORKFLOWS / "WF17_weekly_email_report.json"
    assert wf17_source.exists(), "LRV2-014 must create the WF17 source-of-truth workflow file"
    wf17 = json.loads(wf17_source.read_text(encoding="utf-8"))
    build_html = next(n for n in wf17["nodes"] if n["name"] == "Build HTML")
    code = build_html["parameters"]["jsCode"]

    # Every pre-existing variable/read stays; only additions are allowed.
    for existing in (
        "const recibidos = r.recibidos || 0;",
        "const reclamados = r.reclamados || 0;",
        "const noAt = r.no_atendidos || 0;",
        "const lista = r.no_atendidos_lista || [];",
        "const porAsesor = r.reclamados_por_asesor || [];",
    ):
        assert existing in code, f"WF17 Build HTML lost a pre-existing line: {existing}"

    assert "const rv2 = r.routing_v2 || {};" in code
    assert "rv2Section" in code
    requires(
        code,
        r"rv2\.unassigned_cases_open",
        r"rv2\.escalations",
        r"rv2\.late_claims",
        r"rv2\.acceptance_rate_by_tier",
    )


LEGACY_MARKER = "Reporte semanal de leads"
RV2_MARKER = "Lead Routing v2 (piloto)"


def _run_wf17_build_html(code: str, report_json: dict) -> str:
    """Execute WF17's Build HTML jsCode under real Node with a minimal n8n stub."""
    # The node's jsCode ends with `return [...]`, which is illegal at top level.
    # Wrap it in a function so `return` is valid and we can capture the result.
    wrapped = "function returnValue() {\n" + code + "\n}\n" + (
        "const $input = { first: () => ({ json: " + json.dumps({"report": report_json}) + " }) };\n"
    )
    wrapped += "console.log(JSON.stringify(returnValue()[0].json));\n"

    with tempfile.TemporaryDirectory() as tmp:
        script_path = Path(tmp) / "build_html.js"
        script_path.write_text(wrapped, encoding="utf-8")
        result = subprocess.run(
            ["node", str(script_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
        )
    assert result.returncode == 0, f"node execution failed: {result.stderr}"
    payload = json.loads(result.stdout.strip().splitlines()[-1])
    return payload["html"]


def test_lrv2_014_wf17_build_html_executes_and_renders_routing_v2_section():
    if shutil.which("node") is None:
        pytest.skip("node not on PATH")

    wf17 = json.loads((WORKFLOWS / "WF17_weekly_email_report.json").read_text(encoding="utf-8"))
    code = next(n for n in wf17["nodes"] if n["name"] == "Build HTML")["parameters"]["jsCode"]

    base_report = {
        "recibidos": 12,
        "reclamados": 7,
        "no_atendidos": 5,
        "asesores_en_turno": 2,
        "por_fuente": {"inmuebles24": 8, "easybroker": 4},
        "reclamados_por_asesor": [{"asesor": "Sandy", "n": 5}],
        "no_atendidos_lista": [
            {"nombre": "Juan Perez", "fuente": "inmuebles24", "telefono": "555", "propiedad": "Casa X", "fecha": "2026-08-01"}
        ],
        "days": 7,
    }

    with_rv2 = {
        **base_report,
        "routing_v2": {
            "unassigned_cases_open": 3,
            "escalations": 2,
            "late_claims": 1,
            "avg_total_seconds": 900,
            "acceptance_rate_by_tier": {"owner": 80, "guard": 50},
        },
    }
    html = _run_wf17_build_html(code, with_rv2)
    assert LEGACY_MARKER in html
    assert RV2_MARKER in html
    # rv2Section must render as its own sibling block, never inside a style attribute.
    assert 'style="<div' not in html
    assert 'style="color:#888' in html

    # Legacy payload without routing_v2 must still render (code guards with `|| {}`).
    without_rv2 = dict(base_report)
    html_legacy = _run_wf17_build_html(code, without_rv2)
    assert LEGACY_MARKER in html_legacy
    assert RV2_MARKER in html_legacy  # section header renders even with zeroed rv2 fields
    assert 'style="<div' not in html_legacy
    assert 'style="color:#888' in html_legacy

    export = json.loads(
        (EXPORTS / "WF17_-_Reporte_Semanal_Email__Gerencia__.json").read_text(encoding="utf-8-sig")
    )
    for edition in (export, export.get("activeVersion")):
        assert edition is not None
        export_build_html = next(n for n in edition["nodes"] if n["name"] == "Build HTML")
        assert export_build_html["parameters"]["jsCode"] == code


def test_failed_guard_retry_preserves_history_and_creates_new_attempt():
    sql = normalized(migration("0042_retry_failed_guard_delivery.sql"))
    requires(
        sql,
        r"status\s*=\s*'requested'\s+and\s+a\.provider_message_id\s+is\s+null",
        r"client_request_id\s+like\s+v_base_key\s*\|\|\s*':retry:%'",
        r"insert\s+into\s+lead_routing_delivery_attempts",
        r"delivery_retry_requeued",
        r"failed_attempts_preserved",
        r"security\s+invoker\s+set\s+search_path\s*=\s*pg_catalog,\s*public",
        r"grant\s+execute\s+on\s+function\s+requeue_failed_guard_delivery\(bigint,\s*text,\s*text\)\s+to\s+service_role",
    )
    assert not re.search(
        r"update\s+lead_routing_delivery_attempts\s+set[^;]*provider_message_id\s*=\s*null",
        sql,
    )
