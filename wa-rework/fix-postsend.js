const fs = require('fs');
const path = require('path');
const dir = path.join(__dirname, 'out');
const rd = f => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
const wr = (f, wf) => fs.writeFileSync(path.join(dir, f), JSON.stringify(wf, null, 2));

// ---- WF3a ----
{
  const f = '04aQhTOiXlDmN9bK.json';
  const wf = rd(f);
  const B = "$('Build Fan-out Messages').item.json";
  wf.nodes.find(n => n.name === 'Log Outbound Message').parameters.options.queryReplacement =
    `={{ [${B}.conversation_id, ${B}.number, ${B}.text, JSON.stringify({ purpose: 'auction_notify', auction_id: ${B}.auction_id, agent_id: ${B}.agent_id })] }}`;
  wf.nodes.find(n => n.name === 'Aggregate Results').parameters.jsCode =
    [
      "const fanout = $('Build Fan-out Messages').all();",
      "const notifiedAgents = fanout.map(i => i.json.agent_id).filter(Boolean);",
      "const c = fanout[0] ? fanout[0].json : {};",
      "return [{ json: { auction_id: c.auction_id, conversation_id: c.conversation_id, short_code: c.short_code, notified_agents: notifiedAgents, notified_count: notifiedAgents.length } }];",
    ].join('\n');
  wr(f, wf);
  console.log('WF3a: Log Outbound qr + Aggregate Results fixed');
}

// ---- WF4 ----
{
  const f = 'tnvPoAmVZ0zqGzOs.json';
  const wf = rd(f);
  const B = "$('Parse LLM Response').item.json";
  wf.nodes.find(n => n.name === 'Log AI Response').parameters.options.queryReplacement =
    `={{ [${B}.conversation_id, ${B}.phone, ${B}.ai_response, JSON.stringify({ purpose: 'ai_response', needs_handoff: ${B}.needs_handoff })] }}`;
  wr(f, wf);
  console.log('WF4: Log AI Response qr fixed');
}

// ---- WF5 ----
{
  const f = 'pYGcyX1ur24dQVew.json';
  const wf = rd(f);
  const B = "$('Build Handoff Messages').item.json";
  wf.nodes.find(n => n.name === 'Log Handoff Messages').parameters.options.queryReplacement =
    `={{ [${B}.conversation_id, ${B}.number, ${B}.text] }}`;
  wr(f, wf);
  console.log('WF5: Log Handoff Messages qr fixed');
}
