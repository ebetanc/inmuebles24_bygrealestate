"""Build WF24 - V3 Monitor Diario (n8n JSON).

Every 30 min 08:00-20:30 CDMX: email digest of every lead with activity in the
window (offer sent/delivered, who tapped Tomo, assignment, EasyBroker note).
20:45 CDMX: full-day report. Skips the email when a window has no activity and
no health alert. Run: python build_wf24_monitor.py > WF24_v3_monitor.json
"""
import json

PG_CRED = {"postgres": {"id": "dEHKygi1neTNvPtH", "name": "Postgres account BYG project"}}
GMAIL_CRED = {"gmailOAuth2": {"id": "Hx7tXWjVzyLEwMnJ", "name": "Gmail ESTEBAN"}}
TO = "esteban.betanc@gmail.com"

SQL = r"""SET LOCAL statement_timeout = '20s';
WITH p AS (
  SELECT CASE WHEN $1 = 'day'
    THEN (date_trunc('day', now() AT TIME ZONE 'America/Mexico_City')) AT TIME ZONE 'America/Mexico_City'
    ELSE now() - interval '31 minutes' END AS since
),
active AS (
  SELECT DISTINCT o.opportunity_id
  FROM public.lead_routing_opportunities o, p
  WHERE o.v3_enabled AND (
    o.created_at >= p.since OR o.updated_at >= p.since
    OR EXISTS (SELECT 1 FROM public.lead_routing_delivery_attempts a WHERE a.opportunity_id=o.opportunity_id
               AND GREATEST(a.requested_at, COALESCE(a.delivered_at,a.requested_at), COALESCE(a.claimed_at,a.requested_at), COALESCE(a.failed_at,a.requested_at)) >= p.since)
    OR EXISTS (SELECT 1 FROM public.lead_routing_events ev WHERE ev.opportunity_id=o.opportunity_id AND ev.occurred_at >= p.since)
    OR EXISTS (SELECT 1 FROM public.easybroker_i24_request_links l JOIN public.easybroker_effect_attempts fx ON fx.eb_request_id=l.eb_request_id
               WHERE l.opportunity_id=o.opportunity_id AND fx.finished_at >= p.since)
  )
),
leads AS (
  SELECT o.opportunity_id, o.state, o.routing_tier, o.property_id, o.assigned_agent_id, ag.name AS assigned_name, ag.role AS assigned_role,
    o.created_at, o.assigned_at, o.accepted_at, o.expires_at, o.v3_night_queued_at, o.v3_night_released_at,
    COALESCE(NULLIF(c.lead_name,''), NULLIF(e.offer_context->>'name',''), e.offer_context->>'lead_name') AS lead_name,
    COALESCE(NULLIF(c.lead_phone,''), o.e164_phone, e.offer_context->>'phone') AS lead_phone,
    COALESCE(e.offer_context->>'property_title', NULLIF(concat_ws(' · ', e.offer_context->>'property', e.offer_context->>'address'),''), c.current_property) AS property_title,
    e.route_dispatch_status, e.contactado_status,
    (SELECT json_agg(json_build_object('tier',a.routing_tier,'kind',a.delivery_kind,'to',COALESCE(ta.name,a.target_agent_id),'to_id',a.target_agent_id,'status',a.status,
        'requested_at',a.requested_at,'sent_at',a.provider_accepted_at,'delivered_at',a.delivered_at,'claimed_at',a.claimed_at,'failed_at',a.failed_at) ORDER BY a.requested_at)
     FROM public.lead_routing_delivery_attempts a LEFT JOIN public.agents ta ON ta.agent_id=a.target_agent_id WHERE a.opportunity_id=o.opportunity_id) AS attempts,
    (SELECT json_agg(json_build_object('type',ev.event_type,'actor',COALESCE(ea.name,ev.actor_id),'at',ev.occurred_at,'reason',COALESCE(ev.metadata->>'reason','')) ORDER BY ev.occurred_at)
     FROM public.lead_routing_events ev LEFT JOIN public.agents ea ON ea.agent_id=ev.actor_id
     WHERE ev.opportunity_id=o.opportunity_id AND ev.event_type IN ('detected','i24_contacted','route_dispatched','delivery_requested','delivery_confirmed','accepted','claim_accepted','escalated','manager_assigned','missing_owner_data','route_dispatch_manual_review','route_dispatch_failed','night_queue_activated','assigned_notice_delivered','unassigned_alerted')) AS events,
    (SELECT json_agg(json_build_object('kind',fx.effect_kind,'ok',fx.ok,'at',fx.finished_at,'status',fx.evidence->>'status','eb_request_id',fx.eb_request_id) ORDER BY fx.finished_at)
     FROM public.easybroker_i24_request_links l JOIN public.easybroker_effect_attempts fx ON fx.eb_request_id=l.eb_request_id WHERE l.opportunity_id=o.opportunity_id) AS eb_effects
  FROM active x
  JOIN public.lead_routing_opportunities o ON o.opportunity_id=x.opportunity_id
  LEFT JOIN public.agents ag ON ag.agent_id=o.assigned_agent_id
  LEFT JOIN public.conversations c ON c.conversation_id=o.conversation_id
  LEFT JOIN LATERAL (SELECT offer_context, route_dispatch_status, contactado_status FROM public.i24_capture_events e WHERE e.opportunity_id=o.opportunity_id ORDER BY capture_event_id DESC LIMIT 1) e ON true
  ORDER BY o.opportunity_id
),
health AS (
  SELECT (SELECT max(completed_at) FROM public.scrape_logs WHERE status='ok') AS scraper_last_ok,
    (SELECT count(*) FROM public.lead_routing_delivery_attempts WHERE delivery_kind='offer' AND status='requested' AND requested_at < now()-interval '3 minutes') AS stuck_requested,
    (SELECT count(*) FROM public.lead_routing_opportunities WHERE assigned_agent_id IS NULL AND current_delivery_attempt_id IS NOT NULL AND expires_at IS NOT NULL AND expires_at < now()-interval '90 seconds') AS stuck_expired,
    (SELECT count(*) FROM public.lead_routing_opportunities WHERE state='queued_night') AS queued_night,
    (SELECT count(*) FROM public.i24_capture_events WHERE route_dispatch_status='manual_review' AND happened_at >= (SELECT since FROM p)) AS manual_review_new
)
SELECT $1 AS mode, (SELECT since FROM p) AS since, now() AS until,
  COALESCE((SELECT json_agg(l) FROM leads l), '[]'::json) AS leads,
  (SELECT row_to_json(h) FROM health h) AS health;"""

JS = r"""
const row = $input.first().json;
const leads = Array.isArray(row.leads) ? row.leads : [];
const h = row.health || {};
const mode = row.mode;
const TZ = 'America/Mexico_City';
const hhmm = (v) => v ? new Date(v).toLocaleTimeString('es-MX', {timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false}) : '—';
const dmy = (v) => v ? new Date(v).toLocaleDateString('es-MX', {timeZone: TZ, day: '2-digit', month: 'short'}) : '';
const mins = (a, b) => (a && b) ? Math.round((new Date(b) - new Date(a)) / 60000) : null;
const esc = (s) => String(s ?? '').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
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

let nNew = 0, nClaim = 0, nSandy = 0, nOpen = 0, nEbOk = 0, nProblem = 0;
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
  } else {
    nOpen++;
    lines.push(`${WAIT} Sin responsable todavía · estado <code>${esc(l.state)}</code>${l.routing_tier ? ' · turno de ' + tierName(l.routing_tier) : ''}`);
    if (l.route_dispatch_status === 'manual_review') problems.push('Solicitud en revisión manual (sin propiedad EasyBroker): nadie la va a recibir');
    if (l.expires_at && mins(l.expires_at, row.until) > 2) problems.push('Oferta vencida hace ' + mins(l.expires_at, row.until) + ' min sin escalar');
  }
  const note = effects.filter(f => f.kind === 'note'), att = effects.filter(f => f.kind === 'attended');
  const noteOk = note.some(f => f.ok), attOk = att.some(f => f.ok);
  if (effects.length) {
    if (noteOk && attOk) nEbOk++;
    lines.push(`EasyBroker: nota RESPONSABLE ${noteOk ? OK + ' ' + hhmm(note.find(f => f.ok).at) : (note.length ? BAD + ' falló' : WAIT)} · Atendida ${attOk ? OK + ' ' + hhmm(att.find(f => f.ok).at) : (att.length ? BAD + ' falló' : WAIT)}`);
    if (note.length && !noteOk) problems.push('Nota en EasyBroker falló');
    if (att.length && !attOk) problems.push('Marcar Atendida en EasyBroker falló');
  } else if (l.assigned_agent_id) {
    const age = mins(l.assigned_at, row.until);
    lines.push(`EasyBroker: ${age > 20 ? BAD + ' sin nota ' + age + ' min después de asignar' : WAIT + ' nota pendiente (worker cada 1 min)'}`);
    if (age > 20 && /^EB-/i.test(l.property_id || '')) problems.push('Sin nota en EasyBroker ' + age + ' min después de asignar');
  }
  if (problems.length) nProblem++;
  const title = `#${l.opportunity_id} · ${esc(l.lead_name || 'Sin nombre')} · ${esc(l.lead_phone || '')} · ${esc(l.property_id || 'sin ID EB')}${l.property_title ? ' · ' + esc(l.property_title) : ''}`;
  return `<div style="border:1px solid ${problems.length ? '#C8483B' : '#D3DBE2'};border-left:6px solid ${problems.length ? '#C8483B' : (l.assigned_agent_id ? '#157A73' : '#E09A1B')};border-radius:6px;padding:12px 14px;margin:10px 0">
<div style="font-weight:700;font-size:15px;margin-bottom:6px">${title}</div>
${problems.length ? '<div style="color:#C8483B;font-weight:700;margin-bottom:6px">&#9888; ' + problems.map(esc).join(' · ') + '</div>' : ''}
<div style="font-size:13px;line-height:1.6">${lines.join('<br>')}</div></div>`;
});

const label = mode === 'day' ? 'Reporte del día' : `Ventana ${hhmm(row.since)}–${hhmm(row.until)}`;
const dayStr = new Date(row.until).toLocaleDateString('es-MX', {timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long'});
const summary = `${leads.length} lead(s) con actividad · ${nClaim} tomado(s) por asesor/guardia · ${nSandy} a Sandy · ${nOpen} en oferta · ${nEbOk} con nota+Atendida en EasyBroker · ${nProblem} con problema`;
const healthHtml = `<div style="font-size:13px;color:#5D6C79">Scraper último OK ${hhmm(h.scraper_last_ok)} (hace ${scraperAge ?? '?'} min) · en cola nocturna ${h.queued_night} · ofertas atoradas ${h.stuck_requested} · vencidas sin escalar ${h.stuck_expired}</div>`;
const html = `<div style="font-family:system-ui,Segoe UI,Arial,sans-serif;max-width:760px;color:#16232E">
<div style="font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#5D6C79">Inmobiliaria24 · BYG · Lead Routing V3</div>
<h2 style="margin:4px 0 8px">${label} · ${dayStr}</h2>
${alerts.length ? '<div style="background:#F8E1DD;border:1px solid #C8483B;color:#7A2A22;padding:10px 12px;border-radius:6px;font-weight:700">&#9888; ' + alerts.map(esc).join('<br>&#9888; ') + '</div>' : '<div style="background:#DCEFEC;border:1px solid #157A73;color:#0F4F4A;padding:8px 12px;border-radius:6px">&#10004; Motores sanos: scraper, envíos y reloj de escalación</div>'}
<p style="font-size:14px"><b>${summary}</b></p>
${healthHtml}
${leads.length ? cards.join('') : '<p style="color:#5D6C79">Sin leads con actividad en esta ventana.</p>'}
<p style="font-size:11px;color:#5D6C79;margin-top:18px">Hechos leídos directamente de Supabase (oportunidades, intentos de entrega, eventos, efectos EasyBroker). Horas en CDMX. Generado por WF24.</p></div>`;
const subject = `[V3] ${mode === 'day' ? 'Reporte del día' : hhmm(row.until)} · ${leads.length} leads · ${nClaim + nSandy} asignados${nProblem ? ' · ' + nProblem + ' con problema' : ''}${alerts.length ? ' · ALERTA' : ''}`;
// Half-hour mail only when something needs eyes: new lead, live problem or health alert.
const send = mode === 'day' || nNew > 0 || nProblem > 0 || alerts.length > 0;
return [{ json: { send, subject, html, mode, n_leads: leads.length, n_problem: nProblem, alerts } }];
"""

def node(name, type_, ver, params, pos, extra=None):
    n = {"parameters": params, "name": name, "type": type_, "typeVersion": ver, "position": pos}
    if extra:
        n.update(extra)
    return n

nodes = [
    node("Cada 30 min (08-20 CDMX)", "n8n-nodes-base.scheduleTrigger", 1.2,
         {"rule": {"interval": [{"field": "cronExpression", "expression": "*/30 8-20 * * *"}]}}, [0, 0]),
    node("Fin del día 20:45", "n8n-nodes-base.scheduleTrigger", 1.2,
         {"rule": {"interval": [{"field": "cronExpression", "expression": "45 20 * * *"}]}}, [0, 240]),
    node("Prueba manual (webhook)", "n8n-nodes-base.webhook", 2,
         {"httpMethod": "GET", "path": "v3-monitor-0902-k7q2x9", "responseMode": "onReceived", "options": {}}, [0, 480],
         {"webhookId": "a7c1d2e3-0902-4a30-8b6d-0000000wf024"}),
    node("Modo ventana", "n8n-nodes-base.set", 3.4,
         {"assignments": {"assignments": [{"id": "a1", "name": "mode", "value": "window", "type": "string"}]}, "options": {}}, [240, 0]),
    node("Modo día", "n8n-nodes-base.set", 3.4,
         {"assignments": {"assignments": [{"id": "a2", "name": "mode", "value": "day", "type": "string"}]}, "options": {}}, [240, 240]),
    node("Leer actividad V3", "n8n-nodes-base.postgres", 2.5,
         {"operation": "executeQuery", "query": SQL, "options": {"queryReplacement": "={{ [$json.mode] }}", "connectionTimeout": 15}},
         [480, 120], {"credentials": PG_CRED, "retryOnFail": True, "maxTries": 2, "waitBetweenTries": 5000}),
    node("Armar correo", "n8n-nodes-base.code", 2, {"jsCode": JS}, [720, 120]),
    node("¿Enviar?", "n8n-nodes-base.if", 2.2,
         {"conditions": {"options": {"caseSensitive": True, "typeValidation": "strict", "version": 2},
                         "conditions": [{"id": "c1", "leftValue": "={{ $json.send }}", "rightValue": True,
                                         "operator": {"type": "boolean", "operation": "true"}}],
                         "combinator": "and"}, "options": {}}, [960, 120]),
    node("Enviar correo (Gmail)", "n8n-nodes-base.gmail", 2.1,
         {"sendTo": TO, "subject": "={{ $json.subject }}", "emailType": "html", "message": "={{ $json.html }}", "options": {}},
         [1200, 60], {"credentials": GMAIL_CRED, "retryOnFail": True, "maxTries": 2, "waitBetweenTries": 5000}),
    node("Sin actividad", "n8n-nodes-base.noOp", 1, {}, [1200, 240]),
]

connections = {
    "Cada 30 min (08-20 CDMX)": {"main": [[{"node": "Modo ventana", "type": "main", "index": 0}]]},
    "Fin del día 20:45": {"main": [[{"node": "Modo día", "type": "main", "index": 0}]]},
    "Prueba manual (webhook)": {"main": [[{"node": "Modo día", "type": "main", "index": 0}]]},
    "Modo ventana": {"main": [[{"node": "Leer actividad V3", "type": "main", "index": 0}]]},
    "Modo día": {"main": [[{"node": "Leer actividad V3", "type": "main", "index": 0}]]},
    "Leer actividad V3": {"main": [[{"node": "Armar correo", "type": "main", "index": 0}]]},
    "Armar correo": {"main": [[{"node": "¿Enviar?", "type": "main", "index": 0}]]},
    "¿Enviar?": {"main": [[{"node": "Enviar correo (Gmail)", "type": "main", "index": 0}],
                          [{"node": "Sin actividad", "type": "main", "index": 0}]]},
}

wf = {
    "id": "WF24V3MonitorDia",
    "name": "WF24 - V3 Monitor Diario (Email)",
    "nodes": nodes,
    "connections": connections,
    "settings": {"executionOrder": "v1", "timezone": "America/Mexico_City", "errorWorkflow": "He95yJflKVspGFyb",
                 "callerPolicy": "workflowsFromSameOwner", "executionTimeout": 90},
    "staticData": None,
    "pinData": {},
    "tags": [],
}

if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(wf, ensure_ascii=False, indent=2))
