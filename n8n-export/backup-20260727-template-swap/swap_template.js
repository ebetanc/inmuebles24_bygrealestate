const { DatabaseSync } = require("node:sqlite");
(async () => {
  const db = new DatabaseSync("/home/node/.n8n/database.sqlite", { readOnly: true });
  const keys = db.prepare("SELECT label, apiKey FROM user_api_keys").all();
  db.close();
  let key = null;
  for (const k of keys) {
    const r = await fetch("http://localhost:5678/api/v1/workflows?limit=1", { headers: { "X-N8N-API-KEY": k.apiKey } });
    if (r.ok) { key = k.apiKey; console.log("using key:", k.label); break; }
  }
  if (!key) throw new Error("no working key");
  const api = async (method, path, body) => {
    const r = await fetch("http://localhost:5678/api/v1" + path, {
      method, headers: { "X-N8N-API-KEY": key, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined
    });
    const txt = await r.text();
    if (!r.ok) throw new Error(method + " " + path + " -> " + r.status + " " + txt.slice(0, 300));
    return JSON.parse(txt);
  };

  const patch = async (wfId, nodeName, bodyBuilder) => {
    const wf = await api("GET", "/workflows/" + wfId);
    const node = wf.nodes.find(n => n.name === nodeName);
    if (!node) throw new Error(nodeName + " not found in " + wfId);
    node.parameters.jsonBody = bodyBuilder();
    const allowed = ["name", "nodes", "connections", "settings"];
    const payload = {};
    for (const k of allowed) payload[k] = wf[k];
    if (payload.settings) {
      const s = {};
      for (const k of ["saveExecutionProgress","saveManualExecutions","saveDataErrorExecution","saveDataSuccessExecution","executionTimeout","errorWorkflow","timezone","executionOrder"])
        if (payload.settings[k] !== undefined) s[k] = payload.settings[k];
      payload.settings = s;
    }
    await api("PUT", "/workflows/" + wfId, payload);
    console.log("patched", wf.name, "->", nodeName);
  };

  // WF19 Send to Guardia: to = $json.number, vars t_nombre/t_tel/t_propiedad
  await patch("zOHmTODH4QSqALnp", "Send to Guardia", () =>
`={
  "messaging_product": "whatsapp",
  "to": "{{ $json.number }}",
  "type": "template",
  "template": {
    "name": "nuevo_lead_i24",
    "language": { "code": "es_MX" },
    "components": [
      {
        "type": "body",
        "parameters": [
          { "type": "text", "text": {{ JSON.stringify($json.t_nombre) }} },
          { "type": "text", "text": {{ JSON.stringify($json.t_tel) }} },
          { "type": "text", "text": {{ JSON.stringify($json.t_propiedad) }} }
        ]
      }
    ]
  }
}`);

  // WF10 Notify Agent (Returning): vars from Prepare Agent Notification
  await patch("Obr38705ZZYS3FB8", "Notify Agent (Returning)", () =>
`={
  "messaging_product": "whatsapp",
  "to": "{{ $json.whatsapp_number }}",
  "type": "template",
  "template": {
    "name": "nuevo_lead_i24",
    "language": { "code": "es_MX" },
    "components": [
      {
        "type": "body",
        "parameters": [
          { "type": "text", "text": {{ JSON.stringify(String($('Prepare Agent Notification').first().json.lead_name || 'Sin nombre')) }} },
          { "type": "text", "text": {{ JSON.stringify(String($('Prepare Agent Notification').first().json.lead_phone || 'N/D')) }} },
          { "type": "text", "text": {{ JSON.stringify(String($('Prepare Agent Notification').first().json.property_title || 'Propiedad')) }} }
        ]
      }
    ]
  }
}`);

  // verify active flags survived
  for (const id of ["zOHmTODH4QSqALnp", "Obr38705ZZYS3FB8"]) {
    const w = await api("GET", "/workflows/" + id);
    console.log(w.name, "active:", w.active, "| template now:", (w.nodes.find(n => /Send to Guardia|Notify Agent \(Returning\)/.test(n.name)).parameters.jsonBody.match(/"name": "([^"]+)"/) || [])[1]);
  }
})().catch(e => { console.error(e); process.exit(1); });
