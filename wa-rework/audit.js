const fs = require('fs');
const path = require('path');
const dir = path.join(__dirname, 'out');
const files = fs.readdirSync(dir).filter(f => f.endsWith('.json'));

function countPlaceholders(q) {
  const m = q.match(/\$(\d+)/g) || [];
  const nums = [...new Set(m.map(x => parseInt(x.slice(1))))];
  return nums.length ? Math.max(...nums) : 0;
}
function qrParamCount(qr) {
  if (qr == null) return null;
  if (typeof qr !== 'string') return null;
  const s = qr.trim();
  // array form ={{ [a, b, c] }}  -> count top-level commas inside [...]
  if (/^=\{\{\s*\[/.test(s)) {
    const inner = s.replace(/^=\{\{\s*\[/, '').replace(/\]\s*\}\}$/, '');
    // count commas at depth 0
    let depth = 0, n = inner.trim() ? 1 : 0;
    for (let i = 0; i < inner.length; i++) {
      const c = inner[i];
      if ('([{'.includes(c)) depth++;
      else if (')]}'.includes(c)) depth--;
      else if (c === ',' && depth === 0) n++;
    }
    return { form: 'array', count: n };
  }
  // comma-separated string of ={{ }} expressions  -> BUG-prone
  const parts = s.split(/,(?=\s*={{)/);
  return { form: parts.length > 1 ? 'COMMA-STRING' : 'single', count: parts.length };
}

for (const f of files) {
  const wf = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
  const findings = [];
  for (const n of wf.nodes || []) {
    if (n.type !== 'n8n-nodes-base.postgres') continue;
    const q = (n.parameters && n.parameters.query) || '';
    const qr = n.parameters && n.parameters.options && n.parameters.options.queryReplacement;
    const ph = countPlaceholders(q);
    const qrc = qrParamCount(qr);
    // flag: comma-string multiparam
    if (qrc && qrc.form === 'COMMA-STRING') findings.push(`  [COMMA-STRING qr, ${qrc.count} parts] ${n.name}`);
    // flag: placeholder/param mismatch
    if (ph > 0 && qrc && qrc.count !== ph) findings.push(`  [PARAM MISMATCH: query needs $${ph}, qr provides ${qrc.count} (${qrc.form})] ${n.name}`);
    if (ph > 0 && qr == null) findings.push(`  [NO qr but query has $${ph}] ${n.name}`);
    // flag ON CONFLICT
    if (/ON CONFLICT/i.test(q)) {
      const m = q.match(/ON CONFLICT\s*\(([^)]*)\)/i);
      findings.push(`  [ON CONFLICT (${m ? m[1] : '?'})] ${n.name}`);
    }
    // flag reserved CTE name "returning"
    if (/\bWITH\s+returning\b/i.test(q) || /\),\s*returning\s+AS/i.test(q)) findings.push(`  [CTE named 'returning' (reserved)] ${n.name}`);
  }
  const sendCount = (wf.nodes || []).filter(n => n.type === 'n8n-nodes-base.httpRequest' && /graph\.facebook\.com|WA_PHONE_NUMBER_ID/.test(JSON.stringify(n.parameters || {}))).length;
  const oldEvo = (wf.nodes || []).filter(n => n.type === 'n8n-nodes-base.httpRequest' && /sendText|EVOLUTION_API/.test(JSON.stringify(n.parameters || {}))).length;
  console.log(`\n=== ${wf.name}  (cloudSends=${sendCount}, leftoverEvolution=${oldEvo}) ===`);
  console.log(findings.length ? findings.join('\n') : '  (no query findings)');
}
