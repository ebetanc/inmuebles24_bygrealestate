"""Update WF2 in n8n with v5 changes: returning lead detection, night queue, day/night routing."""
import json
import requests

N8N_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJkZjEzZTZjMi1mMjcxLTRjZmUtYTU5ZC0yYWI0MzZmZGYwYjIiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwianRpIjoiZGRhYjM5NzItYTBiNC00MzA3LThhODEtNTQ3NDhjMWEyYTA1IiwiaWF0IjoxNzc4MjM0MjIzfQ.i9kP3igkUA_eR5g7uNqr0sS8y9G2NK6roIKA0q5GB3g"
N8N_URL = "https://n8n.srv856940.hstgr.cloud/api/v1"
WF2_ID = "CYbIxSodtjGEQwMp"

r = requests.get(f"{N8N_URL}/workflows/{WF2_ID}", headers={"X-N8N-API-KEY": N8N_KEY})
wf = r.json()

# =====================================================================
# 1. Update "Extract Property Context"
# =====================================================================
NEW_EXTRACT_CODE = """// Extract property reference from lead's message.
// v5: Pass timePeriod and source from WF1.
const data = $input.first().json;
const text = data.text || '';

const ebMatch = text.match(/EB-[A-Z0-9]+/i);
const urlMatch = text.match(/https?:\\/\\/[^\\s]+/i);
const searchTerms = text
  .replace(/hola|buenos dias|buenas tardes|hi|hello|me interesa|quiero|informacion|info/gi, '')
  .trim();

return [{
  json: {
    phone: data.phone,
    pushName: data.pushName,
    text: data.text,
    messageId: data.messageId,
    extracted_property_id: ebMatch ? ebMatch[0] : null,
    extracted_url: urlMatch ? urlMatch[0] : null,
    search_terms: searchTerms.substring(0, 100),
    timePeriod: data.timePeriod || 'day',
    currentShift: data.currentShift || 'morning',
    source: data.source || 'whatsapp_direct',
    existing_conversation_id: data.existing_conversation_id || null
  }
}];"""

# =====================================================================
# 2. Update "Create/Update Conversation" SQL
# =====================================================================
NEW_CONVERSATION_SQL = """-- v5: Check returning lead, then create or reuse conversation.
WITH returning AS (
  SELECT conversation_id, assigned_agent_id, current_property,
         (current_property = $3 AND $3 IS NOT NULL)::boolean AS same_property,
         mode
  FROM conversations
  WHERE lead_phone = $1
  ORDER BY last_message_at DESC
  LIMIT 1
),
updated AS (
  UPDATE conversations
  SET last_message_at = NOW(),
      lead_name = COALESCE($2, lead_name)
  WHERE conversation_id = (SELECT conversation_id FROM returning WHERE same_property = true)
  RETURNING conversation_id, lead_phone, lead_name, current_property, mode,
            assigned_agent_id, true AS is_returning, true AS same_property
),
inserted AS (
  INSERT INTO conversations (lead_phone, lead_name, current_property, mode, source, arrived_during)
  SELECT $1, $2, $3,
         CASE WHEN $4 = 'night' THEN 'night_queued' ELSE 'pending_assignment' END,
         $5, $4
  WHERE NOT EXISTS (SELECT 1 FROM returning WHERE same_property = true)
  RETURNING conversation_id, lead_phone, lead_name, current_property, mode,
            assigned_agent_id, false AS is_returning, false AS same_property
)
SELECT * FROM updated
UNION ALL
SELECT * FROM inserted
LIMIT 1;"""

NEW_QUERY_REPLACEMENT = "={{ $json.phone }},={{ $json.pushName || null }},={{ $json.extracted_property_id || null }},={{ $json.timePeriod || 'day' }},={{ $json.source || 'whatsapp_direct' }}"

# =====================================================================
# 3. Update "Prepare Auction Data"
# =====================================================================
NEW_PREPARE_CODE = """// v5: Handle returning leads, night queue, and day auction.
const conv = $('Create/Update Conversation').first().json;
const property = $('Find Matching Property').first().json;
const context = $('Extract Property Context').first().json;

const hasProperty = !!(property && property.title);
const isReturning = conv.is_returning === true;
const sameProperty = conv.same_property === true;
const timePeriod = context.timePeriod || 'day';

const propertyId = hasProperty
  ? (property.listing_hash || 'listing-' + property.id)
  : (context.extracted_property_id || 'unknown');

const propertyTitle = hasProperty ? property.title : 'Propiedad (pendiente de identificar)';
const propertyPrice = hasProperty
  ? (property.price || '') + ' ' + (property.currency || 'MXN')
  : 'Precio por confirmar';

const cachePayload = hasProperty ? {
  title: property.title, price: property.price,
  price_numeric: property.price_numeric, currency: property.currency,
  location: property.location, property_type: property.property_type,
  operation_type: property.operation_type, bedrooms: property.bedrooms,
  bathrooms: property.bathrooms, area_m2: property.area_m2,
  description: property.description, url: property.url,
  image_url: property.image_url
} : null;

let action;
if (isReturning && sameProperty) {
  action = 'notify_existing_agent';
} else if (timePeriod === 'night') {
  action = 'night_queue';
} else {
  action = 'day_auction';
}

return [{
  json: {
    conversation_id: conv.conversation_id,
    lead_phone: conv.lead_phone,
    lead_name: conv.lead_name || context.pushName || null,
    property_id: propertyId,
    property_title: propertyTitle,
    property_price: propertyPrice,
    assigned_agent_id: conv.assigned_agent_id || null,
    cache_property_id: propertyId,
    cache_payload: cachePayload,
    has_property: hasProperty,
    action: action,
    is_returning: isReturning,
    same_property: sameProperty,
    timePeriod: timePeriod,
    source: context.source || 'whatsapp_direct'
  }
}];"""

# =====================================================================
# Apply changes to existing nodes
# =====================================================================
for node in wf["nodes"]:
    if node["name"] == "Extract Property Context":
        node["parameters"]["jsCode"] = NEW_EXTRACT_CODE
        print("Updated: Extract Property Context")

    elif node["name"] == "Create/Update Conversation":
        node["parameters"]["query"] = NEW_CONVERSATION_SQL
        node["parameters"]["options"]["queryReplacement"] = NEW_QUERY_REPLACEMENT
        print("Updated: Create/Update Conversation")

    elif node["name"] == "Prepare Auction Data":
        node["parameters"]["jsCode"] = NEW_PREPARE_CODE
        print("Updated: Prepare Auction Data")

# =====================================================================
# 4. Add new nodes
# =====================================================================
wf3a_pos = None
pg_creds = {}
for node in wf["nodes"]:
    if node["name"] == "Call WF3a: Auction Launcher":
        wf3a_pos = node["position"]
    if node["type"] == "n8n-nodes-base.postgres" and "credentials" in node:
        pg_creds = node["credentials"]

pos = wf3a_pos or [1400, 300]

# Route by Action (Switch)
route_switch = {
    "parameters": {
        "rules": {
            "values": [
                {
                    "conditions": {
                        "options": {"caseSensitive": True, "typeValidation": "strict"},
                        "conditions": [{"leftValue": "={{ $json.action }}", "rightValue": "day_auction",
                                        "operator": {"type": "string", "operation": "equals"}}]
                    },
                    "renameOutput": True, "outputKey": "day_auction"
                },
                {
                    "conditions": {
                        "options": {"caseSensitive": True, "typeValidation": "strict"},
                        "conditions": [{"leftValue": "={{ $json.action }}", "rightValue": "night_queue",
                                        "operator": {"type": "string", "operation": "equals"}}]
                    },
                    "renameOutput": True, "outputKey": "night_queue"
                },
                {
                    "conditions": {
                        "options": {"caseSensitive": True, "typeValidation": "strict"},
                        "conditions": [{"leftValue": "={{ $json.action }}", "rightValue": "notify_existing_agent",
                                        "operator": {"type": "string", "operation": "equals"}}]
                    },
                    "renameOutput": True, "outputKey": "notify_agent"
                }
            ]
        },
        "options": {}
    },
    "type": "n8n-nodes-base.switch",
    "typeVersion": 3.2,
    "position": [pos[0] - 200, pos[1]],
    "id": "route-by-action-v5",
    "name": "Route by Action"
}

# Night Queue Insert
night_queue_node = {
    "parameters": {
        "operation": "executeQuery",
        "query": "INSERT INTO night_queue (conversation_id, source, lead_phone, lead_name, property_id)\nVALUES ($1::uuid, $2, $3, $4, $5)\nRETURNING id, queued_at;",
        "options": {
            "queryReplacement": "={{ $json.conversation_id }},={{ $json.source }},={{ $json.lead_phone }},={{ $json.lead_name }},={{ $json.property_id }}"
        }
    },
    "type": "n8n-nodes-base.postgres",
    "typeVersion": 2.5,
    "position": [pos[0], pos[1] + 200],
    "id": "night-queue-insert-v5",
    "name": "Insert Night Queue",
    "credentials": pg_creds
}

# Notify Existing Agent
notify_agent_node = {
    "parameters": {
        "method": "POST",
        "url": "http://69.62.108.2:32769/message/sendText/byg_bot_n8n",
        "sendBody": True,
        "specifyBody": "json",
        "jsonBody": '={\n  "number": "{{ $json.lead_phone }}",\n  "text": "Lead recurrente\\n\\nEl lead {{ $json.lead_name || $json.lead_phone }} volvio a preguntar por la misma propiedad ({{ $json.property_title }}).\\n\\nTelefono: {{ $json.lead_phone }}\\nYa esta asignado a ti."\n}',
        "options": {}
    },
    "type": "n8n-nodes-base.httpRequest",
    "typeVersion": 4.2,
    "position": [pos[0], pos[1] + 400],
    "id": "notify-existing-agent-v5",
    "name": "Notify Existing Agent"
}

# Night Ack to Lead
night_ack_node = {
    "parameters": {
        "method": "POST",
        "url": "http://69.62.108.2:32769/message/sendText/byg_bot_n8n",
        "sendBody": True,
        "specifyBody": "json",
        "jsonBody": '={\n  "number": "{{ $json.lead_phone }}",\n  "text": "Hola {{ $json.lead_name || "" }}! Gracias por contactarnos. En este momento nuestro equipo no esta disponible, pero un asesor te atendera a primera hora manana. Hay algo especifico que te interese saber sobre la propiedad?"\n}',
        "options": {}
    },
    "type": "n8n-nodes-base.httpRequest",
    "typeVersion": 4.2,
    "position": [pos[0] + 200, pos[1] + 200],
    "id": "night-ack-lead-v5",
    "name": "Send Night Ack to Lead"
}

wf["nodes"].extend([route_switch, night_queue_node, notify_agent_node, night_ack_node])
print("Added 4 new nodes")

# =====================================================================
# 5. Update connections
# =====================================================================
conns = wf["connections"]

# Cache Property Data -> Route by Action (instead of directly to Send Ack)
conns["Cache Property Data"] = {
    "main": [[{"node": "Route by Action", "type": "main", "index": 0}]]
}

# Route by Action: 0=day -> Send Ack, 1=night -> Insert Night Queue, 2=notify -> Notify Agent
conns["Route by Action"] = {
    "main": [
        [{"node": "Send Acknowledgment to Lead", "type": "main", "index": 0}],
        [{"node": "Insert Night Queue", "type": "main", "index": 0}],
        [{"node": "Notify Existing Agent", "type": "main", "index": 0}]
    ]
}

conns["Insert Night Queue"] = {
    "main": [[{"node": "Send Night Ack to Lead", "type": "main", "index": 0}]]
}

wf["name"] = "WF2 - Lead Intake v5 (Returning + Night)"

payload = {
    "name": wf["name"],
    "nodes": wf["nodes"],
    "connections": wf["connections"],
    "settings": wf.get("settings", {}),
    "staticData": wf.get("staticData", None)
}

r = requests.put(
    f"{N8N_URL}/workflows/{WF2_ID}",
    headers={"X-N8N-API-KEY": N8N_KEY, "Content-Type": "application/json"},
    json=payload
)
if r.status_code == 200:
    print("WF2 updated successfully!")
else:
    print(f"WF2 update failed: {r.status_code}")
    print(r.text[:800])
