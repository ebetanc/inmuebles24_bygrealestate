const fs = require('fs');
const path = require('path');
const dir = path.join(__dirname, 'byg');
const outDir = path.join(__dirname, 'out');
fs.mkdirSync(outDir, { recursive: true });

// Extract the raw value token for a top-level key from an n8n json-expression body.
// Handles quoted JSON strings (with escapes) and unquoted {{ }} expressions.
function extractValue(body, key) {
  const marker = `"${key}":`;
  const ki = body.indexOf(marker);
  if (ki === -1) throw new Error(`key ${key} not found`);
  let i = ki + marker.length;
  while (i < body.length && /\s/.test(body[i])) i++;
  if (body[i] === '"') {
    // quoted JSON string
    let j = i + 1;
    while (j < body.length) {
      if (body[j] === '\\') { j += 2; continue; }
      if (body[j] === '"') { j++; break; }
      j++;
    }
    return body.slice(i, j);
  }
  // unquoted: read until top-level , or } (ignore inside {{ }})
  let j = i, depth = 0;
  while (j < body.length) {
    if (body[j] === '{' && body[j + 1] === '{') { depth++; j += 2; continue; }
    if (body[j] === '}' && body[j + 1] === '}') { depth--; j += 2; continue; }
    if (depth === 0 && (body[j] === ',' || body[j] === '}')) break;
    j++;
  }
  return body.slice(i, j).trim();
}

function isEvolutionSend(n) {
  return n.type === 'n8n-nodes-base.httpRequest' &&
    typeof (n.parameters && n.parameters.url) === 'string' &&
    n.parameters.url.includes('/message/sendText/');
}

function convertSendNode(n) {
  const body = n.parameters.jsonBody;
  const num = extractValue(body, 'number');
  const txt = extractValue(body, 'text');
  n.parameters.url = '={{ "https://graph.facebook.com/" + $env.WA_API_VERSION + "/" + $env.WA_PHONE_NUMBER_ID + "/messages" }}';
  n.parameters.sendHeaders = true;
  n.parameters.headerParameters = { parameters: [
    { name: 'Authorization', value: '=Bearer {{ $env.WA_ACCESS_TOKEN }}' },
    { name: 'Content-Type', value: 'application/json' },
  ] };
  n.parameters.sendBody = true;
  n.parameters.specifyBody = 'json';
  n.parameters.jsonBody =
    '={\n  "messaging_product": "whatsapp",\n  "to": ' + num +
    ',\n  "type": "text",\n  "text": {\n    "body": ' + txt + '\n  }\n}';
  return { node: n.name, to: num, text: txt.slice(0, 40) };
}

// ---- WF1 webhook rework ----
function reworkWF1(wf) {
  const nodes = wf.nodes;
  const webhook = nodes.find(n => n.type === 'n8n-nodes-base.webhook');
  webhook.name = 'WA Webhook';
  webhook.parameters = {
    httpMethod: ['GET', 'POST'],
    multipleMethods: true,
    path: 'evolution-webhook',
    responseMode: 'responseNode',
    options: {},
  };
  webhook.notes = 'Meta WhatsApp Cloud API webhook. GET=hub.challenge verify, POST=inbound messages.';

  // Replace parse node jsCode (keep node NAME so Classify & Route ref still resolves)
  const parse = nodes.find(n => n.name === 'Parse Evolution Payload');
  parse.parameters.jsCode = [
    "// Parse Meta WhatsApp Cloud API inbound payload.",
    "const body = $input.first().json.body || {};",
    "const entry = (body.entry && body.entry[0]) || {};",
    "const change = (entry.changes && entry.changes[0]) || {};",
    "const value = change.value || {};",
    "if (value.statuses) {",
    "  return [{ json: { _action: 'ignore', reason: 'status_event' } }];",
    "}",
    "const msg = value.messages && value.messages[0];",
    "if (!msg) {",
    "  return [{ json: { _action: 'ignore', reason: 'no_message' } }];",
    "}",
    "const phone = msg.from || '';",
    "let text = '';",
    "if (msg.type === 'text' && msg.text) { text = msg.text.body || ''; }",
    "else if (msg.type === 'button' && msg.button) { text = msg.button.text || ''; }",
    "else if (msg.type === 'interactive' && msg.interactive) {",
    "  const it = msg.interactive;",
    "  text = (it.button_reply && it.button_reply.title) || (it.list_reply && it.list_reply.title) || '';",
    "} else {",
    "  return [{ json: { _action: 'ignore', reason: 'unsupported_message_type' } }];",
    "}",
    "const contact = (value.contacts && value.contacts[0]) || {};",
    "const pushName = (contact.profile && contact.profile.name) || '';",
    "const messageId = msg.id || '';",
    "const timestamp = msg.timestamp ? parseInt(msg.timestamp, 10) : Math.floor(Date.now() / 1000);",
    "return [{ json: { _action: 'process', phone, text: String(text).trim(), pushName, messageId, timestamp, remoteJid: phone } }];",
  ].join('\n');

  // New nodes: IF (is GET verify), Verify Challenge respond, Ack 200 respond
  const ifNode = {
    parameters: {
      conditions: {
        options: { caseSensitive: true, typeValidation: 'strict', leftValue: '' },
        conditions: [{
          id: 'c0ffee00-aaaa-4000-8000-000000000aaa',
          leftValue: "={{ ($json.query && $json.query['hub.mode']) ? 'yes' : 'no' }}",
          rightValue: 'yes',
          operator: { type: 'string', operation: 'equals' },
        }],
        combinator: 'and',
      },
      options: {},
    },
    id: 'c0ffee00-bbbb-4000-8000-000000000bbb',
    name: 'Is GET Verify?',
    type: 'n8n-nodes-base.if',
    typeVersion: 2.2,
    position: [160, 304],
  };
  const verifyRespond = {
    parameters: {
      respondWith: 'text',
      responseBody: "={{ ($json.query && $json.query['hub.verify_token'] === $env.WA_VERIFY_TOKEN) ? $json.query['hub.challenge'] : '' }}",
      options: { responseCode: 200 },
    },
    id: 'c0ffee00-cccc-4000-8000-000000000ccc',
    name: 'Verify Challenge',
    type: 'n8n-nodes-base.respondToWebhook',
    typeVersion: 1.1,
    position: [384, 160],
  };
  const ackRespond = {
    parameters: {
      respondWith: 'text',
      responseBody: 'EVENT_RECEIVED',
      options: { responseCode: 200 },
    },
    id: 'c0ffee00-dddd-4000-8000-000000000ddd',
    name: 'Ack 200',
    type: 'n8n-nodes-base.respondToWebhook',
    typeVersion: 1.1,
    position: [384, 304],
  };
  nodes.push(ifNode, verifyRespond, ackRespond);

  // Reposition parse downstream of Ack
  parse.position = [608, 304];

  // Rewire connections head: WA Webhook -> Is GET Verify? -> (true) Verify Challenge / (false) Ack 200 -> Parse Evolution Payload
  const c = wf.connections;
  delete c['Evolution Webhook'];
  c['WA Webhook'] = { main: [[{ node: 'Is GET Verify?', type: 'main', index: 0 }]] };
  c['Is GET Verify?'] = { main: [
    [{ node: 'Verify Challenge', type: 'main', index: 0 }],
    [{ node: 'Ack 200', type: 'main', index: 0 }],
  ] };
  c['Ack 200'] = { main: [[{ node: 'Parse Evolution Payload', type: 'main', index: 0 }]] };
  // Parse Evolution Payload -> Valid Message? stays as-is
}

const summary = [];
for (const f of fs.readdirSync(dir).filter(x => x.endsWith('.json'))) {
  const wf = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
  const changes = [];
  for (const n of wf.nodes) {
    if (isEvolutionSend(n)) changes.push(convertSendNode(n));
  }
  if (f === 'snF6Sr9CBJIevMVD.json') reworkWF1(wf);
  // strip export-only metadata that import rejects / that pins version
  delete wf.shared;
  fs.writeFileSync(path.join(outDir, f), JSON.stringify(wf, null, 2));
  summary.push(`${f}  ${wf.name}  -> ${changes.length} send(s) converted${f === 'snF6Sr9CBJIevMVD.json' ? ' + WF1 webhook reworked' : ''}`);
}
console.log(summary.join('\n'));
