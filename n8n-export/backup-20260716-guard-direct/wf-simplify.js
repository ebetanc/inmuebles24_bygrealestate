// Simplify i24 lead flow: scraper -> notify on-shift guardia. No auctions.
// Runs INSIDE the n8n container. Reads API key from sqlite, PUTs WF19 + WF10,
// deactivates auction/follow-up workflows.
const sqlite3 = require("/usr/local/lib/node_modules/n8n/node_modules/.pnpm/sqlite3@5.1.7/node_modules/sqlite3");
const fs = require("fs");

const PG_CRED = { postgres: { id: "dEHKygi1neTNvPtH", name: "Postgres account BYG project" } };

// ---------- new WF19 ----------
const wf19Nodes = [
  {
    parameters: { inputSource: "passthrough" },
    type: "n8n-nodes-base.executeWorkflowTrigger",
    typeVersion: 1,
    position: [0, 0],
    id: "4ca5219c-ceae-4657-92ac-23c0f90bf8ab",
    name: "When Called",
    notes: "Input from WF10/WF7: { conversation_id, lead_phone, lead_name, property_id, property_title, property_price }"
  },
  {
    parameters: {
      operation: "executeQuery",
      query: [
        "-- Current on-shift guardia (calendar-aware), manager as guaranteed fallback.",
        "SELECT agent_id, name, whatsapp_number FROM (",
        "  SELECT a.agent_id, a.name, a.whatsapp_number, 1 AS pri",
        "  FROM get_on_shift_agents() g JOIN agents a ON a.agent_id = g.agent_id",
        "  UNION ALL",
        "  SELECT a.agent_id, a.name, a.whatsapp_number, 2",
        "  FROM agents a WHERE a.agent_id = 'agent_manager'",
        ") t ORDER BY pri, agent_id LIMIT 1;"
      ].join("\n"),
      options: {}
    },
    type: "n8n-nodes-base.postgres",
    typeVersion: 2.5,
    position: [220, 0],
    id: "a1000001-0000-4000-8000-000000000001",
    name: "Get Guardia",
    retryOnFail: true,
    maxTries: 3,
    waitBetweenTries: 5000,
    credentials: PG_CRED
  },
  {
    parameters: {
      operation: "executeQuery",
      query: [
        "-- Direct assignment to guardia. claimed_via='escalation' on purpose:",
        "-- the Pi note/status writers gate on it (supa.py) so NO i24 side-effects",
        "-- happen until a human actually responds.",
        "UPDATE conversations",
        "SET assigned_agent_id = $1,",
        "    claimed_via = 'escalation',",
        "    routing_tier = 'guard',",
        "    assigned_at = NOW(),",
        "    tier_notified_at = NOW(),",
        "    mode = 'ai'",
        "WHERE conversation_id = $2::uuid;"
      ].join("\n"),
      options: {
        queryReplacement: "={{ [$json.agent_id, $('When Called').first().json.conversation_id] }}"
      }
    },
    type: "n8n-nodes-base.postgres",
    typeVersion: 2.5,
    position: [440, 0],
    id: "a1000002-0000-4000-8000-000000000002",
    name: "Assign Guardia",
    credentials: PG_CRED,
    onError: "continueRegularOutput",
    alwaysOutputData: true
  },
  {
    parameters: {
      jsCode: [
        "const lead = $('When Called').first().json;",
        "const g = $('Get Guardia').first().json;",
        "const propiedad = String(lead.property_title || lead.property_id || 'Propiedad');",
        "const nombre = String(lead.lead_name || 'Sin nombre');",
        "const tel = String(lead.lead_phone || 'N/D');",
        "return [{ json: {",
        "  number: g.whatsapp_number,",
        "  agent_id: g.agent_id,",
        "  agent_name: g.name,",
        "  t_propiedad: propiedad,",
        "  t_nombre: nombre,",
        "  t_tel: tel,",
        "  text: `\\u{1F3E0} Nuevo lead Inmuebles24: ${nombre} | ${propiedad} | Tel: ${tel}`,",
        "  conversation_id: lead.conversation_id",
        "} }];"
      ].join("\n")
    },
    type: "n8n-nodes-base.code",
    typeVersion: 2,
    position: [660, 0],
    id: "a1000003-0000-4000-8000-000000000003",
    name: "Build Guardia Message"
  },
  {
    parameters: {
      method: "POST",
      url: '={{ "https://graph.facebook.com/" + $env.WA_API_VERSION + "/" + $env.WA_PHONE_NUMBER_ID + "/messages" }}',
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: "Authorization", value: "=Bearer {{ $env.WA_ACCESS_TOKEN }}" },
          { name: "Content-Type", value: "application/json" }
        ]
      },
      sendBody: true,
      specifyBody: "json",
      jsonBody: [
        "={",
        '  "messaging_product": "whatsapp",',
        '  "to": "{{ $json.number }}",',
        '  "type": "template",',
        '  "template": {',
        '    "name": "lead_seguimiento_prompt",',
        '    "language": { "code": "es_MX" },',
        '    "components": [',
        "      {",
        '        "type": "body",',
        '        "parameters": [',
        '          { "type": "text", "text": {{ JSON.stringify($json.t_nombre) }} },',
        '          { "type": "text", "text": {{ JSON.stringify($json.t_tel) }} },',
        '          { "type": "text", "text": {{ JSON.stringify($json.t_propiedad) }} },',
        '          { "type": "text", "text": "Contactar al cliente (lead NUEVO de Inmuebles24)" }',
        "        ]",
        "      }",
        "    ]",
        "  }",
        "}"
      ].join("\n"),
      options: { timeout: 15000 }
    },
    type: "n8n-nodes-base.httpRequest",
    typeVersion: 4.2,
    position: [880, 0],
    id: "a1000004-0000-4000-8000-000000000004",
    name: "Send to Guardia",
    retryOnFail: true,
    maxTries: 3,
    waitBetweenTries: 5000,
    continueOnFail: true
  },
  {
    parameters: {
      operation: "executeQuery",
      query: "INSERT INTO messages (conversation_id, direction, sender_type, recipient_phone, body, metadata)\nVALUES ($1::uuid, 'outbound', 'system', $2, $3, $4::jsonb);",
      options: {
        queryReplacement: "={{ [$('Build Guardia Message').item.json.conversation_id, $('Build Guardia Message').item.json.number, $('Build Guardia Message').item.json.text, JSON.stringify({ purpose: 'guard_notify', agent_id: $('Build Guardia Message').item.json.agent_id })] }}"
      }
    },
    type: "n8n-nodes-base.postgres",
    typeVersion: 2.5,
    position: [1100, 0],
    id: "a1000005-0000-4000-8000-000000000005",
    name: "Log Outbound Message",
    credentials: PG_CRED,
    continueOnFail: true
  }
];

const wf19Connections = {
  "When Called": { main: [[{ node: "Get Guardia", type: "main", index: 0 }]] },
  "Get Guardia": { main: [[{ node: "Assign Guardia", type: "main", index: 0 }]] },
  "Assign Guardia": { main: [[{ node: "Build Guardia Message", type: "main", index: 0 }]] },
  "Build Guardia Message": { main: [[{ node: "Send to Guardia", type: "main", index: 0 }]] },
  "Send to Guardia": { main: [[{ node: "Log Outbound Message", type: "main", index: 0 }]] }
};

// ---------- main ----------
(async () => {
  const keys = await new Promise((res, rej) => {
    const db = new sqlite3.Database("/home/node/.n8n/database.sqlite", sqlite3.OPEN_READONLY);
    db.all("SELECT label, apiKey FROM user_api_keys", (e, r) => {
      db.close();
      e ? rej(e) : res(r);
    });
  });
  let key = null;
  for (const k of keys) {
    const r = await fetch("http://localhost:5678/api/v1/workflows?limit=1", { headers: { "X-N8N-API-KEY": k.apiKey } });
    if (r.ok) { key = k.apiKey; console.log("using key:", k.label); break; }
  }
  if (!key) throw new Error("no working API key");
  const api = async (method, path, body) => {
    const r = await fetch("http://localhost:5678/api/v1" + path, {
      method,
      headers: { "X-N8N-API-KEY": key, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined
    });
    const txt = await r.text();
    if (!r.ok) throw new Error(method + " " + path + " -> " + r.status + " " + txt.slice(0, 300));
    return JSON.parse(txt);
  };

  // 1. PUT new WF19
  const wf19old = JSON.parse(fs.readFileSync("/tmp/WF19_backup.json", "utf8"));
  const put19 = await api("PUT", "/workflows/zOHmTODH4QSqALnp", {
    name: "WF19 - Guard Notify (Direct)",
    nodes: wf19Nodes,
    connections: wf19Connections,
    settings: JSON.parse(wf19old.settings)
  });
  console.log("WF19 updated:", put19.name, "active=", put19.active);

  // 2. Patch WF10 returning-notify to template
  const wf10old = JSON.parse(fs.readFileSync("/tmp/WF10_backup.json", "utf8"));
  const wf10nodes = JSON.parse(wf10old.nodes);
  const notif = wf10nodes.find(n => n.name === "Notify Agent (Returning)");
  notif.parameters.jsonBody = [
    "={",
    '  "messaging_product": "whatsapp",',
    '  "to": "{{ $json.whatsapp_number }}",',
    '  "type": "template",',
    '  "template": {',
    '    "name": "lead_seguimiento_prompt",',
    '    "language": { "code": "es_MX" },',
    '    "components": [',
    "      {",
    '        "type": "body",',
    '        "parameters": [',
    "          { \"type\": \"text\", \"text\": {{ JSON.stringify(String($('Prepare Agent Notification').first().json.lead_name || 'Sin nombre')) }} },",
    "          { \"type\": \"text\", \"text\": {{ JSON.stringify(String($('Prepare Agent Notification').first().json.lead_phone || 'N/D')) }} },",
    "          { \"type\": \"text\", \"text\": {{ JSON.stringify(String($('Prepare Agent Notification').first().json.property_title || 'Propiedad')) }} },",
    '          { "type": "text", "text": "Lead recurrente: volvió a preguntar por esta propiedad (ya asignada a ti)" }',
    "        ]",
    "      }",
    "    ]",
    "  }",
    "}"
  ].join("\n");
  const put10 = await api("PUT", "/workflows/Obr38705ZZYS3FB8", {
    name: wf10old.name,
    nodes: wf10nodes,
    connections: JSON.parse(wf10old.connections),
    settings: JSON.parse(wf10old.settings)
  });
  console.log("WF10 updated:", put10.name, "active=", put10.active);

  // 3. Deactivate auction/follow-up machinery
  const toDeactivate = {
    "04aQhTOiXlDmN9bK": "WF3a Auction Launcher",
    "JM2HxJxl53k4zlki": "WF3b Claim Handler",
    "UNIKqyAvIUAZkNIs": "WF3c Expiry Sweeper",
    "K8Hzk2fCYjZHWNKi": "WF14 Follow-Up Sweeper",
    "Zwp2aENlqLQwF3Ry": "WF15 Follow-Up Reply Handler",
    "Bo2YbbUpmBzRbhDa": "WF13 Directed Owner Notify",
    "w7yJr7naWoxPq6Pw": "WF12 Owner Resolver"
  };
  for (const [id, name] of Object.entries(toDeactivate)) {
    try {
      const r = await api("POST", "/workflows/" + id + "/deactivate");
      console.log("deactivated:", name, "active=", r.active);
    } catch (e) {
      console.log("deactivate FAILED:", name, e.message);
    }
  }

  // 4. Ensure WF19 + WF10 still active
  for (const id of ["zOHmTODH4QSqALnp", "Obr38705ZZYS3FB8"]) {
    try { const r = await api("POST", "/workflows/" + id + "/activate"); console.log("active OK:", r.name); }
    catch (e) { console.log("activate note:", e.message); }
  }
  console.log("DONE");
})().catch(e => { console.error("FATAL", e); process.exit(1); });
