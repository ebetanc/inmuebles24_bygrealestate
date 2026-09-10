"""Build WF24 - V3 Monitor Diario (n8n JSON).

20:45 CDMX: full-day report. Manual: GET webhook `v3-monitor-0902-k7q2x9`.
Run: python build_wf24_monitor.py > WF24_v3_monitor.json
"""
import json
from pathlib import Path

PG_CRED = {"postgres": {"id": "dEHKygi1neTNvPtH", "name": "Postgres account BYG project"}}
GMAIL_CRED = {"gmailOAuth2": {"id": "Hx7tXWjVzyLEwMnJ", "name": "Gmail ESTEBAN"}}
TO = "esteban.betanc@gmail.com"

SQL = r"""SET LOCAL statement_timeout = '20s';
WITH p AS (
  SELECT (date_trunc('day', now() AT TIME ZONE 'America/Mexico_City')) AT TIME ZONE 'America/Mexico_City' AS since
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

# Cuerpo literal con islas {{ }}, como WF13: un `}}` dentro de una isla cierra la
# expresión antes de tiempo y n8n falla con "invalid syntax" (probado en producción).
WA_BODY = """={
  "messaging_product": "whatsapp",
  "recipient_type": "individual",
  "to": "{{ $json.phone }}",
  "type": "template",
  "template": {
    "name": "reporte_diario_v3",
    "language": { "code": "es_MX" },
    "components": [{
      "type": "body",
      "parameters": [
        { "type": "text", "text": {{ JSON.stringify(String($('Armar correo').first().json.tpl[0] ?? '')) }} },
        { "type": "text", "text": {{ JSON.stringify(String($('Armar correo').first().json.tpl[1] ?? '')) }} },
        { "type": "text", "text": {{ JSON.stringify(String($('Armar correo').first().json.tpl[2] ?? '')) }} },
        { "type": "text", "text": {{ JSON.stringify(String($('Armar correo').first().json.tpl[3] ?? '')) }} },
        { "type": "text", "text": {{ JSON.stringify(String($('Armar correo').first().json.tpl[4] ?? '')) }} },
        { "type": "text", "text": {{ JSON.stringify(String($('Armar correo').first().json.tpl[5] ?? '')) }} },
        { "type": "text", "text": {{ JSON.stringify(String($('Armar correo').first().json.tpl[6] ?? '')) }} }
      ]
    }]
  }
}"""

RENDER_SRC = open(Path(__file__).with_name("wf24_render.js"), encoding="utf-8").read()
JS = RENDER_SRC + "\nconst row = $input.first().json;\nreturn [{ json: { send: true, ...render(row) } }];\n"


def node(name, type_, ver, params, pos, extra=None):
    n = {"parameters": params, "name": name, "type": type_, "typeVersion": ver, "position": pos}
    if extra:
        n.update(extra)
    return n

nodes = [
    node("Fin del día 20:45", "n8n-nodes-base.scheduleTrigger", 1.2,
         {"rule": {"interval": [{"field": "cronExpression", "expression": "45 20 * * *"}]}}, [0, 240]),
    node("Prueba manual (webhook)", "n8n-nodes-base.webhook", 2,
         {"httpMethod": "GET", "path": "v3-monitor-0902-k7q2x9", "responseMode": "onReceived", "options": {}}, [0, 480],
         {"webhookId": "a7c1d2e3-0902-4a30-8b6d-0000000wf024"}),
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
         [1200, 60], {"credentials": GMAIL_CRED, "retryOnFail": True, "maxTries": 2, "waitBetweenTries": 5000,
                      # Gmail caído no debe cancelar el envío por WhatsApp: las dos patas son independientes.
                      "onError": "continueRegularOutput"}),
    node("Sin actividad", "n8n-nodes-base.noOp", 1, {}, [1200, 240]),
    # ponytail: el array se manda como JSON y se expande en SQL; no dependemos de
    # cómo el nodo Postgres serialice un array de JS en un parámetro text[].
    node("Guardar reporte", "n8n-nodes-base.postgres", 2.5,
         {"operation": "executeQuery",
          "query": "INSERT INTO public.v3_daily_reports(report_date,text_chunks,summary) VALUES ((now() AT TIME ZONE 'America/Mexico_City')::date,(SELECT array_agg(x ORDER BY ord) FROM jsonb_array_elements_text($1::jsonb) WITH ORDINALITY t(x,ord)),$2::jsonb) ON CONFLICT (report_date) DO UPDATE SET text_chunks=EXCLUDED.text_chunks,summary=EXCLUDED.summary,updated_at=now() RETURNING report_date;",
          "options": {"queryReplacement": "={{ [JSON.stringify($('Armar correo').first().json.text_chunks), JSON.stringify({tpl: $('Armar correo').first().json.tpl, subject: $('Armar correo').first().json.subject})] }}",
                      "connectionTimeout": 15}},
         [1440, 60], {"credentials": PG_CRED, "retryOnFail": True, "maxTries": 2, "waitBetweenTries": 5000}),
    node("Leer destinatarios", "n8n-nodes-base.postgres", 2.5,
         {"operation": "executeQuery", "query": "SELECT phone,name FROM public.v3_report_recipients WHERE active ORDER BY phone;",
          "options": {"connectionTimeout": 15}},
         [1680, 60], {"credentials": PG_CRED}),
    node("Enviar WhatsApp", "n8n-nodes-base.httpRequest", 4.2,
         {"method": "POST",
          "url": "={{ $env.WA_CLOUD_API_BASE_URL + '/' + $env.WA_API_VERSION + '/' + $env.WA_PHONE_NUMBER_ID + '/messages' }}",
          "sendHeaders": True,
          "headerParameters": {"parameters": [{"name": "Authorization", "value": "=Bearer {{ $env.WA_ACCESS_TOKEN }}"},
                                              {"name": "Content-Type", "value": "application/json"}]},
          "sendBody": True, "specifyBody": "json",
          "jsonBody": WA_BODY,
          "options": {"timeout": 10000}},
         [1920, 60], {"onError": "continueRegularOutput", "retryOnFail": True, "maxTries": 3, "waitBetweenTries": 3000}),
    # Con onError el item de fallo trae `error` (objeto o texto) y ningún `messages`:
    # las dos formas caen en status='failed' con el cuerpo recortado a 500 chars.
    node("Registrar envío", "n8n-nodes-base.postgres", 2.5,
         {"operation": "executeQuery",
          "query": "INSERT INTO public.v3_report_sends(report_date,phone,wamid,status,error) VALUES ((now() AT TIME ZONE 'America/Mexico_City')::date,$1,$2,$3,$4);",
          "options": {"queryReplacement": "={{ [$('Leer destinatarios').item.json.phone, $json.messages?.[0]?.id || null, $json.messages?.[0]?.id ? 'accepted' : 'failed', $json.messages?.[0]?.id ? null : JSON.stringify($json.error || $json).slice(0,500)] }}",
                      "connectionTimeout": 15}},
         [2160, 60], {"credentials": PG_CRED}),
]

connections = {
    "Fin del día 20:45": {"main": [[{"node": "Modo día", "type": "main", "index": 0}]]},
    "Prueba manual (webhook)": {"main": [[{"node": "Modo día", "type": "main", "index": 0}]]},
    "Modo día": {"main": [[{"node": "Leer actividad V3", "type": "main", "index": 0}]]},
    "Leer actividad V3": {"main": [[{"node": "Armar correo", "type": "main", "index": 0}]]},
    "Armar correo": {"main": [[{"node": "¿Enviar?", "type": "main", "index": 0}]]},
    "¿Enviar?": {"main": [[{"node": "Enviar correo (Gmail)", "type": "main", "index": 0}],
                          [{"node": "Sin actividad", "type": "main", "index": 0}]]},
    "Enviar correo (Gmail)": {"main": [[{"node": "Guardar reporte", "type": "main", "index": 0}]]},
    "Guardar reporte": {"main": [[{"node": "Leer destinatarios", "type": "main", "index": 0}]]},
    "Leer destinatarios": {"main": [[{"node": "Enviar WhatsApp", "type": "main", "index": 0}]]},
    "Enviar WhatsApp": {"main": [[{"node": "Registrar envío", "type": "main", "index": 0}]]},
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
