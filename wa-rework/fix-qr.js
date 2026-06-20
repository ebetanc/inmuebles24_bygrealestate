const fs = require('fs');
const path = require('path');
const dir = path.join(__dirname, 'out');
const APPLY = process.argv.includes('--apply');
const files = fs.readdirSync(dir).filter(f => f.endsWith('.json'));

function toArrayForm(qr) {
  const s = qr.trim();
  if (/^=\{\{\s*\[/.test(s)) return null; // already array
  const parts = s.split(/,(?=\s*={{)/).map(x => x.trim());
  if (parts.length < 2) return null;
  // each part must be an ={{ ... }} expression; strip wrapper
  const inner = parts.map(e => {
    const m = e.match(/^=\{\{([\s\S]*)\}\}$/);
    return m ? m[1].trim() : null;
  });
  if (inner.some(x => x === null)) return { error: true, parts };
  return '={{ [' + inner.join(', ') + '] }}';
}

let total = 0;
for (const f of files) {
  const p = path.join(dir, f);
  const wf = JSON.parse(fs.readFileSync(p, 'utf8'));
  let changed = false;
  for (const n of wf.nodes || []) {
    if (n.type !== 'n8n-nodes-base.postgres') continue;
    const opts = n.parameters && n.parameters.options;
    const qr = opts && opts.queryReplacement;
    if (typeof qr !== 'string') continue;
    const res = toArrayForm(qr);
    if (!res) continue;
    if (res.error) { console.log(`!! ${wf.name} / ${n.name}: CANNOT parse, skip\n   ${qr}`); continue; }
    console.log(`\n${wf.name} / ${n.name}`);
    console.log(`  OLD: ${qr}`);
    console.log(`  NEW: ${res}`);
    if (APPLY) { opts.queryReplacement = res; changed = true; }
    total++;
  }
  if (APPLY && changed) fs.writeFileSync(p, JSON.stringify(wf, null, 2));
}
console.log(`\n${APPLY ? 'APPLIED' : 'DRY-RUN'} total: ${total} nodes`);
