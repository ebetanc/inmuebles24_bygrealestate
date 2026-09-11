# Reporte WhatsApp · SIN ASIGNACIÓN · Nota i24 — Plan de ejecución

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Silenciar correos de media hora y nocturnos, mandar el reporte diario V3 por WhatsApp, cerrar leads sin tomador como `unassigned` (sin Sandy) y escribir nota interna en Inmuebles24 por cada cierre.

**Architecture:** Cuatro fases independientes con gate de producción cada una. n8n se modifica solo desde el export vivo y por CLI; Supabase por migraciones con prueba de rollback; el Pi por git tras reconciliar sus cambios privados. Spec: `docs/superpowers/specs/2026-09-10-reporte-whatsapp-sin-asignacion-nota-i24-design.md`.

**Tech Stack:** n8n (JSON generado por `build_wf24_monitor.py`, Code nodes JS), Meta WhatsApp Cloud API (plantillas + texto), Supabase Postgres (plpgsql), Python 3.12 + Playwright en el Pi, pytest.

**Modelos sugeridos:** Sonnet para tareas de n8n mecánicas, deploy y descubrimiento; Opus para SQL, renderer JS y worker Python.

**Reglas fijas para todo subagente:**
- n8n: `ssh root@69.62.108.2`, `docker exec root-n8n-1 n8n export:workflow --id=<ID> --output=/tmp/<ID>.json`, `docker cp` a local, diff contra `whatsapp-agent/workflows/`, aplicar SOLO el cambio, `import:workflow --input=` (JSON con `id`), `publish:workflow --id=`, `docker restart root-n8n-1`. Nunca importar el JSON del repo con credenciales placeholder.
- Supabase: cada migración nueva se prueba con la receta docker PG17 (`tests/sql`, ver `README.md`) con rollback antes de aplicarla en prod.
- Pi: no hacer `git pull` hasta la Tarea 3.0 (reconciliación).
- Commits: uno por tarea, mensaje en inglés, con la línea de atribución de la sesión.

---

## Fase 0 · Silenciar correos (Sonnet)

### Task 0.1: Quitar el disparador de 30 min en WF24

**Files:**
- Modify: `whatsapp-agent/workflows/build_wf24_monitor.py:1-7, 16-18, 147-161, 172-182, 199-202`
- Regenerate: `whatsapp-agent/workflows/WF24_v3_monitor.json`

- [ ] **Step 1: Editar el generador.** Borrar los nodos `Cada 30 min (08-20 CDMX)` y `Modo ventana` y sus dos entradas en `connections`. En `SQL`, sustituir el CTE `p` por:

```sql
WITH p AS (
  SELECT (date_trunc('day', now() AT TIME ZONE 'America/Mexico_City')) AT TIME ZONE 'America/Mexico_City' AS since
),
```

En `JS`: `const label = 'Reporte del día';`, `const subject = \`[V3] Reporte del día · ...\`` (quitar el ternario de `mode`), y `const send = true;` (dejar el IF `¿Enviar?` intacto para no tocar conexiones). Actualizar el docstring: "20:45 CDMX: full-day report. Manual: GET webhook."

- [ ] **Step 2: Regenerar y verificar.**

```bash
python whatsapp-agent/workflows/build_wf24_monitor.py > whatsapp-agent/workflows/WF24_v3_monitor.json
python -c "import json;w=json.load(open('whatsapp-agent/workflows/WF24_v3_monitor.json',encoding='utf-8'));print([n['name'] for n in w['nodes']])"
```
Expected: sin `Cada 30 min (08-20 CDMX)` ni `Modo ventana`; `PYTHONPATH=src python -m pytest -q tests/test_v3_workflow_json_contract.py` pasa.

- [ ] **Step 3: Desplegar desde el export vivo.** Exportar `WF24V3MonitorDia`, comprobar con `python scripts/n8n_control.py diff` que el vivo == repo anterior salvo credenciales; sobre el export vivo eliminar los dos nodos + conexiones y sustituir `query`/`jsCode` por los regenerados; import, publish, restart.

- [ ] **Step 4: Verificar.** `docker exec root-n8n-1 n8n export:workflow --id=WF24V3MonitorDia` → solo un `scheduleTrigger` (`45 20 * * *`). Al día siguiente: cero correos `[V3] HH:MM ·` en Gmail.

- [ ] **Step 5: Commit** `chore(wf24): drop half-hour window digest, keep 20:45 daily report`.

### Task 0.2: Silenciar timeouts nocturnos de WF23/WF20 en WF21

**Files:**
- Modify: `whatsapp-agent/workflows/WF21_error_handler.json` (nodo `Armar mensaje`, `jsCode`)

- [ ] **Step 1: Insertar el filtro** justo después de `const executionUrl=...;`:

```js
// Night freeze (n8n sqlite GC during other tenants' ingest) throws conn timeouts 00:00-03:00 CDMX; known, not actionable.
const cdmxHour=Number(new Intl.DateTimeFormat('en-US',{timeZone:'America/Mexico_City',hour:'numeric',hour12:false}).format(new Date()));
const nightTimeout=/WF23|WF20/.test(workflowName)&&/connection timeout|timed out|ETIMEDOUT|connection terminated/i.test(message)&&cdmxHour>=0&&cdmxHour<3;
if(nightTimeout)return [];
```

- [ ] **Step 2: Prueba local del predicado** con `node -e` copiando las tres líneas y fijando `workflowName='WF23 - Delivery Timeout Sweeper'`, `message='Connection terminated due to connection timeout'`, hora forzada 1 → `[]`; hora 10 → no filtra.

- [ ] **Step 3: Desplegar** (export vivo de `He95yJflKVspGFyb`, reemplazar solo `jsCode`, import, publish, restart).

- [ ] **Step 4: Verificar** mañana: cero correos `🔴 BYG: falló el workflow "WF23…"` entre 00:00 y 03:00 CDMX; un error de WF23 a media mañana (simulable con `n8n execute --id=MjfHw3tYE2qYgJfM` con Supabase pausado) sí llega.

- [ ] **Step 5: Commit** `chore(wf21): mute known night conn-timeout errors from WF23/WF20`.

---

## Fase 1 · Reporte por WhatsApp (Opus código, Sonnet deploy)

### Task 1.1: Tablas de destinatarios, reportes y envíos

**Files:**
- Create: `supabase/migrations/20260911100000_v3_daily_report_whatsapp.sql`
- Test: `tests/sql/test_v3_daily_report_whatsapp.sql` (mismo patrón que los `tests/sql/*.sql` existentes)

- [ ] **Step 1: Migración**

```sql
CREATE TABLE IF NOT EXISTS public.v3_report_recipients (
  phone text PRIMARY KEY CHECK (phone ~ '^[1-9][0-9]{7,14}$'),  -- E.164 digits without '+', same as agents.whatsapp_number
  name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.v3_daily_reports (
  report_date date PRIMARY KEY,
  text_chunks text[] NOT NULL,
  summary jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.v3_report_sends (
  id bigserial PRIMARY KEY,
  report_date date NOT NULL REFERENCES public.v3_daily_reports(report_date),
  phone text NOT NULL,
  wamid text,
  status text NOT NULL CHECK (status IN ('accepted','failed')),
  error text,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT,INSERT,UPDATE ON public.v3_report_recipients, public.v3_daily_reports, public.v3_report_sends TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.v3_report_sends_id_seq TO service_role;
-- Esteban first; client numbers are added later with a plain INSERT.
INSERT INTO public.v3_report_recipients(phone,name) VALUES ('33628457768','Esteban') ON CONFLICT DO NOTHING;
```
Número confirmado por el usuario el 2026-09-10; en `public.agents` existe como `agent_test_fr` / `TEST FR (Esteban)` con `whatsapp_number='33628457768'`.

- [ ] **Step 2: Prueba SQL** (rollback): insertar recipient válido (`33628457768` y `5215591970405`), rechazar `'+33628457768'` y `'abc'` (CHECK), upsert de `v3_daily_reports` dos veces mismo día → 1 fila, insert `v3_report_sends` con status inválido falla.

- [ ] **Step 3: Aplicar en prod** con `psql` (receta en memoria `eb-id-backfill`) tras pasar la prueba. Commit `feat(db): tables for daily WhatsApp report recipients and sends`.

### Task 1.2: Renderer de texto y parámetros de plantilla en WF24

**Files:**
- Modify: `whatsapp-agent/workflows/build_wf24_monitor.py` (`JS`)
- Create: `whatsapp-agent/workflows/test_wf24_render.mjs` + `whatsapp-agent/workflows/fixtures/wf24_leads_sample.json`

- [ ] **Step 1: Extraer el JS a `wf24_render.js`** como módulo puro: `function render(row) { ...; return { subject, html, text_chunks, tpl, summary } }` con `module.exports = { render }`. El generador lo lee con `open('wf24_render.js').read()` y le antepone `const row=$input.first().json;` y le pospone `return [{json:{send:true,...render(row)}}];`. Así el mismo código se prueba con `node`.

- [ ] **Step 2: Añadir el renderer de texto** dentro de `render`: por cada lead construir `tlines` en paralelo a `lines` usando `stripHtml = s => s.replace(/<[^>]+>/g,'').replace(/&#10004;/g,'✔').replace(/&#10008;/g,'✘').replace(/&#8987;/g,'⌛').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>')`. Bloque por lead:

```js
const textCard = [title, ...(problems.length ? ['⚠ ' + problems.join(' · ')] : []), ...lines.map(stripHtml)].join('\n');
```
Cabecera: `📋 Reporte del día · ${dayStr}\n${alerts.length ? '⚠ ' + alerts.join('\n⚠ ') : '✔ Motores sanos'}\n${summary}\n${stripHtml(healthHtml)}`. `text_chunks`: concatenar tarjetas separadas por `\n\n` y partir en trozos ≤ 4000 caracteres cortando solo en límites de tarjeta (una tarjeta > 4000 se trunca con `…`).

- [ ] **Step 3: Parámetros de plantilla** (`tpl`), sin saltos de línea, con `oneLine = s => s.replace(/\s+/g,' ').trim()`:

```js
const unassignedList = leads.filter(l => l.state === 'unassigned' || (!l.assigned_agent_id && l.state !== 'queued_night'))
  .map(l => `#${l.opportunity_id} ${l.lead_name || 'Sin nombre'} · ${l.lead_phone || ''} · ${l.property_id || 'sin ID EB'}`).join(' | ');
const clip = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;
const tpl = [dayStr, String(leads.length), String(nClaim), String(nUnassigned), String(nProblem),
  alerts.length ? clip(oneLine(alerts.join(' · ')), 200) : 'sanos', unassignedList ? clip(oneLine(unassignedList), 600) : 'Ninguno'];
```
Hasta la Fase 2, `nUnassigned` = leads con `assigned_role === 'manager'` (Sandy) para que el reporte ya muestre la cifra que verá la clienta; en la Fase 2 pasa a `state === 'unassigned'`.

- [ ] **Step 4: Prueba** `test_wf24_render.mjs`: carga el fixture (copiar un `leads` real anonimizado del webhook manual), llama `render`, y afirma: `tpl.length === 7`, ningún `tpl[i]` contiene `\n`, `tpl[6].length <= 600`, cada `text_chunks[i].length <= 4000`, `text_chunks.join('')` contiene cada `#<id>` del fixture. Run: `node whatsapp-agent/workflows/test_wf24_render.mjs` → `ok`.

- [ ] **Step 5: Regenerar JSON, commit** `feat(wf24): plain-text renderer and template params for WhatsApp report`.

### Task 1.3: Nodos de envío WhatsApp en WF24

**Files:**
- Modify: `whatsapp-agent/workflows/build_wf24_monitor.py` (nodos + conexiones)

- [ ] **Step 1: Nodos nuevos** después de `Enviar correo (Gmail)` (la rama true del IF se conecta en serie: Gmail → Guardar reporte → Leer destinatarios → Enviar WhatsApp → Registrar envío):

```python
node("Guardar reporte", "n8n-nodes-base.postgres", 2.5,
     {"operation": "executeQuery",
      "query": "INSERT INTO public.v3_daily_reports(report_date,text_chunks,summary) VALUES ((now() AT TIME ZONE 'America/Mexico_City')::date,$1::text[],$2::jsonb) ON CONFLICT (report_date) DO UPDATE SET text_chunks=EXCLUDED.text_chunks,summary=EXCLUDED.summary,updated_at=now() RETURNING report_date;",
      "options": {"queryReplacement": "={{ [$('Armar correo').item.json.text_chunks, JSON.stringify({tpl: $('Armar correo').item.json.tpl, subject: $('Armar correo').item.json.subject})] }}", "connectionTimeout": 15}},
     [1440, 60], {"credentials": PG_CRED, "retryOnFail": True, "maxTries": 2, "waitBetweenTries": 5000}),
node("Leer destinatarios", "n8n-nodes-base.postgres", 2.5,
     {"operation": "executeQuery", "query": "SELECT phone,name FROM public.v3_report_recipients WHERE active ORDER BY phone;", "options": {"connectionTimeout": 15}},
     [1680, 60], {"credentials": PG_CRED, "alwaysOutputData": False}),
node("Enviar WhatsApp", "n8n-nodes-base.httpRequest", 4.2,
     {"method": "POST",
      "url": "={{ $env.WA_CLOUD_API_BASE_URL + '/' + $env.WA_API_VERSION + '/' + $env.WA_PHONE_NUMBER_ID + '/messages' }}",
      "sendHeaders": True, "headerParameters": {"parameters": [{"name": "Authorization", "value": "=Bearer {{ $env.WA_ACCESS_TOKEN }}"}, {"name": "Content-Type", "value": "application/json"}]},
      "sendBody": True, "specifyBody": "json",
      "jsonBody": "={{ JSON.stringify({messaging_product:'whatsapp',recipient_type:'individual',to:$json.phone,type:'template',template:{name:'reporte_diario_v3',language:{code:'es_MX'},components:[{type:'body',parameters:$('Armar correo').first().json.tpl.map(t=>({type:'text',text:t}))}]}}) }}",
      "options": {"timeout": 10000}},
     [1920, 60], {"onError": "continueRegularOutput", "retryOnFail": True, "maxTries": 3, "waitBetweenTries": 3000}),
node("Registrar envío", "n8n-nodes-base.postgres", 2.5,
     {"operation": "executeQuery",
      "query": "INSERT INTO public.v3_report_sends(report_date,phone,wamid,status,error) VALUES ((now() AT TIME ZONE 'America/Mexico_City')::date,$1,$2,$3,$4);",
      "options": {"queryReplacement": "={{ [$('Leer destinatarios').item.json.phone, $json.messages?.[0]?.id || null, $json.messages?.[0]?.id ? 'accepted' : 'failed', $json.messages?.[0]?.id ? null : JSON.stringify($json.error || $json).slice(0,500)] }}", "connectionTimeout": 15}},
     [2160, 60], {"credentials": PG_CRED}),
```

- [ ] **Step 2: Regenerar, correr `tests/test_v3_workflow_json_contract.py`, commit** `feat(wf24): send daily report template to WhatsApp recipients`.

### Task 1.4: Plantilla `reporte_diario_v3` en Meta (usuario)

- [ ] **Step 1: Entregar al usuario el texto exacto** (categoría Utility, idioma es_MX, botón Quick Reply `Ver detalle`):

```text
📋 Reporte del día · {{1}}
Leads: {{2}} · Tomados: {{3}} · Sin asignación: {{4}} · Con problema: {{5}}
Motores: {{6}}
Sin asignación: {{7}}
Toca "Ver detalle" para recibir el reporte completo.
```
Ejemplos para el formulario de Meta: `{{1}}` miércoles, 9 de septiembre · `{{2}}` 10 · `{{3}}` 3 · `{{4}}` 5 · `{{5}}` 1 · `{{6}}` sanos · `{{7}}` #818 SANDRA · 5272211276 · sin ID EB | #825 pilar · 55965892 · sin ID EB.

- [ ] **Step 2: Esperar APPROVED** y registrar nombre/idioma/ID en `docs/superpowers/specs/2026-08-26-lead-routing-v3-contract.md` §6 (nueva viñeta).

### Task 1.5: Rama `Ver detalle` en WF1

**Files:**
- Modify: `whatsapp-agent/workflows/WF1_inbound_router.json` (`Classify & Route` jsCode, `Switch` rules, nodos nuevos, conexiones)

- [ ] **Step 1: En `Classify & Route`, antes de `if (db.is_agent) {`:**

```js
if (/^ver detalle$/i.test(String(text || '')) || /^report:detail$/.test(String(parsed.interactive_id || ''))) {
  return [{ json: { route: 'report_detail', phone, messageId } }];
}
```
(Los botones Quick Reply devuelven `msg.button.text = 'Ver detalle'` y `payload` = mismo texto; se aceptan ambos.)

- [ ] **Step 2: Nueva regla en `Switch`** (`outputKey: "report_detail"`, misma forma que las existentes) y tres nodos:

```json
{"name": "Leer último reporte", "type": "n8n-nodes-base.postgres", "typeVersion": 2.5,
 "parameters": {"operation": "executeQuery",
  "query": "SELECT r.text_chunks FROM public.v3_daily_reports r WHERE EXISTS (SELECT 1 FROM public.v3_report_recipients p WHERE p.phone=$1 AND p.active) ORDER BY r.report_date DESC LIMIT 1;",
  "options": {"queryReplacement": "={{ [$json.phone] }}"}}},
{"name": "Expandir trozos", "type": "n8n-nodes-base.code", "typeVersion": 2,
 "parameters": {"jsCode": "const phone=$('Switch').item.json.phone; const chunks=$input.first()?.json?.text_chunks||[]; return chunks.map((c,i)=>({json:{phone,text:c,idx:i}}));"}},
{"name": "Enviar detalle", "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
 "parameters": {"method": "POST", "url": "={{ $env.WA_CLOUD_API_BASE_URL + '/' + $env.WA_API_VERSION + '/' + $env.WA_PHONE_NUMBER_ID + '/messages' }}",
  "sendHeaders": true, "headerParameters": {"parameters": [{"name": "Authorization", "value": "=Bearer {{ $env.WA_ACCESS_TOKEN }}"}, {"name": "Content-Type", "value": "application/json"}]},
  "sendBody": true, "specifyBody": "json",
  "jsonBody": "={{ JSON.stringify({messaging_product:'whatsapp',recipient_type:'individual',to:$json.phone,type:'text',text:{preview_url:false,body:$json.text}}) }}",
  "options": {"timeout": 10000, "batching": {"batch": {"batchSize": 1, "batchInterval": 800}}}},
 "onError": "continueRegularOutput", "retryOnFail": true, "maxTries": 2}
```
Conexiones: `Switch[report_detail] → Leer último reporte → Expandir trozos → Enviar detalle`. `batchInterval` 800 ms conserva el orden de los trozos.

- [ ] **Step 3: Prueba de contrato** en `tests/test_v3_workflow_json_contract.py`: el `Switch` de WF1 tiene salida `report_detail` conectada a `Leer último reporte`; el `jsCode` de `Classify & Route` contiene `route: 'report_detail'`.

- [ ] **Step 4: Desplegar** WF1 (`snF6Sr9CBJIevMVD`) desde export vivo; WF1 es sub-workflow de WF22, no lleva trigger propio que reactivar. Commit `feat(wf1): reply full daily report on "Ver detalle" button`.

### Task 1.6: Gate de Fase 1

- [ ] Disparar `GET https://n8n.srv856940.hstgr.cloud/webhook/v3-monitor-0902-k7q2x9` → llega plantilla al WhatsApp de Esteban; `v3_report_sends` con `accepted`; tocar `Ver detalle` → llegan los trozos en orden; Gmail sigue llegando. Confirmar a las 20:45 del día siguiente sin intervención.

---

## Fase 2 · Cierre SIN ASIGNACIÓN (Opus)

### Task 2.1: Inventario de dependencias del estado `assigned`

- [ ] `grep -rn "state\s*=\s*'assigned'\|IN ('assigned'\|'assigned'" supabase/migrations src whatsapp-agent/workflows dashboard --include=*.sql --include=*.py --include=*.json --include=*.ts --include=*.tsx > docs/superpowers/plans/2026-09-10-assigned-usages.txt`. Confirmar si `lead_routing_opportunities.state` tiene CHECK (`\d+ lead_routing_opportunities` en prod, solo lectura). Registrar en el archivo qué consultas deben incluir `unassigned` (dashboard "sin responsable", WF24 SQL `stuck_expired`, `v3_day_sweep`, promoción del ledger EB, `v3_release_night_queue`).

### Task 2.2: Migración `v3_unassigned`

**Files:**
- Create: `supabase/migrations/20260912100000_v3_unassigned.sql`
- Test: `tests/sql/test_v3_unassigned.sql`, `tests/test_v3_unassigned_migration_draft.py` (mismo patrón que `tests/test_v3_07_migration_draft.py`)

- [ ] **Step 1: Prueba Python del borrador** (falla primero): el archivo existe, contiene `CREATE OR REPLACE FUNCTION public.v3_mark_unassigned`, no contiene `v3_assign_sandy(` dentro de los cuerpos re-creados de `v3_advance_routing_tier` y `v3_route_ready_opportunity`, y `v3_day_sweep` menciona `'unassigned'`.

- [ ] **Step 2: Migración.**

```sql
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS unassigned_at timestamptz;
-- If a CHECK on state exists (Task 2.1), drop and re-add it here including 'unassigned'.

CREATE OR REPLACE FUNCTION public.v3_mark_unassigned(p_opportunity_id bigint, p_reason text, p_capture_event_id bigint, p_now timestamptz)
RETURNS boolean LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_updated integer; v_conversation_id bigint;
BEGIN
  UPDATE public.lead_routing_opportunities
     SET state='unassigned', routing_tier=NULL, assigned_agent_id=NULL, unassigned_at=p_now,
         expires_at=NULL, current_delivery_attempt_id=NULL, updated_at=p_now,
         external_evidence=COALESCE(external_evidence,'{}'::jsonb)
           || jsonb_build_object('v3_final_route','unassigned','reason',p_reason,'capture_event_id',p_capture_event_id)
   WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL AND state NOT IN ('assigned','unassigned','closed_won','closed_lost')
   RETURNING conversation_id INTO v_conversation_id;
  GET DIAGNOSTICS v_updated=ROW_COUNT;
  IF v_updated=0 THEN RETURN false; END IF;
  UPDATE public.conversations SET assigned_agent_id=NULL, assignment_method='v3_unassigned', claimed_via=NULL, routing_tier=NULL, updated_at=p_now
   WHERE conversation_id=v_conversation_id;
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,actor_id,occurred_at,metadata,idempotency_key)
  VALUES (p_opportunity_id,'left_unassigned',NULL,p_now,jsonb_build_object('reason',p_reason,'capture_event_id',p_capture_event_id),'v3-unassigned:'||p_opportunity_id)
  ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN true;
END $$;
```
Verificar contra el cuerpo real de `v3_assign_sandy` en `20260827154900_lead_routing_v3_intake_routing.sql:759-800` que las columnas de `conversations` y `lead_routing_events` coinciden (nombres exactos, `metadata` vs `payload`, y si `assignment_method` tiene CHECK: añadir `'v3_unassigned'`).

Después, copiar íntegras `v3_advance_routing_tier` y `v3_route_ready_opportunity` desde `20260907152702_v3_day_deadline.sql:741` y `:862`, cambiando cada `public.v3_assign_sandy(` por `public.v3_mark_unassigned(`; y `v3_day_sweep` desde `:107` con estas dos sustituciones:

```sql
    WHEN o.assigned_agent_id IS NULL AND o.state <> 'unassigned' THEN 'responsible_not_assigned'
...
       AND ( (o.assigned_agent_id IS NOT NULL AND o.assigned_at <= c.day_deadline_at
              AND EXISTS (SELECT 1 FROM public.lead_routing_delivery_attempts a
                WHERE a.target_agent_id=o.assigned_agent_id
                  AND (a.capture_event_id=c.capture_event_id OR (c.disposition='active_duplicate' AND a.opportunity_id=c.opportunity_id))
                  AND a.delivered_at IS NOT NULL AND a.delivered_at <= c.day_deadline_at))
           OR (o.state='unassigned' AND o.unassigned_at <= c.day_deadline_at) )
       AND EXISTS (SELECT 1 FROM public.easybroker_effect_ledger e
         WHERE e.opportunity_id=c.opportunity_id AND e.note_state='succeeded'
          AND e.attended_state IN ('succeeded','skipped') AND e.updated_at <= c.day_deadline_at)
```

Ledger EB: `ALTER TABLE public.easybroker_effect_ledger DROP CONSTRAINT <check attended_state>; ADD CONSTRAINT ... CHECK (attended_state IN ('pending','succeeded','failed','skipped'))` (nombre real del constraint desde `20260827154902:4-40`). Re-crear `claim_v3_easybroker_effects` desde `20260907152702:431` con la promoción:

```sql
    AND (o.state IN ('assigned','closed_won') AND o.assigned_agent_id IS NOT NULL OR o.state='unassigned')
```
y `responsible_first_name = CASE WHEN o.state='unassigned' THEN 'SIN ASIGNACIÓN' ELSE split_part(...) END`, `responsible_agent_id = o.assigned_agent_id` (NULL para unassigned), `attended_due = (responsible_agent_id IS NOT NULL AND ...)`. Re-crear `finish_v3_easybroker_effect` para que, al terminar `note` con `ok=true` en un ledger con `responsible_agent_id IS NULL`, fije `attended_state='skipped', close_state='completed'`.

- [ ] **Step 3: Prueba SQL con rollback** (`tests/sql/test_v3_unassigned.sql`): (a) oportunidad en `guard_delivery_pending` sin agente → `v3_mark_unassigned` devuelve true, `state='unassigned'`, evento `left_unassigned`, ninguna fila nueva en `lead_routing_delivery_attempts` de tipo `assigned_notice`; (b) segunda llamada devuelve false; (c) `v3_day_sweep` no crea incidencia si `unassigned_at` y nota EB ocurrieron antes del plazo; sí la crea si la nota EB falta; (d) `claim_v3_easybroker_effects` devuelve `responsible_first_name='SIN ASIGNACIÓN'` y `attended_due=false`; `finish_v3_easybroker_effect(step='note', ok=true)` deja `attended_state='skipped'`, `close_state='completed'`.

- [ ] **Step 4: Aplicar en prod** en ventana sin ofertas abiertas (`SELECT count(*) FROM lead_routing_opportunities WHERE expires_at > now()` = 0). Commit `feat(db): leave unclaimed leads unassigned instead of assigning Sandy`.

### Task 2.3: Worker EB acepta `SIN ASIGNACIÓN`

**Files:**
- Modify: `src/easybroker/inbox.py:418-430` (`_RESPONSIBLE_NOTE_RE`, `find_responsible_notes`), `src/easybroker/main.py:85-90`
- Test: `tests/test_v3_02_easybroker.py`

- [ ] **Step 1: Test que falla:** `find_responsible_notes(["RESPONSABLE: SIN ASIGNACIÓN"]) == ["SIN ASIGNACIÓN"]`; y el worker con claim `{responsible_first_name:'SIN ASIGNACIÓN', responsible_agent_id:None, note_due:True, attended_due:False}` llama `attend_lead` con `note_text='RESPONSABLE: SIN ASIGNACIÓN'` y nunca con `status_done=False`.
- [ ] **Step 2: Implementar:** ampliar la regex a `r"RESPONSABLE:\s*([A-ZÁÉÍÓÚÑ][\wÁÉÍÓÚÑáéíóúñ]*(?:\s+ASIGNACIÓN)?)"` (o equivalente que capture dos palabras en mayúsculas); en `main.py`, `if not claim.get("attended_due"): skip attended step`.
- [ ] **Step 3:** `PYTHONPATH=src python -m pytest -q tests/test_v3_02_easybroker.py` → pass. Deploy al Pi en Task 3.0 (junto con la reconciliación). Commit `feat(easybroker): write SIN ASIGNACIÓN note without marking Atendida`.

### Task 2.4: WF3c salida `unassigned`

**Files:**
- Modify: `whatsapp-agent/workflows/WF3c_expiry_sweeper.json` (`Route Transition` switch, nodo NoOp `V3 Unassigned Durable`)

- [ ] **Step 1:** Leer `Hydrate Transition Attempt` (línea 36) y confirmar que devuelve `state` sin filtrar valores. Añadir regla `outputKey: "unassigned"` (`$json.state == 'unassigned'`) → NoOp nuevo. Confirmar que la rama `unassigned` existente (línea 86-98, alerta a Sandy) se activa por `$json.transition == 'unassigned'` u otra clave, y renombrar la nueva salida a `left_unassigned` si hay colisión de nombre.
- [ ] **Step 2:** Prueba de contrato en `tests/test_v3_workflow_json_contract.py` (nueva salida conectada). Deploy desde export vivo de `UNIKqyAvIUAZkNIs`. Commit `feat(wf3c): route unassigned transitions to a durable no-op`.

### Task 2.5: WF24 muestra SIN ASIGNACIÓN

**Files:**
- Modify: `whatsapp-agent/workflows/wf24_render.js`, `build_wf24_monitor.py` (SQL: incluir `o.unassigned_at`, evento `left_unassigned` en la lista `IN (...)`, `stuck_expired` excluye `state='unassigned'`)

- [ ] **Step 1: Test** en `test_wf24_render.mjs` con un lead `state:'unassigned'`: el texto contiene `Sin asignación 08:16 · nadie tomó (guard_expired)`, `nUnassigned===1`, `tpl[3]==='1'`, `tpl[6]` incluye `#<id>`.
- [ ] **Step 2: Render:** rama `else if (l.state === 'unassigned')` antes del `else` de "Sin responsable todavía":

```js
} else if (l.state === 'unassigned') {
  nUnassigned++;
  const ev = events.find(e => e.type === 'left_unassigned');
  lines.push(`<b>SIN ASIGNACIÓN</b> ${hhmm(l.unassigned_at)} · nadie tomó${ev && ev.reason ? ' (' + esc(ev.reason) + ')' : ''}`);
}
```
Línea EB para este caso: `nota SIN ASIGNACIÓN ✔ hh:mm · Atendida omitida` (cuando `note` ok y no hay `attended`). `summary` cambia `${nSandy} a Sandy` por `${nUnassigned} sin asignación`; el asunto `${nClaim} tomados · ${nUnassigned} sin asignación`.
- [ ] **Step 3:** regenerar, deploy WF24, commit `feat(wf24): report unassigned leads`.

### Task 2.6: Contrato y gate

- [ ] Actualizar `docs/superpowers/specs/2026-08-26-lead-routing-v3-contract.md` (sección Sandy fallback → "SIN ASIGNACIÓN": estado, EB nota sin Atendida, sin WhatsApp a Sandy) y `README.md`/`CLAUDE.md` líneas que dicen "5 min → Sandy".
- [ ] Gate: primer lead real que vence en guardia → `state='unassigned'`, evento `left_unassigned`, nota EB `RESPONSABLE: SIN ASIGNACIÓN`, `attended_state='skipped'`, ningún `assigned_notice` a `agent_manager`, sin incidencia en `v3_day_incidents`, y aparece en el reporte de las 20:45 (correo + WhatsApp).

---

## Fase 3 · Nota interna en Inmuebles24 (Sonnet 3.0/3.1, Opus 3.2–3.4)

### Task 3.0: Reconciliar el Pi con git

- [ ] En el Pi: `git -C /opt/inmobiliaria24 status --short` y `git diff > /tmp/pi-private.diff`; copiar a local `backups/pi-private-20260912.diff`; crear rama `pi-reconcile-20260912`, aplicar el diff, correr `PYTHONPATH=src python -m pytest -q` (esperado: 380 passed, 2 xfailed más los nuevos), PR a `main`. Solo después de mergeado, `sudo bash /opt/inmobiliaria24/deploy/deploy.sh`. Verificar hash de `main.py` en el Pi == repo. Sin este paso no se ejecuta nada más de la Fase 3.

### Task 3.1: Descubrimiento de la pestaña Notas (solo lectura)

**Files:**
- Create: `scripts/i24_notes_discover.py`, `docs/i24-notas-selectors.md`

- [ ] **Step 1: Script** que reutiliza `inmobiliaria24.auth` para abrir sesión (mismo perfil headful que el servicio, CDP 9222 según `phase2.conf`), navega a `/panel/interesados/<lead_id>` de un lead ya cerrado (argumento CLI), hace `page.get_by_role("tab", name="Notas").click()` con fallback `page.get_by_text("Notas", exact=True)`, espera 2 s, y guarda `logs/i24_notes_<lead_id>.html` (outerHTML del contenedor del compositor: ancestro común del textarea con placeholder que empieza por "Escribí una nota interna" y del botón "Anotar") + `logs/i24_notes_<lead_id>.png`. No escribe ni hace clic en Anotar.
- [ ] **Step 2: Ejecutar en el Pi** fuera del minuto de corrida del timer (`systemctl stop inmobiliaria24.timer` 2 min, correr, `start`). Documentar en `docs/i24-notas-selectors.md`: selector de pestaña, selector de textarea, selector del botón, cómo se renderiza una nota existente en el hilo (`Nota interna: <texto>` y su contenedor), y si el botón queda `disabled` hasta escribir.
- [ ] **Step 3: Commit** `docs: Inmuebles24 internal-note composer selectors`.

### Task 3.2: Ledger `i24_note_ledger`

**Files:**
- Create: `supabase/migrations/20260913100000_v3_i24_note_ledger.sql`
- Test: `tests/sql/test_v3_i24_note_ledger.sql`, `tests/test_v3_i24_note_migration_draft.py`

- [ ] **Step 1: Migración**

```sql
CREATE TABLE public.i24_note_ledger (
  opportunity_id bigint PRIMARY KEY REFERENCES public.lead_routing_opportunities(opportunity_id),
  capture_event_id bigint,
  i24_lead_id text NOT NULL,
  note_text text NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','leased','succeeded','failed','manual_review')),
  attempts integer NOT NULL DEFAULT 0,
  lease_token uuid,
  lease_until timestamptz,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT,INSERT,UPDATE ON public.i24_note_ledger TO service_role;

CREATE OR REPLACE FUNCTION public.v3_enqueue_i24_note() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_text text; v_capture record;
BEGIN
  IF NEW.state = OLD.state THEN RETURN NEW; END IF;
  IF NEW.state = 'assigned' AND NEW.assigned_agent_id IS NOT NULL THEN
    SELECT split_part(regexp_replace(BTRIM(a.name),'\s+',' ','g'),' ',1) INTO v_text FROM public.agents a WHERE a.agent_id=NEW.assigned_agent_id;
  ELSIF NEW.state = 'unassigned' THEN v_text := 'SIN ASIGNACIÓN';
  ELSE RETURN NEW; END IF;
  SELECT capture_event_id, external_event_id INTO v_capture FROM public.i24_capture_events
   WHERE opportunity_id=NEW.opportunity_id AND external_event_id IS NOT NULL ORDER BY capture_event_id DESC LIMIT 1;
  IF v_capture.external_event_id IS NULL OR v_text IS NULL THEN RETURN NEW; END IF;
  INSERT INTO public.i24_note_ledger(opportunity_id,capture_event_id,i24_lead_id,note_text)
  VALUES (NEW.opportunity_id,v_capture.capture_event_id,v_capture.external_event_id,v_text)
  ON CONFLICT (opportunity_id) DO NOTHING;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_v3_enqueue_i24_note AFTER UPDATE OF state ON public.lead_routing_opportunities
FOR EACH ROW EXECUTE FUNCTION public.v3_enqueue_i24_note();

CREATE OR REPLACE FUNCTION public.claim_v3_i24_notes(p_limit integer, p_now timestamptz)
RETURNS TABLE(opportunity_id bigint, i24_lead_id text, note_text text, lease_token uuid, attempt integer)
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
  RETURN QUERY
  WITH cand AS (
    SELECT l.opportunity_id FROM public.i24_note_ledger l
     WHERE (l.state='pending' OR (l.state IN ('leased','failed') AND (l.lease_until IS NULL OR l.lease_until < p_now)))
       AND l.attempts < 5
     ORDER BY l.created_at LIMIT GREATEST(p_limit,1) FOR UPDATE SKIP LOCKED)
  UPDATE public.i24_note_ledger l SET state='leased', lease_token=gen_random_uuid(), lease_until=p_now+interval '3 minutes',
         attempts=l.attempts+1, updated_at=p_now
    FROM cand WHERE l.opportunity_id=cand.opportunity_id
  RETURNING l.opportunity_id, l.i24_lead_id, l.note_text, l.lease_token, l.attempts;
END $$;

CREATE OR REPLACE FUNCTION public.finish_v3_i24_note(p_opportunity_id bigint, p_token uuid, p_ok boolean, p_evidence jsonb)
RETURNS boolean LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_rows integer;
BEGIN
  UPDATE public.i24_note_ledger SET
    state = CASE WHEN p_ok THEN 'succeeded' WHEN attempts >= 5 THEN 'manual_review' ELSE 'failed' END,
    lease_token=NULL, lease_until=NULL, updated_at=now(),
    evidence = evidence || jsonb_build_object(to_char(now(),'YYYYMMDDHH24MISS'), p_evidence)
  WHERE opportunity_id=p_opportunity_id AND lease_token=p_token AND state='leased';
  GET DIAGNOSTICS v_rows=ROW_COUNT; RETURN v_rows=1;
END $$;
GRANT EXECUTE ON FUNCTION public.claim_v3_i24_notes(integer,timestamptz), public.finish_v3_i24_note(bigint,uuid,boolean,jsonb) TO service_role;
```
Confirmar en Task 2.1 que `i24_capture_events.external_event_id` es el `contact_publisher_user_id` (ver `20260827154900:504`); si el nombre difiere, usar el real.

- [ ] **Step 2: Prueba SQL con rollback:** UPDATE de `state` a `assigned` crea ledger con el primer nombre; a `unassigned` crea `SIN ASIGNACIÓN`; UPDATE sin cambio de estado no crea; `claim` devuelve la fila y la deja `leased`; `finish(ok=false)` cinco veces termina en `manual_review`; `finish` con token equivocado devuelve false.
- [ ] **Step 3: Backfill** opcional al aplicar: no. Solo leads nuevos. Aplicar en prod. Commit `feat(db): i24 internal-note ledger fed by opportunity state changes`.

### Task 3.3: Worker de notas en el Pi

**Files:**
- Create: `src/inmobiliaria24/i24_notes.py`
- Modify: `src/inmobiliaria24/main.py` (llamada al final de la corrida con navegador), `src/inmobiliaria24/supa.py` (dos RPC), `src/inmobiliaria24/config.py` (`I24_NOTES`)
- Test: `tests/test_i24_notes.py`

- [ ] **Step 1: Tests que fallan** (página falsa con `goto`, `click`, `fill`, `locator(...).count()` grabando llamadas, mismo estilo que `tests/test_i24_session_render.py`):
  - `write_internal_note` cuando ya existe `Nota interna: Gina` → devuelve `{"ok": True, "already": True}` sin `fill`.
  - Camino feliz: navega a `/panel/interesados/123`, clic pestaña Notas, `fill` con "Gina", clic Anotar, verifica que la nota aparece → `ok True`.
  - Verificación falla tras Anotar → `ok False, reason 'note_not_visible'`.
  - `run_v3_i24_note_worker` con dos claims: llama `finish_v3_i24_note` una vez por claim con el resultado.

- [ ] **Step 2: Implementación** (selectores desde `docs/i24-notas-selectors.md`, en constantes al inicio del módulo):

```python
"""Write the internal note in the Inmuebles24 conversation after the auction outcome."""
from __future__ import annotations
import logging
from .scraper import INTERESADOS_URL, _navigate_spa

log = logging.getLogger(__name__)
NOTES_TAB = "role=tab[name='Notas']"          # confirm in docs/i24-notas-selectors.md
NOTE_INPUT = "textarea[placeholder^='Escribí una nota interna']"
NOTE_SUBMIT = "button:has-text('Anotar')"
NOTE_ROW = "text=/^Nota interna:\\s*{text}$/"

async def write_internal_note(page, lead_id: str, text: str, *, evidence) -> dict:
    await _navigate_spa(page, f"{INTERESADOS_URL}/{lead_id}")
    if await page.locator(NOTE_ROW.format(text=text)).count():
        return {"ok": True, "already": True}
    await page.click(NOTES_TAB)
    await page.fill(NOTE_INPUT, text)
    await page.click(NOTE_SUBMIT)
    await page.wait_for_timeout(1500)
    visible = bool(await page.locator(NOTE_ROW.format(text=text)).count())
    await evidence(page, f"i24_note_{lead_id}")
    return {"ok": visible, "already": False, "reason": None if visible else "note_not_visible"}

async def run_v3_i24_note_worker(page, supa, *, evidence, limit: int = 10) -> int:
    done = 0
    for claim in await supa.claim_v3_i24_notes(limit):
        try:
            result = await write_internal_note(page, claim["i24_lead_id"], claim["note_text"], evidence=evidence)
        except Exception as exc:  # portal flake: leave it to the next minute
            result = {"ok": False, "reason": f"{type(exc).__name__}: {exc}"[:300]}
        await supa.finish_v3_i24_note(claim["opportunity_id"], claim["lease_token"], result["ok"], result)
        done += int(result["ok"])
    return done
```
`supa.py`: `claim_v3_i24_notes(limit)` → `rpc('claim_v3_i24_notes', {'p_limit': limit, 'p_now': now_iso})`; `finish_v3_i24_note(...)` → `rpc('finish_v3_i24_note', {...})`, mismo estilo que `claim_v3_i24_contact_effects` ya existente en `supa.py`. `main.py`: tras el bloque de Contactado y antes de cerrar el navegador, `if settings.i24_notes: await run_v3_i24_note_worker(page, supa, evidence=_capture_i24_status_evidence)`. `config.py`: `i24_notes = os.environ.get("I24_NOTES") == "1"`.

- [ ] **Step 3:** `PYTHONPATH=src python -m pytest -q tests/test_i24_notes.py` pass; suite completa pass. Commit `feat(i24): per-minute worker writes internal note after assignment`.

### Task 3.4: Canario y activación

- [ ] Deploy al Pi (`deploy.sh`), `I24_NOTES=0` inicialmente. Ejecutar una corrida manual con `I24_NOTES=1` sobre un ledger sembrado a mano para un lead ya cerrado del día (INSERT en `i24_note_ledger` con su `external_event_id`, texto = responsable real). Verificar en el portal que aparece `Nota interna: <nombre>` y en `i24_note_ledger.state='succeeded'` con evidencia PNG.
- [ ] Activar `I24_NOTES=1` en `/opt/inmobiliaria24/.env`, `systemctl restart inmobiliaria24.timer`. Observar el primer lead real: nota en ≤ 3 min tras `assigned`/`unassigned`.
- [ ] WF24: en `wf24_render.js` añadir línea `Nota i24 ✔ hh:mm` / `✘ nota i24 <state>` leyendo `i24_note_ledger` (join en el SQL de WF24: `(SELECT json_build_object('state',n.state,'at',n.updated_at) FROM public.i24_note_ledger n WHERE n.opportunity_id=o.opportunity_id) AS i24_note`). Test en `test_wf24_render.mjs`. Deploy WF24. Commit `feat(wf24): show Inmuebles24 note status`.
- [ ] `graphify update .` y actualizar memoria del proyecto.

---

## Self-review

- Spec §3.1 → 0.1, 0.2. §3.2 → 1.1–1.6. §3.3 → 2.1–2.6 (incluye Sandy sin WhatsApp: `v3_mark_unassigned` no encola aviso; alerta de anomalías de WF3c revisada en 2.4). §3.4 → 3.0–3.4.
- Nombres consistentes: `v3_mark_unassigned`, `left_unassigned`, `attended_state='skipped'`, `i24_note_ledger`, `claim_v3_i24_notes`, `finish_v3_i24_note`, `write_internal_note`, `run_v3_i24_note_worker`, `wf24_render.js`, `reporte_diario_v3`, `report_detail`.
- Pendientes que el ejecutor debe verificar antes de codificar (no inventar): número de Esteban (1.1), CHECK de `state` y `assignment_method` (2.1/2.2), nombre real del constraint de `attended_state` (2.2), columna `external_event_id` (3.2), selectores (3.1).
