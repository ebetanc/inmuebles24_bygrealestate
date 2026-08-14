import importlib.util
import json
import tempfile
import unittest
import unittest.mock
from pathlib import Path

import httpx

SPEC = importlib.util.spec_from_file_location("n8n_control", Path(__file__).parents[1] / "scripts" / "n8n_control.py")
n8n = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(n8n)

BASE_URL = "https://fake-n8n.example/api/v1/"


def mock_client(handler):
    """Offline httpx.Client: MockTransport never opens a socket, so no live API is ever called."""
    return httpx.Client(base_url=BASE_URL, headers={"X-N8N-API-KEY": "secret"}, transport=httpx.MockTransport(handler))


def workflow(id, name, active=False, nodes=None, connections=None, settings=None, **extra):
    return {"id": id, "name": name, "active": active, "isArchived": False, "nodes": nodes or [{"id": "n1", "name": "Start", "type": "n8n-nodes-base.manualTrigger"}], "connections": connections or {}, "settings": settings or {}, **extra}


class N8nControlTests(unittest.TestCase):
    def write(self, directory, *items):
        for number, item in enumerate(items):
            (directory / f"{number}.json").write_text(json.dumps(item), encoding="utf-8")

    def test_happy_error_handler(self):
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp); handler = workflow("err", "Error Handler", True, [{"id":"e", "name":"Error", "type":"n8n-nodes-base.errorTrigger"}])
            self.write(d, handler, workflow("main", "Main", True, settings={"errorWorkflow":"err"}))
            self.assertEqual(n8n.validate(d)["summary"]["fail"], 0)

    def test_watchdog_is_an_error_workflow_exception(self):
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp); self.write(d, workflow("watch", "WF20 Watchdog", True))
            self.assertEqual(n8n.validate(d)["summary"]["fail"], 0)

    def test_broken_connection_and_literal_reference(self):
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp); node = {"id":"x", "name":"Call", "type":"n8n-nodes-base.executeWorkflow", "parameters":{"workflowId":"gone"}}
            self.write(d, workflow("a", "A", nodes=[node], connections={"Call":{"main":[[{"node":"nope"}]]}}))
            codes = {i["code"] for i in n8n.validate(d)["issues"]}; self.assertTrue({"workflow_ref", "connection_target"} <= codes)

    def test_malformed_execute_workflow_parameters_fail_without_crashing(self):
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp); node = {"id":"x", "name":"Call", "type":"n8n-nodes-base.executeWorkflow", "parameters":"bad"}
            self.write(d, workflow("a", "A", nodes=[node]))
            self.assertIn("workflow_ref", {i["code"] for i in n8n.validate(d)["issues"]})

    def test_env_reference_warns(self):
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp); node = {"id":"x", "name":"Call", "type":"n8n-nodes-base.executeWorkflow", "parameters":{"workflowId":{"value":"={{ $env.WF2_WORKFLOW_ID }}"}}}
            self.write(d, workflow("a", "A", nodes=[node])); self.assertIn("env_workflow_ref", {i["code"] for i in n8n.validate(d)["issues"]})

    def test_active_requires_error_and_smoke_inactive(self):
        with tempfile.TemporaryDirectory() as temp:
            d = Path(temp); self.write(d, workflow("a", "WF1 SMOKE_TEST", True))
            codes = {i["code"] for i in n8n.validate(d)["issues"]}; self.assertTrue({"error_workflow", "smoke_active"} <= codes)

    def test_drift_ignores_envelope_but_finds_changed_missing(self):
        with tempfile.TemporaryDirectory() as temp:
            base, same, changed = (Path(temp) / name for name in ("base", "same", "changed"))
            for d in (base, same, changed): d.mkdir()
            item = workflow("a", "A", False, versionId="one")
            self.write(base, item, workflow("b", "B")); self.write(same, workflow("a", "A", False, versionId="two"), workflow("b", "B"))
            self.assertFalse(any(n8n.drift(base, same).values()))
            self.write(changed, workflow("a", "A", nodes=[{"id":"n2", "name":"Changed", "type":"n8n-nodes-base.noOp"}])); result = n8n.drift(base, changed)
            self.assertEqual(result["changed"], ["A"])
            self.assertEqual(result["missing"], ["B"])
            self.assertEqual(n8n.drift(base, Path(temp) / "none")["fatal"].startswith("directory not found"), True)

    def test_drift_detects_operational_state(self):
        with tempfile.TemporaryDirectory() as temp:
            base, candidate = Path(temp) / "base", Path(temp) / "candidate"
            base.mkdir(); candidate.mkdir(); self.write(base, workflow("a", "A", False)); self.write(candidate, workflow("a", "A", True))
            self.assertEqual(n8n.drift(base, candidate)["changed"], ["A"])

    def test_sensitive_header_literal_but_not_env(self):
        literal = {"headers":[{"name":"Authorization", "value":"Bearer secret"}]}
        dynamic = {"headers":[{"name":"Authorization", "value":"={{ $env.API_TOKEN }}"}]}
        self.assertTrue(n8n.find_sensitive(literal))
        self.assertFalse(n8n.find_sensitive(dynamic))

    def test_drift_rejects_invalid_or_duplicate_inputs(self):
        with tempfile.TemporaryDirectory() as temp:
            base, candidate = Path(temp) / "base", Path(temp) / "candidate"
            base.mkdir(); candidate.mkdir(); self.write(base, workflow("a", "A")); self.write(candidate, workflow("a", "A"))
            (candidate / "bad.json").write_text("{", encoding="utf-8")
            self.assertIn("fatal", n8n.drift(base, candidate))

    def test_empty_export_is_fatal(self):
        with tempfile.TemporaryDirectory() as temp:
            empty = Path(temp)
            self.assertIn("fatal", n8n.validate(empty))

    def test_inventory_classifies_workflows(self):
        with tempfile.TemporaryDirectory() as temp:
            live = Path(temp) / "live"; live.mkdir()
            self.write(live, workflow("a", "Live", True), workflow("s", "WF SMOKE TEST"), workflow("z", "Old", isArchived=True))
            rows = n8n.inventory(live, [])["live"]["workflows"]
            self.assertEqual([row["scope"] for row in rows], ["live", "smoke", "archive"])
            self.assertTrue(all(row["format"] == "export" for row in rows))

    def test_inventory_marks_partial_workflow_as_template(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp); self.write(directory, {"name":"Template", "nodes":[], "connections":{}})
            self.assertEqual(n8n.inventory(directory, [])["live"]["workflows"][0]["format"], "template")

    def test_inventory_exposes_literal_and_env_workflow_refs(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            nodes = [
                {"id":"a", "name":"Literal", "type":"n8n-nodes-base.executeWorkflow", "parameters":{"workflowId":"target"}},
                {"id":"b", "name":"Env", "type":"n8n-nodes-base.executeWorkflow", "parameters":{"workflowId":{"value":"={{ $env.WF2_WORKFLOW_ID }}"}}},
            ]
            self.write(directory, workflow("source", "Source", nodes=nodes))
            refs = n8n.inventory(directory, [])["live"]["workflows"][0]["workflowRefs"]
            self.assertEqual(refs, ["={{ $env.WF2_WORKFLOW_ID }}", "target"])

    def test_inventory_reports_missing_extra_and_duplicate_by_name_not_id(self):
        with tempfile.TemporaryDirectory() as temp:
            live, mirror = Path(temp) / "live", Path(temp) / "mirror"
            live.mkdir(); mirror.mkdir()
            self.write(live, workflow("live-a", "A"), workflow("live-b", "B"))
            self.write(mirror, workflow("other-a", "A"), workflow("one", "C"), workflow("two", "C"))
            result = n8n.inventory(live, [mirror])
            self.assertEqual(result["mirrors"][0]["missing"], ["B"])
            self.assertEqual(result["mirrors"][0]["extra"], ["C"])
            self.assertEqual(result["mirrors"][0]["duplicates"], ["C"])
            self.assertEqual(result["summary"], {"duplicates": 1, "missing": 1, "extra": 1})

    def test_inventory_empty_export_is_fatal(self):
        with tempfile.TemporaryDirectory() as temp:
            empty = Path(temp) / "empty"; empty.mkdir()
            self.assertIn("fatal", n8n.inventory(empty, []))

    def test_manifest_happy_snapshot_ignores_envelope(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source, mirror = root / "source", root / "mirror"; source.mkdir(); mirror.mkdir()
            self.write(source, workflow("one", "A", versionId="new")); self.write(mirror, workflow("other", "A", versionId="old"))
            manifest = {"schema":n8n.MANIFEST_SCHEMA,"source":"source","mirrors":[{"directory":"mirror","coverage":"partial","files":{"0.json":{"role":"snapshot","workflow":"A","reason":"copy"}}}]}
            path = root / "manifest.json"; path.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertEqual(n8n.manifest_check(path)["summary"]["policy"], 0)

    def test_manifest_unknown_stale_ambiguous_drift_and_unsafe(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source, mirror = root / "source", root / "mirror"; source.mkdir(); mirror.mkdir()
            self.write(source, workflow("one", "A")); self.write(mirror, workflow("two", "A", active=True))
            base = {"schema":n8n.MANIFEST_SCHEMA,"source":"source","mirrors":[{"directory":"mirror","coverage":"partial","files":{"0.json":{"role":"snapshot","workflow":"A","reason":"copy"}}}]}
            path = root / "manifest.json"; path.write_text(json.dumps(base), encoding="utf-8")
            issues = n8n.manifest_check(path)["issues"]
            self.assertEqual({x["code"] for x in issues}, {"content_drift"})
            self.assertIn("active", issues[0]["detail"])
            base["mirrors"][0]["files"]["gone.json"]={"role":"ambiguous","reason":"review"}; path.write_text(json.dumps(base), encoding="utf-8")
            self.assertIn("fatal", n8n.manifest_check(path))
            base["mirrors"][0]["files"]={"../bad.json":{"role":"template","reason":"bad"}}; path.write_text(json.dumps(base), encoding="utf-8")
            self.assertIn("fatal", n8n.manifest_check(path))

    def test_manifest_rejects_identically_malformed_snapshots(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source, mirror = root / "source", root / "mirror"; source.mkdir(); mirror.mkdir()
            malformed = {"name":"A", "nodes":[], "connections":{}}
            self.write(source, malformed); self.write(mirror, malformed)
            manifest = {"schema":n8n.MANIFEST_SCHEMA,"source":"source","mirrors":[{"directory":"mirror","coverage":"partial","files":{"0.json":{"role":"snapshot","workflow":"A","reason":"test"}}}]}
            path = root / "manifest.json"; path.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertIn("fatal", n8n.manifest_check(path))

    def test_drift_detail_handles_nodes_without_identity(self):
        source = workflow("a", "A", nodes=[{}])
        mirror = workflow("b", "A", nodes=[{"id":"x"}])
        self.assertIn("nodes[", n8n.drift_detail(source, mirror))


class CredentialResolutionTests(unittest.TestCase):
    """E2E fix A: placeholder credential ids resolve through an explicit deploy-time mapping;
    any surviving REPLACE_WITH_* fails closed before any request; no secret ever reaches logs."""

    def node_with_credential(self, credential_id):
        return {"id": "n1", "name": "DB", "type": "n8n-nodes-base.postgres",
                "credentials": {"postgres": {"id": credential_id, "name": "Postgres - Supabase"}}}

    def test_resolve_credentials_replaces_placeholder_via_mapping(self):
        wf = workflow("x", "X", nodes=[self.node_with_credential("REPLACE_WITH_POSTGRES_CREDENTIAL_ID")])
        resolved = n8n.resolve_credentials(wf, {"REPLACE_WITH_POSTGRES_CREDENTIAL_ID": "cred-123"})
        self.assertEqual(resolved["nodes"][0]["credentials"]["postgres"]["id"], "cred-123")
        # input untouched (pure function)
        self.assertEqual(wf["nodes"][0]["credentials"]["postgres"]["id"], "REPLACE_WITH_POSTGRES_CREDENTIAL_ID")

    def test_resolve_credentials_fails_closed_on_unmapped_placeholder(self):
        wf = workflow("x", "X", nodes=[self.node_with_credential("REPLACE_WITH_POSTGRES_CREDENTIAL_ID")])
        with self.assertRaises(ValueError) as ctx:
            n8n.resolve_credentials(wf, {"REPLACE_WITH_TWILIO_CREDENTIAL_ID": "cred-999"})
        self.assertIn("REPLACE_WITH_POSTGRES_CREDENTIAL_ID", str(ctx.exception))
        self.assertNotIn("cred-999", str(ctx.exception))  # never echo mapped ids

    def test_resolve_credentials_fails_closed_on_placeholder_outside_credentials(self):
        node = {"id": "n1", "name": "Set", "type": "n8n-nodes-base.set",
                "parameters": {"value": "REPLACE_WITH_POSTGRES_CREDENTIAL_ID"}}
        with self.assertRaises(ValueError):
            n8n.resolve_credentials(workflow("x", "X", nodes=[node]), {"REPLACE_WITH_POSTGRES_CREDENTIAL_ID": "cred-123"})

    def test_resolve_credentials_never_touches_real_ids(self):
        wf = workflow("x", "X", nodes=[self.node_with_credential("realCredId123")])
        resolved = n8n.resolve_credentials(wf, {"REPLACE_WITH_POSTGRES_CREDENTIAL_ID": "cred-123"})
        self.assertEqual(resolved["nodes"][0]["credentials"]["postgres"]["id"], "realCredId123")

    def test_import_inactive_resolves_credentials_and_sends_no_placeholder(self):
        captured = {}
        def handler(request):
            captured["body"] = json.loads(request.content)
            return httpx.Response(200, json={"id": "new", "active": False})
        wf = workflow("x", "X", nodes=[self.node_with_credential("REPLACE_WITH_POSTGRES_CREDENTIAL_ID")])
        n8n.import_inactive(wf, BASE_URL, "secret", client=mock_client(handler),
                            credential_map={"REPLACE_WITH_POSTGRES_CREDENTIAL_ID": "cred-123"})
        self.assertNotIn("REPLACE_WITH_", json.dumps(captured["body"]))
        self.assertEqual(captured["body"]["nodes"][0]["credentials"]["postgres"]["id"], "cred-123")

    def test_import_inactive_fails_closed_before_any_request_on_leftover_placeholder(self):
        calls = []
        def handler(request):
            calls.append(request.method)
            return httpx.Response(200, json={})
        wf = workflow("x", "X", nodes=[self.node_with_credential("REPLACE_WITH_POSTGRES_CREDENTIAL_ID")])
        with self.assertRaises(ValueError):
            n8n.import_inactive(wf, BASE_URL, "secret", client=mock_client(handler))
        self.assertEqual(calls, [])  # rejected before dialing out

    def test_import_inactive_falls_back_to_env_mapping(self):
        captured = {}
        def handler(request):
            captured["body"] = json.loads(request.content)
            return httpx.Response(200, json={"id": "new", "active": False})
        wf = workflow("x", "X", nodes=[self.node_with_credential("REPLACE_WITH_POSTGRES_CREDENTIAL_ID")])
        env = {"N8N_CREDENTIAL_MAP": json.dumps({"REPLACE_WITH_POSTGRES_CREDENTIAL_ID": "cred-env"})}
        with unittest.mock.patch.dict("os.environ", env, clear=False):
            n8n.import_inactive(wf, BASE_URL, "secret", client=mock_client(handler))
        self.assertEqual(captured["body"]["nodes"][0]["credentials"]["postgres"]["id"], "cred-env")

    def test_rollback_from_backup_passes_credential_map_through(self):
        captured = {}
        def handler(request):
            captured["body"] = json.loads(request.content)
            return httpx.Response(200, json={"id": "abc", "active": False})
        with tempfile.TemporaryDirectory() as temp:
            backup = Path(temp) / "wf_abc_backup.json"
            backup.write_text(json.dumps(workflow("abc", "A", nodes=[self.node_with_credential("REPLACE_WITH_POSTGRES_CREDENTIAL_ID")])), encoding="utf-8")
            n8n.rollback_from_backup(backup, BASE_URL, "secret", "abc", client=mock_client(handler),
                                     credential_map={"REPLACE_WITH_POSTGRES_CREDENTIAL_ID": "cred-rb"})
        self.assertEqual(captured["body"]["nodes"][0]["credentials"]["postgres"]["id"], "cred-rb")

    def test_credential_map_from_env_parses_and_rejects(self):
        self.assertEqual(n8n.credential_map_from_env({}), {})
        env = {"N8N_CREDENTIAL_MAP": json.dumps({"REPLACE_WITH_POSTGRES_CREDENTIAL_ID": "cred-123"})}
        self.assertEqual(n8n.credential_map_from_env(env), {"REPLACE_WITH_POSTGRES_CREDENTIAL_ID": "cred-123"})
        for bad in ("not json", json.dumps(["x"]), json.dumps({"NOT_A_PLACEHOLDER": "id"}), json.dumps({"REPLACE_WITH_X": ""})):
            with self.assertRaises(ValueError) as ctx:
                n8n.credential_map_from_env({"N8N_CREDENTIAL_MAP": bad})
            self.assertNotIn("cred-", str(ctx.exception))  # malformed input is never echoed


class N8nApiTests(unittest.TestCase):
    """Offline, mockable n8n REST calls (LRV2-015 deliverable 2). No test ever opens a socket:
    httpx.MockTransport intercepts every request, so there is no live n8n API call here."""

    def test_fetch_live_gets_workflow_by_id(self):
        def handler(request):
            self.assertEqual(request.method, "GET")
            self.assertEqual(request.url.path, "/api/v1/workflows/abc")
            self.assertEqual(request.headers["x-n8n-api-key"], "secret")
            return httpx.Response(200, json=workflow("abc", "A"))
        result = n8n.fetch_live(BASE_URL, "secret", "abc", client=mock_client(handler))
        self.assertEqual(result["name"], "A")

    def test_fetch_live_raises_on_http_error(self):
        client = mock_client(lambda request: httpx.Response(404, json={"message": "not found"}))
        with self.assertRaises(httpx.HTTPStatusError):
            n8n.fetch_live(BASE_URL, "secret", "missing", client=client)

    def test_diff_local_vs_live_detects_no_change(self):
        with tempfile.TemporaryDirectory() as temp:
            local = Path(temp) / "local.json"
            local.write_text(json.dumps(workflow("abc", "A")), encoding="utf-8")
            client = mock_client(lambda request: httpx.Response(200, json=workflow("abc", "A")))
            result = n8n.diff_local_vs_live(local, BASE_URL, "secret", "abc", client=client)
            self.assertFalse(result["differs"])
            self.assertEqual(result["detail"], "")

    def test_diff_local_vs_live_detects_change_without_writing_anything(self):
        with tempfile.TemporaryDirectory() as temp:
            local = Path(temp) / "local.json"
            changed_node = {"id": "n2", "name": "Changed", "type": "n8n-nodes-base.noOp"}
            local.write_text(json.dumps(workflow("abc", "A", nodes=[changed_node])), encoding="utf-8")
            calls = []
            def handler(request):
                calls.append(request.method)
                return httpx.Response(200, json=workflow("abc", "A"))
            result = n8n.diff_local_vs_live(local, BASE_URL, "secret", "abc", client=mock_client(handler))
            self.assertTrue(result["differs"])
            self.assertIn("nodes[", result["detail"])
            self.assertEqual(calls, ["GET"])  # dry-run: read-only, single fetch

    def test_diff_local_vs_live_reports_invalid_local_file(self):
        with tempfile.TemporaryDirectory() as temp:
            local = Path(temp) / "local.json"
            local.write_text("{", encoding="utf-8")
            result = n8n.diff_local_vs_live(local, BASE_URL, "secret", "abc", client=mock_client(lambda r: httpx.Response(200, json={})))
            self.assertIn("fatal", result)

    def test_import_inactive_creates_without_active_field(self):
        captured = {}
        def handler(request):
            captured["method"] = request.method
            captured["path"] = request.url.path
            captured["body"] = json.loads(request.content)
            return httpx.Response(200, json={"id": "new", "active": False})
        # Even a workflow dict carrying active=True must not leak into the request body.
        result = n8n.import_inactive(workflow("x", "X", active=True), BASE_URL, "secret", client=mock_client(handler))
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["path"], "/api/v1/workflows")
        self.assertNotIn("active", captured["body"])
        self.assertNotIn("id", captured["body"])
        self.assertEqual(set(captured["body"]), {"name", "nodes", "connections", "settings"})
        self.assertFalse(result["active"])

    def test_import_inactive_filters_settings_through_whitelist(self):
        captured = {}
        def handler(request):
            captured["body"] = json.loads(request.content)
            return httpx.Response(200, json={"id": "new", "active": False})
        # Repo exports carry keys like availableInMCP that the n8n PUT/POST rejects.
        wf = workflow("x", "X", settings={"timezone": "America/Mexico_City", "availableInMCP": True})
        n8n.import_inactive(wf, BASE_URL, "secret", client=mock_client(handler))
        self.assertEqual(captured["body"]["settings"], {"timezone": "America/Mexico_City"})

    def test_import_inactive_updates_existing_by_id_via_put(self):
        captured = {}
        def handler(request):
            captured["method"] = request.method
            captured["path"] = request.url.path
            captured["body"] = json.loads(request.content)
            return httpx.Response(200, json={"id": "abc", "active": False})
        n8n.import_inactive(workflow("abc", "A"), BASE_URL, "secret", workflow_id="abc", client=mock_client(handler))
        self.assertEqual(captured["method"], "PUT")
        self.assertEqual(captured["path"], "/api/v1/workflows/abc")
        self.assertNotIn("active", captured["body"])

    def test_activate_is_a_separate_explicit_call(self):
        def handler(request):
            self.assertEqual(request.method, "POST")
            self.assertEqual(request.url.path, "/api/v1/workflows/abc/activate")
            return httpx.Response(200, json={"id": "abc", "active": True})
        result = n8n.activate("abc", BASE_URL, "secret", client=mock_client(handler))
        self.assertTrue(result["active"])

    def test_rollback_from_backup_reimports_inactive_and_never_activates(self):
        calls = []
        def handler(request):
            calls.append((request.method, request.url.path))
            return httpx.Response(200, json={"id": "abc", "active": False})
        with tempfile.TemporaryDirectory() as temp:
            backup = Path(temp) / "wf_abc_backup_20260812T083420Z.json"
            backup.write_text(json.dumps(workflow("abc", "A")), encoding="utf-8")
            result = n8n.rollback_from_backup(backup, BASE_URL, "secret", "abc", client=mock_client(handler))
        self.assertEqual(calls, [("PUT", "/api/v1/workflows/abc")])
        self.assertFalse(result["active"])

    def test_rollback_from_backup_reports_invalid_snapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            backup = Path(temp) / "wf_abc_backup.json"
            backup.write_text("not json", encoding="utf-8")
            result = n8n.rollback_from_backup(backup, BASE_URL, "secret", "abc", client=mock_client(lambda r: httpx.Response(200, json={})))
            self.assertIn("fatal", result)


if __name__ == "__main__":
    unittest.main()
