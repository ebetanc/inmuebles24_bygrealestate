# Deploy owner-first tiered routing to live n8n.
#
# Tier 1: property owner (from EasyBroker `agent` label, synced daily) gets a
#         2-min directed TOMO DM (WF13).
# Tier 2: no claim -> guard auction, on-shift agents + Sandy, 5 min (WF3a).
# Tier 3: no claim -> auto-assign to Sandy (WF3c, unchanged behavior).
#
# Pieces:
#   1. Create WF19 "Lead Router (Owner First)": WF12 resolve -> WF13 | WF3a.
#   2. Create WF18 "EB Owner Sync": daily 7:45 upsert of eb_property_owner.
#   3. Rewrite WF12 to read eb_property_owner (tags approach is dead).
#   4. WF10/WF8b: carry property_public_id, call WF19 instead of WF3a.
#   5. WF7: night batch also routes owner-first via WF19.
#   6. WF3c: tiered sweeper (owner-expired -> guard auction; else -> manager).
import json
import os
import sys

import requests

BASE = os.environ.get("N8N_BASE_URL", "https://n8n.srv856940.hstgr.cloud/api/v1")
KEY = os.environ.get("N8N_API_KEY", "").strip()
if not KEY:
    print("FATAL: N8N_API_KEY environment variable is not set", file=sys.stderr)
    sys.exit(1)
H = {"X-N8N-API-KEY": KEY, "Content-Type": "application/json"}
SCRATCH = os.path.dirname(os.path.abspath(__file__))

WF3A = "04aQhTOiXlDmN9bK"
WF12 = "w7yJr7naWoxPq6Pw"
WF13 = "Bo2YbbUpmBzRbhDa"
WF10 = "Obr38705ZZYS3FB8"
WF8B = "Mu3YTTH8IgtaH7Ml"
WF7 = "xzBG0GIsHCUd44DC"
WF3C = "UNIKqyAvIUAZkNIs"

PG_CRED = {"postgres": {"id": "dEHKygi1neTNvPtH", "name": "Postgres account BYG project"}}

ALLOWED_SETTINGS = {
    "saveExecutionProgress", "saveManualExecutions", "saveDataErrorExecution",
    "saveDataSuccessExecution", "executionTimeout", "errorWorkflow",
    "timezone", "executionOrder", "callerPolicy",
}


def get_wf(wid):
    r = requests.get(f"{BASE}/workflows/{wid}", headers=H)
    r.raise_for_status()
    return r.json()


def put_wf(wid, wf):
    settings = {k: v for k, v in (wf.get("settings") or {}).items() if k in ALLOWED_SETTINGS}
    body = {"name": wf["name"], "nodes": wf["nodes"], "connections": wf["connections"], "settings": settings}
    r = requests.put(f"{BASE}/workflows/{wid}", headers=H, json=body)
    if r.status_code >= 300:
        print(r.text)
    r.raise_for_status()
    return r.json()


def post_wf(body):
    r = requests.post(f"{BASE}/workflows", headers=H, json=body)
    if r.status_code >= 300:
        print(r.text)
    r.raise_for_status()
    return r.json()


def activate(wid):
    r = requests.post(f"{BASE}/workflows/{wid}/activate", headers=H)
    if r.status_code >= 300:
        print(r.text)
    r.raise_for_status()


def node(wf, name):
    for n in wf["nodes"]:
        if n["name"] == name:
            return n
    raise KeyError(f"node not found: {name} in {wf['name']}")


def backup(tag, wf):
    path = os.path.join(SCRATCH, f"backup_{tag}_ownerfirst.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(wf, f, ensure_ascii=False, indent=1)


def exec_wf_node(name, target_id, pos, note=""):
    return {
        "parameters": {
            "workflowId": {"__rl": True, "value": target_id, "mode": "id"},
            "workflowInputs": {"mappingMode": "defineBelow", "value": {}},
            "options": {},
            "mode": "each",
        },
        "type": "n8n-nodes-base.executeWorkflow",
        "typeVersion": 1.2,
        "position": pos,
        "id": "",
        "name": name,
        "notesInFlow": bool(note),
        "notes": note,
    }


import uuid


def wid():
    return str(uuid.uuid4())


# ---------------------------------------------------------------------------
# 1. WF19 - Lead Router (Owner First)
# ---------------------------------------------------------------------------

def build_wf19():
    trigger = {
        "parameters": {"inputSource": "passthrough"},
        "type": "n8n-nodes-base.executeWorkflowTrigger",
        "typeVersion": 1,
        "position": [0, 0],
        "id": wid(),
        "name": "When Called",
    }
    call_wf12 = exec_wf_node("Resolve Owner (WF12)", WF12, [220, 0])
    call_wf12["id"] = wid()
    if_node = {
        "parameters": {
            "conditions": {
                "options": {"caseSensitive": True, "typeValidation": "loose", "version": 2},
                "conditions": [
                    {
                        "id": wid(),
                        "leftValue": "={{ $json.resolved }}",
                        "rightValue": "",
                        "operator": {"type": "boolean", "operation": "true", "singleValue": True},
                    }
                ],
                "combinator": "and",
            },
            "options": {},
        },
        "type": "n8n-nodes-base.if",
        "typeVersion": 2.2,
        "position": [440, 0],
        "id": wid(),
        "name": "Owner Resolved?",
    }
    prep_owner = {
        "parameters": {
            "jsCode": (
                "// Shape the payload for WF13 (directed owner notify).\n"
                "const j = $input.first().json;\n"
                "return [{ json: {\n"
                "  conversation_id: j.conversation_id,\n"
                "  property_id: j.property_id,\n"
                "  property_title: j.property_title,\n"
                "  property_price: j.property_price,\n"
                "  lead_name: j.lead_name,\n"
                "  lead_phone: j.lead_phone,\n"
                "  owner_agent_id: j.owner_agent_id,\n"
                "  owner_name: j.owner_name,\n"
                "  owner_number: j.owner_number\n"
                "} }];"
            )
        },
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [660, -120],
        "id": wid(),
        "name": "Prepare Owner Notify",
    }
    call_wf13 = exec_wf_node("Notify Owner (WF13)", WF13, [880, -120])
    call_wf13["id"] = wid()
    set_guard = {
        "parameters": {
            "operation": "executeQuery",
            "query": (
                "-- No resolvable owner: this lead starts at the guard tier, so the\n"
                "-- sweeper escalates it straight to the manager if the auction dies.\n"
                "UPDATE conversations SET routing_tier = 'guard'\n"
                "WHERE conversation_id = $1::uuid AND assigned_agent_id IS NULL;"
            ),
            "options": {"queryReplacement": "={{ $json.conversation_id }}"},
        },
        "type": "n8n-nodes-base.postgres",
        "typeVersion": 2.5,
        "position": [660, 120],
        "id": wid(),
        "name": "Set Guard Tier",
        "credentials": PG_CRED,
        "alwaysOutputData": True,
        "onError": "continueRegularOutput",
    }
    prep_guard = {
        "parameters": {
            "jsCode": (
                "// Guard auction gets the original payload, not the UPDATE's output.\n"
                "const j = $('When Called').first().json;\n"
                "return [{ json: {\n"
                "  conversation_id: j.conversation_id,\n"
                "  lead_phone: j.lead_phone,\n"
                "  lead_name: j.lead_name,\n"
                "  property_id: j.property_id || 'Sin propiedad',\n"
                "  property_title: j.property_title || j.property_id || 'Propiedad',\n"
                "  property_price: j.property_price || 'Precio por confirmar',\n"
                "  assigned_agent_id: null\n"
                "} }];"
            )
        },
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [880, 120],
        "id": wid(),
        "name": "Prepare Guard Payload",
    }
    call_wf3a = exec_wf_node("Guard Auction (WF3a)", WF3A, [1100, 120])
    call_wf3a["id"] = wid()

    connections = {
        "When Called": {"main": [[{"node": "Resolve Owner (WF12)", "type": "main", "index": 0}]]},
        "Resolve Owner (WF12)": {"main": [[{"node": "Owner Resolved?", "type": "main", "index": 0}]]},
        "Owner Resolved?": {
            "main": [
                [{"node": "Prepare Owner Notify", "type": "main", "index": 0}],
                [{"node": "Set Guard Tier", "type": "main", "index": 0}],
            ]
        },
        "Prepare Owner Notify": {"main": [[{"node": "Notify Owner (WF13)", "type": "main", "index": 0}]]},
        "Set Guard Tier": {"main": [[{"node": "Prepare Guard Payload", "type": "main", "index": 0}]]},
        "Prepare Guard Payload": {"main": [[{"node": "Guard Auction (WF3a)", "type": "main", "index": 0}]]},
    }
    return {
        "name": "WF19 - Lead Router (Owner First)",
        "nodes": [trigger, call_wf12, if_node, prep_owner, call_wf13, set_guard, prep_guard, call_wf3a],
        "connections": connections,
        "settings": {"executionOrder": "v1", "timezone": "America/Mexico_City"},
    }


# ---------------------------------------------------------------------------
# 2. WF18 - EB Owner Sync (daily)
# ---------------------------------------------------------------------------

def build_wf18(cron="45 7 * * *"):
    trigger = {
        "parameters": {"rule": {"interval": [{"field": "cronExpression", "expression": cron}]}},
        "type": "n8n-nodes-base.scheduleTrigger",
        "typeVersion": 1.2,
        "position": [0, 0],
        "id": wid(),
        "name": "Daily 7:45 CDMX",
    }
    fetch = {
        "parameters": {
            "url": "={{ $env.EASYBROKER_BASE + '/properties' }}",
            "sendQuery": True,
            "queryParameters": {"parameters": [
                {"name": "limit", "value": "50"},
                {"name": "page", "value": "1"},
            ]},
            "sendHeaders": True,
            "headerParameters": {"parameters": [
                {"name": "X-Authorization", "value": "={{ $env.EASYBROKER_API_KEY }}"},
                {"name": "accept", "value": "application/json"},
            ]},
            "options": {
                "timeout": 20000,
                "pagination": {
                    "pagination": {
                        "paginationMode": "updateAParameterInEachRequest",
                        "parameters": {"parameters": [
                            {"type": "qs", "name": "page", "value": "={{ $pageCount + 1 }}"}
                        ]},
                        "paginationCompleteWhen": "other",
                        "completeExpression": "={{ !$response.body.pagination.next_page }}",
                        "limitPagesFetched": True,
                        "maxRequests": 20,
                    }
                },
            },
        },
        "type": "n8n-nodes-base.httpRequest",
        "typeVersion": 4.2,
        "position": [220, 0],
        "id": wid(),
        "name": "Fetch EB Properties",
    }
    build = {
        "parameters": {
            "jsCode": (
                "// Flatten paginated EB responses into one jsonb payload for a single upsert.\n"
                "const rows = [];\n"
                "for (const it of $input.all()) {\n"
                "  const content = (it.json && it.json.content) || [];\n"
                "  for (const p of content) {\n"
                "    if (!p.public_id) continue;\n"
                "    rows.push({ public_id: p.public_id, agent_label: String(p.agent || '').trim() || 'unknown' });\n"
                "  }\n"
                "}\n"
                "if (!rows.length) throw new Error('EB sync: 0 properties returned — refusing to upsert nothing');\n"
                "return [{ json: { payload: JSON.stringify(rows), count: rows.length } }];"
            )
        },
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [440, 0],
        "id": wid(),
        "name": "Build Upsert Payload",
    }
    upsert = {
        "parameters": {
            "operation": "executeQuery",
            "query": (
                "INSERT INTO eb_property_owner (public_id, agent_label, synced_at)\n"
                "SELECT x.public_id, x.agent_label, now()\n"
                "FROM jsonb_to_recordset($1::jsonb) AS x(public_id text, agent_label text)\n"
                "ON CONFLICT (public_id) DO UPDATE\n"
                "SET agent_label = EXCLUDED.agent_label, synced_at = now();"
            ),
            "options": {"queryReplacement": "={{ $json.payload }}"},
        },
        "type": "n8n-nodes-base.postgres",
        "typeVersion": 2.5,
        "position": [660, 0],
        "id": wid(),
        "name": "Upsert Owners",
        "credentials": PG_CRED,
    }
    connections = {
        "Daily 7:45 CDMX": {"main": [[{"node": "Fetch EB Properties", "type": "main", "index": 0}]]},
        "Fetch EB Properties": {"main": [[{"node": "Build Upsert Payload", "type": "main", "index": 0}]]},
        "Build Upsert Payload": {"main": [[{"node": "Upsert Owners", "type": "main", "index": 0}]]},
    }
    return {
        "name": "WF18 - EB Owner Sync",
        "nodes": [trigger, fetch, build, upsert],
        "connections": connections,
        "settings": {"executionOrder": "v1", "timezone": "America/Mexico_City"},
    }


# ---------------------------------------------------------------------------
# 3. WF12 v2 - resolver reads eb_property_owner
# ---------------------------------------------------------------------------

RESOLVE_SQL = """-- Resolve the owner agent for a property from the daily EB sync table.
-- Resolution happens at read time via property_agent_alias, so alias fixes
-- take effect immediately (no re-sync needed).
SELECT
  r.agent_id          AS owner_agent_id,
  r.name              AS owner_name,
  r.whatsapp_number   AS owner_number,
  (r.agent_id IS NOT NULL) AS resolved,
  p.agent_label
FROM (SELECT NULLIF(btrim(COALESCE($1, '')), '') AS pub) k
LEFT JOIN eb_property_owner p ON p.public_id = k.pub
LEFT JOIN LATERAL (
  SELECT a.agent_id, a.name, a.whatsapp_number
  FROM agents a
  WHERE a.agent_id = resolve_agent_from_tags(
          ARRAY[p.agent_label, split_part(p.agent_label, ' ', 1)])
    AND a.is_available = TRUE
) r ON TRUE;"""

SHAPE_JS = """// Merge the caller's payload with the resolver row.
const input = $('When Called').first().json;
const r = $input.first() ? $input.first().json : {};
return [{ json: { ...input,
  owner_agent_id: r.owner_agent_id || null,
  owner_name: r.owner_name || null,
  owner_number: r.owner_number || null,
  owner_label: r.agent_label || null,
  resolved: !!(r.resolved && r.owner_number)
} }];"""


def rewrite_wf12():
    wf = get_wf(WF12)
    backup("wf12", wf)
    trigger = node(wf, "When Called")
    resolve = {
        "parameters": {
            "operation": "executeQuery",
            "query": RESOLVE_SQL,
            "options": {"queryReplacement": "={{ $json.property_public_id || '' }}"},
        },
        "type": "n8n-nodes-base.postgres",
        "typeVersion": node(wf, "Resolve Owner Agent")["typeVersion"],
        "position": [220, 0],
        "id": wid(),
        "name": "Resolve Owner",
        "credentials": node(wf, "Resolve Owner Agent").get("credentials", PG_CRED),
        "alwaysOutputData": True,
    }
    shape = {
        "parameters": {"jsCode": SHAPE_JS},
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [440, 0],
        "id": wid(),
        "name": "Shape Output",
    }
    wf["name"] = "WF12 - Owner Resolver (EB owner table)"
    wf["nodes"] = [trigger, resolve, shape]
    wf["connections"] = {
        "When Called": {"main": [[{"node": "Resolve Owner", "type": "main", "index": 0}]]},
        "Resolve Owner": {"main": [[{"node": "Shape Output", "type": "main", "index": 0}]]},
    }
    put_wf(WF12, wf)
    print("WF12 rewritten")


# ---------------------------------------------------------------------------
# 4. WF10 / WF8b patches
# ---------------------------------------------------------------------------

def patch_intake(wf_id, tag, wf19_id, is_eb):
    wf = get_wf(wf_id)
    backup(tag, wf)

    sn = node(wf, "Split & Normalize Leads")
    if "property_public_id" not in sn["parameters"]["jsCode"]:
        if is_eb:
            old = "  source: 'easybroker',"
            assert old in sn["parameters"]["jsCode"], f"{tag}: normalize anchor missing"
            sn["parameters"]["jsCode"] = sn["parameters"]["jsCode"].replace(
                old,
                "  property_public_id: /^EB-/i.test(String(contact.property_id || '')) ? contact.property_id : null,\n" + old,
            )
        else:
            old = "    scraper_lead_id: lead.lead_id || null,"
            assert old in sn["parameters"]["jsCode"], f"{tag}: normalize anchor missing"
            sn["parameters"]["jsCode"] = sn["parameters"]["jsCode"].replace(
                old,
                "    property_public_id: lead.property_public_id || null,\n" + old,
            )

    id_col = "eb_contact_id" if is_eb else "i24_lead_id"
    id_param = "$json.eb_contact_id]" if is_eb else "$json.scraper_lead_id]"
    for conv_node in ("Create Day Conversation", "Create Night Conversation"):
        n = node(wf, conv_node)
        q = n["parameters"]["query"]
        if "property_public_id" in q:
            continue
        assert f", {id_col})" in q and ", $6)" in q, f"{tag}/{conv_node}: INSERT shape changed"
        q = q.replace(f", {id_col})", f", {id_col}, property_public_id)")
        q = q.replace(", $6)", ", $6, NULLIF($7, ''))")
        q = q.replace("RETURNING conversation_id,", "RETURNING conversation_id, property_public_id,")
        n["parameters"]["query"] = q
        qr = n["parameters"]["options"]["queryReplacement"]
        assert id_param in qr, f"{tag}/{conv_node}: replacement shape"
        n["parameters"]["options"]["queryReplacement"] = qr.replace(
            id_param, id_param[:-1] + ", $json.property_public_id]"
        )

    pad = node(wf, "Prepare Auction Data")
    if "property_public_id" not in pad["parameters"]["jsCode"]:
        anchor = "      assigned_agent_id: null,"
        if anchor not in pad["parameters"]["jsCode"]:
            anchor = "    assigned_agent_id: null,"
        assert anchor in pad["parameters"]["jsCode"], f"{tag}: auction data anchor"
        indent = anchor[: len(anchor) - len(anchor.lstrip())]
        pad["parameters"]["jsCode"] = pad["parameters"]["jsCode"].replace(
            anchor,
            indent + "property_public_id: conv.property_public_id || lead.property_public_id || null,\n" + anchor,
        )

    try:
        call = node(wf, "Call WF3a: TOMO Auction")
        call["name"] = "Call WF19: Lead Router"
    except KeyError:
        call = node(wf, "Call WF19: Lead Router")
    call["parameters"]["workflowId"]["value"] = wf19_id
    conns = wf["connections"]
    for src, outs in conns.items():
        for branch in outs.get("main", []):
            for c in branch or []:
                if c["node"] == "Call WF3a: TOMO Auction":
                    c["node"] = "Call WF19: Lead Router"
    if "Call WF3a: TOMO Auction" in conns:
        conns["Call WF19: Lead Router"] = conns.pop("Call WF3a: TOMO Auction")

    put_wf(wf_id, wf)
    print(f"{tag} patched")


# ---------------------------------------------------------------------------
# 5. WF7 patch (night batch enters owner-first routing)
# ---------------------------------------------------------------------------

def patch_wf7(wf19_id):
    wf = get_wf(WF7)
    backup("wf7", wf)

    fetch = node(wf, "Fetch Queue for Processing")
    q = fetch["parameters"]["query"]
    if "property_public_id" not in q:
        anchor = "  nq.queued_at,"
        assert anchor in q, "WF7 fetch queue anchor missing"
        fetch["parameters"]["query"] = q.replace(anchor, anchor + "\n  c.property_public_id,")

    prep = node(wf, "Prepare WF3a Payload")
    if "property_public_id" not in prep["parameters"]["jsCode"]:
        anchor = "  assigned_agent_id: null"
        assert anchor in prep["parameters"]["jsCode"], "WF7 payload anchor missing"
        prep["parameters"]["jsCode"] = prep["parameters"]["jsCode"].replace(
            anchor,
            "  property_public_id: q.property_public_id || (/^EB-/i.test(String(q.property_id || '')) ? q.property_id : null),\n" + anchor,
        )

    try:
        call = node(wf, "Call WF3a: Auction Launcher")
        call["name"] = "Call WF19: Lead Router"
    except KeyError:
        call = node(wf, "Call WF19: Lead Router")
    call["parameters"]["workflowId"]["value"] = wf19_id
    conns = wf["connections"]
    for src, outs in conns.items():
        for branch in outs.get("main", []):
            for c in branch or []:
                if c["node"] == "Call WF3a: Auction Launcher":
                    c["node"] = "Call WF19: Lead Router"
    if "Call WF3a: Auction Launcher" in conns:
        conns["Call WF19: Lead Router"] = conns.pop("Call WF3a: Auction Launcher")

    put_wf(WF7, wf)
    print("WF7 patched")


# ---------------------------------------------------------------------------
# 6. WF3c v3 - tiered sweeper
# ---------------------------------------------------------------------------

EXPIRE_SQL = """WITH expired AS (
  UPDATE auctions
  SET status = 'expired'
  WHERE status = 'open' AND expires_at <= NOW()
  RETURNING auction_id, conversation_id, property_id, short_code
),
ctx AS (
  SELECT e.auction_id, e.conversation_id, e.property_id, e.short_code,
         c.lead_phone, c.lead_name, c.routing_tier, c.property_public_id,
         COALESCE(pc.payload->>'title', c.current_property, e.property_id) AS property_title,
         COALESCE(pc.payload->>'price', 'Precio por confirmar') AS property_price
  FROM expired e
  JOIN conversations c ON c.conversation_id = e.conversation_id
  LEFT JOIN properties_cache pc ON pc.property_id = e.property_id
),
-- Owner tier expired: escalate to the guard auction (tier 2), keep unassigned.
guard AS (
  UPDATE conversations c
  SET routing_tier = 'guard'
  FROM ctx
  WHERE c.conversation_id = ctx.conversation_id
    AND ctx.routing_tier = 'owner'
    AND c.assigned_agent_id IS NULL
    AND c.mode = 'pending_assignment'
  RETURNING c.conversation_id
),
-- Guard tier (or legacy untiered) expired: manager fallback so the lead
-- never sits ownerless.
assigned AS (
  UPDATE conversations c
  SET assigned_agent_id = 'agent_manager',
      mode = 'ai',
      claimed_via = 'escalation',
      routing_tier = 'manager',
      assigned_at = NOW()
  FROM ctx
  WHERE c.conversation_id = ctx.conversation_id
    AND ctx.routing_tier IS DISTINCT FROM 'owner'
    AND c.assigned_agent_id IS NULL
    AND c.mode = 'pending_assignment'
  RETURNING c.conversation_id
)
SELECT ctx.*,
       (g.conversation_id IS NOT NULL) AS to_guard,
       (a.conversation_id IS NOT NULL) AS auto_assigned,
       m.manager_phone
FROM ctx
LEFT JOIN guard g ON g.conversation_id = ctx.conversation_id
LEFT JOIN assigned a ON a.conversation_id = ctx.conversation_id
CROSS JOIN (SELECT whatsapp_number AS manager_phone FROM agents WHERE agent_id = 'agent_manager') m;"""

GUARD_PREP_JS = """// Expired owner auction -> launch the tier-2 guard auction via WF3a.
return $input.all().map(it => { const j = it.json; return { json: {
  conversation_id: j.conversation_id,
  lead_phone: j.lead_phone,
  lead_name: j.lead_name,
  property_id: j.property_id || 'Sin propiedad',
  property_title: j.property_title || j.property_id || 'Propiedad',
  property_price: j.property_price || 'Precio por confirmar',
  assigned_agent_id: null
} }; });"""


def patch_wf3c():
    wf = get_wf(WF3C)
    backup("wf3c", wf)
    if any(n["name"] == "Owner Tier?" for n in wf["nodes"]):
        print("WF3c already patched — skipping")
        return

    expire = node(wf, "Expire Unclaimed Auctions")
    expire["parameters"]["query"] = EXPIRE_SQL

    tier_if = {
        "parameters": {
            "conditions": {
                "options": {"caseSensitive": True, "typeValidation": "loose", "version": 2},
                "conditions": [
                    {
                        "id": wid(),
                        "leftValue": "={{ $json.to_guard }}",
                        "rightValue": "",
                        "operator": {"type": "boolean", "operation": "true", "singleValue": True},
                    }
                ],
                "combinator": "and",
            },
            "options": {},
        },
        "type": "n8n-nodes-base.if",
        "typeVersion": node(wf, "Any Expired?")["typeVersion"],
        "position": [660, 0],
        "id": wid(),
        "name": "Owner Tier?",
    }
    prep_guard = {
        "parameters": {"jsCode": GUARD_PREP_JS},
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [880, -140],
        "id": wid(),
        "name": "Prepare Guard Auction",
    }
    call_wf3a = exec_wf_node("Guard Auction (WF3a)", WF3A, [1100, -140])
    call_wf3a["id"] = wid()

    wf["nodes"].extend([tier_if, prep_guard, call_wf3a])
    wf["name"] = "WF3c - Auction Expiry Sweeper (Tiered)"
    wf["connections"]["Any Expired?"] = {"main": [[{"node": "Owner Tier?", "type": "main", "index": 0}]]}
    wf["connections"]["Owner Tier?"] = {
        "main": [
            [{"node": "Prepare Guard Auction", "type": "main", "index": 0}],
            [{"node": "Escalate to Manager via Evolution", "type": "main", "index": 0}],
        ]
    }
    wf["connections"]["Prepare Guard Auction"] = {"main": [[{"node": "Guard Auction (WF3a)", "type": "main", "index": 0}]]}

    put_wf(WF3C, wf)
    print("WF3c patched")


# ---------------------------------------------------------------------------

def main():
    step = sys.argv[1] if len(sys.argv) > 1 else "all"

    wf19_id = None
    if step in ("all", "create"):
        created = post_wf(build_wf19())
        wf19_id = created["id"]
        print(f"WF19 created: {wf19_id}")
        with open(os.path.join(SCRATCH, "wf19_id.txt"), "w") as f:
            f.write(wf19_id)
        created18 = post_wf(build_wf18())
        print(f"WF18 created: {created18['id']}")
        with open(os.path.join(SCRATCH, "wf18_id.txt"), "w") as f:
            f.write(created18["id"])
        activate(created18["id"])
        print("WF18 activated (daily 7:45 CDMX)")

    if wf19_id is None:
        wf19_id = open(os.path.join(SCRATCH, "wf19_id.txt")).read().strip()

    if step in ("all", "patch"):
        rewrite_wf12()
        activate(WF13)
        print("WF13 activated")

    if step in ("all", "patch", "patch2"):
        patch_intake(WF10, "wf10", wf19_id, is_eb=False)
        patch_intake(WF8B, "wf8b", wf19_id, is_eb=True)
        patch_wf7(wf19_id)
        patch_wf3c()

    print("DONE")


if __name__ == "__main__":
    main()
