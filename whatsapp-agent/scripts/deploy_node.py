"""Push one node's jsCode from a repo workflow JSON to the LIVE n8n workflow.

Backs up the live workflow first, replaces only the named node's jsCode with the
repo version, idempotent-ish (PUT is safe to repeat). Reads N8N_API_KEY from env.

Usage:
    python whatsapp-agent/scripts/deploy_node.py <WF_ID> <repo_json> "<Node Name>"
"""
import os
import sys
import json
import datetime
import requests

if len(sys.argv) != 4:
    sys.exit("Usage: deploy_node.py <WF_ID> <repo_json> '<Node Name>'")
WF_ID, REPO, NODE = sys.argv[1], sys.argv[2], sys.argv[3]

KEY = os.environ.get("N8N_API_KEY")
if not KEY:
    sys.exit("ERROR: set N8N_API_KEY in your environment first.")
URL = os.environ.get("N8N_URL", "https://n8n.srv856940.hstgr.cloud/api/v1")
H = {"X-N8N-API-KEY": KEY}

repo = json.load(open(REPO, encoding="utf-8"))
new_code = next(n["parameters"]["jsCode"] for n in repo["nodes"] if n["name"] == NODE)

r = requests.get(f"{URL}/workflows/{WF_ID}", headers=H, timeout=30)
r.raise_for_status()
wf = r.json()

ts = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
bak = f"wf_{WF_ID}_backup_{ts}.json"
with open(bak, "w", encoding="utf-8") as f:
    json.dump(wf, f, indent=2, ensure_ascii=False)
print(f"[{NODE}] backed up live -> {bak}")

found = False
for n in wf["nodes"]:
    if n["name"] == NODE:
        if n["parameters"].get("jsCode", "") == new_code:
            print(f"[{NODE}] live already matches repo. No change.")
            sys.exit(0)
        n["parameters"]["jsCode"] = new_code
        found = True
if not found:
    sys.exit(f"ERROR: node '{NODE}' not found in live WF {WF_ID}.")

payload = {
    "name": wf["name"],
    "nodes": wf["nodes"],
    "connections": wf["connections"],
    "settings": wf.get("settings", {}),
    "staticData": wf.get("staticData", None),
}
pr = requests.put(f"{URL}/workflows/{WF_ID}",
                  headers={**H, "Content-Type": "application/json"},
                  json=payload, timeout=30)
print(f"[{NODE}] PUT status: {pr.status_code}")
if pr.status_code != 200:
    print(pr.text[:800]); sys.exit(1)
print(f"[{NODE}] OK live.")
