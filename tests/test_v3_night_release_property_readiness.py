"""Static contracts for the 2026-09-01 V3 routing incident hardening."""

import json
import re
from pathlib import Path


ROOT = Path(__file__).parents[1]
MIGRATION = (
    ROOT
    / "supabase"
    / "migrations"
    / "20260901153200_fix_v3_night_release_property_readiness.sql"
)
CANONICAL_WF10 = ROOT / "whatsapp-agent" / "workflows" / "WF10_scraper_intake.json"
MIRROR_WF10 = ROOT / "n8n-export" / "WF10_-_Scraper_Lead_Intake_.json"
CANONICAL_WF7 = ROOT / "whatsapp-agent" / "workflows" / "WF7_morning_report.json"
MIRROR_WF7 = ROOT / "n8n-export" / "WF7_-_Morning_Report___Night_Queue_Processing_.json"
SQL_FIXTURE = ROOT / "tests" / "fixtures" / "v3" / "test_night_release_property_readiness.sql"
PREFLIGHT = ROOT / "output" / "v3-execution" / "incident-20260901" / "opp706_preflight_readonly.sql"
REPAIR = ROOT / "output" / "v3-execution" / "incident-20260901" / "opp706_repair_cas.sql"


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8").lower()


def _function(sql: str, name: str, next_name: str | None = None) -> str:
    start = sql.index(f"create or replace function public.{name}")
    if next_name is None:
        return sql[start:]
    end = sql.index(f"create or replace function public.{next_name}", start)
    return sql[start:end]


def _node(workflow: dict, name: str) -> dict:
    return next(item for item in workflow["nodes"] if item["name"] == name)


def test_idempotent_intake_repairs_only_a_missing_valid_property():
    intake = _function(_sql(), "v3_intake", "claim_v3_i24_contact_effects")

    assert "^eb-[a-z0-9]{4,}$" in intake
    assert "v_existing.property_public_id is null" in intake
    assert "property_public_id is null" in intake
    assert "property_id = coalesce(o.property_id, v_property)" in intake
    assert "v_opp.identity_key is not distinct from v_existing.identity_key" in intake
    assert "not exists (" in intake and "conflicting.opportunity_id" in intake
    assert "conflicting.v3_enabled" in intake
    assert "conflicting.v3_account_key = v_account" in intake
    assert "v_existing_capture_id := v_existing.capture_event_id" in intake
    assert "where e.capture_event_id = v_existing_capture_id" in intake
    assert "e.route_dispatch_status in ('failed', 'manual_review')" in intake
    assert "e.route_dispatch_last_error_code = 'missing_property_public_id'" in intake
    assert "v_existing.route_dispatched_at is null" in intake
    assert "v_opp.assigned_agent_id is null" in intake
    assert "v_opp.current_delivery_attempt_id is null" in intake
    assert "from public.lead_routing_delivery_attempts attempt" in intake
    assert "'v3-route-dispatched:' || v_existing_capture_id::text" in intake
    assert "and v_can_rearm" in intake
    assert "greatest(" in intake
    assert "coalesce(e.route_dispatch_next_attempt_at, p_now), p_now" in intake
    assert "route_dispatch_attempts =" not in intake
    assert "return query select v_existing.disposition" in intake


def test_intake_qualifies_columns_that_collide_with_table_output_parameters():
    intake = _function(_sql(), "v3_intake", "claim_v3_i24_contact_effects")

    assert "#variable_conflict error" in intake
    assert "from public.i24_capture_events as e" in intake
    assert "where e.account_key = v_account" in intake
    assert "order by e.capture_event_id" in intake
    assert "from public.lead_routing_opportunities as o" in intake
    assert "where o.opportunity_id = v_existing.opportunity_id" in intake
    assert "where o.opportunity_id = v_opp.opportunity_id" in intake
    assert "when e.reason = 'missing_property_pending_backfill'" in intake
    assert "else e.reason" in intake
    assert "where e.capture_event_id = v_existing_capture_id" in intake
    assert "order by o.opportunity_id" in intake
    assert ") on conflict do nothing" in intake
    assert "on conflict (opportunity_id)" not in intake

    output_columns = (
        "disposition",
        "opportunity_id",
        "capture_event_id",
        "contactado_status",
        "reason",
    )
    for column in output_columns:
        assert not re.search(
            rf"(?m)^\s*(?:where|and|or|order\s+by|when|else)\s+{column}\b",
            intake,
        ), f"unqualified v3_intake output column in SQL expression: {column}"


def test_contactado_waits_for_route_readiness_without_creating_a_deadlock():
    contact = _function(
        _sql(), "claim_v3_i24_contact_effects", "claim_v3_route_dispatches"
    )

    assert "#variable_conflict error" in contact
    assert "e.route_dispatch_status = 'pending'" in contact
    assert "upper(btrim(e.property_public_id)) ~ '^eb-[a-z0-9]{4,}$'" in contact
    assert "upper(btrim(o.property_id)) = upper(btrim(e.property_public_id))" in contact
    assert "e.disposition <> 'non_routable'" in contact
    assert "route_dispatch_status = 'dispatched'" not in contact


def test_route_dispatch_cannot_claim_a_night_or_unmapped_capture():
    claim = _function(
        _sql(), "claim_v3_route_dispatches", "v3_release_night_queue"
    )

    assert "#variable_conflict error" in claim
    assert "o.state <> 'queued_night'" in claim
    assert "perform public.v3_release_night_queue(500, p_now)" in claim
    assert "e.contactado_status = 'verified'" in claim
    assert "e.route_dispatch_status in ('pending', 'failed', 'leased')" in claim
    assert "e.route_dispatch_status = 'manual_review'" not in claim
    assert "upper(btrim(e.property_public_id)) ~ '^eb-[a-z0-9]{4,}$'" in claim
    assert "upper(btrim(o.property_id)) = upper(btrim(e.property_public_id))" in claim
    assert "for update of e skip locked" in claim


def test_intake_keeps_the_0800_to_0805_boundary_in_the_night_queue():
    intake = _function(_sql(), "v3_intake", "claim_v3_i24_contact_effects")

    assert "time '20:00:00'" in intake
    assert "time '08:05:00'" in intake
    assert "time '08:00:00'" not in intake
    assert "v_route_not_before" in intake
    assert "route_dispatch_next_attempt_at, happened_at" in intake

    claim = _function(_sql(), "claim_v3_route_dispatches", "v3_release_night_queue")
    assert "e.happened_at at time zone 'america/mexico_city'" in claim
    assert "+ 1 + time '08:05:00'" in claim


def test_night_release_only_opens_a_verified_pending_hold():
    release = _function(_sql(), "v3_release_night_queue", "claim_night_queue")

    assert "time '08:05:00'" in release
    assert "o.state = 'queued_night'" in release
    assert "released as (" in release
    assert "legacy_retired as (" in release
    assert "rearmed as (" not in release
    assert "update public.i24_capture_events" not in release
    assert "e.disposition = 'created_new'" in release
    assert "e.contactado_status = 'verified'" in release
    assert "e.route_dispatch_status = 'pending'" in release
    assert "e.route_dispatch_status in ('failed', 'manual_review')" not in release
    assert "e.route_dispatch_attempts = 0" not in release
    assert "e.route_dispatch_last_error_code is null" not in release
    assert "e.route_dispatch_next_attempt_at <= p_now" in release
    assert "webhook_dispatch_failed" not in release
    assert "from public.lead_routing_delivery_attempts" in release
    assert "o.assigned_agent_id is null" in release
    assert "o.current_delivery_attempt_id is null" in release
    assert "'v3-route-dispatched:' || e.capture_event_id::text" in release
    assert "processing_status = 'processed'" in release
    assert "cross join effect_barrier" in release


def test_wf10_uses_one_explicit_stable_2xx_after_each_durable_branch():
    canonical = json.loads(CANONICAL_WF10.read_text(encoding="utf-8"))
    mirror = json.loads(MIRROR_WF10.read_text(encoding="utf-8"))

    for workflow in (canonical, mirror):
        webhook = _node(workflow, "Scraper Webhook")
        verify = _node(workflow, "Verify V3 Dispatch Durable")
        response = _node(workflow, "Respond V3 Dispatch Accepted")
        rejected = _node(workflow, "Respond V3 Dispatch Not Durable")
        assert webhook["parameters"]["responseMode"] == "responseNode"
        assert response["type"] == "n8n-nodes-base.respondToWebhook"
        assert response["parameters"]["options"]["responseCode"] == 200
        assert rejected["parameters"]["options"]["responseCode"] == 409
        assert "capture_event_id" in response["parameters"]["responseBody"]
        assert _node(workflow, "Notify Owner (WF13)")["alwaysOutputData"] is True
        assert _node(workflow, "Route Missing Owner Data")["alwaysOutputData"] is True
        assert "lead_routing_delivery_attempts" in verify["parameters"]["query"]
        assert "delivery_kind = 'assigned_notice'" in verify["parameters"]["query"]
        assert "event_type = 'deduplicated'" in verify["parameters"]["query"]
        assert "event_type = 'missing_owner_data'" in verify["parameters"]["query"]
        assert workflow["connections"]["Notify Owner (WF13)"]["main"][0][0]["node"] == verify["name"]
        assert workflow["connections"]["End (Owner Fallback)"]["main"][0][0]["node"] == verify["name"]
        assert workflow["connections"]["V3 Dispatch Durable?"]["main"][0][0]["node"] == response["name"]
        assert workflow["connections"]["V3 Dispatch Durable?"]["main"][1][0]["node"] == rejected["name"]
        assert workflow.get("activeVersionId") is None

    canonical_parameters = {
        item["name"]: item.get("parameters") for item in canonical["nodes"]
    }
    mirror_parameters = {
        item["name"]: item.get("parameters") for item in mirror["nodes"]
    }
    assert mirror_parameters == canonical_parameters
    assert mirror["connections"] == canonical["connections"]
    assert mirror.get("activeVersion") is None
    assert isinstance(mirror.get("historicalActiveVersion"), dict)


def test_non_new_dispositions_cannot_open_owner_fallback_or_duplicate_delivery():
    for path in (CANONICAL_WF10, MIRROR_WF10):
        workflow = json.loads(path.read_text(encoding="utf-8"))
        handler = _node(workflow, "Handle V3 Non-New Disposition")

        assert workflow["connections"]["Restore V3 Dispatch Context"]["main"][0][0]["node"] == "Created New V3?"
        assert workflow["connections"]["Created New V3?"]["main"][0][0]["node"] == "Resolve Owner (WF12)"
        assert workflow["connections"]["Created New V3?"]["main"][1][0]["node"] == handler["name"]
        assert workflow["connections"][handler["name"]]["main"][0][0]["node"] == "Verify V3 Dispatch Durable"
        assert "v3_route_ready_opportunity" in handler["parameters"]["query"]
        assert "route_missing_owner_data" not in handler["parameters"]["query"]


def test_safe_mode_is_explicitly_v2_only_and_unconnected_from_v3():
    text = _sql()
    legacy_claim = _function(text, "claim_night_queue")
    workflow = json.loads(CANONICAL_WF10.read_text(encoding="utf-8"))
    wf7 = json.loads(CANONICAL_WF7.read_text(encoding="utf-8"))
    wf7_mirror = json.loads(MIRROR_WF7.read_text(encoding="utf-8"))

    assert "#variable_conflict error" in legacy_claim
    assert "scope is v2 only" in text
    assert "v3 must not branch on this singleton" in text
    assert "singleton" in text
    assert "not exists (" in legacy_claim
    assert "o.opportunity_id = nq.opportunity_id" in legacy_claim
    assert "and o.v3_enabled" in legacy_claim
    for edition in (wf7, wf7_mirror):
        release_query = _node(edition, "Release V3 Night Queue 08:05")["parameters"]["query"].lower()
        fetch_query = _node(edition, "Fetch Queue for Processing")["parameters"]["query"]
        assert "select count(*)::integer as released_count" in release_query
        assert "v3_release_night_queue(500,now())" in release_query.replace(" ", "")
        assert "select *" not in release_query
        assert "claim_night_queue" in fetch_query
        assert edition["connections"]["Release V3 Night Queue 08:05"]["main"][0][0]["node"] == "Fetch Queue for Processing"
        assert edition["connections"]["Process One by One"]["main"][1][0]["node"] == "Check Routing Safe Mode"
    assert workflow["connections"]["Scraper Webhook"]["main"][0][0]["node"] == "Split & Normalize Leads"
    assert "Check V3 Routing Safe Mode" not in {
        edge["node"]
        for outputs in workflow["connections"]["Split & Normalize Leads"]["main"]
        for edge in outputs
    }


def test_deterministic_easybroker_conflicts_stop_without_retry():
    sql = _sql()
    finish = _function(sql, "finish_v3_easybroker_effect")
    terminal_predicate = finish.split("v_manual_review :=", 1)[1].split(";", 1)[0]

    assert "'manual_review'" in sql
    assert "easybroker_effect_ledger_close_state_check" in sql
    assert "'easybroker_assignee_conflict'" in terminal_predicate
    assert "'responsible_note_conflict'" in terminal_predicate
    assert "easybroker_assignee_check_failed" not in terminal_predicate
    assert "when v_manual_review then 'manual_review'" in finish
    assert "when v_close_state = 'manual_review' then null" in finish
    assert "when v_manual_review or v_next_count >= 5 then null" in finish
    assert "easybroker_effects_exhausted', 'easybroker_effect_manual_review" in sql
    assert "if v_close_state in ('exhausted', 'manual_review')" in finish
    assert "'easybroker_effect_manual_review:' || p_eb_request_id" in finish
    assert "when 'manual_review' then 'easybroker_effect_manual_review'" in finish
    assert "'error_code', nullif(p_evidence->>'error_code', '')" in finish
    assert "on conflict (incident_key) do nothing" in finish


def test_sql_fixture_and_approval_gated_repair_artifacts_exist():
    fixture = SQL_FIXTURE.read_text(encoding="utf-8").lower()
    preflight = PREFLIGHT.read_text(encoding="utf-8").lower()
    repair = REPAIR.read_text(encoding="utf-8").lower()

    assert "begin;" in fixture and "rollback;" in fixture
    assert "claim_v3_i24_contact_effects" in fixture
    assert "v3_release_night_queue" in fixture
    assert "claim_night_queue" in fixture
    assert "fresh v3 release did not retire its legacy report-only row" in fixture
    assert "route_dispatch_status = 'failed'" in fixture
    assert "route_dispatch_status = 'manual_review'" in fixture
    assert "backfill rearmed a capture with durable dispatch evidence" in fixture
    assert "08:04:59 cdmx intake escaped the night queue" in fixture
    assert "night release opened before 08:05 cdmx" in fixture
    assert "08:05 cdmx did not release the boundary intake" in fixture
    assert "legacy manual_review capture changed without its explicit cas" in fixture
    assert "legacy manual_review state or evidence changed during release" in fixture
    assert "legacy manual_review report row changed during release" in fixture
    assert "legacy manual_review capture was claimable without its explicit cas" in fixture
    assert "night recurrent did not preserve its assigned opportunity" in fixture
    assert "returning_assigned escaped its 08:05 night hold" in fixture
    assert "returning_assigned did not release at 08:05" in fixture
    assert "night property backfill erased the 08:05 hold" in fixture
    assert "night property backfill routed before 08:05" in fixture
    assert "night property backfill did not release at 08:05" in fixture
    assert "route_dispatch_attempts = 4" in fixture
    assert "deterministic easybroker conflict was not parked and alerted" in fixture
    assert "manual-review conflict retained retry or lease state" in fixture
    assert "manual-review conflict did not create its exact alert" in fixture
    assert "manual-review replay duplicated its alert" in fixture
    assert fixture.count("missing_property_public_id") >= 4
    assert "begin transaction read only" in preflight
    assert "rollback;" in preflight
    assert "do not run without explicit production approval" in repair
    assert "route_dispatch_attempts" in repair
    assert "set route_dispatch_attempts" not in repair
    assert "lead_routing_delivery_attempts" in repair
