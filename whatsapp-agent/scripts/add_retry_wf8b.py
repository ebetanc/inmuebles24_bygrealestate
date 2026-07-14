"""Add retryOnFail to WF8b node "Fetch EB Contacts" via n8n REST API.

Idempotent: skips PUT if retry already set. Backs up live workflow first.
Reads N8N_API_KEY from env. Run:  python whatsapp-agent/scripts/add_retry_wf8b.py
"""
import os
import sys
import json
import datetime
import requests

WF_ID = "Mu3YTTH8IgtaH7Ml"
NODE = "Fetch EB Contacts"
KEY = os.environ.get("N8N_API_KEY")
if not KEY:
    sys.exit("ERROR: N8N_API_KEY not set in env.")
BASE = os.environ.get("N8N_URL", "https://n8n.srv856940.hstgr.cloud/api/v1")
H = {"X-N8N-API-KEY": KEY, "Content-Type": "application/json"}

r = requests.get(f"{BASE}/workflows/{WF_ID}", headers=H, timeout=30)
r.raise_for_status()
wf = r.json()

ts = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
bak = f"wf_{WF_ID}_backup_{ts}.json"
with open(bak, "w", encoding="utf-8") as f:
    json.dump(wf, f, indent=2, ensure_ascii=False)
print(f"backed up live -> {bak}")

node = next((n for n in wf["nodes"] if n["name"] == NODE), None)
if node is None:
    sys.exit(f"ERROR: node '{NODE}' not found. Nodes: {[n['name'] for n in wf['nodes']]}")

if node.get("retryOnFail") and node.get("maxTries", 0) >= 2:
    print(f"'{NODE}' already has retryOnFail (maxTries={node.get('maxTries')}). No change.")
    sys.exit(0)

node["retryOnFail"] = True
node["maxTries"] = 2
node["waitBetweenTries"] = 5000
print(f"set retryOnFail=True maxTries=2 waitBetweenTries=5000ms on '{NODE}'")

# PUT whitelist: n8n rejects read-only fields (id/active/tags/createdAt/...)
payload = {
    "name": wf["name"],
    "nodes": wf["nodes"],
    "connections": wf["connections"],
    "settings": wf.get("settings", {}),
}
p = requests.put(f"{BASE}/workflows/{WF_ID}", headers=H, data=json.dumps(payload), timeout=30)
if not p.ok:
    print(f"PUT failed {p.status_code}: {p.text[:400]}")
    p.raise_for_status()
print("PUT ok. Verifying...")

v = requests.get(f"{BASE}/workflows/{WF_ID}", headers=H, timeout=30).json()
vn = next(n for n in v["nodes"] if n["name"] == NODE)
print(f"LIVE now: retryOnFail={vn.get('retryOnFail')} maxTries={vn.get('maxTries')} wait={vn.get('waitBetweenTries')}")
