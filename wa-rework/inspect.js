const fs = require('fs');
const path = require('path');
const dir = path.join(__dirname, 'byg');
const files = fs.readdirSync(dir).filter(f => f.endsWith('.json'));
for (const f of files) {
  const wf = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
  const sends = (wf.nodes || []).filter(n =>
    n.type === 'n8n-nodes-base.httpRequest' &&
    typeof (n.parameters && n.parameters.url) === 'string' &&
    n.parameters.url.includes('/message/sendText/'));
  if (!sends.length) { console.log(`\n=== ${f}  ${wf.name}  [NO SEND NODES]`); continue; }
  console.log(`\n=== ${f}  ${wf.name}  (${sends.length} send node(s))`);
  for (const n of sends) {
    console.log(`  NODE: ${n.name}  continueOnFail=${n.continueOnFail}`);
    console.log(`  jsonBody: ${JSON.stringify(n.parameters.jsonBody)}`);
  }
}
