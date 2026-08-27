"""Offline regression for the three defects found by the 2026-08-13 LRV2 E2E test.

A) n8n imports resolve credential placeholders via explicit mapping and fail closed.
B) executeWorkflow typeVersion 1.2 requires the __rl resource-locator form (plain-string
   workflowId silently breaks: "No information about the workflow to execute found").
C) claim_lead_opportunity needs pgcrypto's digest() reachable via `extensions` in its fixed
   search_path (Supabase layout). The dynamic half of C runs in the PG17 gate with
   tests/fixtures/routing_v2/test_claim_pgcrypto.sql; here we pin the migration contract.

Also enforces that no production credential id enters LRV2 chain artifacts (placeholders only).
"""
import importlib.util
import json
import re
import unittest
from pathlib import Path

import httpx

ROOT = Path(__file__).parents[1]
WORKFLOWS = ROOT / "whatsapp-agent" / "workflows"
EXPORTS = ROOT / "n8n-export"
MIGRATIONS = ROOT / "whatsapp-agent" / "migrations"

SPEC = importlib.util.spec_from_file_location("n8n_control", ROOT / "scripts" / "n8n_control.py")
n8n = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(n8n)

RL_ENV_REF = re.compile(r"^=\{\{ \$env\.[A-Z0-9_]+_WORKFLOW_ID \}\}$")

# LRV2 E2E chain artifacts: any postgres credential in these files must stay a placeholder.
LRV2_CHAIN = [
    WORKFLOWS / "WF1_inbound_router.json",
    WORKFLOWS / "WF3b_claim_handler.json",
    WORKFLOWS / "WF13_directed_notify.json",
    WORKFLOWS / "WF22_delivery_status.json",
    WORKFLOWS / "WF23_delivery_timeout_sweeper.json",
    EXPORTS / "WF1_-_Inbound_Router__Evolution__.json",
    EXPORTS / "WF3b_-_Claim_Handler__Evolution__.json",
    EXPORTS / "WF13_-_Directed_Owner_Notify__Cloud_API__.json",
    EXPORTS / "WF22_-_Delivery_Status_.json",
    EXPORTS / "WF23_-_Delivery_Timeout_Sweeper_.json",
]

OBSERVABLE_V2 = [
    "WF7_morning_report.json",
    "WF10_scraper_intake.json",
    "WF12_owner_resolver.json",
    "WF13_directed_notify.json",
    "WF22_delivery_status.json",
    "WF23_delivery_timeout_sweeper.json",
    "WF3b_claim_handler.json",
    "WF3c_expiry_sweeper.json",
]
OBSERVABLE_V2_EXPORTS = [
    "WF7_-_Morning_Report___Night_Queue_Processing_.json",
    "WF10_-_Scraper_Lead_Intake_.json",
    "WF12_-_Owner_Resolver__EB_owner_table__.json",
    "WF13_-_Directed_Owner_Notify__Cloud_API__.json",
    "WF22_-_Delivery_Status_.json",
    "WF23_-_Delivery_Timeout_Sweeper_.json",
    "WF3b_-_Claim_Handler__Evolution__.json",
    "WF3c_-_Auction_Expiry_Sweeper__Tiered__.json",
]


def load(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def editions(workflow):
    yield workflow
    if isinstance(workflow.get("activeVersion"), dict):
        yield workflow["activeVersion"]


def execute_workflow_nodes(edition):
    for node in edition.get("nodes", []):
        if isinstance(node, dict) and node.get("type") == "n8n-nodes-base.executeWorkflow":
            yield node


def test_v2_dependencies_persist_errors_but_not_successes():
    for directory, names in (
        (WORKFLOWS, OBSERVABLE_V2),
        (EXPORTS, OBSERVABLE_V2_EXPORTS),
    ):
        for name in names:
            for edition in editions(load(directory / name)):
                settings = edition.get("settings", {})
                assert settings.get("saveDataErrorExecution") == "all", name
                assert settings.get("saveDataSuccessExecution") == "none", name
                if name.startswith(("WF23", "WF3c")):
                    assert settings.get("timezone") == "America/Mexico_City", name


class ExecuteWorkflowResourceLocatorTests(unittest.TestCase):
    """Fix B: never regress to plain-string workflowId on typeVersion >= 1.2."""

    def assert_rl(self, node, context):
        workflow_id = node.get("parameters", {}).get("workflowId")
        self.assertIsInstance(workflow_id, dict, f"{context}: {node['name']} must use __rl resource locator")
        self.assertIs(workflow_id.get("__rl"), True, f"{context}: {node['name']} missing __rl:true")
        self.assertEqual(workflow_id.get("mode"), "id", f"{context}: {node['name']} mode must be 'id'")
        self.assertTrue(workflow_id.get("value"), f"{context}: {node['name']} empty workflowId value")

    def test_all_canonical_sources_and_exports_use_rl_form(self):
        checked = 0
        for directory in (WORKFLOWS, EXPORTS):
            for path in sorted(directory.glob("*.json")):
                if path.name.startswith("live_"):  # historical live snapshots, not templates
                    continue
                for edition in editions(load(path)):
                    for node in execute_workflow_nodes(edition):
                        if (node.get("typeVersion") or 0) >= 1.2:
                            self.assert_rl(node, path.name)
                            checked += 1
        self.assertGreaterEqual(checked, 20)

    def test_wf1_source_export_and_active_version_call_wf3b_via_rl_env_ref(self):
        for path in (WORKFLOWS / "WF1_inbound_router.json", EXPORTS / "WF1_-_Inbound_Router__Evolution__.json"):
            for edition in editions(load(path)):
                nodes = {n["name"]: n for n in execute_workflow_nodes(edition)}
                self.assertEqual(
                    set(nodes),
                    {"Call WF2: Lead Intake", "Call WF3b: Claim Handler", "Call WF4: AI Conversation", "Call WF15: Followup Reply"},
                )
                for node in nodes.values():
                    self.assert_rl(node, path.name)
                    self.assertRegex(node["parameters"]["workflowId"]["value"], RL_ENV_REF)
                wf3b = nodes["Call WF3b: Claim Handler"]
                self.assertEqual(wf3b["parameters"]["workflowId"]["value"], "={{ $env.WF3B_WORKFLOW_ID }}")

    def test_wf1_to_wf3b_chain_is_wired(self):
        wf1 = load(WORKFLOWS / "WF1_inbound_router.json")
        self.assertEqual(wf1["connections"]["Classify & Route"]["main"][0][0]["node"], "Attach V3 Capture Context")
        self.assertEqual(wf1["connections"]["Attach V3 Capture Context"]["main"][0][0]["node"], "Switch")
        self.assertEqual(
            wf1["connections"]["Switch"]["main"][1][0]["node"],
            "Call WF3b: Claim Handler",
        )
        wf3b = load(WORKFLOWS / "WF3b_claim_handler.json")
        self.assertEqual(wf3b["connections"]["When Called by WF1"]["main"][0][0]["node"], "Is Routing V2 Claim?")


class CredentialImportRegressionTests(unittest.TestCase):
    """Fix A on the real LRV2 artifacts: import with mapping works, without mapping fails closed."""

    def mock_client(self, handler):
        return httpx.Client(base_url="https://fake-n8n.example/api/v1/",
                            headers={"X-N8N-API-KEY": "k"}, transport=httpx.MockTransport(handler))

    def test_wf3b_export_imports_with_mapping_and_without_placeholders(self):
        captured = {}
        def handler(request):
            captured["body"] = request.content.decode("utf-8")
            return httpx.Response(200, json={"id": "JMx", "active": False})
        result = n8n.import_inactive(
            load(EXPORTS / "WF3b_-_Claim_Handler__Evolution__.json"),
            "https://fake-n8n.example/api/v1/", "k", workflow_id="JMx",
            client=self.mock_client(handler),
            credential_map={"REPLACE_WITH_POSTGRES_CREDENTIAL_ID": "cred-test-id"},
        )
        self.assertFalse(result["active"])
        self.assertNotIn("REPLACE_WITH_", captured["body"])
        self.assertIn("cred-test-id", captured["body"])
        body = json.loads(captured["body"])
        self.assertNotIn("active", body)
        self.assertNotIn("id", body)

    def test_wf1_export_import_without_mapping_fails_closed(self):
        calls = []
        def handler(request):
            calls.append(request.method)
            return httpx.Response(200, json={})
        with self.assertRaises(ValueError) as ctx:
            n8n.import_inactive(load(EXPORTS / "WF1_-_Inbound_Router__Evolution__.json"),
                                "https://fake-n8n.example/api/v1/", "k",
                                client=self.mock_client(handler))
        self.assertEqual(calls, [])
        self.assertIn("REPLACE_WITH_POSTGRES_CREDENTIAL_ID", str(ctx.exception))


class NoProductionCredentialIdsTests(unittest.TestCase):
    """Repo artifacts of the LRV2 chain must carry only placeholders — never live credential ids."""

    def test_lrv2_chain_postgres_credentials_are_placeholders_only(self):
        for path in LRV2_CHAIN:
            for edition in editions(load(path)):
                for node in edition.get("nodes", []):
                    credential = (node.get("credentials") or {}).get("postgres")
                    if credential is None:
                        continue
                    self.assertRegex(
                        credential.get("id", ""), r"^REPLACE_WITH_[A-Z0-9_]+$",
                        f"{path.name}: node {node.get('name')} must keep a placeholder credential id",
                    )


class ClaimPgcryptoMigrationTests(unittest.TestCase):
    """Fix C contract: forward-only migration 0034 exists, pins the exact signature, and adds
    `extensions` to the function search_path. Dynamic proof lives in the PG17 gate fixture."""

    def test_migration_0034_contract(self):
        sql = (MIGRATIONS / "0034_claim_pgcrypto_search_path.sql").read_text(encoding="utf-8")
        self.assertIn("pg_get_function_identity_arguments", sql)
        self.assertIn(
            "p_opportunity_id bigint, p_tier text, p_agent_id text, p_actor_phone_hash text, p_idempotency_key text",
            sql,
        )
        self.assertRegex(
            sql,
            r"ALTER FUNCTION public\.claim_lead_opportunity\(bigint, text, text, text, text\)\s*"
            r"SET search_path = pg_catalog, public, extensions;",
        )
        self.assertNotIn("CREATE OR REPLACE FUNCTION", sql)  # forward-only: never redefines 0026

    def test_migration_0026_is_not_retroactively_edited(self):
        sql = (MIGRATIONS / "0026_claim_lead_opportunity.sql").read_text(encoding="utf-8")
        self.assertIn("SET search_path=pg_catalog,public;", sql)
        self.assertNotIn("extensions", sql)

    def test_pg17_gate_fixture_demands_supabase_layout_and_idempotent_claim(self):
        fixture = (ROOT / "tests" / "fixtures" / "routing_v2" / "test_claim_pgcrypto.sql").read_text(encoding="utf-8")
        for required in (
            "extname='pgcrypto' AND n.nspname='extensions'",
            "search_path=pg_catalog, public, extensions",
            "idempotent replay",
            "ROLLBACK;",
        ):
            self.assertIn(required, fixture)

    def test_verify_production_checks_claim_search_path(self):
        sql = (ROOT / "whatsapp-agent" / "scripts" / "02_verify_production.sql").read_text(encoding="utf-8")
        self.assertIn("claim_search_path_includes_extensions", sql)
        self.assertIn("search_path=pg_catalog, public, extensions", sql)


if __name__ == "__main__":
    unittest.main()
