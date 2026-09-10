// node whatsapp-agent/workflows/test_wf24_render.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const { render } = createRequire(import.meta.url)(join(here, 'wf24_render.js'));
const row = JSON.parse(readFileSync(join(here, 'fixtures', 'wf24_leads_sample.json'), 'utf8'));

const out = render(row);

assert.equal(out.tpl.length, 7);
out.tpl.forEach((p, i) => assert.ok(!p.includes('\n'), `tpl[${i}] has a newline`));
assert.ok(out.tpl[6].length <= 600, 'tpl[6] too long');
assert.equal(out.tpl[3], '1', 'expected exactly one lead sin asignación (Sandy)');

const joined = out.text_chunks.join('\n');
out.text_chunks.forEach(c => assert.ok(c.length <= 4000, 'chunk over 4000'));
for (const l of row.leads) assert.ok(joined.includes('#' + l.opportunity_id), 'missing #' + l.opportunity_id);
assert.ok(!/<[a-z]/i.test(joined), 'HTML tag leaked into text');
assert.ok(out.subject.startsWith('[V3] Reporte del día'), out.subject);
assert.ok(out.html.includes('Reporte del día'));

// stress: 60 leads must split into several chunks and lose nothing
const many = { ...row, leads: [] };
for (let i = 0; i < 60; i++) {
  const src = row.leads[i % row.leads.length];
  many.leads.push({ ...src, opportunity_id: 9000 + i });
}
const big = render(many);
assert.ok(big.text_chunks.length > 1, 'expected more than one chunk');
big.text_chunks.forEach(c => assert.ok(c.length <= 4000, 'chunk over 4000'));
const bigJoined = big.text_chunks.join('\n');
for (const l of many.leads) assert.ok(bigJoined.includes('#' + l.opportunity_id), 'missing #' + l.opportunity_id);
assert.ok(big.tpl.every(p => !p.includes('\n')));
assert.ok(big.tpl[6].length <= 600);

console.log('ok');
