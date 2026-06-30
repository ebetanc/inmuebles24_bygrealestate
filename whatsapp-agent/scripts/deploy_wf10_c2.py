"""Deploy C2 fix to the LIVE n8n WF10: make 'Prepare Auction Data' auction every
lead in a batch (was .first(), dropped all but the first).

Safe: backs up the live workflow to a timestamped file BEFORE changing anything,
patches only the one node (copying the reviewed jsCode from the repo file), and
is idempotent (no-op if already patched).

Run from the repo root. Keep N8N_API_KEY in your environment (do not paste it in
chat):
    python whatsapp-agent/scripts/deploy_wf10_c2.py
"""
import os
import sys
import json
import datetime
import requests

N8N_KEY = os.environ.get("N8N_API_KEY")
if not N8N_KEY:
    sys.exit("ERROR: set N8N_API_KEY in your environment first.")
N8N_URL = os.environ.get("N8N_URL", "https://n8n.srv856940.hstgr.cloud/api/v1")
WF_ID = os.environ.get("WF10_WORKFLOW_ID", "Obr38705ZZYS3FB8")
H = {"X-N8N-API-KEY": N8N_KEY}

r = requests.get(f"{N8N_URL}/workflows/{WF_ID}", headers=H, timeout=30)
r.raise_for_status()
wf = r.json()

ts = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
bak = f"wf10_live_backup_{ts}.json"
with open(bak, "w", encoding="utf-8") as f:
    json.dump(wf, f, indent=2, ensure_ascii=False)
print(f"Backed up LIVE WF10 -> {bak}")

repo = json.load(open("wa-rework/out/Obr38705ZZYS3FB8.json", encoding="utf-8"))
new_code = next(n["parameters"]["jsCode"]
                for n in repo["nodes"] if n["name"] == "Prepare Auction Data")

found = False
for n in wf["nodes"]:
    if n["name"] == "Prepare Auction Data":
        cur = n["parameters"].get("jsCode", "")
        if "convs = $input.all()" in cur:
            print("Live WF10 already has the C2 fix. Nothing to do.")
            sys.exit(0)
        n["parameters"]["jsCode"] = new_code
        found = True
if not found:
    sys.exit("ERROR: node 'Prepare Auction Data' not found in live WF10.")

payload = {
    "name": wf["name"],
    "nodes": wf["nodes"],
    "connections": wf["connections"],
    "settings": wf.get("settings", {}),
    "staticData": wf.get("staticData", None),
}
pr = requests.put(
    f"{N8N_URL}/workflows/{WF_ID}",
    headers={**H, "Content-Type": "application/json"},
    json=payload,
    timeout=30,
)
print("PUT status:", pr.status_code)
if pr.status_code != 200:
    print(pr.text[:800])
    sys.exit(1)
print("OK: WF10 'Prepare Auction Data' now auctions EVERY lead in a batch.")
print(f"Rollback if needed: PUT the backup {bak} back to the same endpoint.")
