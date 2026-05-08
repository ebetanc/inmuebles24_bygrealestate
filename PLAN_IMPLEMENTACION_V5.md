# Plan de Implementacion v5 — Sistema 24/7 de Leads BYG Real Estate

## Lo que necesito para construir

### Accesos requeridos (por prioridad)

| # | Servicio | Que necesito | Para que | Cuando |
|---|----------|-------------|----------|--------|
| 1 | **Supabase** | URL del proyecto + service_role key (o acceso al SQL Editor) | Correr migration 0005, verificar schema, probar queries | Fase 1 (dia 1) |
| 2 | **n8n** | URL + credenciales de login al VPS | Importar/actualizar workflows, configurar credenciales, activar triggers | Fase 2 (dia 2) |
| 3 | **EasyBroker** | API key con permisos de lectura/escritura de contactos | Crear contactos, asignar agentes, polling de leads directos | Fase 3 (dia 3-4) |
| 4 | **Google Sheets** | ID de la hoja del calendario de guardias + cuenta de servicio Google (o compartir la hoja con una cuenta de servicio) | Leer el calendario de turnos automaticamente | Fase 4 (dia 5) |
| 5 | **OpenRouter** | API key (ya lo tienes en .env) | AI bot nocturno y conversacion | Ya configurado |
| 6 | **Evolution API / WhatsApp** | Acceso al VPS donde esta instalado | Conectar WhatsApp al final para pruebas con el manager de BYG | Fase 7 (ultimo) |

### Datos que necesito del cliente (BYG)

1. **Lista de agentes actualizada**: Nombres completos, numeros de WhatsApp, emails de EasyBroker de las 6 agentes (Lupita, Paty, Yol, Gina, Carol, Moni)
2. **Numero del manager**: WhatsApp del manager para alertas y reportes
3. **Google Sheet de guardias**: URL de la hoja o crearla juntos con el formato acordado
4. **Horarios confirmados**: 8AM-2PM y 2PM-9PM turnos, 9PM-8AM nocturno (confirmar)
5. **Propiedades en EasyBroker**: Confirmar que las propiedades ya estan cargadas para poder vincular leads

---

## Arquitectura actual (lo que ya existe)

```
SCRAPER (Python/Playwright - Raspberry Pi)
  |-- Inmuebles24 panel -> extrae leads "Pendiente"
  |-- Dedup local (SQLite StateStore)
  |-- POST a n8n webhook

n8n WORKFLOWS (7 existentes):
  WF1: Router de mensajes entrantes (Evolution webhook)
  WF2: Intake de leads (crea conversacion + property match)
  WF3a: Lanzador de subasta TOMO-XXXX
  WF3b: Handler de claims (first-reply-wins)
  WF3c: Sweeper de expiracion (5 min -> alerta manager)
  WF4: Conversacion AI (OpenRouter)
  WF5: Handoff a humano

DATABASE (Supabase Postgres):
  agents, conversations, auctions, messages,
  properties_cache, listings, scrape_logs
```

**Reutilizable (~80%)**: Scraper, auction TOMO, AI conversation, handoff, message routing

---

## Plan de construccion por fases

### FASE 1: Fundacion de Base de Datos (Dia 1)
**Migration 0005 — Schema para v5**

Cambios:
- `conversations`: Quitar UNIQUE en `lead_phone` (permite leads recurrentes con distintas propiedades)
- `conversations`: Agregar columna `source` (inmuebles24 / easybroker / whatsapp_direct)
- `conversations`: Agregar columna `arrived_during` (day / night)
- Nueva tabla `agent_schedule`: calendario de guardias por fecha y turno
- Nueva tabla `night_queue`: cola de leads nocturnos pendientes de TOMO matutino
- `agents`: Agregar columna `shift_slot` (morning / afternoon / null)
- Seed data: insertar las 6 agentes con datos reales

```sql
-- Estructura de agent_schedule
CREATE TABLE agent_schedule (
  id            BIGSERIAL PRIMARY KEY,
  schedule_date DATE NOT NULL,
  shift         TEXT NOT NULL CHECK (shift IN ('morning','afternoon')),
  agent_id      TEXT NOT NULL REFERENCES agents(agent_id),
  synced_at     TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(schedule_date, shift, agent_id)
);

-- Estructura de night_queue
CREATE TABLE night_queue (
  id              BIGSERIAL PRIMARY KEY,
  conversation_id UUID REFERENCES conversations(conversation_id),
  source          TEXT NOT NULL,
  lead_phone      TEXT NOT NULL,
  lead_name       TEXT,
  property_id     TEXT,
  queued_at       TIMESTAMPTZ DEFAULT NOW(),
  processed       BOOLEAN DEFAULT FALSE,
  processed_at    TIMESTAMPTZ
);
```

**Entregable**: Migration SQL ejecutada en Supabase
**Requiere**: Acceso a Supabase

---

### FASE 2: Router Dia/Noche + Calendario de Guardias (Dia 2-3)
**Adaptar WF1 + nuevo mecanismo de turnos**

2a. **Time Router** — Modificar WF1 para:
- Detectar hora CDMX (America/Mexico_City)
- 8:00-21:00 = dia (TOMO auction)
- 21:00-08:00 = noche (queue o bot)
- Marcar `arrived_during` en la conversacion

2b. **Google Sheets Sync** — Nuevo workflow WF6:
- Cron trigger: ejecuta a medianoche y 2:00 PM CDMX
- Lee la Google Sheet del calendario
- Actualiza tabla `agent_schedule`
- Actualiza `agents.on_shift` segun el turno actual

2c. **Deteccion de leads recurrentes** — Modificar WF2:
- Antes de crear auction, buscar: `SELECT * FROM conversations WHERE lead_phone = $phone`
- Si existe + misma propiedad → notificar agente asignado (sin subasta)
- Si existe + distinta propiedad → nueva subasta normal
- Si no existe → flujo normal

**Entregable**: WF1 adaptado, WF6 nuevo, WF2 adaptado
**Requiere**: n8n + Google Sheets

---

### FASE 3: Integracion EasyBroker (Dia 3-4)
**Dos componentes**

3a. **EasyBroker CRM Adapter** — En cada lead procesado:
- POST /contacts en EasyBroker API para crear contacto
- PUT /contacts/{id}/assign para asignar al agente ganador
- Buscar duplicados por email/phone antes de crear

3b. **EasyBroker Polling (WF8)** — Nuevo workflow:
- Cron trigger cada 15 min
- GET /contacts?status=unassigned (o similar)
- Para cada contacto nuevo: inyectar en el flujo como si fuera lead del scraper
- Marcar contacto como "en proceso" para no duplicar

**Entregable**: WF8 nuevo, adaptacion de WF3b para actualizar EasyBroker al asignar
**Requiere**: EasyBroker API key

---

### FASE 4: Flujo Nocturno (Dia 5-6)
**Tres componentes**

4a. **Night Queue** — Para leads de Inmuebles24/EasyBroker:
- Si llegan entre 9PM-8AM → registrar en DB + insertar en `night_queue`
- NO enviar WhatsApp, NO crear subasta
- Solo almacenar silenciosamente

4b. **Night AI Bot** — Para leads de WhatsApp directo:
- Si llegan entre 9PM-8AM → activar WF4 (AI conversation)
- Bot responde con info de propiedad, califica interes
- Guarda toda la conversacion en `messages`
- NO lanza TOMO (nadie de guardia)

4c. **Morning Report (WF7)** — Nuevo workflow:
- Cron trigger a las 8:00 AM CDMX
- Query: leads nocturnos, conversaciones del bot, temperaturas
- Envia resumen al manager por WhatsApp
- A las 8:05 AM: procesa `night_queue` → lanza TOMO para cada lead

**Entregable**: WF7 nuevo, logica de queue en WF1/WF2
**Requiere**: n8n + Evolution API (puede probarse con mock)

---

### FASE 5: WhatsApp Directo — Intake Hibrido (Dia 6-7)
**WF9 — Nuevo workflow**

Flujo de dia:
1. Lead escribe al numero publicado de WhatsApp
2. Bot responde inmediatamente (saludo + "un momento")
3. Simultaneamente: lanza TOMO a agentes de guardia
4. Si agente reclama antes de 2 min → handoff inmediato
5. Si no reclama en 5 min → bot sigue conversando hasta que alguien reclame

Flujo de noche:
1. Lead escribe al numero
2. Bot responde con info de propiedad + calificacion
3. Sin TOMO (cola para manana)

**Entregable**: WF9 nuevo
**Requiere**: WF1 adaptado (Fase 2) + WF4 existente

---

### FASE 6: Dashboard de Monitoreo (Dia 7-9)
**Panel web para ver resultados en tiempo real**

Stack propuesto: **Next.js + Supabase Realtime + Tailwind + shadcn/ui**

Paginas del dashboard:

| Pagina | Contenido |
|--------|-----------|
| **Vista General** | KPIs del dia: leads totales, por fuente, asignados, pendientes, tiempo promedio de respuesta |
| **Leads en Vivo** | Feed en tiempo real de leads entrando, estado de subasta, agente asignado |
| **Agentes** | Tabla de agentes: disponibilidad, leads asignados hoy/semana/mes, tasa de claim, turno actual |
| **Subastas** | Historial de TOMO: tiempo de claim, quien gano, cuales expiraron |
| **Nocturno** | Conversaciones del bot, temperatura de leads, queue pendiente |
| **Calendario** | Vista del calendario de guardias, editable (sync con Google Sheets) |
| **Reportes** | Metricas semanales/mensuales exportables: conversion, velocidad, carga por agente |

Datos que muestra:
- Leads por fuente (Inmuebles24 vs EasyBroker vs WhatsApp directo)
- Leads diurnos vs nocturnos
- Tiempo promedio de claim por agente
- Tasa de expiracion de subastas
- Leads recurrentes detectados
- Actividad del bot nocturno

**Entregable**: App web desplegable (Vercel o VPS)
**Requiere**: Supabase (ya configurado)

---

### FASE 7: Integracion Final y Pruebas (Dia 9-10)
**Conectar WhatsApp real + testing end-to-end**

1. Conectar Evolution API con WhatsApp del negocio (QR code)
2. Prueba con el manager de BYG:
   - Enviar mensaje de prueba → verificar routing
   - Simular lead diurno → verificar TOMO
   - Simular lead nocturno → verificar bot + queue
   - Verificar morning report
   - Verificar deteccion de lead recurrente
3. Activar todos los workflows en n8n
4. Monitorear 24h en dashboard

**Entregable**: Sistema en produccion
**Requiere**: Evolution API + WhatsApp del negocio

---

## Cronograma resumido

```
Dia 1:     FASE 1 - Migration DB
Dia 2-3:   FASE 2 - Router dia/noche + guardias + leads recurrentes
Dia 3-4:   FASE 3 - EasyBroker integracion
Dia 5-6:   FASE 4 - Flujo nocturno + morning report
Dia 6-7:   FASE 5 - WhatsApp directo hibrido
Dia 7-9:   FASE 6 - Dashboard
Dia 9-10:  FASE 7 - Integracion final + pruebas con BYG
```

**Total estimado: 10 dias de trabajo**

---

## Propuesta para el cliente

### Que recibe BYG Real Estate

**Sistema completo 24/7 de gestion de leads inmobiliarios:**

1. **3 fuentes de leads automatizadas**: Inmuebles24, EasyBroker, WhatsApp directo
2. **Subasta inteligente TOMO**: Los leads se asignan al primer agente que responda (maximo 5 min)
3. **Bot nocturno con IA**: Atiende leads fuera de horario con informacion de propiedades
4. **Reporte matutino**: Cada manana a las 8 AM, resumen de actividad nocturna
5. **Deteccion de leads recurrentes**: Si un lead vuelve por la misma propiedad, va al mismo agente
6. **Calendario de guardias**: Gestion automatica de turnos desde Google Sheets
7. **Dashboard en tiempo real**: Panel web para monitorear leads, agentes, subastas y metricas
8. **Integracion con EasyBroker**: Leads se registran automaticamente, agentes se asignan al CRM

### Valor para el negocio

- **0 leads perdidos**: Todo lead se atiende (dia o noche)
- **Respuesta < 5 minutos** en horario laboral
- **Transparencia total**: Dashboard muestra quien atiende que y cuando
- **Escalabilidad**: Funciona igual con 6 o 20 agentes
- **Automatizacion**: El manager solo llena el calendario mensual, el sistema hace el resto

### Entregables concretos

1. Sistema de WhatsApp automatizado (ya en VPS)
2. 10+ workflows de n8n configurados y activos
3. Dashboard web con acceso para el manager
4. Documentacion y guia de operacion
5. 1 semana de soporte post-lanzamiento

---

## Notas tecnicas

### Stack completo
- **Scraper**: Python 3.12, Playwright, httpx (Raspberry Pi)
- **Workflows**: n8n self-hosted (Hostinger VPS)
- **WhatsApp**: Evolution API (mismo VPS)
- **Database**: Supabase Postgres (cloud)
- **AI**: OpenRouter (Claude Sonnet / GPT-4o / Gemini Flash)
- **Dashboard**: Next.js 15 + Supabase Realtime + shadcn/ui
- **Deploy dashboard**: Vercel (free tier) o mismo VPS

### Riesgos y mitigaciones
| Riesgo | Mitigacion |
|--------|-----------|
| Inmuebles24 cambia su UI | Scraper tiene 2 estrategias de extraccion + screenshots de debug |
| EasyBroker API rate limits | Polling cada 15 min (muy conservador) + cache local |
| WhatsApp se desconecta | Monitor + alerta automatica al manager + reconexion |
| Agente no responde en 5 min | Escalacion automatica al manager |
| Google Sheet mal formateada | Validacion al importar + fallback a ultimo calendario valido |
