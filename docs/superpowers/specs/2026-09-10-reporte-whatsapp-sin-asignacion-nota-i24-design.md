# Reporte por WhatsApp, cierre SIN ASIGNACIÓN y nota interna en Inmuebles24

Fecha: 2026-09-10. Estado: diseño aprobado verbalmente por Esteban (respuestas 1A, 2 sí,
3A, 4A, 5A, 6 silencio, 7 sí). Pendiente: revisión del documento escrito.

## 1. Objetivo

Cuatro cambios sobre Lead Routing V3, pedidos por la clienta (BYG):

1. Dejar de recibir los correos de cada media hora. Silenciar también los correos rojos
   nocturnos de WF23/WF20 por "connection timeout".
2. Enviar el reporte del día por WhatsApp (primero a Esteban, luego a los números que
   la clienta indique). El correo a Gmail se conserva hasta nuevo aviso.
3. Cuando nadie toma el lead, ya no se asigna a Sandy. El lead termina en estado
   `unassigned` ("SIN ASIGNACIÓN"), aparece en el reporte, y en EasyBroker recibe la nota
   `RESPONSABLE: SIN ASIGNACIÓN` sin marcar Atendida. Sandy no recibe WhatsApp por ello.
4. Al cerrar cada lead (tomado o sin asignación) el Pi escribe una nota interna en la
   conversación de Inmuebles24, como lo hace el equipo a mano: el primer nombre del
   responsable (`Gina`) o `SIN ASIGNACIÓN`.

Fuera de alcance: frenar la subasta cuando ya existe una nota manual previa a la captura
(empalme documentado el 6-sep), la cola nocturna, y la linealización de workflows.

## 2. Estado actual relevante

- WF24 (`whatsapp-agent/workflows/build_wf24_monitor.py` genera `WF24_v3_monitor.json`)
  tiene dos disparadores: `*/30 8-20 * * *` (modo `window`) y `45 20 * * *` (modo
  `day`). Un Code node `Armar correo` produce solo `html` + `subject`; un nodo Gmail lo
  manda a `esteban.betanc@gmail.com`.
- WF21 (error handler) manda Gmail por cualquier error de cualquier workflow. Los
  timeouts de WF23/WF20 entre 00:30 y 02:30 CDMX vienen del congelamiento nocturno de
  n8n por los ingest de otros clientes (ver memoria 2026-09-05).
- Envíos WhatsApp = nodos HTTP Request a Meta Cloud API con `$env.WA_*`. Plantillas
  vivas: `lead_subasta_v3`, `lead_asignado_v3`, `alerta_routing_v3`. Meta exige
  plantilla aprobada para iniciar conversación; texto libre solo dentro de la ventana de
  24 h que abre el destinatario al escribir o tocar un botón. Los parámetros de plantilla
  no admiten saltos de línea; cuerpo ≤ 1024 caracteres; mensaje de texto ≤ 4096.
- Los botones que toca un agente llegan por WF22 → WF1 (`Classify & Route` → `Switch`).
- El fallback a Sandy vive en SQL: `public.v3_assign_sandy(...)`, llamada desde
  `v3_advance_routing_tier` (razones `owner_equals_guard`, `guard_unavailable`,
  `guard_expired`) y `v3_route_ready_opportunity`. Versión vigente en
  `supabase/migrations/20260907152702_v3_day_deadline.sql`.
- `v3_day_sweep` (mismo archivo, línea 107) considera incumplido cualquier lead sin
  `assigned_agent_id` al vencer el plazo de 15 min, y `v3_day_claim_alerts` manda
  `alerta_routing_v3` a Sandy por WF23.
- El ledger de EasyBroker (`easybroker_effect_ledger`) se promueve de
  `awaiting_responsible` a `pending` solo con `state IN ('assigned','closed_won')` y
  agente no nulo; el worker `src/easybroker/main.py` escribe `RESPONSABLE: <nombre>` y
  luego Atendida, un paso por lease, cada minuto.
- El Pi (`src/inmobiliaria24`) solo cambia el chip a Contactado
  (`scraper.py:mark_lead_contacted`, navega a `/panel/interesados/<lead_id>` con
  `contact_publisher_user_id`). No existe código de notas. Corre como proceso oneshot
  cada minuto de 08:05 a 19:59 y cada 15 min de noche (`deploy/inmobiliaria24.timer`).
- El Pi tiene cambios privados sin commit en `main.py`, `fast_inbox.py`, `auth.py`
  (incidente 2026-09-07). No se puede hacer `git pull` sin reconciliar.

## 3. Diseño

### 3.1 Silenciar correos (Fase 0)

- WF24: eliminar el nodo `Cada 30 min (08-20 CDMX)` y `Modo ventana`, y sus
  conexiones. El modo `window` deja de existir en el generador (el webhook manual ya
  usa `day`); se elimina la rama `ELSE now()-31 min` del SQL y la variable `send` pasa
  a ser siempre verdadera.
- WF21: nuevo IF `¿Silenciar?` antes del Gmail. Se silencia cuando se cumplen las tres
  condiciones: workflow ∈ {`WF23 - Delivery Timeout Sweeper`, `BYG WF20 Watchdog`},
  mensaje coincide con `/connection timeout|timed out|ETIMEDOUT/i`, y hora CDMX entre
  00:00 y 03:00. Fuera de esa ventana el correo sigue saliendo (protege contra caídas
  diurnas reales).

### 3.2 Reporte por WhatsApp (Fase 1)

Dos niveles, según respuesta 1A.

**Nivel 1, plantilla `reporte_diario_v3`** (categoría utility, es_MX), enviada por WF24
a las 20:45 CDMX a cada destinatario activo:

```text
📋 Reporte del día · {{1}}
Leads: {{2}} · Tomados: {{3}} · Sin asignación: {{4}} · Con problema: {{5}}
Motores: {{6}}
Sin asignación: {{7}}
Toca "Ver detalle" para recibir el reporte completo.
```

Botón de respuesta rápida: `Ver detalle`. Parámetro 7 = lista `#818 SANDRA · 5572112765
· sin ID EB | #825 pilar · ...` en una sola línea, truncada de forma determinista a
600 caracteres con `…`; `Ninguno` cuando no hay. Parámetro 6 = `sanos` o la lista de
alertas de salud en una línea.

**Nivel 2, detalle en texto libre.** Al tocar `Ver detalle`, el destinatario abre la
ventana de 24 h. WF1 reconoce el payload del botón y responde con el reporte completo
del día en texto plano, en trozos ≤ 4000 caracteres, solo si el remitente está en la
lista de destinatarios.

Componentes:

- Tabla `public.v3_report_recipients(phone text PK, name text, active boolean,
  created_at)`. Arranca con el número de Esteban. Agregar números = un INSERT.
- Tabla `public.v3_daily_reports(report_date date PK, text_chunks text[], summary
  jsonb, created_at)`. WF24 la escribe cada noche (UPSERT) antes de enviar.
- WF24: el Code node `Armar correo` pasa a producir además `text_chunks` (renderer de
  texto plano con las mismas líneas por lead que el HTML, sin etiquetas), y los siete
  parámetros de la plantilla. Nuevos nodos: `Guardar reporte` (Postgres UPSERT),
  `Leer destinatarios` (Postgres), `Enviar WhatsApp` (HTTP Request copiado de
  `Send Assigned Notice` de WF13, `onError: continueRegularOutput`, retry 3),
  `Registrar envío` (Postgres, tabla `v3_report_sends(report_date, phone, wamid,
  status, created_at)` para que el reporte de mañana pueda listar entregas fallidas).
- WF1: `Classify & Route` reconoce `button.payload == 'Ver detalle'` (o
  `button.text`), ruta nueva `report_detail`. Nueva salida del `Switch` → Postgres
  `SELECT text_chunks FROM v3_daily_reports ORDER BY report_date DESC LIMIT 1` con
  verificación de remitente en `v3_report_recipients` → Code que expande a un item por
  trozo → HTTP Request `type: text` (copiado de `Send Routing V2 Claim Result` de WF3b).
- El Gmail se conserva sin cambios.

### 3.3 Cierre SIN ASIGNACIÓN (Fase 2)

Migración `supabase/migrations/2026091xxxxxxx_v3_unassigned.sql`:

- Estado nuevo `unassigned` en `lead_routing_opportunities.state` (ajustar CHECK si
  existe). Columna nueva `unassigned_at timestamptz`.
- Función `public.v3_mark_unassigned(p_opportunity_id, p_reason, p_capture_event_id,
  p_now)`: misma guarda que `v3_assign_sandy` (`assigned_agent_id IS NULL`); fija
  `state='unassigned'`, `routing_tier=NULL`, `assigned_agent_id=NULL`,
  `unassigned_at=p_now`, `external_evidence || {v3_final_route:'unassigned', reason}`;
  en `conversations`: `assignment_method='v3_unassigned'`, `assigned_agent_id=NULL`,
  `routing_tier=NULL`; evento `lead_routing_events(event_type='left_unassigned')` con
  idempotencia `v3-unassigned:<id>`. No encola aviso `lead_asignado_v3`.
- `v3_advance_routing_tier` y `v3_route_ready_opportunity` se re-crean idénticas a la
  versión 20260907152702 sustituyendo cada `v3_assign_sandy(` por
  `v3_mark_unassigned(`. `v3_assign_sandy` se conserva sin llamadas (rollback).
- `v3_day_sweep`: el bloque de éxito acepta también
  `o.state='unassigned' AND o.unassigned_at <= c.day_deadline_at` en lugar de
  `assigned_agent_id IS NOT NULL ... AND EXISTS entrega al asignado`; la condición del
  ledger EB pasa a exigir `note_state='succeeded'` y (`attended_state='succeeded'` o
  `attended_state='skipped'`). El CASE de razón pasa `responsible_not_assigned` solo si
  `o.state NOT IN ('assigned','unassigned','closed_won')`.
- Ledger EB: `attended_state` admite `skipped`. `claim_v3_easybroker_effects` promueve
  también `o.state='unassigned'` con `responsible_agent_id=NULL` y
  `responsible_first_name='SIN ASIGNACIÓN'`. Un claim con `responsible_agent_id IS NULL`
  solo ofrece el paso `note`; al terminar `note` con éxito, `finish` marca
  `attended_state='skipped'` y `close_state='completed'`.
- Worker EB (`src/easybroker/main.py`): sin cambio de flujo salvo aceptar
  `responsible_first_name='SIN ASIGNACIÓN'` en el texto de nota y en el parser
  `_RESPONSIBLE_NOTE_RE` (`src/easybroker/inbox.py`). Conflicto con una nota
  `RESPONSABLE: <otro>` previa sigue enviando a `manual_review` (alguien ya lo tomó).
- WF3c `Route Transition`: salida nueva `unassigned` → NoOp `V3 Unassigned Durable`
  (la BD ya hizo el trabajo). Verificar que `Hydrate Transition Attempt` no filtre el
  estado.
- WF24 (HTML, texto y plantilla): cubo "Sin asignación"; línea por lead
  `Sin asignación 08:16 · nadie tomó (guard_expired)`; la nota EB se muestra como
  `nota SIN ASIGNACIÓN ✔ 08:17 · Atendida omitida`. Los contadores del asunto y del
  parámetro 3/4 separan tomados de sin asignación.
- Alertas a Sandy: ninguna por `unassigned` (respuesta 4A). La rama `unassigned` de WF3c
  (alerta `alerta_routing_v3`) sigue reservada a anomalías (sin guardia y sin dueño
  resolubles); se revisa que no se dispare por el nuevo estado.
- Dashboard y consultas que filtran `state='assigned'` se inventarían con grep en la
  fase de plan; las que listen "sin responsable" incluyen `unassigned`.

### 3.4 Nota interna en Inmuebles24 (Fase 3)

Factibilidad: sí. No hace falta mantener el navegador abierto. Cada corrida del Pi es
un proceso nuevo que entra al portal y navega a `/panel/interesados/<lead_id>`; el
`lead_id` (`contact_publisher_user_id`) queda guardado en `i24_capture_events` desde la
captura. Volver minutos después es lo mismo que hoy hace para marcar Contactado.

Componentes:

- Descubrimiento (3a, solo lectura): script en el Pi que abre un lead ya cerrado,
  hace clic en la pestaña `Notas`, y guarda HTML del compositor + captura. No toca
  `Anotar`. Resultado: `docs/i24-notas-selectors.md` con selectores de pestaña,
  textarea (placeholder "Escribí una nota interna…"), botón `Anotar` y cómo aparece
  la nota en el hilo (`Nota interna: <texto>`).
- Tabla `public.i24_note_ledger(opportunity_id bigint PK, capture_event_id bigint,
  i24_lead_id text NOT NULL, note_text text NOT NULL, state text CHECK IN
  ('pending','leased','succeeded','failed','manual_review'), attempts int DEFAULT 0,
  lease_token uuid, lease_until timestamptz, evidence jsonb, created_at, updated_at)`.
- Alimentación: trigger AFTER UPDATE en `lead_routing_opportunities` cuando `state`
  pasa a `assigned` (texto = primer nombre de `agents.name`) o `unassigned` (texto =
  `SIN ASIGNACIÓN`). INSERT ... ON CONFLICT DO NOTHING. Cubre claim por botón, fallback
  y asignaciones manuales por SQL.
- Funciones `claim_v3_i24_notes(p_limit, p_now)` (lease 3 min, máximo 5 intentos,
  después `manual_review`) y `finish_v3_i24_note(p_opportunity_id, p_token, p_ok,
  p_evidence)`. Mismo patrón que `claim_v3_easybroker_effects`/`finish_v3_easybroker_effect`.
- Pi: módulo nuevo `src/inmobiliaria24/i24_notes.py` con
  `write_internal_note(page, lead_id, text, *, evidence)` (navegar, pestaña Notas,
  si ya existe `Nota interna: <text>` → éxito idempotente; si no, escribir, `Anotar`,
  verificar que aparece en el hilo, captura de evidencia) y
  `run_v3_i24_note_worker(page, supa)` que drena claims. Se invoca en `main.py` al
  final de cada corrida con navegador (día y noche), gateado por env `I24_NOTES=1`.
  Reintentos y bloqueo Cloudflare reutilizan la lógica existente de `mark_lead_contacted`.
- WF24 muestra `Nota i24 ✔ 08:18` o `✘ nota i24 pendiente/manual_review` por lead.
- El plazo de 15 min no se amplía por la nota i24: la nota i24 no entra en
  `v3_day_sweep` (queda como visibilidad en WF24, no como incumplimiento).

## 4. Flujo de datos resultante

```
Pi captura → Contactado → dispatch → WF10/12/13 oferta dueño (5 min) → guardia (5 min)
  → Tomo (WF3b) → state=assigned ──┐
  → nadie → v3_mark_unassigned ────┤→ trigger → i24_note_ledger (Pi escribe nota)
                                   └→ easybroker_effect_ledger (EB nota [+Atendida])
20:45 WF24 → v3_daily_reports + Gmail + plantilla reporte_diario_v3 a destinatarios
Botón "Ver detalle" → WF22 → WF1 route report_detail → texto completo en trozos
```

## 5. Errores y bordes

- Plantilla no aprobada aún: WF24 registra el fallo en `v3_report_sends` y el correo
  sigue saliendo. No bloquea el resto.
- Destinatario que toca `Ver detalle` sin estar en `v3_report_recipients`: se ignora.
- Botón tocado dos veces: se reenvía el mismo reporte (idempotente por naturaleza).
- Lead `unassigned` que después alguien toma a mano: fuera de alcance; el reporte lo
  muestra como sin asignación hasta que un cierre manual cambie el estado.
- Nota i24 con `manual_review` tras 5 intentos: visible en WF24 como problema.
- Nota manual previa en i24 con otro nombre: se agrega la nuestra igual (el equipo verá
  ambas); no hay conflicto como en EB porque i24 no tiene un solo "responsable".

## 6. Pruebas y verificación

- SQL: pruebas con rollback (receta docker PG17) para `v3_mark_unassigned`, sweep con
  `unassigned`, promoción de ledger EB con `attended_state='skipped'`, trigger y
  claim/finish de `i24_note_ledger`.
- JS: el renderer de WF24 vive en el Code node; se prueba con `node` sobre un fixture
  de `leads` (`whatsapp-agent/workflows/test_wf24_render.mjs`), verificando longitud
  de parámetros, ausencia de saltos de línea y trozos ≤ 4000.
- Python: pytest para `i24_notes.write_internal_note` con página falsa y para el parser
  de nota EB con `SIN ASIGNACIÓN`. Suite completa `PYTHONPATH=src python -m pytest -q`.
- n8n: cada workflow se parte del export vivo, se compara con el repo
  (`scripts/n8n_control.py`), se importa con `id`, `publish` y `docker restart`.
- Gates por fase: 0 = ningún correo a las :00/:30 del día siguiente; 1 = plantilla
  llega al WhatsApp de Esteban a las 20:45 y `Ver detalle` devuelve el texto completo;
  2 = un lead real termina `unassigned`, con nota EB y sin WhatsApp a Sandy; 3 = nota
  visible en un lead real de Inmuebles24 con captura de evidencia.

## 7. Riesgos

- Divergencia del Pi (cambios privados sin commit). Antes de la Fase 3 se reconcilian
  en una rama y se despliega desde git; hasta entonces no se toca el Pi.
- Aprobación de plantilla por Meta: fuera de nuestro control, típicamente < 24 h.
- Cloudflare/login en Inmuebles24: más navegaciones por lead (una extra). Volumen
  bajo (10–15 leads/día), reintentos existentes.
- Cambio de contrato V3: el documento
  `docs/superpowers/specs/2026-08-26-lead-routing-v3-contract.md` se actualiza en la
  Fase 2 (sección Sandy fallback → SIN ASIGNACIÓN).
