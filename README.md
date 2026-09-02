# Inmobiliaria24 — Lead Routing V3

Sistema de atención de leads de BYG Real Estate. Captura cada solicitud nueva de
Inmuebles24, la marca `Contactado` en el portal, la ofrece por WhatsApp al
ejecutivo correcto y cierra el ciclo dejando nota y estado `Atendida` en la
solicitud exacta de EasyBroker.

**Estado: Lead Routing V3 en producción (desde 2026-09-02).** Todo lo anterior
(subastas masivas, bot de IA nocturno, Evolution API, V2/LRV2) está apagado o
fue reemplazado; ver [Legacy](#legacy--apagado-o-fuera-del-camino-v3).

## Arquitectura V3

```
Inmuebles24 (3 bandejas) --15 min--> scraper (Raspberry Pi)
      |                                  |
      | marca "Contactado" (verificado)   +--> v3_intake (Supabase)
      v                                            |
  POST /webhook/scraper-leads ----> WF10 --> WF12 (dueño por tag EasyBroker)
                                     |
                                     v
                              WF13 --> Meta Cloud API: plantilla "lead_subasta_v3"
                                     |                (botón único "Tomo")
  Meta callbacks --> WF22 --> WF1 --> WF3b  (primer clic válido gana, atómico)
                                     ^
                     WF23 (cron 30 s) --> WF3c: dueño -> guardia del turno -> Sandy
                                     |
  EasyBroker worker (1 min) <--------+  nota "RESPONSABLE: <nombre>" + "Atendida"
```

Noche 20:00–08:00 CDMX: las ofertas quedan en `queued_night` y WF7 las libera a
las 08:05.

## Flujo, paso a paso

1. **Captura.** El scraper (`src/inmobiliaria24/`) recorre las 3 bandejas de
   Inmuebles24 cada 15 minutos, 24/7, y persiste cada solicitud en `v3_intake`
   antes de tocar nada más. Reintentar el mismo evento no crea otra oportunidad.
2. **Contactado.** El scraper cambia el estado en Inmuebles24 de `Pendiente` a
   `Contactado` y **verifica** el efecto. Ninguna oferta sale antes de eso.
3. **Intake.** `POST https://n8n.srv856940.hstgr.cloud/webhook/scraper-leads`
   → WF10, que crea/reusa la oportunidad y decide si es de día o de noche.
4. **Dueño.** WF12 resuelve la propiedad por su ID público de EasyBroker y toma
   el tag de la propiedad (nombre del ejecutivo) contra `property_agent_alias`.
   Sandy puede ser dueña aunque sea manager. Cero o más de un tag = dueño
   inválido → se escala directo a guardia.
5. **Oferta.** WF13 envía la plantilla Meta `lead_subasta_v3` con un solo botón
   "Tomo" (payload `claim:v3:<opp>:<attempt>`). **Requiere URL pública de
   EasyBroker**; sin ella no hay mensaje posible.
6. **Reclamo.** Callbacks de Meta → WF22 (valida HMAC, escribe en un inbox
   durable) → WF1 → WF3b `claim_v3_delivery_from_webhook`. El primer clic válido
   gana; respuestas tardías o de otro intento no cambian al responsable.
7. **Tiempos.** WF23 es el **único** temporizador (cron cada 30 s): 2 minutos sin
   `delivered`, o 5 minutos después de `delivered`, disparan WF3c
   `v3_advance_routing_tier` → guardia del turno (`get_guard_coverage_slots`, una
   sola guardia por turno, tomada del calendario del dashboard) → 5 minutos más →
   `v3_assign_sandy` (`agent_id = agent_manager`) con plantilla `lead_asignado_v3`
   (sin botón).
8. **Cierre EasyBroker.** El worker `src/easybroker/` corre cada minuto, correlaciona
   la solicitud exacta (propiedad + email/teléfono) y escribe por Playwright la nota
   `RESPONSABLE: <nombre>` y el estado `Atendida`. Los efectos son idempotentes vía
   `easybroker_effect_attempts`.

## Workflows vivos (n8n)

| WF | ID | Disparador | Qué hace |
|----|----|-----------|----------|
| WF10 | `Obr38705ZZYS3FB8` | Webhook `/webhook/scraper-leads` | Intake del scraper, dedupe, día/noche |
| WF12 | `w7yJr7naWoxPq6Pw` | Sub-workflow (WF10) | Resuelve dueño por tag de EasyBroker |
| WF13 | `Bo2YbbUpmBzRbhDa` | Sub-workflow | Envía `lead_subasta_v3` al destinatario del tier |
| WF22 | `Z89IQDw1fgWlqXEW` | Webhook Meta (HMAC) | Inbox durable de callbacks `sent/delivered/read/failed` y clics |
| WF1 | `snF6Sr9CBJIevMVD` | Sub-workflow (WF22) | Enruta el evento entrante al handler correcto |
| WF3b | `JM2HxJxl53k4zlki` | Sub-workflow (WF1) | `claim_v3_delivery_from_webhook`: reclamo atómico |
| WF23 | `MjfHw3tYE2qYgJfM` | Cron cada 30 s | Único motor de tiempos: detecta vencimientos |
| WF3c | `UNIKqyAvIUAZkNIs` | Sub-workflow (WF23) | `v3_advance_routing_tier` / `v3_assign_sandy` |
| WF7 | `xzBG0GIsHCUd44DC` | Cron 08:05 `America/Mexico_City` | `v3_release_night_queue` + reporte matutino |
| WF20 | `pYV88ntxI0Lc4NCB` | Cron | Watchdog: scraper sin corrida, errores, silencios |
| WF21 | `He95yJflKVspGFyb` | Error trigger global | Email de error con throttling |
| WF24 | `WF24V3MonitorDia` | Cada 30 min 08:00–20:30 + 20:45 | Monitor V3 por email (se genera con `build_wf24_monitor.py`) |
| WF17 | `YkhDEps0WbqaszMX` | Lunes 08:00 CDMX | Reporte semanal por email — **todavía lee datos V1** |

`whatsapp-agent/workflows/` es la fuente de verdad del repo; `n8n-export/` es el
snapshot semanal de producción. `tests/test_v3_workflow_json_contract.py` compara
ambos.

## Legacy — apagado o fuera del camino V3

| Qué | Estado |
|-----|--------|
| WF2 / WF4 / WF5 | Bot de IA nocturno. Apagados. |
| WF6 | Sync de turnos. Sin uso (el calendario del dashboard es la fuente). |
| WF8 / WF8b | Polling de EasyBroker como fuente de leads. Apagados. |
| WF3a | Stub de subasta masiva. Apagado. |
| WF14 / WF15 / WF16 | Seguimientos automáticos. Apagados. |
| WF19 | Guard-direct. Sigue activo en el VPS pero **fuera del camino V3 → desactivar**. |
| WF18 | EB owner sync. Solo existe en `n8n-export/`. |
| Evolution API | Reemplazado por Meta Cloud API. |
| Lead Routing V2 / LRV2 | Solo llegó a shadow, nunca se activó. `routing_safe_mode_state` es ignorado por V3. |
| Adaptador HubSpot (`src/inmobiliaria24/crm/hubspot.py`) | Sin uso. |
| Bot de calificación (`src/inmobiliaria24/whatsapp/`) | Sin uso. |
| `whatsapp-agent/migrations/` (47) | Migraciones V1/V2, históricas. |

## Componentes

| Componente | Dónde | Tecnología |
|-----------|-------|-----------|
| Scraper Inmuebles24 | Raspberry Pi `/opt/inmobiliaria24`, `src/inmobiliaria24/` | Python 3.12, Playwright, SQLite |
| Worker EasyBroker | Raspberry Pi, `src/easybroker/` | Python 3.12, Playwright (headful bajo xvfb) |
| Motor de workflows | VPS Hostinger `69.62.108.2`, contenedor `root-n8n-1` | n8n self-hosted |
| Base de datos | Supabase, proyecto `wkaeutndwawkdhswisqe` | Postgres + RPC + RLS |
| Dashboard | Vercel, `dashboard/` | Next.js |
| WhatsApp | Meta Cloud API (plantillas `lead_subasta_v3`, `lead_asignado_v3`) | — |
| Portal de propiedades | EasyBroker (API de lectura + UI por Playwright) | — |

Páginas del dashboard: `agentes`, `calendario`, `leads`, `logs`, `nocturno`,
`subastas`. El calendario define la guardia de cada turno que consume WF3c.

## Desplegar al Raspberry Pi

```bash
ssh esteban@100.88.225.103          # Tailscale
sudo bash /opt/inmobiliaria24/deploy/deploy.sh
```

`deploy.sh` hace `git pull --ff-only origin main`, `pip install -e .` en el venv,
`systemctl daemon-reload` y reinicia `inmobiliaria24.timer`. Si tocaste el worker
de EasyBroker o los reportes, reinicia también sus timers:

```bash
sudo systemctl restart easybroker.timer reporte-semanal.timer
systemctl list-timers | grep -E 'inmobiliaria24|easybroker|n8n-export'
```

Timers en el Pi: `inmobiliaria24.timer` (cada 15 min, 24/7),
`easybroker.timer` (cada minuto), `reporte-semanal.timer`,
`n8n-export.timer` (domingo 03:00 CDMX, snapshot de solo lectura a `n8n-export/`).

## Tocar n8n — solo por CLI

**La API key de n8n está muerta.** Todo se hace por CLI dentro del contenedor:

```bash
ssh root@69.62.108.2

# exportar el estado vivo ANTES de cualquier cambio
docker exec root-n8n-1 n8n export:workflow --id=<ID> --output=/tmp/wf.json
docker cp root-n8n-1:/tmp/wf.json ./wf.json

# importar
docker exec root-n8n-1 n8n import:workflow --input=/tmp/wf.json
docker exec root-n8n-1 n8n publish:workflow --id=<ID>
docker restart root-n8n-1
```

Gotchas que muerden:

- El JSON a importar **debe traer el campo `id`**, o n8n crea un workflow nuevo.
- `import:workflow` **desactiva** el workflow. Siempre `publish:workflow --id=`
  después, y luego `docker restart root-n8n-1`.
- Nunca importes sin haber exportado antes y comparado contra
  `whatsapp-agent/workflows/`: producción puede haber divergido del repo.

`scripts/n8n_control.py` valida los JSON exportados offline (drift, credenciales
placeholder, secretos filtrados) y hace diff/dry-run.

## Tests

```bash
PYTHONPATH=src python -m pytest -q
# 380 passed, 2 xfailed
```

El contrato de workflows se valida solo con:

```bash
PYTHONPATH=src python -m pytest -q tests/test_v3_workflow_json_contract.py
```

## Variables de entorno

Copia `.env.example` a `.env`. Las claves que importan hoy en el Pi:

| Variable | Valor en producción | Para qué |
|----------|--------------------|----------|
| `INMUEBLES24_EMAIL` / `INMUEBLES24_PASSWORD` | credenciales del portal | login del scraper |
| `WEBHOOK_URL` | `https://n8n.srv856940.hstgr.cloud/webhook/scraper-leads` | destino del intake |
| `I24_WEBHOOK_TOKEN` | secreto compartido con n8n | header auth del webhook |
| `LEAD_ROUTING_V3_ENABLED` | `1` | activa el camino V3 en el scraper |
| `LEAD_ROUTING_ACCOUNT_KEY` | clave del tenant | debe ser igual a `EASYBROKER_ACCOUNT_KEY` |
| `MARK_CONTACTED` | legacy | gate viejo del cambio de estado |
| `EASYBROKER_EMAIL` / `EASYBROKER_PASSWORD` | login de la UI de EB | nota + `Atendida` |
| `EASYBROKER_API_KEY` | key de cuenta | correlación de solicitudes (lectura) |
| `EASYBROKER_V3_INBOX` | `1` | inbox durable a nivel solicitud |
| `EASYBROKER_CREATE_REQUESTS` | `1` | creación idempotente de solicitudes EB |
| `EB_MARK_ATTENDED` | `1` | sin esto el worker es no-op |
| `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` | proyecto `wkaeutndwawkdhswisqe` | acceso a la base |

## Monitoreo

- **WF20** watchdog: alerta si el scraper deja de correr o si hay silencios.
- **WF21** error handler: captura cualquier ejecución fallida y manda email
  (con throttling para no inundar).
- **WF24** monitor V3: email cada 30 min entre 08:00 y 20:30 y reporte del día a
  las 20:45.
- Telegram opcional para errores del scraper (`TELEGRAM_*`).

## Brechas conocidas

- Leads **sin ID de propiedad de EasyBroker** caen en `manual_review` en silencio.
  No hay WhatsApp posible porque las plantillas exigen la URL pública de EB.
- **Secretos nunca rotados.** Ver `SECURITY-ROTATION.md`.
- **Respaldo de Supabase**: `pg_dump` diario 03:20 CDMX desde el VPS (`deploy/supabase-backup.timer`, retención 14 días, ver `docs/ops/supabase-backup.md`). Restauración aún no ensayada.
- **WF17** (reporte semanal) sigue leyendo tablas V1.
- El **dashboard es ciego a V3**: lee tablas V1/V2 (se está corrigiendo en una rama).
- El host de n8n se traba a diario alrededor de la 01:05 CDMX.
- WF19 sigue activo en el VPS aunque no forma parte del camino V3.

## Dónde está la verdad

| Tema | Archivo |
|------|---------|
| Contrato funcional V3 | `docs/superpowers/specs/2026-08-26-lead-routing-v3-contract.md` |
| Plan de ejecución V3 | `docs/superpowers/plans/2026-08-26-lead-routing-v3-execution-plan.md` |
| Estado de migraciones | `supabase/V3_PRODUCTION_MIGRATION_STATUS.md` (22 migraciones aplicadas) |
| Worker EasyBroker | `src/easybroker/README.md` |
| Workflows (canónico) | `whatsapp-agent/workflows/*.json` |
| Workflows (producción) | `n8n-export/*.json` |
| Plantillas de WhatsApp | `WHATSAPP_TEMPLATES_SUBMIT.md` |
| Rotación de secretos | `SECURITY-ROTATION.md` |
| Documentos históricos | `docs/archive/` |
| Grafo del código | `graphify query "<pregunta>"` (ver `CLAUDE.md`) |

## Licencia

Privado / propietario. Todos los derechos reservados.
