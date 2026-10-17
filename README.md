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
Portales --> Tokko --> correo (Gmail Marusa, filtro reenvía a esteban.betanc)
                              |
                WF25 (Gmail cada minuto) --> v3_tokko_intake (Supabase)
                                                   |
  despachador Pi --> POST /webhook/scraper-leads --> WF10 --> WF12 (dueño por tag EasyBroker)
                                     |
                                     v
                              WF13 --> Meta Cloud API: plantilla "lead_subasta_v3"
                                     |                (botón único "Tomo")
  Meta callbacks --> WF22 --> WF1 --> WF3b  (primer clic válido gana, atómico)
                                     ^
                     WF23 (cron 30 s) --> WF3c: dueño -> guardia del turno -> SIN ASIGNACIÓN
                                     |
  EasyBroker worker (1 min) <--------+  nota "RESPONSABLE: <nombre>" + "Atendida"
```

Noche 20:00–08:00 CDMX: las ofertas quedan en `queued_night` y WF7 las libera a
las 08:05.

El despacho de capturas verificadas tiene un servicio independiente:
`inmobiliaria24-dispatch.timer` revisa la cola cada minuto sin abrir el navegador.
El scraper también intenta el envío al terminar Contactado; las reservas atómicas
de Supabase evitan que ambos consumidores tomen el mismo trabajo. Un fallo de
sesión ya no detiene la cola lista ni obliga a esperar el siguiente ciclo de 15
minutos. El horario efectivo de liberación de la mañana sigue siendo 08:05 CDMX.

Las filas Contactado visibles sin captura V3 se registran como advertencias en
`scrape_logs.error_message` y `metadata.uncaptured_contacted_rows`. Esta comparación
cubre las filas observadas en las tres bandejas, no todo el historial del portal.
No identifica quién cambió el estado ni vuelve a repartir esas solicitudes.

## Flujo, paso a paso

1. **Captura (desde 2026-10-10).** Tokko manda un correo por consulta (Inmuebles24,
   JamesEdition…). Un filtro en el Gmail de Marusa (`from:notifier@tokkobroker.com "nueva consulta"`)
   lo reenvía a esteban.betanc@gmail.com; WF25 lo lee cada minuto, lo guarda en
   `tokko_shadow_leads` y, si trae contacto + `Ref: EB-…`, llama `v3_tokko_intake`.
   Los dos avisos de un mismo lead (Consulta + WhatsApp) son una sola oportunidad.
   WF26 manda a la papelera (03:30 CDMX) los avisos con más de 7 días.
   **EasyBroker directo (desde 2026-10-15):** WF27 lee cada 2 min la API `contact_requests`
   y mete por `v3_tokko_intake` (`origin=easybroker`, id `eb:<request>`) todo lo que no sea
   Inmuebles24 (ya llega por Tokko) ni Instagram: Lamudi, Pincali, MLS, web… El worker EB
   enlaza la solicitud existente (no crea otra); no hay marca ni nota en i24.
2. **Contactado al TOMO (desde 2026-10-13).** La captura de Tokko nace verificada y la Pi ya
   no captura. Con `I24_TOKKO_MARK=1`, `inmobiliaria24.timer` (cada 5 min) solo marca: cuando
   un lead de Tokko/Inmuebles24 queda asignado, empareja su conversación en la bandeja de i24
   (mismo aviso + mismo correo o teléfono, una sola coincidencia, ventana 3 h), la pasa a
   Contactado y escribe `<Nombre> · V3 HH:MM` (`i24_note_ledger`, 5 intentos). Los leads sin
   asignación quedan en Pendiente. Sin trabajo no abre Chrome. Proxy `gost-proxy` →
   DataImpulse residencial con Anonymous filter; `rotate-proxy-ip` (`deploy/`) prueba
   sessids hasta que i24 no responda con bloqueo duro de Cloudflare. El trigger
   `v3_enqueue_i24_note` sigue deshabilitado (rollback a captura: ver historial de git).
3. **Intake.** El despachador de la Pi (`inmobiliaria24-dispatch.timer`, sin navegador) hace
   `POST https://n8n.srv856940.hstgr.cloud/webhook/scraper-leads`
   → WF10, que crea/reusa la oportunidad y decide si es de día o de noche.
4. **Dueño.** WF12 resuelve la propiedad por su ID público de EasyBroker y toma
   el tag de la propiedad (nombre del ejecutivo) contra `property_agent_alias`.
   Sandy puede ser dueña aunque sea manager. Cero o más de un tag = dueño
   inválido → se escala directo a guardia.
   **Cliente que regresa (desde 2026-10-16):** antes del dueño, si la misma persona
   (correo o teléfono) ya la tomó una asesora en los últimos 90 días, va directo a esa
   asesora con aviso `lead_asignado_v3`, sin oferta (`v3_returning_client_agent`). Los de
   MLS son otros asesores y se reparten normal; los números de BYG no cuentan.
   **Asesores (desde 2026-10-17):** la regla de 90 días no aplica si la persona está marcada
   como asesor (`lead_advisor_flags`: la asesora contesta `asesor` por WhatsApp citando la
   oferta o el aviso del lead; sin cita vale su único lead de las últimas 24 h) o si
   `v3_identity_looks_like_advisor` detecta correo de empresa (cualquier dominio que no sea
   de consumidor), nombre de inmobiliaria o mensaje de colega. En ambos casos el lead entra a
   reparto normal. `asesor` solo marca: no toma ni cierra el lead.
   `v3_advisor_reason(opportunity_id)` dice por qué.
5. **Oferta.** WF13 envía la plantilla Meta `lead_subasta_v3b` (sin minutos fijos) con un solo botón
   "Tomo" (payload `claim:v3:<opp>:<attempt>`). **Requiere URL pública de
   EasyBroker**; sin ella no hay mensaje posible.
6. **Reclamo.** Callbacks de Meta → WF22 (valida HMAC, escribe en un inbox
   durable) → WF1 → WF3b `claim_v3_delivery_from_webhook`. El primer clic válido
   gana; respuestas tardías o de otro intento no cambian al responsable. Un "tomo"
   escrito a mano también vale: toma la oferta citada o, si no cita, la única oferta
   abierta del remitente (con varias abiertas pide usar el botón). Al que llega tarde
   WF3b le dice quién lo tomó.
7. **Tiempos (hora compartida desde 2026-10-15).** WF23 es el **único** temporizador
   (cron cada 30 s). El dueño tiene 5 min solo (o 2 min sin `delivered`); entonces WF3c
   `v3_advance_routing_tier` manda la oferta a la guardia del turno **sin cerrar la del
   dueño**: los dos pueden tocar Tomo hasta el minuto 65 (`v3_shared_deadline` = primera
   oferta + 65 min). Si no hay guardia o la guardia es la propia dueña, la segunda oferta
   va a Sandy (`v3_second_offer_target`). Nadie la toma en el minuto 65 →
   `v3_assign_manager`: Sandy de lunes a viernes 09:00–18:00 CDMX, el celular BYG
   (Marusa, `agent_manager_2`) el resto (`v3_fallback_agent`), con aviso
   `lead_asignado_v3`. `SIN ASIGNACIÓN` queda solo si no hay a quién ofrecer.
   Prueba sin escribir nada: `python scripts/v3_shared_hour_check.py`.
8. **Cierre EasyBroker.** El worker `src/easybroker/` corre cada minuto, correlaciona
   la solicitud exacta (propiedad + email/teléfono) y escribe por Playwright la nota
   `RESPONSABLE: <nombre>` y el estado `Atendida`. Los efectos son idempotentes vía
   `easybroker_effect_attempts`.

## Workflows vivos (n8n)

| WF | ID | Disparador | Qué hace |
|----|----|-----------|----------|
| WF10 | `Obr38705ZZYS3FB8` | Webhook `/webhook/scraper-leads` | Intake del scraper, dedupe, día/noche |
| WF12 | `w7yJr7naWoxPq6Pw` | Sub-workflow (WF10) | Resuelve dueño por tag de EasyBroker |
| WF13 | `Bo2YbbUpmBzRbhDa` | Sub-workflow | Envía `lead_subasta_v3b` al destinatario del tier |
| WF22 | `Z89IQDw1fgWlqXEW` | Webhook Meta (HMAC) | Inbox durable de callbacks `sent/delivered/read/failed` y clics |
| WF1 | `snF6Sr9CBJIevMVD` | Sub-workflow (WF22) | Enruta el evento entrante al handler correcto |
| WF3b | `JM2HxJxl53k4zlki` | Sub-workflow (WF1) | `claim_v3_delivery_from_webhook`: reclamo atómico |
| WF23 | `MjfHw3tYE2qYgJfM` | Cron cada 30 s | Único motor de tiempos: detecta vencimientos |
| WF3c | `UNIKqyAvIUAZkNIs` | Sub-workflow (WF23) | `v3_advance_routing_tier` (guardia en el min 5, respaldo en el 65) |
| WF7 | `xzBG0GIsHCUd44DC` | Cron 08:05 `America/Mexico_City` | `v3_release_night_queue` + reporte matutino |
| WF25 | `TokkoWF25Shadow1` | Gmail cada minuto | Lee avisos de Tokko → `tokko_shadow_leads` + `v3_tokko_intake` |
| WF27 | `EBDirectWF27Intk` | Cron cada 2 min | EasyBroker directo (todo menos Inmuebles24 e Instagram) → `v3_tokko_intake` |
| WF26 | `TokkoWF26Cleanup` | Cron 03:30 CDMX | Manda a la papelera los avisos de Tokko con más de 7 días en el Gmail de intake |
| WF20 | `pYV88ntxI0Lc4NCB` | Cron diario 09:00 CDMX | Watchdog: 24 h sin avisos de Tokko, errores, silencios |
| WF21 | `He95yJflKVspGFyb` | Error trigger global | Email de error con throttling |
| WF24 | `WF24V3MonitorDia` | 20:45 CDMX | Reporte diario V3 por email y WhatsApp (`reporte_diario_v3`, botón "Ver detalle") (se genera con `build_wf24_monitor.py`) |
| WF17 | `YkhDEps0WbqaszMX` | Lunes 08:00 CDMX | Reporte semanal por email (datos V3) |

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
| WF19 | Guard-direct. Inactivo en el snapshot vivo del 2026-09-23; fuera del camino V3. |
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
`systemctl daemon-reload`, deja corriendo el despachador y reinicia `inmobiliaria24.timer`
(scraper) solo si está habilitado; desde el corte a Tokko está deshabilitado y así se queda. Si tocaste el worker
de EasyBroker o los reportes, reinicia también sus timers:

```bash
sudo systemctl restart easybroker.timer reporte-semanal.timer
systemctl list-timers | grep -E 'inmobiliaria24|easybroker|n8n-export'
```

Timers en el Pi: `inmobiliaria24.timer` (cada 5 min, solo Contactado + nota i24 de leads Tokko tomados),
`inmobiliaria24-dispatch.timer` (cada minuto),
`easybroker.timer` (cada minuto), `reporte-semanal.timer`,
`n8n-export.timer` (domingo 03:00 CDMX, snapshot privado en
`/var/backups/inmobiliaria24/n8n-export/` de la Pi).

Estado 2026-09-23: la Pi usa una clave SSH dedicada que en el VPS solo puede
ejecutar el exportador de los 29 workflows permitidos. Los snapshots nuevos
quedan en la Pi con permisos de root; no se suben a GitHub porque `origin` es
público. `n8n-export/` conserva las instantáneas históricas del repositorio.

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
| `MARK_CONTACTED` | `1` | permite pasar la conversación i24 a Contactado |
| `I24_TOKKO_MARK` | `1` | la Pi solo marca i24 (no captura) |
| `I24_FAST_DAY` | `0` | con `1` un bloqueo de Cloudflare aborta sin rotar IP (era de la captura) |
| `EASYBROKER_EMAIL` / `EASYBROKER_PASSWORD` | login de la UI de EB | nota + `Atendida` |
| `EASYBROKER_API_KEY` | key de cuenta | correlación de solicitudes (lectura) |
| `EASYBROKER_V3_INBOX` | `1` | inbox durable a nivel solicitud |
| `EASYBROKER_CREATE_REQUESTS` | `1` | creación idempotente de solicitudes EB |
| `EB_MARK_ATTENDED` | `1` | sin esto el worker es no-op |
| `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` | proyecto `wkaeutndwawkdhswisqe` | acceso a la base |

## Monitoreo

- **WF20** watchdog: alerta si en 24 h no llega ningún aviso de Tokko o si hay silencios.
- **WF21** error handler: captura cualquier ejecución fallida y manda email
  (con throttling para no inundar).
- **WF24** monitor V3: reporte del día a las 20:45 CDMX por email y WhatsApp
  (`reporte_diario_v3` a `public.v3_report_recipients`, botón "Ver detalle" que
  WF1 responde con el texto completo de `public.v3_daily_reports`).
- Telegram opcional para errores del scraper (`TELEGRAM_*`).

## Brechas conocidas

- Leads **sin ID de propiedad de EasyBroker** caen en `manual_review` en silencio.
  No hay WhatsApp posible porque las plantillas exigen la URL pública de EB.
- **Secretos nunca rotados.** Ver `SECURITY-ROTATION.md`.
- **Respaldo de Supabase**: `pg_dump` diario 03:20 CDMX desde el VPS (`deploy/supabase-backup.timer`, retención 14 días, ver `docs/ops/supabase-backup.md`). Restauración ensayada el 2026-09-23 en un `postgres:17-alpine` desechable: conteos idénticos a producción.
- **WF17** lee `weekly_lead_report()` sobre `v3_leads_dashboard` desde el 2026-09-23; su sección "Lead Routing v2 (piloto)" sale vacía.
- En el **dashboard** solo la página "Leads V3" lee V3; "Vista General" y "Leads en Vivo" siguen en tablas V1/V2.
- El host de n8n se traba a diario alrededor de la 01:05 CDMX (WF23 ~10 errores `connection timeout`, con la cola nocturna; sin efecto en leads).

## Dónde está la verdad

| Tema | Archivo |
|------|---------|
| Contrato funcional V3 | `docs/superpowers/specs/2026-08-26-lead-routing-v3-contract.md` |
| Plan de ejecución V3 | `docs/superpowers/plans/2026-08-26-lead-routing-v3-execution-plan.md` |
| Estado de migraciones | `supabase/V3_PRODUCTION_MIGRATION_STATUS.md` (registro reconciliado el 2026-09-23) |
| Worker EasyBroker | `src/easybroker/README.md` |
| Workflows (canónico) | `whatsapp-agent/workflows/*.json` |
| Workflows (producción) | `n8n-export/*.json` |
| Plantillas de WhatsApp | `WHATSAPP_TEMPLATES_SUBMIT.md` |
| Rotación de secretos | `SECURITY-ROTATION.md` |
| Documentos históricos | `docs/archive/` |
| Grafo del código | `graphify query "<pregunta>"` (ver `CLAUDE.md`) |

## Licencia

Privado / propietario. Todos los derechos reservados.

Plazo diurno de 15 minutos desde la llegada original de I24: activación, pruebas
y limitaciones en [el informe operativo](docs/incidents/2026-09-07-day-sla.md).
