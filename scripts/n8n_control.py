#!/usr/bin/env python3
"""Offline validation and drift checks for exported n8n workflows."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

import httpx

Issue = dict[str, str]
ENV_REF = re.compile(r"^=\{\{\s*\$env\.([A-Z][A-Z0-9_]*)_WORKFLOW_ID\s*\}\}$")
# Repo workflow JSONs never carry real credential IDs — only these placeholders, mapped at
# deploy time (env/argument). Anything matching this that survives into an import body is a bug.
CREDENTIAL_PLACEHOLDER = re.compile(r"REPLACE_WITH_[A-Z0-9_]+")
CREDENTIAL_MAP_ENV = "N8N_CREDENTIAL_MAP"
SENSITIVE = re.compile(r"(?:password|passphrase|secret|token|api[_-]?key|authorization|apikey)", re.I)
SMOKE_TEST = re.compile(r"smoke[\s_-]*test", re.I)
WORKFLOW_FIELDS = {"id": str, "name": str, "active": bool, "isArchived": bool, "nodes": list, "connections": dict, "settings": dict}


def issue(out: list[Issue], level: str, code: str, workflow: str, detail: str) -> None:
    out.append({"level": level, "code": code, "workflow": workflow, "detail": detail})


def read_workflows(directory: Path) -> tuple[list[tuple[Path, Any]], str | None]:
    if not directory.is_dir():
        return [], f"directory not found: {directory}"
    rows = []
    for path in sorted(directory.glob("*.json")):
        try:
            rows.append((path, json.loads(path.read_text(encoding="utf-8"))))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            rows.append((path, exc))
    return rows, None


def workflow_ref(node: dict[str, Any]) -> Any:
    parameters = node.get("parameters")
    if not isinstance(parameters, dict):
        return None
    value = parameters.get("workflowId")
    return value.get("value") if isinstance(value, dict) else value


def workflow_refs(data: dict[str, Any]) -> list[str]:
    refs = []
    for node in data.get("nodes", []):
        if isinstance(node, dict) and node.get("type") == "n8n-nodes-base.executeWorkflow":
            ref = workflow_ref(node)
            if isinstance(ref, str) and ref:
                refs.append(ref)
    return sorted(set(refs))


def find_sensitive(value: Any, path: str = "") -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        header_name, header_value = value.get("name"), value.get("value")
        dynamic = isinstance(header_value, str) and (header_value.startswith("=") or "$env." in header_value)
        if isinstance(header_name, str) and SENSITIVE.search(header_name) and header_value not in (None, "", False) and not dynamic:
            found.append(f"{path}.value" if path else "value")
        for key, child in value.items():
            here = f"{path}.{key}" if path else key
            literal = not isinstance(child, (dict, list)) and not (isinstance(child, str) and (child.startswith("=") or "$env." in child))
            if SENSITIVE.search(key) and literal and child not in (None, "", False):
                found.append(here)
            found.extend(find_sensitive(child, here))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(find_sensitive(child, f"{path}[{index}]"))
    return found


def validate(directory: Path, strict_secrets: bool = False) -> dict[str, Any]:
    rows, error = read_workflows(directory)
    if error:
        return {"fatal": error, "issues": [], "summary": {"ok": 0, "warn": 0, "fail": 0}}
    if not rows:
        return {"fatal": f"no JSON workflows found: {directory}", "issues": [], "summary": {"ok": 0, "warn": 0, "fail": 0}}
    issues: list[Issue] = []
    workflows: list[dict[str, Any]] = []
    for path, data in rows:
        label = path.name
        if isinstance(data, Exception):
            issue(issues, "FAIL", "json", label, "invalid JSON or unreadable file")
        elif not isinstance(data, dict):
            issue(issues, "FAIL", "root", label, "root must be an object")
        else:
            data["_file"] = label
            workflows.append(data)
    valid: list[dict[str, Any]] = []
    for wf in workflows:
        label = wf["_file"]
        bad = [key for key, kind in WORKFLOW_FIELDS.items() if not isinstance(wf.get(key), kind)]
        if bad:
            issue(issues, "FAIL", "schema", label, "invalid required fields: " + ", ".join(bad))
        else:
            valid.append(wf)
    for key in ("id", "name"):
        seen: set[str] = set()
        for wf in valid:
            value = wf[key]
            if value in seen:
                issue(issues, "FAIL", f"duplicate_{key}", wf["_file"], f"duplicate {key}: {value}")
            seen.add(value)
    by_id = {wf["id"]: wf for wf in valid}
    for wf in valid:
        label, nodes = wf["_file"], wf["nodes"]
        names: set[str] = set()
        node_names: set[str] = set()
        for node in nodes:
            if not isinstance(node, dict) or not isinstance(node.get("id"), str) or not isinstance(node.get("name"), str):
                issue(issues, "FAIL", "node_schema", label, "node requires string id and name")
                continue
            if node["id"] in names:
                issue(issues, "FAIL", "duplicate_node_id", label, f"duplicate node id: {node['id']}")
            if node["name"] in node_names:
                issue(issues, "FAIL", "duplicate_node_name", label, f"duplicate node name: {node['name']}")
            names.add(node["id"]); node_names.add(node["name"])
            if node.get("type") == "n8n-nodes-base.executeWorkflow":
                ref = workflow_ref(node)
                if isinstance(ref, str) and ref.startswith("="):
                    if ENV_REF.match(ref):
                        issue(issues, "WARN", "env_workflow_ref", label, f"dynamic env workflow reference in {node['name']}")
                    else:
                        issue(issues, "FAIL", "workflow_expression", label, f"unsupported workflow expression in {node['name']}")
                elif not isinstance(ref, str) or ref not in by_id:
                    issue(issues, "FAIL", "workflow_ref", label, f"missing workflow reference in {node['name']}")
        for source, outputs in wf["connections"].items():
            if source not in node_names:
                issue(issues, "FAIL", "connection_source", label, f"unknown source node: {source}")
            if not isinstance(outputs, dict):
                issue(issues, "FAIL", "connection_shape", label, f"invalid outputs for {source}")
                continue
            for groups in outputs.values():
                if not isinstance(groups, list):
                    issue(issues, "FAIL", "connection_shape", label, f"invalid targets for {source}")
                    continue
                for group in groups:
                    if not isinstance(group, list):
                        issue(issues, "FAIL", "connection_shape", label, f"invalid target group for {source}")
                        continue
                    for target in group:
                        if not isinstance(target, dict) or target.get("node") not in node_names:
                            issue(issues, "FAIL", "connection_target", label, f"unknown target from {source}")
        for field in find_sensitive(wf):
            issue(issues, "FAIL" if strict_secrets else "WARN", "sensitive_literal", label, f"sensitive literal at {field}")
        error_trigger = any(isinstance(n, dict) and n.get("type") == "n8n-nodes-base.errorTrigger" for n in nodes)
        lowered_name = wf["name"].lower()
        exempt = error_trigger or "error handler" in lowered_name or "watchdog" in lowered_name
        if wf["active"] and not exempt:
            error_id = wf["settings"].get("errorWorkflow")
            target = by_id.get(error_id)
            if not target or not target["active"] or target["isArchived"]:
                issue(issues, "FAIL", "error_workflow", label, "active workflow needs active, nonarchived errorWorkflow")
        if SMOKE_TEST.search(wf["name"]) and wf["active"]:
            issue(issues, "FAIL", "smoke_active", label, "SMOKE_TEST workflow must be inactive")
    counts = {level.lower(): sum(i["level"] == level for i in issues) for level in ("WARN", "FAIL")}
    counts["ok"] = len(valid)
    return {"issues": issues, "summary": counts}


def normalized(data: dict[str, Any]) -> dict[str, Any]:
    keys = ("name", "active", "isArchived", "nodes", "connections", "settings", "staticData")
    return {key: data[key] for key in keys if key in data}


def drift_detail(source: dict[str, Any], mirror: dict[str, Any]) -> str:
    """Describe deployable drift without exposing values or credentials."""
    details = []
    for key in ("name", "active", "isArchived", "connections", "staticData"):
        if source.get(key) != mirror.get(key):
            details.append(key)
    if source.get("settings") != mirror.get("settings"):
        source_keys = set(source.get("settings", {})); mirror_keys = set(mirror.get("settings", {}))
        changed = {key for key in source_keys & mirror_keys if source["settings"][key] != mirror["settings"][key]}
        details.append("settings[" + ",".join(sorted(source_keys ^ mirror_keys | changed)) + "]")
    if source.get("nodes") != mirror.get("nodes"):
        def node_index(data: dict[str, Any]) -> dict[str, Any]:
            result = {}
            for index, node in enumerate(data.get("nodes", [])):
                if isinstance(node, dict):
                    key = node.get("id") or node.get("name")
                    result[key if isinstance(key, str) and key else f"<invalid:{index}>"] = node
            return result
        source_nodes, mirror_nodes = node_index(source), node_index(mirror)
        changed = set(source_nodes) ^ set(mirror_nodes)
        changed |= {key for key in set(source_nodes) & set(mirror_nodes) if source_nodes[key] != mirror_nodes[key]}
        details.append("nodes[" + ",".join(sorted(changed)) + "]")
    return ", ".join(details)


def drift(baseline: Path, candidate: Path) -> dict[str, Any]:
    old, old_error = read_workflows(baseline)
    new, new_error = read_workflows(candidate)
    if old_error or new_error:
        return {"fatal": old_error or new_error, "missing": [], "extra": [], "changed": []}
    if not old or not new:
        empty = baseline if not old else candidate
        return {"fatal": f"no JSON workflows found: {empty}", "missing": [], "extra": [], "changed": []}
    def index(rows: list[tuple[Path, Any]]) -> tuple[dict[str, dict[str, Any]], str | None]:
        result: dict[str, dict[str, Any]] = {}
        for path, data in rows:
            if not isinstance(data, dict):
                return {}, f"invalid JSON or workflow object: {path}"
            # Names are portable across n8n instances; generated IDs are not.
            key = data.get("name") or data.get("id")
            if not isinstance(key, str) or not key:
                return {}, f"workflow needs id or name: {path}"
            if key in result:
                return {}, f"duplicate workflow key: {key}"
            result[key] = data
        return result, None
    old_i, old_index_error = index(old)
    new_i, new_index_error = index(new)
    if old_index_error or new_index_error:
        return {"fatal": old_index_error or new_index_error, "missing": [], "extra": [], "changed": []}
    missing = sorted(set(old_i) - set(new_i)); extra = sorted(set(new_i) - set(old_i))
    changed = sorted(key for key in set(old_i) & set(new_i) if normalized(old_i[key]) != normalized(new_i[key]))
    return {"missing": missing, "extra": extra, "changed": changed}


# --- Live n8n REST calls (mockable via the `client` param; never dial out on their own) ---
# Body fields match the real n8n API contract observed in deploy_owner_first.py: create/update
# bodies carry only name/nodes/connections/settings (n8n rejects/ignores an `active` field there;
# new workflows default inactive) and activation is always its own POST .../activate call. That
# split is what makes "import inactive" and "rollback without activating" true by construction
# rather than by a flag someone can forget to pass.
IMPORT_FIELDS = ("name", "nodes", "connections", "settings")

# Same whitelist deploy_owner_first.py applies: the n8n PUT/POST rejects unknown settings keys
# (e.g. `availableInMCP` present in repo exports), so filter before sending.
ALLOWED_SETTINGS = {
    "saveExecutionProgress", "saveManualExecutions", "saveDataErrorExecution",
    "saveDataSuccessExecution", "executionTimeout", "errorWorkflow",
    "timezone", "executionOrder", "callerPolicy",
}


def credential_map_from_env(environ: dict[str, str]) -> dict[str, str]:
    """Parse the deploy-time placeholder->credential-id mapping from N8N_CREDENTIAL_MAP
    (a JSON object). Returns {} when unset. Raises ValueError on malformed input without
    echoing any value from the variable (it may contain credential IDs)."""
    raw = environ.get(CREDENTIAL_MAP_ENV)
    if raw is None or not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{CREDENTIAL_MAP_ENV} must be a JSON object") from exc
    if not isinstance(data, dict) or not all(
        isinstance(key, str) and CREDENTIAL_PLACEHOLDER.fullmatch(key) and isinstance(value, str) and value
        for key, value in data.items()
    ):
        raise ValueError(f"{CREDENTIAL_MAP_ENV} must map REPLACE_WITH_* placeholders to non-empty credential ids")
    return data


def resolve_credentials(workflow: dict[str, Any], credential_map: dict[str, str] | None) -> dict[str, Any]:
    """Return a copy of `workflow` with placeholder credential ids replaced via `credential_map`.
    Fail closed: any REPLACE_WITH_* placeholder left anywhere in the result raises ValueError.
    Error messages name only the placeholders — never mapped credential ids or secrets."""
    resolved = json.loads(json.dumps(workflow))
    mapping = credential_map or {}
    for node in resolved.get("nodes", []):
        credentials = node.get("credentials") if isinstance(node, dict) else None
        if not isinstance(credentials, dict):
            continue
        for credential in credentials.values():
            if isinstance(credential, dict) and isinstance(credential.get("id"), str):
                replacement = mapping.get(credential["id"])
                if replacement is not None and CREDENTIAL_PLACEHOLDER.fullmatch(credential["id"]):
                    credential["id"] = replacement
    leftover = sorted(set(CREDENTIAL_PLACEHOLDER.findall(json.dumps(resolved))))
    if leftover:
        raise ValueError("unresolved credential placeholders: " + ", ".join(leftover))
    return resolved


def _client(base_url: str, api_key: str) -> httpx.Client:
    base = base_url if base_url.endswith("/") else base_url + "/"
    return httpx.Client(base_url=base, headers={"X-N8N-API-KEY": api_key, "Content-Type": "application/json"}, timeout=30)


def fetch_live(base_url: str, api_key: str, workflow_id: str, client: httpx.Client | None = None) -> dict[str, Any]:
    """GET a live workflow by id. Network call unless `client` is a mock (e.g. httpx.MockTransport)."""
    owns, c = client is None, client or _client(base_url, api_key)
    try:
        response = c.get(f"workflows/{workflow_id}")
        response.raise_for_status()
        return response.json()
    finally:
        if owns:
            c.close()


def diff_local_vs_live(local: Path, base_url: str, api_key: str, workflow_id: str, client: httpx.Client | None = None) -> dict[str, Any]:
    """Read-only dry-run diff of a local workflow file vs. the live workflow. Never writes."""
    try:
        local_wf = json.loads(local.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return {"fatal": f"invalid local workflow: {exc}"}
    live_wf = fetch_live(base_url, api_key, workflow_id, client=client)
    differs = normalized(live_wf) != normalized(local_wf)
    return {"differs": differs, "detail": drift_detail(live_wf, local_wf) if differs else ""}


def import_inactive(workflow: dict[str, Any], base_url: str, api_key: str, workflow_id: str | None = None, client: httpx.Client | None = None, credential_map: dict[str, str] | None = None) -> dict[str, Any]:
    """Create (no workflow_id) or update (PUT by workflow_id) a workflow. The request body never
    includes `active` or `id`, so the result is inactive by construction, not by a flag.
    Placeholder credential ids are resolved through `credential_map` (defaults to the
    N8N_CREDENTIAL_MAP env var via credential_map_from_env); any REPLACE_WITH_* left in the
    outgoing body raises before any request is made."""
    if credential_map is None:
        credential_map = credential_map_from_env(dict(os.environ))
    body = {key: workflow[key] for key in IMPORT_FIELDS if key in workflow}
    body = resolve_credentials(body, credential_map)
    if "settings" in body:
        body["settings"] = {k: v for k, v in (body["settings"] or {}).items() if k in ALLOWED_SETTINGS}
    owns, c = client is None, client or _client(base_url, api_key)
    try:
        response = c.put(f"workflows/{workflow_id}", json=body) if workflow_id else c.post("workflows", json=body)
        response.raise_for_status()
        return response.json()
    finally:
        if owns:
            c.close()


def activate(workflow_id: str, base_url: str, api_key: str, client: httpx.Client | None = None) -> dict[str, Any]:
    """Explicit, separate activation step. Never called implicitly by import_inactive/rollback."""
    owns, c = client is None, client or _client(base_url, api_key)
    try:
        response = c.post(f"workflows/{workflow_id}/activate")
        response.raise_for_status()
        return response.json()
    finally:
        if owns:
            c.close()


def rollback_from_backup(backup: Path, base_url: str, api_key: str, workflow_id: str, client: httpx.Client | None = None, credential_map: dict[str, str] | None = None) -> dict[str, Any]:
    """Re-import a wf_*_backup snapshot as inactive. Call activate() separately to reactivate.
    Snapshots normally carry real credential ids (passed through untouched); credential_map
    covers the incident case of a snapshot taken with placeholders still in it."""
    try:
        snapshot = json.loads(backup.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return {"fatal": f"invalid backup: {exc}"}
    return import_inactive(snapshot, base_url, api_key, workflow_id=workflow_id, client=client, credential_map=credential_map)


def inventory_directory(directory: Path) -> tuple[dict[str, Any] | None, str | None]:
    rows, error = read_workflows(directory)
    if error:
        return None, error
    if not rows:
        return None, f"no JSON workflows found: {directory}"
    entries: list[dict[str, Any]] = []
    for path, data in rows:
        if not isinstance(data, dict):
            return None, f"invalid JSON or workflow object: {path}"
        name = data.get("name")
        if not isinstance(name, str) or not name:
            return None, f"workflow needs name: {path}"
        scope = "archive" if data.get("isArchived") else "smoke" if SMOKE_TEST.search(name) else "live"
        export_fields = (data.get("id"), data.get("active"), data.get("isArchived"))
        format_name = "export" if isinstance(export_fields[0], str) and all(isinstance(value, bool) for value in export_fields[1:]) else "template"
        entries.append({"directory": str(directory), "file": path.name, "name": name, "id": data.get("id"), "active": data.get("active"), "isArchived": data.get("isArchived"), "scope": scope, "format": format_name, "workflowRefs": workflow_refs(data)})
    by_name: dict[str, list[dict[str, Any]]] = {}
    for entry in entries:
        by_name.setdefault(str(entry["name"]), []).append(entry)
    return {"directory": str(directory), "workflows": entries, "by_name": {name: by_name[name] for name in sorted(by_name)}, "duplicates": sorted(name for name, group in by_name.items() if len(group) > 1)}, None


def inventory(live: Path, mirrors: list[Path]) -> dict[str, Any]:
    live_result, error = inventory_directory(live)
    if error:
        return {"fatal": error, "live": None, "mirrors": [], "summary": {"duplicates": 0, "missing": 0, "extra": 0}}
    mirror_results: list[dict[str, Any]] = []
    for directory in mirrors:
        result, error = inventory_directory(directory)
        if error:
            return {"fatal": error, "live": None, "mirrors": [], "summary": {"duplicates": 0, "missing": 0, "extra": 0}}
        live_names = set(live_result["by_name"])
        mirror_names = set(result["by_name"])
        result["missing"] = sorted(live_names - mirror_names)
        result["extra"] = sorted(mirror_names - live_names)
        mirror_results.append(result)
    duplicate_count = len(live_result["duplicates"]) + sum(len(result["duplicates"]) for result in mirror_results)
    summary = {"duplicates": duplicate_count, "missing": sum(len(result["missing"]) for result in mirror_results), "extra": sum(len(result["extra"]) for result in mirror_results)}
    return {"live": live_result, "mirrors": mirror_results, "summary": summary}


MANIFEST_SCHEMA = "n8n-workflow-manifest/v1"
MANIFEST_ROLES = {"snapshot", "template", "retired", "ambiguous"}


def manifest_path(parent: Path, value: Any, directory: bool) -> tuple[Path | None, str | None]:
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        return None, "path must be a non-empty relative string"
    path = Path(value)
    if ".." in path.parts or (not directory and (path.name != value or path.suffix != ".json")):
        return None, "unsafe path"
    try:
        resolved = (parent / path).resolve()
        resolved.relative_to(parent.resolve())
    except (OSError, ValueError):
        return None, "unsafe path"
    return resolved, None


def manifest_check(manifest: Path) -> dict[str, Any]:
    """Check declared workflow mirrors without changing files or n8n."""
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return {"fatal": f"invalid manifest: {exc}", "issues": [], "summary": {"policy": 0}}
    if not isinstance(data, dict) or data.get("schema") != MANIFEST_SCHEMA or not isinstance(data.get("mirrors"), list):
        return {"fatal": "invalid manifest schema", "issues": [], "summary": {"policy": 0}}
    parent = manifest.parent.resolve()
    source, error = manifest_path(parent, data.get("source"), True)
    if error or source is None or not source.is_dir():
        return {"fatal": f"invalid source: {error or 'directory not found'}", "issues": [], "summary": {"policy": 0}}
    source_rows, error = read_workflows(source)
    if error or not source_rows:
        return {"fatal": f"invalid source: {error or 'no JSON workflows found'}", "issues": [], "summary": {"policy": 0}}
    source_by_name: dict[str, dict[str, Any]] = {}
    for path, item in source_rows:
        if not isinstance(item, dict) or any(not isinstance(item.get(key), kind) for key, kind in WORKFLOW_FIELDS.items()):
            return {"fatal": f"invalid source workflow: {path.name}", "issues": [], "summary": {"policy": 0}}
        if item["name"] in source_by_name:
            return {"fatal": f"duplicate source workflow: {item['name']}", "issues": [], "summary": {"policy": 0}}
        source_by_name[item["name"]] = item
    issues: list[Issue] = []
    seen_directories: set[Path] = set()
    for mirror in data["mirrors"]:
        if not isinstance(mirror, dict) or set(mirror) != {"directory", "coverage", "files"}:
            return {"fatal": "invalid mirror schema", "issues": [], "summary": {"policy": 0}}
        directory, error = manifest_path(parent, mirror["directory"], True)
        if error or directory is None or not directory.is_dir():
            return {"fatal": f"invalid mirror directory: {error or 'directory not found'}", "issues": [], "summary": {"policy": 0}}
        if directory in seen_directories:
            return {"fatal": f"duplicate mirror directory: {mirror['directory']}", "issues": [], "summary": {"policy": 0}}
        seen_directories.add(directory)
        files = mirror["files"]
        if mirror["coverage"] not in {"partial", "full"} or not isinstance(files, dict):
            return {"fatal": f"invalid mirror declaration: {mirror['directory']}", "issues": [], "summary": {"policy": 0}}
        actual = {path.name for path in directory.glob("*.json")}
        declared = set(files)
        for name in declared:
            _, file_error = manifest_path(directory, name, False)
            if file_error:
                return {"fatal": f"invalid mirror file: {name}", "issues": [], "summary": {"policy": 0}}
        unknown, stale = sorted(actual - declared), sorted(declared - actual)
        if unknown or stale:
            detail = ", ".join((f"unknown {name}" for name in unknown)) or ""
            detail += ("; " if detail and stale else "") + ", ".join(f"stale {name}" for name in stale)
            return {"fatal": f"mirror file mismatch in {mirror['directory']}: {detail}", "issues": [], "summary": {"policy": 0}}
        for name, declaration in files.items():
            if not isinstance(declaration, dict) or set(declaration) - {"role", "workflow", "reason"}:
                return {"fatal": f"invalid declaration: {mirror['directory']}/{name}", "issues": [], "summary": {"policy": 0}}
            role, reason, workflow = declaration.get("role"), declaration.get("reason"), declaration.get("workflow")
            if role not in MANIFEST_ROLES or not isinstance(reason, str) or not reason.strip():
                return {"fatal": f"invalid role or reason: {mirror['directory']}/{name}", "issues": [], "summary": {"policy": 0}}
            if role in {"template", "retired"} and mirror["coverage"] != "partial":
                return {"fatal": f"non-snapshot needs partial coverage: {mirror['directory']}/{name}", "issues": [], "summary": {"policy": 0}}
            if workflow is not None and (not isinstance(workflow, str) or not workflow):
                return {"fatal": f"invalid workflow: {mirror['directory']}/{name}", "issues": [], "summary": {"policy": 0}}
            if role == "ambiguous":
                issue(issues, "FAIL", "ambiguous", name, reason)
                continue
            if role != "snapshot":
                continue
            if not isinstance(workflow, str):
                return {"fatal": f"snapshot needs workflow: {mirror['directory']}/{name}", "issues": [], "summary": {"policy": 0}}
            source_item = source_by_name.get(workflow)
            if source_item is None:
                issue(issues, "FAIL", "missing_workflow", name, workflow)
                continue
            try:
                mirror_item = json.loads((directory / name).read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                return {"fatal": f"invalid mirror JSON: {mirror['directory']}/{name}", "issues": [], "summary": {"policy": 0}}
            if not isinstance(mirror_item, dict) or any(not isinstance(mirror_item.get(key), kind) for key, kind in WORKFLOW_FIELDS.items()):
                return {"fatal": f"invalid mirror workflow: {mirror['directory']}/{name}", "issues": [], "summary": {"policy": 0}}
            if mirror_item.get("name") != workflow:
                issue(issues, "FAIL", "name_mismatch", name, f"declared {workflow}; found {mirror_item.get('name')!r}")
            elif normalized(mirror_item) != normalized(source_item):
                issue(issues, "FAIL", "content_drift", name, f"{workflow}: {drift_detail(source_item, mirror_item)}")
    return {"issues": issues, "summary": {"policy": len(issues)}}


def emit(result: dict[str, Any], as_json: bool, command: str) -> int:
    if as_json:
        print(json.dumps({"command": command, **result}, sort_keys=True, separators=(",", ":")))
    elif "fatal" in result:
        print(f"FAIL {result['fatal']}")
    elif command == "validate":
        for item in result["issues"]:
            print(f"{item['level']} {item['workflow']} {item['code']}: {item['detail']}")
        summary = result["summary"]; print(f"OK {summary['ok']} WARN {summary['warn']} FAIL {summary['fail']}")
    elif command == "inventory":
        for label, directory in (("LIVE", result["live"]), * (("MIRROR", item) for item in result["mirrors"])):
            for name in directory["duplicates"]:
                print(f"FAIL {label} duplicate: {name}")
        for mirror in result["mirrors"]:
            for name in mirror["missing"]: print(f"FAIL missing {mirror['directory']}: {name}")
            for name in mirror["extra"]: print(f"FAIL extra {mirror['directory']}: {name}")
        summary = result["summary"]
        print(f"OK inventory duplicates {summary['duplicates']} missing {summary['missing']} extra {summary['extra']}")
    elif command == "manifest-check":
        for item in result["issues"]:
            print(f"FAIL {item['workflow']} {item['code']}: {item['detail']}")
        print(f"OK manifest policy {result['summary']['policy']}")
    else:
        for key in ("missing", "extra", "changed"):
            for value in result[key]: print(f"FAIL {key}: {value}")
        print("OK no drift" if not any(result.values()) else "FAIL drift")
    if "fatal" in result: return 3
    if command == "inventory": return 1 if any(result["summary"].values()) else 0
    if command == "manifest-check": return 1 if result["summary"]["policy"] else 0
    return 1 if (result.get("summary", {}).get("fail") or any(result.get(k) for k in ("missing", "extra", "changed"))) else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    val = sub.add_parser("validate"); val.add_argument("directory", nargs="?", default="n8n-export"); val.add_argument("--json", action="store_true"); val.add_argument("--strict-secrets", action="store_true")
    dr = sub.add_parser("drift"); dr.add_argument("baseline"); dr.add_argument("candidate"); dr.add_argument("--json", action="store_true")
    inv = sub.add_parser("inventory"); inv.add_argument("live"); inv.add_argument("mirrors", nargs="*"); inv.add_argument("--json", action="store_true")
    man = sub.add_parser("manifest-check"); man.add_argument("manifest"); man.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.command == "validate": return emit(validate(Path(args.directory), args.strict_secrets), args.json, "validate")
    if args.command == "inventory": return emit(inventory(Path(args.live), [Path(path) for path in args.mirrors]), args.json, "inventory")
    if args.command == "manifest-check": return emit(manifest_check(Path(args.manifest)), args.json, "manifest-check")
    return emit(drift(Path(args.baseline), Path(args.candidate)), args.json, "drift")


if __name__ == "__main__":
    sys.exit(main())
