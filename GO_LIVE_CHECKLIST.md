# GO-LIVE CHECKLIST — Inmobiliaria24 v5
# Sistema 24/7 de Gestion de Leads BYG Real Estate

> **Estado**: PRE-PRODUCCION
> **Fecha**: 2026-05-08
> **Objetivo**: Poner el sistema completo en vivo con cero leads perdidos

---

## RESUMEN EJECUTIVO

El sistema tiene ~80% del codigo listo pero 0% listo para produccion.
Los problemas criticos son:

1. **Telefonos de agentes son placeholder** (5215500000001-6) — no hay numeros reales
2. **WhatsApp no conectado** — falta escanear QR code
3. **Scraper no conectado a n8n** — webhook URL no configurado en produccion
4. **Calendario de guardias vacio** — llenar desde el dashboard /calendario
5. **Base de datos tiene data de prueba** — necesita limpieza antes de go-live
6. **Sin autenticacion en el dashboard** — cualquiera con la URL ve los datos
7. **Sin politicas RLS para escritura** — n8n usa service_role (OK, pero documentar)

---

## ETAPA 0: DATOS DEL CLIENTE (Bloqueante — sin esto no se puede avanzar)

### 0.1 Datos que BYG debe proveer

| # | Dato | Formato | Status |
|---|------|---------|--------|
| 1 | **Numeros WhatsApp de las 6 agentes** | Digitos con codigo de pais, sin +. Ej: `5215598765432` | [ ] Pendiente |
| 2 | **Numero WhatsApp del manager** | Mismo formato | [ ] Pendiente |
| 3 | **Emails de EasyBroker de cada agente** | Para vincular contactos asignados | [ ] Pendiente |
| 4 | **API key de EasyBroker** | Con permisos de lectura Y escritura de contactos | [ ] Verificar si la actual tiene permisos de escritura |
| 5 | **Confirmacion de horarios** | 8AM-2PM turno 1, 2PM-9PM turno 2, 9PM-8AM noche | [ ] Pendiente |
| 6 | **Calendario de guardias del primer mes** | Se llena desde el dashboard en /calendario | [ ] Pendiente |
| 7 | **Numero de WhatsApp para el bot** | El numero que publicaran para que leads escriban | [ ] Pendiente (es el mismo de Evolution?) |

### 0.2 Accesos tecnicos requeridos

| # | Servicio | Que necesito | Status |
|---|----------|-------------|--------|
| 1 | **Supabase** | Ya tengo acceso via MCP | [x] Listo |
| 2 | **n8n VPS** | URL + login: https://n8n.srv856940.hstgr.cloud/ | [ ] Verificar acceso actual |
| 3 | **Evolution API VPS** | SSH o panel para configurar webhook + QR | [ ] Verificar acceso |
| 4 | **Raspberry Pi** (scraper) | SSH para deploy del scraper | [ ] Verificar acceso |
| 5 | **EasyBroker** | API key con permisos completos | [ ] Verificar permisos |
| 6 | **OpenRouter** | API key — ya configurado | [x] Listo |
| 7 | **Vercel** (dashboard) | Ya desplegado | [x] Listo |

---

## ETAPA 1: LIMPIEZA DE BASE DE DATOS (30 min)

**Prerequisito**: Etapa 0 completada (numeros reales de agentes)

### 1.1 Limpiar datos de prueba

```sql
-- EJECUTAR EN ESTE ORDEN (por foreign keys)
DELETE FROM messages;
DELETE FROM night_queue;
DELETE FROM auctions;
DELETE FROM conversations;
DELETE FROM agent_schedule;
DELETE FROM scrape_logs;
DELETE FROM listings;
DELETE FROM properties_cache;
```

- [ ] Ejecutar limpieza en Supabase SQL Editor
- [ ] Verificar que todas las tablas estan vacias

### 1.2 Actualizar agentes con datos reales

```sql
UPDATE agents SET
  name = 'NOMBRE_REAL',
  whatsapp_number = 'NUMERO_REAL',
  easybroker_email = 'EMAIL_REAL',
  on_shift = false,
  is_available = true,
  shift_slot = NULL
WHERE agent_id = 'agent_lupita';
-- Repetir para: agent_paty, agent_yol, agent_gina, agent_carol, agent_moni

UPDATE agents SET
  name = 'NOMBRE_MANAGER',
  whatsapp_number = 'NUMERO_MANAGER',
  on_shift = true,
  is_available = true
WHERE agent_id = 'agent_manager';
```

- [ ] Actualizar los 7 agentes con datos reales
- [ ] Verificar: `SELECT agent_id, name, whatsapp_number, easybroker_email FROM agents;`

### 1.3 Verificar funciones de DB

- [ ] Probar `SELECT is_daytime();` — debe retornar true/false segun hora CDMX
- [ ] Probar `SELECT current_shift();` — debe retornar 'morning', 'afternoon', o 'night'
- [ ] Probar `SELECT * FROM get_on_shift_agents();` — debe estar vacio (nadie asignado aun)
- [ ] Probar `SELECT * FROM find_returning_lead('5215500000001');` — debe estar vacio

### 1.4 Verificar indices

```sql
SELECT indexname, tablename FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;
```

Indices esperados:
- [ ] `idx_agent_schedule_date` en agent_schedule
- [ ] `idx_night_queue_pending` en night_queue
- [ ] `idx_conversations_lead_phone` en conversations
- [ ] `idx_conversations_lead_email` en conversations
- [ ] `idx_conversations_phone_property` en conversations

---

## ETAPA 2: CALENDARIO DE GUARDIAS (30 min)

> **Google Sheets eliminado** — el calendario se gestiona directamente desde el dashboard
> en `/calendario`. Los datos se guardan en la tabla `agent_schedule` de Supabase.

### 2.1 Llenar el calendario desde el dashboard

- [ ] Ir a `https://[DASHBOARD_URL]/calendario`
- [ ] Seleccionar el mes actual
- [ ] Asignar 2 agentes por turno por dia (Manana + Tarde)
- [ ] Usar "Auto-rotacion" como base y ajustar manualmente
- [ ] Click "Guardar mes"

### 2.2 Verificar datos en Supabase

- [ ] Verificar: `SELECT * FROM agent_schedule WHERE schedule_date = CURRENT_DATE;`
- [ ] Verificar: `SELECT * FROM get_on_shift_agents();` — debe retornar 2 agentes

### 2.3 Test de WF6

- [ ] Ejecutar WF6 manualmente en n8n
- [ ] Verificar: `SELECT agent_id, name, on_shift, shift_slot FROM agents WHERE on_shift = true;`
- [ ] Debe mostrar los 2 agentes del turno actual con on_shift=true

---

## ETAPA 3: CONFIGURACION DE n8n (2-3 horas)

### 3.1 Variables de entorno en n8n

Establecer TODAS las siguientes en **Settings > Environment Variables**:

```
# Evolution API
EVOLUTION_API_URL=https://[TU_URL_EVOLUTION]
EVOLUTION_INSTANCE=inmobiliaria24
EVOLUTION_API_KEY=[TU_API_KEY]

# Manager
MANAGER_PHONE=[NUMERO_REAL_MANAGER]

# EasyBroker
EASYBROKER_API_KEY=[TU_API_KEY]

# OpenRouter
OPENROUTER_API_KEY=[TU_API_KEY]
OPENROUTER_MODEL=anthropic/claude-sonnet-4

# Workflow IDs (llenar DESPUES de importar)
WF2_WORKFLOW_ID=
WF3A_WORKFLOW_ID=
WF3B_WORKFLOW_ID=
WF4_WORKFLOW_ID=
WF5_WORKFLOW_ID=
WF6_WORKFLOW_ID=
WF8_WORKFLOW_ID=
WF10_WORKFLOW_ID=

# Guard Schedule — managed via dashboard /calendario (no env vars needed)
```

- [ ] Todas las variables de entorno configuradas
- [ ] Reiniciar n8n despues de cambiar variables

### 3.2 Importar workflows (en orden)

Importar desde `whatsapp-agent/workflows/`:

| Orden | Archivo | Descripcion | Activar? |
|-------|---------|-------------|----------|
| 1 | WF3c_expiry_sweeper.json | Sweeper de subastas expiradas (cada 1 min) | SI — Schedule trigger |
| 2 | WF5_human_handoff.json | Handoff a agente humano | NO — llamado por otros |
| 3 | WF4_ai_conversation.json | Conversacion AI (OpenRouter) | NO — llamado por otros |
| 4 | WF3b_claim_handler.json | Handler de claims TOMO | NO — llamado por WF1 |
| 5 | WF3a_auction_launcher.json | Lanzador de subastas | NO — llamado por WF2/WF10 |
| 6 | WF2_lead_intake.json | Intake de leads WhatsApp | NO — llamado por WF1 |
| 7 | WF6_guard_schedule.json | Sync on_shift flag from agent_schedule | SI — Schedule trigger |
| 8 | WF7_morning_report.json | Reporte matutino 8 AM | SI — Schedule trigger |
| 9 | WF8_easybroker_polling.json | Polling EasyBroker cada 15 min | SI — Schedule trigger |
| 10 | WF10_scraper_intake.json | Webhook del scraper | SI — Webhook trigger |
| 11 | WF1_inbound_router.json | Router de WhatsApp entrante | SI — Webhook trigger |

- [ ] Importar todos los workflows
- [ ] Anotar CADA workflow ID (del URL bar de n8n)
- [ ] Actualizar las variables de entorno con los IDs
- [ ] Reiniciar n8n

### 3.3 Configurar credenciales de Postgres en cada workflow

Para CADA workflow importado:
- [ ] Abrir el workflow
- [ ] Click en CADA nodo Postgres
- [ ] Seleccionar credencial `Postgres - Supabase`
- [ ] Guardar

Conteo de nodos Postgres por workflow (verificar TODOS):
| Workflow | Nodos Postgres estimados |
|----------|--------------------------|
| WF1 | 3-4 (lookup conversacion, dedup, classify) |
| WF2 | 4-5 (create conversation, property match, returning lead) |
| WF3a | 3 (create auction, get agents, notify) |
| WF3b | 3-4 (atomic claim, update conversation, notify) |
| WF3c | 2-3 (find expired, update status, escalate) |
| WF4 | 3 (get context, save message, check handoff) |
| WF5 | 2-3 (update mode, notify agent) |
| WF6 | 1 (sync on_shift from agent_schedule) |
| WF7 | 4-5 (query night_queue, conversations, compose report) |
| WF8 | 3-4 (check processed, create conversation, launch auction) |
| WF10 | 4-5 (returning lead check, create conversation, route day/night) |

- [ ] **TOTAL: ~35-40 nodos Postgres** — TODOS deben tener credencial asignada

### 3.4 Verificar triggers con schedule

| Workflow | Schedule esperado | Verificar |
|----------|-------------------|-----------|
| WF3c | Cada 1 minuto | [ ] |
| WF6 | 8 AM + 2 PM + 9 PM CDMX (shift changes) | [ ] |
| WF7 | 8:00 AM CDMX + 8:05 AM CDMX | [ ] |
| WF8 | Cada 15 minutos | [ ] |

### 3.6 Anotar las URLs de webhook

Despues de activar WF1 y WF10, anotar:
- [ ] WF1 webhook URL: `https://n8n.srv856940.hstgr.cloud/webhook/________`
- [ ] WF10 webhook URL: `https://n8n.srv856940.hstgr.cloud/webhook/________`

Estas URLs se necesitan para Evolution API y para el scraper.

---

## ETAPA 4: EVOLUTION API + WHATSAPP (1-2 horas)

### 4.1 Verificar instancia de Evolution

```bash
# Verificar estado de la instancia
curl -X GET "https://[EVOLUTION_URL]/instance/connectionState/inmobiliaria24" \
  -H "apikey: [API_KEY]"
```

- [ ] Instancia responde y esta en estado `close` o `open`

### 4.2 Conectar WhatsApp (QR Code)

```bash
# Generar QR code
curl -X GET "https://[EVOLUTION_URL]/instance/connect/inmobiliaria24" \
  -H "apikey: [API_KEY]"
```

- [ ] Escanear QR code con el telefono designado para el bot
- [ ] Verificar estado = `open`
- [ ] **IMPORTANTE**: Este telefono NO debe tener WhatsApp Business ya instalado (conflicto)

### 4.3 Configurar webhook de Evolution

```bash
curl -X POST "https://[EVOLUTION_URL]/webhook/set/inmobiliaria24" \
  -H "apikey: [API_KEY]" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "[WF1_WEBHOOK_URL_DE_ETAPA_3.6]",
    "webhook_by_events": false,
    "webhook_base64": false,
    "events": ["MESSAGES_UPSERT"]
  }'
```

- [ ] Webhook configurado apuntando al WF1 de n8n
- [ ] Verificar: `curl -X GET "https://[EVOLUTION_URL]/webhook/find/inmobiliaria24" -H "apikey: [API_KEY]"`

### 4.4 Test de conectividad

- [ ] Enviar un mensaje de WhatsApp al numero del bot desde un telefono de prueba
- [ ] Verificar que WF1 se ejecuta en n8n (revisar Executions)
- [ ] Si NO se ejecuta: revisar webhook URL, estado de Evolution, logs de n8n

---

## ETAPA 5: SCRAPER EN RASPBERRY PI (1-2 horas)

### 5.1 Verificar el scraper actual

```bash
# SSH al Raspberry Pi
ssh user@[IP_RASPBERRY]

# Verificar que el codigo existe
ls -la /opt/inmobiliaria24/

# Verificar Python y dependencias
/opt/inmobiliaria24/.venv/bin/python --version
/opt/inmobiliaria24/.venv/bin/python -c "import playwright; print('OK')"
```

- [ ] Python 3.12+ instalado
- [ ] Playwright instalado y funcional
- [ ] Chromium browser disponible

### 5.2 Configurar .env del scraper

```bash
# En /opt/inmobiliaria24/.env
INMUEBLES24_EMAIL=[email_real]
INMUEBLES24_PASSWORD=[password_real]
WEBHOOK_URL=[WF10_WEBHOOK_URL_DE_ETAPA_3.6]
STATE_DB_PATH=/opt/inmobiliaria24/data/state.db
TELEGRAM_BOT_TOKEN=[token_para_alertas]
TELEGRAM_ALERT_CHAT_ID=[chat_id]
```

- [ ] .env configurado con credenciales reales
- [ ] WEBHOOK_URL apunta al WF10 de n8n
- [ ] Directorio `data/` existe y tiene permisos de escritura

### 5.3 Test manual del scraper

```bash
cd /opt/inmobiliaria24
.venv/bin/python -m inmobiliaria24 --dry-run
```

- [ ] Scraper arranca sin errores
- [ ] Puede hacer login en Inmuebles24
- [ ] Extrae leads (o reporta 0 pendientes)
- [ ] Dry-run no envia webhook pero muestra los leads

### 5.4 Test real (sin dry-run)

```bash
.venv/bin/python -m inmobiliaria24
```

- [ ] Scraper envia leads al webhook de n8n
- [ ] WF10 se ejecuta en n8n
- [ ] Lead aparece en tabla `conversations` de Supabase
- [ ] Si es dia: subasta TOMO se lanza
- [ ] Si es noche: lead va a `night_queue`

### 5.5 Deploy del systemd timer

```bash
# Copiar archivos de servicio
sudo cp deploy/inmobiliaria24.service /etc/systemd/system/
sudo cp deploy/inmobiliaria24.timer /etc/systemd/system/

# Habilitar y arrancar
sudo systemctl daemon-reload
sudo systemctl enable inmobiliaria24.timer
sudo systemctl start inmobiliaria24.timer

# Verificar
systemctl status inmobiliaria24.timer
systemctl list-timers | grep inmobiliaria
```

- [ ] Timer instalado y activo
- [ ] Proxima ejecucion muestra la hora correcta
- [ ] Verificar schedule: cada 2 horas, 8am-10pm

---

## ETAPA 6: EASYBROKER POLLING (30 min)

### 6.1 Verificar API key

```bash
curl -X GET "https://www.easybroker.com/api/v1/contact_requests?limit=1" \
  -H "X-Authorization: [EASYBROKER_API_KEY]"
```

- [ ] API responde con 200
- [ ] Retorna contactos (o array vacio si no hay)

### 6.2 Test de WF8

- [ ] Ejecutar WF8 manualmente en n8n
- [ ] Verificar que consulta EasyBroker API
- [ ] Si hay contactos nuevos: se crean conversaciones en Supabase
- [ ] Si no hay: termina sin error

### 6.3 Verificar escritura en EasyBroker

Si la API key tiene permisos de escritura:

```bash
# Test crear contacto
curl -X POST "https://www.easybroker.com/api/v1/contact_requests" \
  -H "X-Authorization: [API_KEY]" \
  -H "Content-Type: application/json" \
  -d '{"name":"Test","email":"test@test.com","phone":"5215500000000","message":"test"}'
```

- [ ] Creacion de contacto funciona (o documentar si es read-only)
- [ ] Si es read-only: decidir si se necesita upgrade con el cliente

---

## ETAPA 7: PRUEBAS END-TO-END (2-3 horas)

**CRITICO: No activar workflows de produccion hasta completar TODAS las pruebas.**

### 7.1 Test: Lead de WhatsApp directo (DIA)

1. [ ] Verificar que son horas de dia (8AM-9PM CDMX)
2. [ ] Enviar mensaje desde telefono de prueba al numero del bot
3. [ ] WF1 recibe y clasifica como `new_lead`
4. [ ] WF2 crea conversacion con `source=whatsapp_direct`, `arrived_during=day`
5. [ ] WF3a lanza subasta TOMO-XXXX a los 2 agentes de guardia
6. [ ] Agente responde TOMO-XXXX desde su WhatsApp
7. [ ] WF3b procesa claim atomico
8. [ ] Agente ganador recibe confirmacion
9. [ ] Lead recibe mensaje de "te conectamos con [agente]"
10. [ ] Conversation mode cambia a `human`
11. [ ] Verificar en dashboard

### 7.2 Test: Lead de WhatsApp directo (NOCHE)

1. [ ] Verificar que son horas de noche (9PM-8AM CDMX) — o simular cambiando la funcion
2. [ ] Enviar mensaje desde telefono de prueba
3. [ ] WF1 detecta modo nocturno
4. [ ] AI bot responde con info de propiedad
5. [ ] Conversacion guardada en `messages`
6. [ ] Lead aparece en `night_queue`
7. [ ] Verificar en dashboard seccion "Nocturno"

### 7.3 Test: Lead del scraper

1. [ ] Ejecutar scraper manualmente
2. [ ] WF10 recibe lead via webhook
3. [ ] Returning lead check ejecuta (debe ser primera vez → no returning)
4. [ ] Conversacion creada con `source=inmuebles24`
5. [ ] Si dia: subasta se lanza
6. [ ] Si noche: va a night_queue

### 7.4 Test: Lead de EasyBroker

1. [ ] Ejecutar WF8 manualmente
2. [ ] Si hay contactos no asignados: se procesan
3. [ ] Conversacion creada con `source=easybroker`
4. [ ] Subasta o night_queue segun hora

### 7.5 Test: Lead recurrente (misma propiedad)

1. [ ] Crear un lead con telefono X y propiedad Y (via test anterior)
2. [ ] Enviar otro lead con telefono X y propiedad Y
3. [ ] Sistema detecta lead recurrente
4. [ ] Notifica al agente ya asignado (sin nueva subasta)

### 7.6 Test: Lead recurrente (diferente propiedad)

1. [ ] Enviar lead con telefono X y propiedad Z (diferente)
2. [ ] Sistema detecta que es el mismo lead pero diferente propiedad
3. [ ] Nueva subasta TOMO se lanza

### 7.7 Test: Subasta expirada

1. [ ] Crear subasta y NO responder el TOMO
2. [ ] Esperar 5 minutos (o lo que este configurado)
3. [ ] WF3c detecta expiracion
4. [ ] Manager recibe alerta de subasta expirada
5. [ ] Subasta cambia a status `expired`

### 7.8 Test: AI conversation + handoff

1. [ ] Desde un lead activo en modo AI, enviar pregunta sobre propiedad
2. [ ] WF4 responde con info de propiedad via OpenRouter
3. [ ] Enviar "quiero agendar una visita"
4. [ ] WF4 detecta necesidad de handoff
5. [ ] WF5 ejecuta: agente recibe resumen, lead recibe "te conectamos"
6. [ ] Mode cambia a `human`

### 7.9 Test: Morning report

1. [ ] Asegurar que hay leads en night_queue (manual si es necesario)
2. [ ] Ejecutar WF7 manualmente
3. [ ] Manager recibe reporte por WhatsApp con resumen nocturno
4. [ ] A los 5 min: leads de night_queue entran en TOMO
5. [ ] night_queue items marcados como `processed=true`

### 7.10 Test: Guard schedule sync

1. [ ] Verificar que el calendario del mes esta llenado en el dashboard (/calendario)
2. [ ] Ejecutar WF6 manualmente en n8n
3. [ ] Verificar `SELECT agent_id, on_shift, shift_slot FROM agents WHERE on_shift = true;`
4. [ ] Verificar `get_on_shift_agents()` retorna los 2 agentes correctos del turno
5. [ ] Cambiar una asignacion en el dashboard, guardar, re-ejecutar WF6
6. [ ] Verificar que el cambio se refleja en agents.on_shift

---

## ETAPA 8: SEGURIDAD Y HARDENING (1 hora)

### 8.1 Base de datos

- [ ] Verificar que n8n usa `service_role` key (bypasses RLS — necesario para escritura)
- [ ] Dashboard usa `anon` key (solo SELECT — correcto)
- [ ] Considerar agregar politicas RLS para `service_role` si se quiere mas seguridad
- [ ] Verificar que la Supabase password NO esta en ningun archivo commiteado

### 8.2 Dashboard

- [ ] Evaluar si necesita autenticacion (Supabase Auth con magic link?)
- [ ] Si no: al menos verificar que no expone datos sensibles (mensajes completos, etc.)
- [ ] Configurar CORS si es necesario
- [ ] Verificar que `.env.local` del dashboard NO esta en git

### 8.3 n8n

- [ ] Login de n8n tiene password fuerte
- [ ] HTTPS habilitado (ya esta via Hostinger)
- [ ] Webhooks tienen URLs no predecibles (UUIDs, no paths simples)
- [ ] Variables de entorno no tienen valores por defecto inseguros

### 8.4 Evolution API

- [ ] API key es fuerte y unica
- [ ] Acceso restringido por IP si es posible
- [ ] Webhook URL usa HTTPS

### 8.5 Scraper (Raspberry Pi)

- [ ] .env con permisos 600 (solo owner puede leer)
- [ ] SSH con key, no password
- [ ] Firewall configurado (solo SSH + salida HTTPS)

### 8.6 Secretos en el repositorio

```bash
# Verificar que no hay secretos commiteados
git log --all -p | grep -i "api_key\|password\|secret" | head -20
```

- [ ] Ningun .env real commiteado
- [ ] .gitignore cubre: .env, .env.local, .env.production

---

## ETAPA 9: MONITOREO Y ALERTAS (30 min)

### 9.1 Telegram alertas del scraper

- [ ] Bot de Telegram creado
- [ ] Chat ID del manager configurado
- [ ] Test: ejecutar scraper con error forzado → alerta llega a Telegram

### 9.2 n8n execution monitoring

- [ ] Verificar que n8n retiene historico de ejecuciones (Settings > Executions)
- [ ] Configurar retencion: al menos 7 dias de ejecuciones exitosas, 30 dias de errores
- [ ] Configurar email de error de n8n (si disponible)

### 9.3 Evolution API health check

- [ ] Verificar periodicamente: `GET /instance/connectionState/inmobiliaria24`
- [ ] Si se desconecta: alerta al manager + reconexion manual (QR)
- [ ] Considerar WF de health check cada hora que verifica estado

### 9.4 Dashboard como monitor

- [ ] Auto-refresh cada 30 segundos (ya implementado)
- [ ] KPIs visibles: leads hoy, subastas activas, leads sin asignar
- [ ] Si leads sin asignar > 0 por mas de 10 min: investigar

---

## ETAPA 10: GO-LIVE (1 hora)

### 10.1 Pre-go-live checklist final

| # | Item | Status |
|---|------|--------|
| 1 | Agentes con numeros reales en DB | [ ] |
| 2 | Google Sheet de guardias llena para el mes | [ ] |
| 3 | WF6 ejecutado — agent_schedule poblado | [ ] |
| 4 | WhatsApp conectado (Evolution state = open) | [ ] |
| 5 | Webhook de Evolution apunta a WF1 | [ ] |
| 6 | Todos los nodos Postgres tienen credencial | [ ] |
| 7 | Todas las variables de entorno en n8n | [ ] |
| 8 | Scraper apunta a WF10 webhook | [ ] |
| 9 | Todas las pruebas E2E pasaron (Etapa 7) | [ ] |
| 10 | Data de prueba limpiada | [ ] |
| 11 | Dashboard funcionando con datos reales | [ ] |

### 10.2 Activar en este orden

1. [ ] **WF3c** (expiry sweeper) — Schedule trigger ON
2. [ ] **WF6** (guard schedule) — Schedule trigger ON
3. [ ] **WF8** (EasyBroker polling) — Schedule trigger ON
4. [ ] **WF7** (morning report) — Schedule trigger ON
5. [ ] **WF1** (inbound router) — Webhook trigger ON
6. [ ] **WF10** (scraper intake) — Webhook trigger ON
7. [ ] **Scraper timer** en Raspberry Pi — `sudo systemctl start inmobiliaria24.timer`

### 10.3 Monitorear primera hora

- [ ] Revisar n8n Executions cada 5 minutos
- [ ] Verificar que WF3c ejecuta cada minuto (sin errores)
- [ ] Verificar que WF8 ejecuta cada 15 minutos
- [ ] Enviar mensaje de prueba real y seguir todo el flujo
- [ ] Verificar dashboard muestra datos en tiempo real

### 10.4 Monitorear primeras 24 horas

- [ ] Verificar morning report a las 8 AM del dia siguiente
- [ ] Verificar que night_queue se proceso a las 8:05 AM
- [ ] Verificar que el scraper ejecuto segun schedule (revisar scrape_logs o systemd journal)
- [ ] Revisar errores en n8n Executions
- [ ] Revisar dashboard al final del dia: KPIs hacen sentido

---

## ETAPA 11: POST-GO-LIVE (primera semana)

### 11.1 Dia 1-2: Observacion intensiva

- [ ] Revisar TODAS las ejecuciones de n8n 2x al dia
- [ ] Responder rapidamente a cualquier error
- [ ] Documentar cualquier caso edge no previsto
- [ ] Verificar que EasyBroker polling no duplica leads

### 11.2 Dia 3-5: Ajustes

- [ ] Ajustar timeout de subastas si es necesario (5 min default)
- [ ] Ajustar prompts de AI bot si las respuestas no son optimas
- [ ] Ajustar scraper frequency si hay muchos o pocos leads
- [ ] Verificar que Google Sheets sync funciona a medianoche + 2 PM

### 11.3 Dia 5-7: Estabilizacion

- [ ] Revisar metricas en dashboard: leads/dia, tiempo de claim, tasa de expiracion
- [ ] Reunion con manager de BYG para feedback
- [ ] Documentar ajustes realizados
- [ ] Preparar guia de operacion para el manager

---

## RIESGOS Y MITIGACIONES

| # | Riesgo | Impacto | Mitigacion | Plan B |
|---|--------|---------|------------|--------|
| 1 | WhatsApp se desconecta | Leads de WA directo se pierden | Monitor de conexion, alerta al manager | Reconexion manual via QR |
| 2 | Inmuebles24 cambia su UI | Scraper deja de funcionar | Screenshots de debug, 2 estrategias de extraccion | Desactivar scraper, depender solo de EasyBroker+WA |
| 3 | EasyBroker rate limit | Polling falla | Intervalo conservador (15 min) | Aumentar intervalo a 30 min |
| 4 | n8n VPS se cae | Todo el sistema se detiene | Monitoreo con UptimeRobot | Reinicio automatico via systemd |
| 5 | Supabase free tier limits | DB deja de aceptar writes | Monitorear uso en Supabase dashboard | Upgrade a plan Pro ($25/mes) |
| 6 | OpenRouter sin credito | AI bot no responde | Monitorear balance | Fallback a mensaje fijo "te contactaremos manana" |
| 7 | Calendario no llenado en dashboard | No hay agentes de guardia | Alerta en WF6 summary | Fallback a on_shift flag manual en agents |
| 8 | Agente no tiene WhatsApp activo | No recibe TOMO | Verificar numeros antes de go-live | Manager recibe como fallback |

---

## CRONOGRAMA ESTIMADO

```
Dia 0:  Etapa 0 — Recopilar datos del cliente (BLOQUEANTE)
Dia 1:  Etapa 1 (DB) + Etapa 2 (Calendario en dashboard) + Etapa 3 (n8n)
Dia 2:  Etapa 4 (Evolution/WA) + Etapa 5 (Scraper) + Etapa 6 (EasyBroker)
Dia 3:  Etapa 7 (Pruebas E2E completas)
Dia 4:  Etapa 8 (Seguridad) + Etapa 9 (Monitoreo) + Etapa 10 (GO-LIVE)
Dia 5+: Etapa 11 (Monitoreo post-go-live)
```

**Total: 4 dias de trabajo + datos del cliente**

---

## CONTACTO DE EMERGENCIA POST-GO-LIVE

| Problema | Quien resuelve | Accion |
|----------|---------------|--------|
| WhatsApp desconectado | Manager BYG | Re-escanear QR en Evolution |
| Leads no llegan | Desarrollador | Revisar n8n executions + webhook |
| Bot responde mal | Desarrollador | Ajustar prompt en WF4 |
| Scraper falla | Desarrollador | SSH al Raspberry Pi, revisar logs |
| Dashboard caido | Desarrollador | Revisar Vercel deployment |
| DB llena | Desarrollador | Limpiar datos viejos o upgrade Supabase |
