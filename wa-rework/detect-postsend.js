const fs = require('fs');
const path = require('path');
const dir = path.join(__dirname, 'out');

function isSend(n) {
  return n.type === 'n8n-nodes-base.httpRequest' &&
    /graph\.facebook\.com|WA_PHONE_NUMBER_ID/.test(JSON.stringify(n.parameters || {}));
}

for (const f of fs.readdirSync(dir).filter(x => x.endsWith('.json'))) {
  const wf = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
  const byName = Object.fromEntries(wf.nodes.map(n => [n.name, n]));
  const conns = wf.connections || {};
  const sends = wf.nodes.filter(isSend).map(n => n.name);
  if (!sends.length) continue;
  // BFS downstream from each send
  const downstream = new Set();
  let frontier = [...sends];
  while (frontier.length) {
    const next = [];
    for (const name of frontier) {
      const outs = (conns[name] && conns[name].main) || [];
      for (const arr of outs) for (const c of (arr || [])) {
        if (!downstream.has(c.node)) { downstream.add(c.node); next.push(c.node); }
      }
    }
    frontier = next;
  }
  const flagged = [];
  for (const name of downstream) {
    const n = byName[name];
    if (!n) continue;
    const blob = JSON.stringify(n.parameters || {});
    // reads $json.<field> (not via $('...')) -> likely reading pre-send fields lost after send
    const reads = (blob.match(/\$json\.\w+/g) || []);
    const refsSource = /\$\('[^']+'\)/.test(blob);
    if ((n.type === 'n8n-nodes-base.postgres' || n.type === 'n8n-nodes-base.code') && reads.length) {
      flagged.push(`    ${name} [${n.type.replace('n8n-nodes-base.','')}] reads ${[...new Set(reads)].join(',')}${refsSource?'  (also has $() refs)':''}`);
    }
  }
  console.log(`\n${wf.name}`);
  console.log(`  sends: ${sends.join(', ')}`);
  console.log(flagged.length ? `  POST-SEND nodes reading $json:\n${flagged.join('\n')}` : '  (no post-send $json readers)');
}
