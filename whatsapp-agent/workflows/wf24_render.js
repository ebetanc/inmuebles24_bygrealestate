// WF24 report renderer. Pure: no n8n globals here (the builder appends the
// `$input` tail). Also loadable from node for tests via module.exports below.
function render(row) {
const leads = Array.isArray(row.leads) ? row.leads : [];
const h = row.health || {};
const mode = row.mode;
const TZ = 'America/Mexico_City';
const hhmm = (v) => v ? new Date(v).toLocaleTimeString('es-MX', {timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false}) : '—';
const dmy = (v) => v ? new Date(v).toLocaleDateString('es-MX', {timeZone: TZ, day: '2-digit', month: 'short'}) : '';
const mins = (a, b) => (a && b) ? Math.round((new Date(b) - new Date(a)) / 60000) : null;
const esc = (s) => String(s ?? '').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
const stripHtml = s => String(s).replace(/<[^>]+>/g,'').replace(/&#10004;/g,'✔').replace(/&#10008;/g,'✘').replace(/&#8987;/g,'⌛').replace(/&#9888;/g,'⚠').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>');
const oneLine = s => String(s).replace(/\s+/g,' ').trim();
const clip = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;
const OK = '<span style="color:#157A73;font-weight:700">&#10004;</span>';
const BAD = '<span style="color:#C8483B;font-weight:700">&#10008;</span>';
const WAIT = '<span style="color:#B7791F;font-weight:700">&#8987;</span>';
const tierName = (t) => ({owner:'propietario', primary_guard:'guardia', backup_guard:'guardia', sandy:'Sandy'}[t] || t || '');

let alerts = [];
const scraperAge = h.scraper_last_ok ? mins(h.scraper_last_ok, row.until) : null;
if (scraperAge === null || scraperAge > 40) alerts.push('Scraper sin corrida OK hace ' + (scraperAge ?? '?') + ' min');
if (Number(h.stuck_requested) > 0) alerts.push(h.stuck_requested + ' oferta(s) pedidas hace >3 min sin enviar (¿WF23/WF13 caído?)');
if (Number(h.stuck_expired) > 0) alerts.push(h.stuck_expired + ' oferta(s) vencidas sin escalar (¿WF23 apagado?)');
if (Number(h.manual_review_new) > 0) alerts.push(h.manual_review_new + ' solicitud(es) nuevas cayeron en revisión manual (sin ID EasyBroker)');

let nNew = 0, nClaim = 0, nSandy = 0, nUnassigned = 0, nOpen = 0, nEbOk = 0, nProblem = 0;
const tcards = [];
const cards = leads.map(l => {
  const attempts = l.attempts || [], events = l.events || [], effects = l.eb_effects || [];
  const lines = [];
  const problems = [];
  const detected = events.find(e => e.type === 'detected');
  if (detected && new Date(detected.at) >= new Date(row.since)) nNew++;
  const contacted = events.find(e => e.type === 'i24_contacted');
  lines.push(`Detectado ${hhmm(detected ? detected.at : l.created_at)} · Contactado en Inmuebles24 ${contacted ? OK + ' ' + hhmm(contacted.at) : (l.contactado_status === 'verified' ? OK : WAIT)}`);
  if (l.v3_night_queued_at) lines.push(`Cola nocturna ${hhmm(l.v3_night_queued_at)} ${dmy(l.v3_night_queued_at)} → liberado ${l.v3_night_released_at ? OK + ' ' + hhmm(l.v3_night_released_at) : WAIT + ' pendiente 08:05'}`);
  // NOTE: attempts.claimed_at is the sender's lease (WF13/WF23), NOT the human click.
  // The human click is opportunity.accepted_at, on the offer addressed to the assigned agent.
  let claimed = null;
  for (const a of attempts) {
    if (a.kind === 'offer') {
      let st;
      const isClaim = !!l.accepted_at && a.to_id === l.assigned_agent_id;
      if (isClaim) { st = `${OK} <b>Tomó ${esc(a.to)}</b> ${hhmm(l.accepted_at)} (${mins(a.delivered_at || a.sent_at || a.requested_at, l.accepted_at)} min tras entrega)`; claimed = a; }
      else if (a.status === 'expired') st = `${BAD} venció sin respuesta`;
      else if (a.status === 'failed' || a.failed_at) { st = `${BAD} WhatsApp falló ${hhmm(a.failed_at)}`; if (!l.assigned_agent_id) problems.push('WhatsApp no llegó a ' + a.to); }
      else if (a.delivered_at && l.assigned_agent_id) st = `${BAD} venció sin respuesta`;
      else if (a.delivered_at) st = `${WAIT} entregado, esperando Tomo (5 min)`;
      else if (a.sent_at) { st = `${WAIT} enviado, sin confirmación de entrega`; if (!l.assigned_agent_id && mins(a.sent_at, row.until) > 3) problems.push('Sin "entregado" de Meta para ' + a.to); }
      else { st = `${WAIT} pedido, aún no enviado`; if (!l.assigned_agent_id && mins(a.requested_at, row.until) > 3) problems.push('Oferta a ' + a.to + ' pedida hace ' + mins(a.requested_at, row.until) + ' min sin enviar'); }
      lines.push(`WhatsApp a <b>${esc(a.to)}</b> (${tierName(a.tier)}): enviado ${hhmm(a.sent_at || a.requested_at)} · entregado ${a.delivered_at ? OK + ' ' + hhmm(a.delivered_at) : '—'} · ${st}`);
    } else if (a.kind === 'assigned_notice') {
      lines.push(`Aviso de asignación a <b>${esc(a.to)}</b>: ${a.delivered_at ? OK + ' entregado ' + hhmm(a.delivered_at) : (a.failed_at ? BAD + ' falló' : WAIT + ' ' + a.status)}`);
    }
  }
  const sandyEv = events.find(e => e.type === 'manager_assigned');
  if (l.assigned_agent_id) {
    if (claimed) nClaim++; else if (l.assigned_role === 'manager') nSandy++; else nClaim++;
    const how = claimed ? 'tocó Tomo' : (sandyEv ? 'nadie tomó → responsable final' + (sandyEv.reason ? ' (' + esc(sandyEv.reason) + ')' : '') : 'asignación directa');
    lines.push(`<b>Asignado a ${esc(l.assigned_name || l.assigned_agent_id)}</b> ${hhmm(l.assigned_at)} · ${how}`);
  } else if (l.state === 'unassigned') {
    nUnassigned++;
    const ev = events.find(e => e.type === 'left_unassigned');
    lines.push(`<b>SIN ASIGNACIÓN</b> ${hhmm(l.unassigned_at)} · nadie tomó${ev && ev.reason ? ' (' + esc(ev.reason) + ')' : ''}`);
  } else {
    nOpen++;
    lines.push(`${WAIT} Sin responsable todavía · estado <code>${esc(l.state)}</code>${l.routing_tier ? ' · turno de ' + tierName(l.routing_tier) : ''}`);
    if (l.route_dispatch_status === 'manual_review') problems.push('Solicitud en revisión manual (sin propiedad EasyBroker): nadie la va a recibir');
    if (l.expires_at && mins(l.expires_at, row.until) > 2) problems.push('Oferta vencida hace ' + mins(l.expires_at, row.until) + ' min sin escalar');
  }
  const note = effects.filter(f => f.kind === 'note'), att = effects.filter(f => f.kind === 'attended');
  const noteOk = note.some(f => f.ok), attOk = att.some(f => f.ok);
  const isUnassigned = l.state === 'unassigned';
  if (effects.length) {
    if (isUnassigned && noteOk && !att.length) {
      nEbOk++;
      lines.push(`EasyBroker: nota SIN ASIGNACIÓN ${OK} ${hhmm(note.find(f => f.ok).at)} · Atendida omitida`);
    } else {
      if (noteOk && attOk) nEbOk++;
      lines.push(`EasyBroker: nota RESPONSABLE ${noteOk ? OK + ' ' + hhmm(note.find(f => f.ok).at) : (note.length ? BAD + ' falló' : WAIT)} · Atendida ${attOk ? OK + ' ' + hhmm(att.find(f => f.ok).at) : (att.length ? BAD + ' falló' : WAIT)}`);
    }
    if (note.length && !noteOk) problems.push('Nota en EasyBroker falló');
    if (att.length && !attOk) problems.push('Marcar Atendida en EasyBroker falló');
  } else if (l.assigned_agent_id || isUnassigned) {
    const age = mins(l.assigned_at || l.unassigned_at, row.until);
    const afterWord = isUnassigned ? 'después de quedar sin asignación' : 'después de asignar';
    lines.push(`EasyBroker: ${age > 20 ? BAD + ' sin nota ' + age + ' min ' + afterWord : WAIT + ' nota pendiente (worker cada 1 min)'}`);
    if (age > 20 && /^EB-/i.test(l.property_id || '')) problems.push('Sin nota en EasyBroker ' + age + ' min ' + afterWord);
  }
  const n24 = l.i24_note;
  if (n24) {
    if (n24.state === 'succeeded') lines.push(`Nota en Inmuebles24 ${OK} ${hhmm(n24.at)} · <i>${esc(n24.text)}</i>`);
    else if (n24.state === 'manual_review') { lines.push(`Nota en Inmuebles24 ${BAD} agotó ${n24.attempts} intentos`); problems.push('Nota en Inmuebles24 no se pudo escribir'); }
    else lines.push(`Nota en Inmuebles24 ${WAIT} pendiente${n24.attempts ? ' (' + n24.attempts + ' intento(s))' : ''} · <i>${esc(n24.text)}</i>`);
  }
  if (problems.length) nProblem++;
  const title = `#${l.opportunity_id} · ${esc(l.lead_name || 'Sin nombre')} · ${esc(l.lead_phone || '')} · ${esc(l.property_id || 'sin ID EB')}${l.property_title ? ' · ' + esc(l.property_title) : ''}`;
  tcards.push([stripHtml(title), ...(problems.length ? ['⚠ ' + problems.join(' · ')] : []), ...lines.map(stripHtml)].join('\n'));
  return `<div style="border:1px solid ${problems.length ? '#C8483B' : '#D3DBE2'};border-left:6px solid ${problems.length ? '#C8483B' : (l.assigned_agent_id ? '#157A73' : '#E09A1B')};border-radius:6px;padding:12px 14px;margin:10px 0">
<div style="font-weight:700;font-size:15px;margin-bottom:6px">${title}</div>
${problems.length ? '<div style="color:#C8483B;font-weight:700;margin-bottom:6px">&#9888; ' + problems.map(esc).join(' · ') + '</div>' : ''}
<div style="font-size:13px;line-height:1.6">${lines.join('<br>')}</div></div>`;
});

const label = 'Reporte del día';
const dayStr = new Date(row.until).toLocaleDateString('es-MX', {timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long'});
const summary = `${leads.length} lead(s) con actividad · ${nClaim} tomado(s) por asesor/guardia · ${nUnassigned} sin asignación${nSandy ? ' · ' + nSandy + ' a Sandy' : ''} · ${nOpen} en oferta · ${nEbOk} con EasyBroker cerrado · ${nProblem} con problema`;
const healthHtml = `<div style="font-size:13px;color:#5D6C79">Scraper último OK ${hhmm(h.scraper_last_ok)} (hace ${scraperAge ?? '?'} min) · en cola nocturna ${h.queued_night} · ofertas atoradas ${h.stuck_requested} · vencidas sin escalar ${h.stuck_expired}</div>`;
const html = `<div style="font-family:system-ui,Segoe UI,Arial,sans-serif;max-width:760px;color:#16232E">
<div style="font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#5D6C79">Inmobiliaria24 · BYG · Lead Routing V3</div>
<h2 style="margin:4px 0 8px">${label} · ${dayStr}</h2>
${alerts.length ? '<div style="background:#F8E1DD;border:1px solid #C8483B;color:#7A2A22;padding:10px 12px;border-radius:6px;font-weight:700">&#9888; ' + alerts.map(esc).join('<br>&#9888; ') + '</div>' : '<div style="background:#DCEFEC;border:1px solid #157A73;color:#0F4F4A;padding:8px 12px;border-radius:6px">&#10004; Motores sanos: scraper, envíos y reloj de escalación</div>'}
<p style="font-size:14px"><b>${summary}</b></p>
${healthHtml}
${leads.length ? cards.join('') : '<p style="color:#5D6C79">Sin leads con actividad en esta ventana.</p>'}
<p style="font-size:11px;color:#5D6C79;margin-top:18px">Hechos leídos directamente de Supabase (oportunidades, intentos de entrega, eventos, efectos EasyBroker). Horas en CDMX. Generado por WF24.</p></div>`;
const subject = `[V3] Reporte del día · ${leads.length} leads · ${nClaim} tomados · ${nUnassigned} sin asignación${nProblem ? ' · ' + nProblem + ' con problema' : ''}${alerts.length ? ' · ALERTA' : ''}`;

const unassignedList = leads.filter(l => l.state === 'unassigned').map(l => `#${l.opportunity_id} ${l.lead_name || 'Sin nombre'} · ${l.lead_phone || ''} · ${l.property_id || 'sin ID EB'}`).join(' | ');

const LIMIT = 4000;
const FOOTER = 'Hechos leídos directamente de Supabase (oportunidades, intentos de entrega, eventos, efectos EasyBroker). Horas en CDMX. Generado por WF24.';
const headerText = [
  `📋 ${label} · ${dayStr}`,
  alerts.length ? alerts.map(a => '⚠ ' + a).join('\n') : '✔ Motores sanos: scraper, envíos y reloj de escalación',
  summary,
  stripHtml(healthHtml),
].join('\n');
const pieces = [headerText, ...(tcards.length ? tcards : ['Sin leads con actividad en esta ventana.'])]
  .map(p => p.length > LIMIT ? p.slice(0, LIMIT - 1) + '…' : p);
const text_chunks = [];
for (const p of pieces) {
  const i = text_chunks.length - 1;
  if (i >= 0 && text_chunks[i].length + 2 + p.length <= LIMIT) text_chunks[i] += '\n\n' + p;
  else text_chunks.push(p);
}
const last = text_chunks.length - 1;
if (text_chunks[last].length + 2 + FOOTER.length <= LIMIT) text_chunks[last] += '\n\n' + FOOTER;
else text_chunks.push(FOOTER);

const tpl = [
  dayStr,
  String(leads.length),
  String(nClaim),
  String(nUnassigned),
  String(nProblem),
  alerts.length ? clip(oneLine(alerts.join(' · ')), 200) : 'sanos',
  unassignedList ? clip(oneLine(unassignedList), 600) : 'Ninguno',
];

return { subject, html, text_chunks, tpl, mode, n_leads: leads.length, n_problem: nProblem, alerts };
}

if (typeof module !== 'undefined') module.exports = { render };
