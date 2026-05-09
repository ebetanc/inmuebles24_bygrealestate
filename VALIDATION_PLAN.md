# PLAN DE VALIDACION COMPLETO — Inmobiliaria24

> **Fecha**: 2026-05-09
> **Autor**: Claude (analisis exhaustivo de todo el codigo, SQL, workflows y DB)
> **Objetivo**: Cero leads perdidos. Cero errores silenciosos. Sistema perfecto antes de go-live.

---

## RESUMEN DE HALLAZGOS

### BUGS CRITICOS (deben corregirse ANTES de go-live)

| # | Bug | Impacto | Donde |
|---|-----|---------|-------|
| C1 | **classify_sender() retorna multiples filas** para leads recurrentes | WF1 podria enrutar al lead a la conversacion EQUIVOCADA (la mas vieja, no la mas reciente) | `0004_evolution.sql`, WF1 |
| C2 | **WF6 cron no se ajusta a DST** — durante CST (nov-mar), agentes NUNCA se activan correctamente | 4 meses al ano, el sistema de turnos falla. Morning agents llegan 1 hr tarde, afternoon NUNCA se activan | WF6 cron `0 2,13,19 * * *` |
| C3 | **Mensajes de leads recurrentes quedan con conversation_id=NULL** | Historial de conversacion incompleto, AI bot no ve mensajes previos, dashboard no muestra mensajes | WF1 dedup SQL |
| C4 | **WF1 no maneja mode='night_queued'** para scraper leads nocturnos | Si un scraper lead nocturno escribe por WA, su mensaje se IGNORA | WF1 "Classify & Route" code |
| C5 | **Calendar editor delete+insert NO es atomico** | Si el INSERT falla despues del DELETE, se PIERDE todo el calendario del mes | `dashboard/calendario/actions.ts` |
| C6 | **Dashboard Supabase key ambigua** — el env var dice service_role pero podria ser anon | Si es anon: el calendario NO puede escribir (no hay policies INSERT/DELETE). Si es service_role: el dashboard tiene acceso total sin RLS | `dashboard/src/lib/supabase.ts` |

### BUGS MEDIOS (corregir antes o durante go-live)

| # | Bug | Impacto | Donde |
|---|-----|---------|-------|
| M1 | **WF1 human_forward no actualiza conversation_id del mensaje** | Mensajes en modo humano quedan huerfanos en la tabla messages | WF1 "Build Forward Message" path |
| M2 | **TOMO short_code tiene 65K combinaciones** — colision silenciosa | Con alto volumen, el INSERT fallaria por UNIQUE constraint y la subasta no se crea | WF3a "Create Auction Row" |
| M3 | **WF3a no reintenta si Evolution API falla** | continueOnFail=true traga el error. Agente nunca recibe TOMO notification | WF3a "Send via Evolution" |
| M4 | **find_returning_lead() busca por email OR phone** sin priorizar | Un email compartido entre familiares podria linkear leads incorrectamente | `0005_v5_24h_system.sql` |
| M5 | **WF2 "Find Matching Property" usa ILIKE con search_terms** | Busqueda demasiado amplia — "casa" matchea CUALQUIER propiedad con "casa" en titulo | WF2 "Find Matching Property" SQL |
| M6 | **Scraper espera 30 segundos por tab** — run total puede ser >2 min | Con 3 tabs, el scraper tarda 90s+ solo en esperar. Timeout del systemd timer podria matarlo | `scraper.py` lines 289, 300 |

### ADVERTENCIAS (monitorear post-go-live)

| # | Advertencia | Donde |
|---|-------------|-------|
| W1 | `messages.msg_external_id` index aun se llama `messages_twilio_sid_key` (legacy) | DB indexes |
| W2 | `properties_cache` vacia — AI bot no tendra contexto de propiedades hasta que se cachee | DB |
| W3 | `listings` vacia — WF2 "Find Matching Property" siempre retornara vacio hasta primer scrape | DB |
| W4 | `agent_schedule` tiene 28 filas de test que deben limpiarse | DB |
| W5 | Todos los Postgres nodes tienen `"id": "REPLACE_WITH_POSTGRES_CREDENTIAL_ID"` — hay que reconfigurar manualmente | Todos los WF JSONs |
| W6 | `scrape_logs` no se esta usando desde los workflows — solo desde el scraper local | DB/WFs |

---

## FASE 1: CORRECCION DE BUGS CRITICOS

### C1: Fix classify_sender() — multiples filas para leads recurrentes

**Problema**: Cuando `conversations.lead_phone` perdio su UNIQUE constraint (migracion 0005), `classify_sender()` paso a poder retornar N filas por un LEFT JOIN sin LIMIT. WF1 usa `$input.first().json` que toma la primera fila arbitraria — podria ser una conversacion vieja en modo 'human' cuando la actual esta en 'ai'.

**Fix SQL**:
```sql
CREATE OR REPLACE FUNCTION classify_sender(sender_phone TEXT)
RETURNS TABLE (
  is_agent BOOLEAN,
  agent_id TEXT,
  agent_name TEXT,
  conversation_id UUID,
  conv_mode TEXT,
  assigned_agent_id TEXT,
  current_property TEXT,
  assigned_agent_phone TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    (a.agent_id IS NOT NULL)::BOOLEAN AS is_agent,
    a.agent_id,
    a.name AS agent_name,
    c.conversation_id,
    c.mode AS conv_mode,
    c.assigned_agent_id,
    c.current_property,
    aa.whatsapp_number AS assigned_agent_phone
  FROM (SELECT sender_phone AS phone) AS input
  LEFT JOIN agents a ON a.whatsapp_number = input.phone
  LEFT JOIN LATERAL (
    SELECT * FROM conversations conv
    WHERE conv.lead_phone = input.phone
    ORDER BY conv.last_message_at DESC
    LIMIT 1
  ) c ON TRUE
  LEFT JOIN agents aa ON aa.agent_id = c.assigned_agent_id;
END;
$$ LANGUAGE plpgsql STABLE;
```

**Validacion**:
- [ ] Crear 2 conversaciones con el mismo telefono
- [ ] Llamar `classify_sender('ese_telefono')` — debe retornar exactamente 1 fila
- [ ] La fila debe ser la conversacion MAS RECIENTE (mayor last_message_at)

---

### C2: Fix WF6 DST — cron automatico con timezone

**Problema**: n8n schedule triggers usan cron en UTC. Cuando Mexico cambia de CDT a CST (primer domingo de noviembre) y viceversa (primer domingo de abril), los shift changes quedan desfasados 1 hora. Durante CST, morning agents NUNCA se activan a tiempo.

**Opcion A — cron con timezone en n8n** (preferida):
n8n soporta timezone en Schedule Trigger. Cambiar el trigger para usar timezone `America/Mexico_City`:
```json
{
  "rule": {
    "interval": [
      {
        "field": "cronExpression",
        "expression": "0 8,14,21 * * *"
      }
    ]
  },
  "timezone": "America/Mexico_City"
}
```

**Opcion B — doble cron** (si n8n no soporta timezone en ese node):
Usar 2 crons que cubran ambas zonas y filtrar por fecha:
```
CDT (abr-oct): 0 2,13,19 * * *
CST (nov-mar): 0 3,14,20 * * *
```
Con un Code node al inicio que verifica si la hora CDMX es 8, 14, o 21.

**Validacion**:
- [ ] Verificar que n8n Schedule Trigger soporta campo `timezone`
- [ ] Configurar con `America/Mexico_City`
- [ ] Probar ejecutando WF6 manualmente y verificar que `current_shift()` concuerda
- [ ] Documentar que NO requiere ajuste manual en cambio de horario

---

### C3: Fix mensajes huerfanos — linking de conversation_id

**Problema**: WF1 inserta TODOS los mensajes con `conversation_id = NULL`. Solo WF2 linkea mensajes de leads NUEVOS. Mensajes de leads recurrentes (ai, human, pending) quedan con NULL permanentemente.

**Fix en WF1**: Agregar un Postgres node despues de "Dedup + Classify Sender" que actualiza el conversation_id:
```sql
UPDATE messages
SET conversation_id = $1::uuid
WHERE msg_external_id = $2
  AND conversation_id IS NULL
  AND $1 IS NOT NULL;
```

Con queryReplacement: `={{ $json.conversation_id }},={{ $('Parse Evolution Payload').first().json.messageId }}`

Este node debe ejecutarse DESPUES del dedup, pero ANTES del routing, usando el conversation_id del classify_sender.

**Validacion**:
- [ ] Enviar mensaje desde lead existente (modo human)
- [ ] Verificar que `messages` tiene el `conversation_id` correcto
- [ ] Verificar que el dashboard muestra el mensaje en la conversacion correcta

---

### C4: Fix WF1 — agregar manejo de mode='night_queued'

**Problema**: Si un lead del scraper nocturno envia un mensaje por WhatsApp, su conversacion esta en mode='night_queued'. WF1 no tiene handler para este modo y lo ignora.

**Fix**: En el "Classify & Route" code node de WF1, agregar:
```javascript
if (mode === 'night_queued') {
  // Treat as AI conversation — same as WF2 night path
  return [{
    json: {
      route: 'ai_conversation',
      conversation_id: db.conversation_id,
      phone,
      pushName,
      text,
      messageId,
      current_property: db.current_property,
      assigned_agent_id: db.assigned_agent_id
    }
  }];
}
```

Y actualizar la conversacion a mode='ai' para que WF4 la atienda:
```sql
UPDATE conversations SET mode = 'ai' WHERE conversation_id = $1 AND mode = 'night_queued';
```

**Validacion**:
- [ ] Crear conversacion con mode='night_queued' en DB
- [ ] Enviar mensaje desde ese telefono
- [ ] WF1 debe enrutar a WF4 (AI conversation)
- [ ] Conversacion debe cambiar a mode='ai'

---

### C5: Fix calendario atomico

**Problema**: `saveMonthSchedule()` hace DELETE + INSERT como operaciones separadas. Si el INSERT falla, el calendario se pierde.

**Fix**: Usar upsert o transaccion. Supabase JS client no soporta transacciones nativas, pero podemos usar un RPC:

```sql
CREATE OR REPLACE FUNCTION save_month_schedule(
  p_first_date DATE,
  p_last_date DATE,
  p_rows JSONB -- [{schedule_date, shift, agent_id}, ...]
)
RETURNS INTEGER AS $$
DECLARE
  inserted INTEGER;
BEGIN
  -- Delete existing entries
  DELETE FROM agent_schedule
  WHERE schedule_date >= p_first_date
    AND schedule_date <= p_last_date;

  -- Insert new entries
  INSERT INTO agent_schedule (schedule_date, shift, agent_id)
  SELECT
    (r->>'schedule_date')::DATE,
    r->>'shift',
    r->>'agent_id'
  FROM jsonb_array_elements(p_rows) AS r;

  GET DIAGNOSTICS inserted = ROW_COUNT;
  RETURN inserted;
END;
$$ LANGUAGE plpgsql;
```

El dashboard llama: `supabase.rpc('save_month_schedule', { p_first_date, p_last_date, p_rows })`

**Validacion**:
- [ ] Guardar un calendario de mes completo
- [ ] Verificar en DB que los datos estan
- [ ] Intentar guardar con un agent_id invalido — debe fallar SIN borrar el calendario anterior

---

### C6: Clarificar Supabase key del dashboard

**Problema**: `supabase.ts` usa `SUPABASE_SERVICE_ROLE_KEY` pero el project status dice "anon key labeled as service_role". Esto es ambiguo y peligroso.

**Investigacion requerida**:
1. Ir a Supabase Dashboard > Settings > API
2. Comparar el valor de `SUPABASE_SERVICE_ROLE_KEY` en Vercel con las keys de Supabase
3. Si es anon key:
   - El calendario NO puede escribir (no hay INSERT/DELETE policies para anon)
   - Agregar policies: `CREATE POLICY "anon_manage_schedule" ON agent_schedule FOR ALL TO anon USING (true) WITH CHECK (true);`
   - O cambiar a service_role key
4. Si es service_role key:
   - El dashboard tiene acceso TOTAL a la DB (bypass RLS)
   - Aceptable para uso interno, pero documentar el riesgo
   - La middleware de auth previene acceso no autorizado al dashboard

**Validacion**:
- [ ] Verificar que key en Vercel
- [ ] Probar guardar calendario desde produccion
- [ ] Probar que las queries SELECT funcionan
- [ ] Documentar decision final

---

## FASE 2: VALIDACION BASE DE DATOS

### 2.1 Estado actual verificado

| Check | Estado | Notas |
|-------|--------|-------|
| 9 tablas existen | OK | agents, conversations, auctions, messages, properties_cache, listings, scrape_logs, agent_schedule, night_queue |
| RLS habilitado en todas | OK | 9/9 tablas con RLS |
| Policies SELECT anon | OK | 9 policies, una por tabla |
| Policies WRITE | FALTANTE | No hay policies INSERT/UPDATE/DELETE para anon — el calendario necesita esto si usa anon key |
| 7 funciones | OK | classify_sender, current_shift, evolution_phone, find_returning_lead, get_on_shift_agents, is_daytime, update_updated_at_column |
| is_daytime() | OK | Retorna false a las 3:53 AM CDMX |
| current_shift() | OK | Retorna 'night' a las 3:53 AM CDMX |
| get_on_shift_agents() | OK | Retorna vacio de noche (correcto) |
| 29 indexes | OK | Todos los indexes criticos presentes |

### 2.2 Queries de validacion para ejecutar en go-live

```sql
-- 1. Verificar funciones de tiempo
SELECT is_daytime(), current_shift(),
       NOW() AT TIME ZONE 'America/Mexico_City' AS cdmx_now;

-- 2. Verificar que los agentes tienen datos reales (NO placeholder)
SELECT agent_id, name, whatsapp_number,
       CASE WHEN whatsapp_number LIKE '52155000%' THEN 'PLACEHOLDER!'
            ELSE 'OK' END AS status
FROM agents;

-- 3. Verificar que get_on_shift_agents retorna agentes (durante el dia)
SELECT * FROM get_on_shift_agents();

-- 4. Verificar integridad de foreign keys
SELECT 'conversations sin agente valido' AS issue, count(*)
FROM conversations c
LEFT JOIN agents a ON a.agent_id = c.assigned_agent_id
WHERE c.assigned_agent_id IS NOT NULL AND a.agent_id IS NULL
UNION ALL
SELECT 'auctions sin conversacion', count(*)
FROM auctions a
LEFT JOIN conversations c ON c.conversation_id = a.conversation_id
WHERE c.conversation_id IS NULL
UNION ALL
SELECT 'night_queue sin conversacion', count(*)
FROM night_queue nq
LEFT JOIN conversations c ON c.conversation_id = nq.conversation_id
WHERE nq.conversation_id IS NOT NULL AND c.conversation_id IS NULL
UNION ALL
SELECT 'agent_schedule sin agente', count(*)
FROM agent_schedule s
LEFT JOIN agents a ON a.agent_id = s.agent_id
WHERE a.agent_id IS NULL;

-- 5. Verificar que classify_sender retorna 1 fila (DESPUES del fix C1)
-- Crear 2 convos con mismo telefono y verificar
INSERT INTO conversations (lead_phone, lead_name, mode, source)
VALUES ('test_999', 'Test Old', 'human', 'whatsapp_direct');
INSERT INTO conversations (lead_phone, lead_name, mode, source)
VALUES ('test_999', 'Test New', 'ai', 'whatsapp_direct');
SELECT count(*) AS rows_returned FROM classify_sender('test_999');
-- Debe retornar 1 (la mas reciente)
DELETE FROM conversations WHERE lead_phone = 'test_999';

-- 6. Verificar que no hay data huerfana
SELECT 'messages sin conversation_id' AS issue, count(*)
FROM messages WHERE conversation_id IS NULL;

-- 7. Verificar indices para performance
SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY idx_scan DESC;
```

---

## FASE 3: VALIDACION DE WORKFLOWS (11 workflows)

### 3.1 WF1 — Inbound Router

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Mensaje de WhatsApp nuevo lead | Evolution webhook con phone desconocido | Route = new_lead, llama WF2 | [ ] |
| 2 | Mensaje de agente con TOMO | Agent phone + "TOMO-AB12" | Route = agent_claim, llama WF3b | [ ] |
| 3 | Mensaje de agente sin TOMO | Agent phone + "hola" | Route = ignore (agent_non_claim) | [ ] |
| 4 | Lead en modo AI | Phone con conversacion mode='ai' | Route = ai_conversation, llama WF4 | [ ] |
| 5 | Lead en modo human | Phone con conversacion mode='human' | Forwarded al agente asignado | [ ] |
| 6 | Lead pending_assignment | Phone con mode='pending_assignment' | Envia "estamos buscando asesor" | [ ] |
| 7 | Lead night_queued (FIX C4) | Phone con mode='night_queued' | Route a AI, actualiza a mode='ai' | [ ] |
| 8 | Mensaje duplicado | Mismo messageId dos veces | Segundo ignorado (dedup) | [ ] |
| 9 | Mensaje de grupo | remoteJid con @g.us | Ignorado | [ ] |
| 10 | Status update (no mensaje) | event != messages.upsert | Ignorado | [ ] |
| 11 | Imagen/audio/video | No text content | Ignorado (unsupported_message_type) | [ ] |
| 12 | Lead recurrente (2 convos) | Phone con 2 conversations (FIX C1) | Enruta a la conversacion MAS RECIENTE | [ ] |
| 13 | TOMO case-insensitive | "tomo-ab12" en minusculas | Match correcto (regex usa /i flag) | [ ] |
| 14 | Linking de mensaje (FIX C3) | Cualquier lead con conversation existente | conversation_id actualizado en messages | [ ] |

### 3.2 WF2 — Lead Intake

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Lead diurno | Llamado por WF1 durante dia | Crea conversacion mode='pending_assignment', lanza WF3a | [ ] |
| 2 | Lead nocturno | Llamado por WF1 durante noche | Crea conversacion mode='night_queued', inserta night_queue, cambia a mode='ai', lanza WF4 | [ ] |
| 3 | Lead con property ID | Texto incluye "EB-12345" | extracted_property_id = 'EB-12345' | [ ] |
| 4 | Lead sin property | Texto generico | property = 'unknown', titulo = 'Propiedad (pendiente de identificar)' | [ ] |
| 5 | Lead con URL | Texto con https://... | extracted_url capturado | [ ] |
| 6 | Cache de propiedad | Lead con listing encontrado | properties_cache tiene entry | [ ] |
| 7 | Listings vacia | Tabla listings vacia | Find Matching Property retorna vacio, continua sin error | [ ] |

### 3.3 WF3a — Auction Launcher

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Subasta creada | conversation_id + property_id | Auction row con short_code de 4 chars, expires_at = NOW()+5min | [ ] |
| 2 | Agentes notificados | 2 agentes de guardia + manager | 3 mensajes enviados via Evolution | [ ] |
| 3 | Short code unico | Multiples subastas | Todos los short_codes son diferentes | [ ] |
| 4 | No agentes de guardia | agent_schedule vacio para hoy | Solo manager recibe notificacion | [ ] |
| 5 | Evolution API caida | Timeout en HTTP request | continueOnFail=true, error silencioso — ADVERTENCIA M3 | [ ] |
| 6 | notified_agents registrado | Despues de enviar | auctions.notified_agents tiene los agent_ids correctos | [ ] |
| 7 | Mensaje del agente incluye info correcta | N/A | TOMO code, property title, price, lead name | [ ] |

### 3.4 WF3b — Claim Handler

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Claim exitoso | Agent envia TOMO-XXXX, subasta open | UPDATE atomico, winner asignado, mode='ai' | [ ] |
| 2 | Claim tardio | Agent envia TOMO-XXXX, subasta ya claimed | No rows returned, "Too Late" message | [ ] |
| 3 | Claim expirado | Agent envia TOMO-XXXX, subasta expired | No rows returned, "Too Late" message | [ ] |
| 4 | Claim simultaneo | 2 agentes envian TOMO al mismo tiempo | Solo 1 gana (WHERE status='open' es atomico), otro recibe "Too Late" | [ ] |
| 5 | Winner recibe confirmacion | Claim exitoso | Mensaje con lead phone, property, instrucciones | [ ] |
| 6 | Lead recibe saludo | Claim exitoso | Mensaje AI greeting bilingue | [ ] |
| 7 | Perdedores notificados | 2+ agentes en pool | Los que no ganaron reciben "ya fue tomado" | [ ] |
| 8 | Conversation mode correcto | Despues de claim | mode = 'ai' (AI atiende, handoff a humano cuando necesario) | [ ] |

### 3.5 WF3c — Expiry Sweeper

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Subasta expirada detectada | Auction open con expires_at < NOW() | Status = 'expired', conversation assigned to manager | [ ] |
| 2 | Manager notificado | Subasta expirada | WhatsApp al manager con detalle del lead | [ ] |
| 3 | Sin subastas expiradas | Todas open o ya claimed | No action (query retorna vacio) | [ ] |
| 4 | Conversation mode actualizado | Subasta expirada | mode = 'human', assigned_agent_id = 'agent_manager' | [ ] |
| 5 | Multiples expiradas | 3 subastas expiradas | Las 3 procesadas, 3 notificaciones al manager | [ ] |

### 3.6 WF4 — AI Conversation

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Pregunta sobre propiedad | Lead pregunta "cuantas recamaras?" | AI responde con info de properties_cache | [ ] |
| 2 | Deteccion de handoff | Lead dice "quiero agendar visita" | WF5 ejecutado, mode cambia a 'human' | [ ] |
| 3 | Sin property en cache | properties_cache vacia | AI da respuesta generica, no crashea | [ ] |
| 4 | Historial de conversacion | Multiples mensajes | AI tiene contexto de mensajes previos | [ ] |
| 5 | OpenRouter timeout | API no responde | Error manejado, lead recibe mensaje de fallback o nada | [ ] |
| 6 | Mensaje guardado | Respuesta de AI | Registrado en messages con sender_type='ai' | [ ] |

### 3.7 WF5 — Human Handoff

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Handoff exitoso | Llamado por WF4 | mode = 'human', agente notificado con resumen | [ ] |
| 2 | Lead notificado | Handoff | Lead recibe "te conectamos con [nombre]" | [ ] |
| 3 | Sin agente asignado | conversation sin assigned_agent_id | Fallback al manager | [ ] |

### 3.8 WF6 — Guard Schedule Sync

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Morning sync | Ejecutar a las 8 AM CDMX | 2 agentes con on_shift=true, shift_slot='morning' | [ ] |
| 2 | Afternoon sync | Ejecutar a las 2 PM CDMX | 2 agentes cambian a shift_slot='afternoon' | [ ] |
| 3 | Night sync | Ejecutar a las 9 PM CDMX | Todos off (current_shift='night', UPDATE no activa nadie) | [ ] |
| 4 | Sin schedule | Dia sin datos en agent_schedule | Fallback a on_shift flag manual | [ ] |
| 5 | Manager siempre activo | Cualquier hora | agent_manager mantiene on_shift=true (no se toca) | [ ] |
| 6 | DST transition (FIX C2) | Cambio de horario | Cron con timezone auto-ajusta | [ ] |

### 3.9 WF7 — Morning Report

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Reporte con leads | night_queue tiene items | Manager recibe resumen por WhatsApp | [ ] |
| 2 | Reporte vacio | night_queue vacia | Manager recibe "sin leads nocturnos" o no recibe nada | [ ] |
| 3 | Auto-TOMO 8:05 | 5 min despues del reporte | Cada lead de night_queue entra en subasta TOMO | [ ] |
| 4 | night_queue marcada processed | Despues de auto-TOMO | processed=true, processed_at filled | [ ] |
| 5 | Lead con bot_summary | WA lead nocturno con AI interaction | Resumen incluido en el reporte | [ ] |

### 3.10 WF8 — EasyBroker Polling

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Contacto nuevo | EasyBroker API retorna contact no procesado | Conversacion creada, subasta lanzada (dia) o night_queue (noche) | [ ] |
| 2 | Contacto ya procesado | Contacto que ya esta en conversations | Skipado (dedup) | [ ] |
| 3 | API sin contactos | Array vacio | Termina sin error | [ ] |
| 4 | API key invalida | 401 error | Error loggeado, no crash | [ ] |

### 3.11 WF10 — Scraper Intake

| # | Test | Input | Resultado esperado | Status |
|---|------|-------|-------------------|--------|
| 1 | Lead nuevo, dia | Webhook con lead data, hora dia | Conversacion mode='pending_assignment', TOMO lanzado | [ ] |
| 2 | Lead nuevo, noche | Webhook con lead data, hora noche | Conversacion mode='night_queued', night_queue insert | [ ] |
| 3 | Lead recurrente, misma propiedad | Mismo phone + listing_id | Update last_message_at, notifica agente asignado | [ ] |
| 4 | Lead recurrente, diferente propiedad | Mismo phone, diferente listing_id | Nueva conversacion + nueva subasta | [ ] |
| 5 | Lead sin telefono | phone vacio | Skip (route='skip', reason='no_phone') | [ ] |
| 6 | Array de multiples leads | Webhook con [lead1, lead2, lead3] | Cada uno procesado individualmente | [ ] |
| 7 | Returning lead sin agente | Returning pero assigned_agent_id = null | skip=true, reason='no_assigned_agent' | [ ] |

---

## FASE 4: VALIDACION DEL SCRAPER

### 4.1 Configuracion

| # | Check | Validacion | Status |
|---|-------|------------|--------|
| 1 | WEBHOOK_URL configurado | No vacio en .env | [ ] |
| 2 | WEBHOOK_URL rechaza vacioexplicitamente | `scraper.py:511` lanza ValueError | [ ] |
| 3 | Credenciales Inmuebles24 | INMUEBLES24_EMAIL + PASSWORD en .env | [ ] |
| 4 | State DB writable | STATE_DB_PATH apunta a directorio con permisos | [ ] |
| 5 | Telegram alertas configuradas | TELEGRAM_BOT_TOKEN + CHAT_ID | [ ] |
| 6 | Playwright + Chromium instalados | `.venv/bin/python -c "import playwright"` | [ ] |

### 4.2 Flujo end-to-end

| # | Test | Validacion | Status |
|---|------|------------|--------|
| 1 | Dry run | `python -m inmobiliaria24 --dry-run` — session valida | [ ] |
| 2 | Login Inmuebles24 | Cloudflare bypass + login form | [ ] |
| 3 | Extraccion leads | Navegar a /panel/interesados, extraer Pendientes | [ ] |
| 4 | Dedup local | StateStore filtra leads ya vistos | [ ] |
| 5 | Webhook delivery | POST a WF10 con retry (3 intentos, exponential backoff) | [ ] |
| 6 | Session recovery | Si session stale, re-login automatico | [ ] |
| 7 | Error alerting | Si falla, Telegram alert enviado | [ ] |
| 8 | Screenshot on error | `/logs/error_*.png` capturado | [ ] |

### 4.3 Riesgos del scraper

| Riesgo | Probabilidad | Mitigacion |
|--------|-------------|------------|
| Inmuebles24 cambia su HTML/React | Alta (cada 2-3 meses) | 2 estrategias de extraccion (links vs click), screenshots de debug |
| Cloudflare bloquea | Media | `_wait_for_cloudflare()` en auth.py, retry con backoff |
| Rate limiting | Baja | Delays de 2-3.5s entre paginas, 30s por tab |
| Session expira mid-run | Media | `SessionStaleError` + re-login automatico |
| Chromium crash en RPi | Baja | systemd timer re-ejecuta cada 2 hrs |
| Webhook n8n caido | Baja | 3 retries con exponential backoff (2, 4, 8 seg) |

---

## FASE 5: VALIDACION DEL DASHBOARD

### 5.1 Autenticacion

| # | Test | Validacion | Status |
|---|------|------------|--------|
| 1 | Login con password correcto | Cookie `dashboard_session` creada, redirect a / | [ ] |
| 2 | Login con password incorrecto | Error "Contrasena incorrecta" | [ ] |
| 3 | Acceso sin cookie | Redirect a /login | [ ] |
| 4 | Cookie invalida | Redirect a /login, cookie borrada | [ ] |
| 5 | DASHBOARD_PASSWORD no configurada | Error claro "no configurado" | [ ] |
| 6 | Session persiste 30 dias | maxAge = 30 dias en cookie | [ ] |
| 7 | Logout | Cookie borrada, redirect a /login | [ ] |

### 5.2 Dashboard pages

| # | Pagina | Datos que muestra | Que puede fallar |
|---|--------|------------------|-----------------|
| 1 | / (overview) | KPIs, leads hoy/semana, auctions activas, night queue | Supabase query falla → datos en 0 |
| 2 | /leads | 20 conversaciones recientes con JOIN agents | agents JOIN retorna null si no hay agente |
| 3 | /agentes | Agentes con is_available=true | Solo muestra 6 agentes (excluyendo manager si is_available=true) |
| 4 | /subastas | Auctions con status='open' | Si no hay auctions abiertas, muestra vacio |
| 5 | /calendario | Editor mensual de guardias | **CRITICO: verificar que puede escribir (C6)** |
| 6 | /nocturno | night_queue con processed=false | Muestra items no procesados |

### 5.3 Calendario editor

| # | Test | Validacion | Status |
|---|------|------------|--------|
| 1 | Cargar mes actual | Muestra dias del mes con dropdowns de agentes | [ ] |
| 2 | Asignar agentes | Seleccionar 2 agentes por turno | [ ] |
| 3 | Guardar mes | INSERT en agent_schedule exitoso | [ ] |
| 4 | Recargar despues de guardar | Datos persisten correctamente | [ ] |
| 5 | Sobreescribir mes | Guardar el mismo mes de nuevo — DELETE+INSERT | [ ] |
| 6 | Mes sin datos | Mes futuro sin schedule | Muestra vacio, permite crear | [ ] |
| 7 | Agente duplicado en mismo turno | Mismo agente en Manana 1 y Manana 2 | Deberia alertar o prevenir (UNIQUE constraint lo bloquea) | [ ] |

---

## FASE 6: VALIDACION EVOLUTION API + WHATSAPP

### 6.1 Configuracion

| # | Check | Como verificar | Status |
|---|-------|---------------|--------|
| 1 | Instancia existe | `GET /instance/connectionState/inmobiliaria24` | [ ] |
| 2 | WhatsApp conectado | state = 'open' | [ ] |
| 3 | Webhook configurado | `GET /webhook/find/inmobiliaria24` apunta a WF1 | [ ] |
| 4 | Webhook solo MESSAGES_UPSERT | No otros eventos innecesarios | [ ] |
| 5 | API key valida | Header `apikey` funciona en requests | [ ] |

### 6.2 Formato de mensajes

| # | Test | Validacion | Status |
|---|------|------------|--------|
| 1 | Enviar texto simple | `POST /message/sendText/inmobiliaria24` con number + text | [ ] |
| 2 | Numero con codigo de pais | `5215512345678` (sin +, sin @s.whatsapp.net) | [ ] |
| 3 | Delay entre mensajes | `delay: 1200` (1.2 seg) — anti-spam | [ ] |
| 4 | Mensaje con emojis | Unicode emojis en auction notifications | [ ] |
| 5 | Mensaje largo | TOMO notification con 5+ lineas | [ ] |
| 6 | Timeout de 10-15s | httpRequest timeout configurado | [ ] |

### 6.3 Riesgos WhatsApp

| Riesgo | Mitigacion |
|--------|------------|
| WhatsApp bans por mensajes masivos | Delay de 1.2s, maximo ~10 msgs/min |
| Desconexion de WhatsApp | Monitor periodico, alerta al manager |
| Numero reportado como spam | Mensajes solo a leads que contactaron primero |
| Multi-device conflict | Un solo telefono para el bot, sin WA Business |

---

## FASE 7: VALIDACION END-TO-END (10 escenarios)

### E2E-1: Lead WhatsApp directo — DIA completo

```
[Lead envia WA] → WF1 → WF2 → WF3a → [Agente ve TOMO]
→ [Agente responde TOMO-XXXX] → WF1 → WF3b → [Lead recibe AI greeting]
→ [Lead pregunta sobre propiedad] → WF1 → WF4 → [AI responde]
→ [Lead pide visita] → WF4 → WF5 → [Agente recibe resumen + lead recibe "te conectamos"]
```

Verificar en cada paso:
- [ ] conversations: mode transitions (pending → ai → human)
- [ ] auctions: status transitions (open → claimed)
- [ ] messages: todos los mensajes registrados con conversation_id correcto
- [ ] agents: on_shift correctos
- [ ] Dashboard: todo visible en tiempo real

### E2E-2: Lead WhatsApp directo — NOCHE completo

```
[Lead envia WA 10PM] → WF1 → WF2 → [AI greeting nocturno]
→ [Lead pregunta] → WF1 → WF4 → [AI responde]
→ [8:00 AM] → WF7 → [Manager recibe reporte]
→ [8:05 AM] → WF7 → WF3a → [TOMO a agentes de turno manana]
→ [Agente responde TOMO] → WF3b → [Claim exitoso]
```

### E2E-3: Lead scraper — DIA

```
[Scraper extrae lead] → POST webhook → WF10 → Create conversation → WF3a → TOMO
```

### E2E-4: Lead scraper — NOCHE

```
[Scraper extrae lead 11PM] → WF10 → night_queue → [8:05 AM] → auto-TOMO
```

### E2E-5: Lead EasyBroker

```
[WF8 polls EB API] → Nuevo contacto → Create conversation → WF3a → TOMO
```

### E2E-6: Lead recurrente misma propiedad

```
[Lead ya asignado a Lupita] → [Scraper encuentra misma propiedad]
→ WF10 → returning_same → Update last_message_at → Notify Lupita
```

### E2E-7: Lead recurrente diferente propiedad

```
[Lead ya asignado] → [Nuevo lead con propiedad diferente]
→ WF10 → day_auction → Nueva conversation → WF3a → TOMO
```

### E2E-8: Subasta expirada

```
[TOMO enviado, nadie responde en 5 min] → WF3c → Expire → Assign to manager → Notify manager
```

### E2E-9: Guard schedule change

```
[Manager edita calendario en dashboard] → Guardar → [WF6 ejecuta] → agents.on_shift actualizado
```

### E2E-10: Scraper failure + recovery

```
[Scraper falla] → Telegram alert → [Re-run manual] → Session recovery → Leads extraidos
```

---

## FASE 8: VALIDACION DE SEGURIDAD

| # | Check | Como verificar | Status |
|---|-------|---------------|--------|
| 1 | No hay secretos en git | `git log --all -p \| grep -iE "api.key\|password\|secret\|jwt" \| head -30` | [ ] |
| 2 | .gitignore cubre .env* | Verificar patterns | [x] Done (May 8) |
| 3 | n8n JWT rotado | Settings > API Keys (viejo esta en git history commit 1a941d9) | [ ] URGENTE |
| 4 | Dashboard HTTPS | Vercel auto-HTTPS | [x] |
| 5 | n8n HTTPS | Via Hostinger reverse proxy | [ ] Verificar |
| 6 | Evolution API key unica | No compartida con otros servicios | [ ] |
| 7 | Webhook URLs no predecibles | UUID-based paths, no /webhook/leads | [ ] |
| 8 | RPi SSH con key | No password auth | [ ] |
| 9 | RPi .env permisos 600 | `chmod 600 .env` | [ ] |
| 10 | Dashboard password fuerte | Minimo 16 chars, random | [ ] |
| 11 | Cookie httpOnly + secure | Ya implementado en auth | [x] |
| 12 | Cookie sameSite=lax | Previene CSRF basico | [x] |

---

## FASE 9: MONITOREO POST-GO-LIVE

### 9.1 Alertas automaticas

| Alerta | Quien detecta | Quien recibe | Accion |
|--------|--------------|-------------|--------|
| Scraper falla | monitor.py via Telegram | Manager + Dev | SSH a RPi, revisar logs |
| Scraper sin exito 24h | check_stale_runs() | Manager + Dev | Login manual, verificar Inmuebles24 |
| Subasta expirada (nadie respondio) | WF3c | Manager via WA | Asignacion manual |
| WF6 sin agentes | WF6 Summary | (no alerting!) | **AGREGAR: notificar manager** |
| Evolution desconectado | (no detectado!) | Nadie | **AGREGAR: health check WF** |
| n8n caido | (no detectado!) | Nadie | **AGREGAR: UptimeRobot** |

### 9.2 Metricas a monitorear (primera semana)

| Metrica | Donde | Frecuencia | Alerta si |
|---------|-------|-----------|-----------|
| Leads por dia | Dashboard KPIs | Continua | 0 leads en dia laboral |
| Subastas abiertas | Dashboard | Continua | >3 subastas open simultaneas |
| Tiempo de claim | auctions.claimed_at - created_at | Diario | Promedio > 3 min |
| Tasa de expiracion | expired / total auctions | Diario | >30% |
| Night queue size | Dashboard | Diario 7AM | >10 items |
| n8n execution errors | n8n UI | 2x/dia | Cualquier error |
| Scraper success rate | scrape_logs / systemd journal | Diario | <80% |
| Evolution state | API health check | Cada hora | state != 'open' |

---

## ORDEN DE EJECUCION RECOMENDADO

```
DIA -1: Corregir bugs criticos (C1-C6) en codigo
         - Fix classify_sender SQL
         - Fix WF6 timezone
         - Fix WF1 message linking
         - Fix WF1 night_queued handling
         - Fix calendario atomico
         - Clarificar Supabase key
         - Commit + push + deploy

DIA 0:  Datos del cliente (Etapa 0 del GO_LIVE_CHECKLIST)

DIA 1:  DB cleanup + agentes reales + calendario
         - Ejecutar validaciones Fase 2
         - Importar workflows + reconfigurar Postgres credentials
         - Ejecutar validaciones Fase 3 (test cada WF manualmente)

DIA 2:  Evolution + Scraper + EasyBroker
         - Ejecutar validaciones Fase 6
         - Ejecutar validaciones Fase 4
         - Ejecutar validaciones Fase 5

DIA 3:  End-to-end tests (Fase 7)
         - Los 10 escenarios E2E
         - Fix cualquier issue encontrado

DIA 4:  Security audit (Fase 8) + Go-live (Fase 9)
         - Rotar n8n JWT (URGENTE)
         - Activar workflows en orden
         - Monitorear primera hora
```

---

## APENDICE: MAPA DE DATOS COMPLETO

```
                    LEADS
                      |
        +-------------+-------------+
        |             |             |
   Inmuebles24    EasyBroker    WhatsApp
   (scraper)      (WF8 poll)    (directo)
        |             |             |
        v             v             v
      WF10          WF8           WF1
        |             |             |
        +------+------+      +-----+-----+
               |              |           |
          is_daytime?    classify_sender   |
          /        \         |            |
         v          v        v            v
       DAY        NIGHT    new_lead    existing
        |           |        |         /  |  \
        v           v        v        v   v   v
      WF3a    night_queue   WF2     WF4  WF5  forward
    (TOMO)    + WF7 8AM      |       |    |     |
        |                    |       |    |     |
        v              is_daytime?   v    v     v
    auctions            /      \   AI   handoff agent
    (5 min)            v        v  bot    to    gets
        |            WF3a    night    human  msg
    +---+---+       (TOMO)   queue
    |       |
  claimed  expired
    |       |
    v       v
  WF3b   WF3c
  (win)  (escalate)
    |       |
    v       v
  mode=   mode=
   ai     human
    |     (manager)
    v
  WF4 → WF5
  (AI)  (handoff)
```

### Tablas afectadas por cada workflow:

| WF | SELECT | INSERT | UPDATE | DELETE |
|----|--------|--------|--------|--------|
| WF1 | messages, agents, conversations | messages | messages | - |
| WF2 | conversations, listings, properties_cache | conversations, messages, night_queue, properties_cache | messages, conversations | - |
| WF3a | agents, agent_schedule, auctions | auctions, messages | auctions | - |
| WF3b | auctions, conversations, properties_cache, agents | - | auctions, conversations | - |
| WF3c | auctions, conversations | - | auctions, conversations | - |
| WF4 | conversations, messages, properties_cache | messages | conversations | - |
| WF5 | conversations, agents | messages | conversations | - |
| WF6 | agents, agent_schedule | - | agents | - |
| WF7 | night_queue, conversations | - | night_queue | - |
| WF8 | conversations | conversations | - | - |
| WF10 | conversations, agents | conversations, night_queue, properties_cache | conversations | - |
| Dashboard | ALL (read-only for most) | agent_schedule | - | agent_schedule |
