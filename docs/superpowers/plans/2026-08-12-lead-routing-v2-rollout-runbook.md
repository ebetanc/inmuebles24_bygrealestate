# Runbook de rollout: Lead Routing v2 (LRV2-015)

**Estado:** `ready-for-production` (evidencia de gate lista; ninguna accion productiva ejecutada). No se cambia a `done` desde este documento — esa decision es del supervisor.
**Alcance de este documento:** preparacion de artefactos y procedimiento. No autoriza por si mismo activar workflows, aplicar migraciones remotas ni tocar produccion.

## 1. Alcance y estado

### Que esta listo

- Tickets LRV2-001 a LRV2-014: todos `done`, cada uno con gate de verification/security/quality PASS registrado en `docs/superpowers/tickets/2026-08-12-lead-routing-v2/README.md`.
- Contrato de negocio congelado en `docs/superpowers/specs/2026-08-12-lead-routing-v2-contract.md` (S-01 a S-14).
- Baseline productivo firmado en `.planning/lead-routing-v2-production-baseline.json`, `supervisor_approval.production_changes_authorized=false`.
- Integridad de los 25 snapshots de rollback (`wf_*_backup_20260812T083420Z.json`) verificada byte a byte contra el baseline el 2026-08-13: **25/25 SHA-256 coinciden**, ningun anchor de rollback fue alterado por la serie.
- Suite completa `uv run pytest -q`: **192 passed** (182 preexistentes + 10 nuevos de `test_n8n_control.py`), 0 failed.
- `dashboard`: `npm run build` OK; `npm run lint` con el unico error preexistente conocido en `src/components/source-chart.tsx:42` (no tocado por esta serie).
- Validacion JSON/nodos/conexiones de los 55 archivos en `whatsapp-agent/workflows/*.json` y `n8n-export/*.json`: 55/55 OK (JSON parseable, sin IDs de nodo duplicados, todas las conexiones apuntan a nodos reales; re-verificado 2026-08-13).
- Migraciones `0001` a `0033` re-verificadas de punta a punta en un contenedor PG17 efimero, incluyendo reaplicacion idempotente de `0028`/`0029`/`0033` y las 6 fixtures dinamicas de `tests/fixtures/routing_v2/`. Detalle en §3.
- `scripts/n8n_control.py` ahora soporta diff/import-inactivo/rollback contra la API real de n8n, siempre mockeable, con pruebas nuevas en `tests/test_n8n_control.py` (ver §7).

### Que requiere autorizacion humana explicita

**Todo lo productivo**, sin excepcion:

- Aplicar cualquier migracion (`0021`→`0033`) a la base de datos productiva.
- Importar cualquier workflow a la instancia n8n productiva (VPS Hostinger), incluso en estado inactivo.
- Activar cualquier workflow.
- Cambiar cualquier flag operativo productivo (`EB_MARK_ATTENDED`, `MARK_CONTACTED`, credenciales, etc.).
- Iniciar shadow mode, canary, o cualquier ventana de observacion sobre trafico real.

## 2. Prerrequisitos

### Credenciales (referenciar, nunca pegar el valor)

- n8n API key vigente: alias `chirey_provisional` (ver memoria de sesion `i24-guard-direct-2026-07-16`). Rotar tras uso segun politica del cliente.
- Supabase `service_role` key del proyecto productivo (usada por n8n via connection string directa; RLS no aplica a ese rol).
- Acceso SSH al Pi (`esteban@100.88.225.103` via Tailscale) solo si el rollout toca el scraper/monitor, no la ruta de n8n/DB.

### Backups frescos pre-cambio

1. Ejecutar `scripts/export-n8n-workflows.sh` (solo lectura contra n8n — usa `n8n export:workflow`, nunca importa) para refrescar `n8n-export/` inmediatamente antes de cualquier ventana de cambio.
2. Confirmar que el commit resultante en `n8n-backup` existe antes de continuar.
3. Los 25 snapshots `wf_*_backup_20260812T083420Z.json` en la raiz del repo son el ancla de rollback autorizada por LRV2-001; no se sobreescriben. Un nuevo snapshot pre-cambio (con timestamp propio) se toma ademas, no en reemplazo.

### Ventana de mantenimiento sugerida

Fuera de horario activo del scraper i24 (08:45-20:45 MX, ver `BYG_WF20_Watchdog_.json`) y con guardias notificadas de una posible discontinuidad temporal de notificaciones. Ventana sugerida: 21:00-23:00 MX cualquier dia entre semana.

## 3. Orden de migraciones

Migraciones nuevas de la serie v2: **`0021` a `0033`** (produccion ya tiene `0001`-`0020` aplicadas).

```
0021_lead_routing_v2.sql            -- estado/eventos/identidad durable + partial unique index
0022_guard_coverage_slots.sql       -- guardia primaria/respaldo
0023_routing_business_time.sql      -- ventana 20:00-08:00 + drenado 08:05
0024_upsert_lead_opportunity.sql    -- upsert persona+propiedad en intake
0025_resolve_first_property_tag.sql -- codigo EB + tags[0] estricto
0026_claim_lead_opportunity.sql     -- claim atomico
0027_advance_routing_tier.sql       -- escalamiento owner->primaria->respaldo
0028_routing_safe_mode.sql          -- circuit breaker
0029_routing_v2_metrics.sql         -- KPIs, vista operativa, dedupe de alertas
0030_delivery_attempts.sql          -- intentos de entrega por proveedor
0031_easybroker_step_evidence.sql   -- evidencia de pasos EasyBroker
0032_i24_contact_effect_lease.sql   -- lease Inmuebles24 Contactado
0033_easybroker_attend_effect_lease.sql -- lease EasyBroker Atendida
```

### Nota del stub `agent_manager_2`

`0011_owner_routing.sql` (ya aplicada en produccion) inserta un mapeo que referencia `agent_manager_2` como FK a `agents.agent_id`. **En un entorno construido desde cero** (no produccion), esa fila no existe hasta que se siembra manualmente o el seed de desarrollo la incluya — sin ella, `0011`/`0018` fallan por violacion de FK. La receta de gate de esta serie usa un stub minimo:

```sql
INSERT INTO agents (agent_id, name, whatsapp_number, on_shift, is_available)
VALUES ('agent_manager_2', 'Marusa (stub)', '+5215500000099', true, true)
ON CONFLICT (agent_id) DO NOTHING;
```

**En produccion NO se aplica este stub.** Antes de aplicar `0021`+ en produccion, verificar que el agente real ya existe:

```sql
SELECT agent_id, name, role FROM agents WHERE agent_id = 'agent_manager_2';
```

Si la fila no existe con ese `agent_id` exacto en produccion, detener el rollout — implica que el mapeo de `0011`/`0018` esta roto y `0021`+ heredaria el mismo problema.

### Aplicacion via psql session pooler

```bash
psql "$SUPABASE_SESSION_POOLER_URL" -v ON_ERROR_STOP=1 -f whatsapp-agent/migrations/0021_lead_routing_v2.sql
psql "$SUPABASE_SESSION_POOLER_URL" -v ON_ERROR_STOP=1 -f whatsapp-agent/migrations/0022_guard_coverage_slots.sql
# ... continuar en orden estricto hasta 0033
```

Aplicar **una migracion a la vez**, verificando `ON_ERROR_STOP=1` detiene en el primer error sin dejar la migracion a medias en la mayoria de los casos (cada archivo de la serie es transaccional internamente donde corresponde — confirmar visualmente que no hay error antes de continuar con la siguiente).

### Verificacion post-aplicacion

```sql
-- RPCs nuevas presentes y con el tipo esperado
\df get_routing_v2_kpis
\df claim_lead_opportunity
\df advance_routing_tier
\df report_routing_failure
\df get_routing_safe_mode
\df exit_routing_safe_mode

-- KPIs iniciales (debe responder sin error; en produccion recien migrada
-- reflejara datos reales de los ultimos 7 dias, no debe estar vacio si hay trafico)
SELECT get_routing_v2_kpis();

-- Estado del circuit breaker (debe estar 'normal' antes de activar cualquier workflow)
SELECT * FROM routing_safe_mode_state;

-- Privilegios: anon/authenticated deben ser denegados, service_role debe poder ejecutar
SET ROLE anon;
SELECT get_routing_v2_kpis();  -- debe fallar con "permission denied"
RESET ROLE;
```

### Evidencia de esta re-verificacion (contenedor `lrv2-015-gate`, PG17, efimero, ya eliminado)

| Paso | Resultado |
|---|---|
| Roles `anon`/`authenticated`/`service_role` (+ `BYPASSRLS` en `service_role`) | PASS |
| Apply `0001`→`0010` | PASS (10/10) |
| Stub `agent_manager_2` (solo gate) | PASS |
| Apply `0011`→`0033` | PASS (23/23) |
| Reapply `0028`, `0029`, `0033` (idempotencia) | PASS (3/3) |
| 6 fixtures de `tests/fixtures/routing_v2/*.sql`, cada una contra una base recien migrada 0001→0033 | PASS (6/6) — ver nota abajo |
| `\df get_routing_v2_kpis` | presente, `jsonb`, `p_days_back integer DEFAULT 7` |
| `SET ROLE service_role; SELECT get_routing_v2_kpis();` | PASS, JSON valido, todos los contadores en 0 (DB limpia) |
| `SET ROLE anon; SELECT get_routing_v2_kpis();` | `ERROR: permission denied for function get_routing_v2_kpis` (esperado) |
| `SELECT * FROM routing_safe_mode_state;` (como `service_role`) | `status = 'normal'`, sin incidentes (esperado en DB limpia) |

**Nota sobre las 6 fixtures:** al ejecutarlas en secuencia sobre la **misma** sesion/base ya migrada, `test_routing_metrics.sql` falla (`owner tier acceptance rate must be 100 given one claim_accepted and no rejections`). Causa raiz: `test_atomic_claims.sql` es la unica de las 6 sin un `BEGIN`/`ROLLBACK` de nivel superior — sus `INSERT` quedan comprometidos permanentemente y contaminan el calculo de tasa de aceptacion que hace `test_routing_metrics.sql` sobre toda la tabla. No es un bug de las migraciones ni de esta serie: es un supuesto de aislamiento de la fixture (cada una espera una base limpia). Se re-ejecuto cada fixture contra una base recien reconstruida (`DROP DATABASE`/`CREATE DATABASE` + `0001`→`0033` + stub) y las 6 pasan de forma independiente. No se modifico ningun archivo de fixture (fuera del alcance de `Archivos permitidos` de este ticket) — queda como riesgo abierto en §8 para quien ejecute el gate final.

## 4. Artefactos de importacion n8n

### Que importar

Workflows tocados por la serie LRV2 (fuente: gates en `docs/superpowers/tickets/2026-08-12-lead-routing-v2/README.md`, confirmado por diff contra baseline en §1):

| Workflow | ID productivo (baseline) | Nota |
|---|---|---|
| WF1 - Inbound Router (Evolution) | `snF6Sr9CBJIevMVD` | activo hoy; reimportar como inactivo, activar solo tras validacion |
| WF2 - Lead Intake (Evolution) | `ZUO5otqPzu9VYv8Z` | activo hoy |
| WF3b - Claim Handler (Evolution) | `JM2HxJxl53k4zlki` | `do_not_activate_yet` en baseline — reusable, no activar sin decision explicita |
| WF7 - Morning Report & Night Queue Processing | `xzBG0GIsHCUd44DC` | activo hoy |
| WF8b - EasyBroker Lead Intake | `Mu3YTTH8IgtaH7Ml` | `do_not_activate_yet` — EasyBroker sigue pausado por decision de cliente (ver memoria `eb-stopped-2026-07-15`) |
| WF10 - Scraper Lead Intake | `Obr38705ZZYS3FB8` | activo hoy; requiere credencial `headerAuth` (ver abajo) |
| WF12 - Owner Resolver (EB owner table) | `w7yJr7naWoxPq6Pw` | `do_not_activate_yet` — **ver advertencia critica abajo, el export local dice `active:true`** |
| WF13 - Directed Owner Notify (Cloud API) | `Bo2YbbUpmBzRbhDa` | `do_not_activate_yet` |
| WF17 - Reporte Semanal Email (Gerencia) | `YkhDEps0WbqaszMX` | activo hoy |
| BYG WF20 Watchdog | `pYV88ntxI0Lc4NCB` | activo hoy; **ver advertencia critica de drift abajo** |
| WF3a (renombrado a "Legacy Auction Disabled" en el export actual) | `04aQhTOiXlDmN9bK` | `do_not_activate_yet`, inactivo en baseline y en export actual |
| WF3c (renombrado a "Tiered Escalation Sweeper (Evolution)" en el export actual) | `UNIKqyAvIUAZkNIs` | `do_not_activate_yet`, inactivo en baseline y en export actual |

**Todos se importan primero como INACTIVOS**, sin excepcion — usar `scripts/n8n_control.py` (ver §7) o el flujo manual de n8n con "activo" desmarcado. Ningun workflow de esta lista se activa como parte de la importacion.

Los IDs productivos anteriores son autoridad segun `.planning/lead-routing-v2-production-baseline.json` (que a su vez cita `n8n-workflow-manifest.json` como autoridad de inventario). No inventar IDs nuevos ni reutilizar los de `whatsapp-agent/workflows/*.json` (esos son plantillas portables sin `id` real).

### Credencial WF10

WF10 - Scraper Lead Intake usa un nodo con credencial nativa `headerAuth` para el webhook del scraper. Esa credencial es un **placeholder** en el export — debe configurarse manualmente en la instancia n8n destino (nunca hardcodear el secreto en el JSON ni en este repo). No importar WF10 sin haber configurado esa credencial primero, o el workflow quedara con un nodo roto.

### Advertencia CRITICA: drift WF12 `active`

El diff contra baseline (§6) muestra que **`n8n-export/WF12_-_Owner_Resolver__EB_owner_table__.json` tiene actualmente `"active": true`**, mientras que el baseline y `do_not_activate_yet` lo marcan explicitamente como `false`/no-activar. Esto es un artefacto del export local (nadie con este ticket toco produccion), pero es exactamente el tipo de deriva que una importacion descuidada convertiria en una activacion accidental. **Antes de cualquier importacion de WF12: forzar `active:false` en el body enviado** (la funcion `import_inactive()` de §7 ya lo hace por construccion, nunca envia el campo `active`) y confirmar con el cliente/supervisor si ese cambio de estado en el export fue intencional antes de continuar.

### Drift WF20 fuente vs export: RESUELTO (2026-08-13)

Reconciliado en el cierre tecnico: la fuente `whatsapp-agent/workflows/WF20_watchdog.json` adopto la logica productiva aprobada del export (`cron */30 * * * *` con gate DB `i24_active_window` del fix 2026-07-07 y `EB_ENABLED=false` del apagado EasyBroker 2026-07-15), verificado contra el snapshot baseline `wf_pYV88ntxI0Lc4NCB` (testigo pre-LRV2). Paridad total fuente↔export↔activeVersion vigilada por `tests/test_routing_v2_contract.py::test_lrv2_wf20_full_parity` (falla ante cualquier drift nuevo). Cualquiera de las dos rutas de importacion es ahora equivalente; se mantiene la regla de no mezclar rutas en la misma ventana de cambio.

## 5. Shadow mode

Objetivo: comparar las decisiones que tomaria v2 contra el flujo actual **sin notificar a nadie**.

- Consultar `routing_v2_ops_view` (creada en `0029`) y `get_routing_v2_kpis()` en paralelo al flujo productivo activo, sin que ningun workflow v2 este activo — los datos de v2 solo existen si algo los escribe. En este modo, correr las funciones de escritura de v2 (`upsert_lead_opportunity`, `resolve_first_property_tag`, etc.) manualmente o via un workflow importado-pero-inactivo invocado a mano contra una copia de los leads reales, sin disparar notificaciones (los nodos de envio deben estar deshabilitados o apuntar a un canal de prueba).
- Duracion sugerida: minimo 3 dias habiles con volumen real de leads.
- Criterio de exito: 0 divergencias no explicadas entre el responsable que v2 hubiera asignado y el que el flujo actual asigno, para el mismo lead+propiedad. Toda divergencia se documenta con `opportunity_id` y motivo antes de pasar a canary.

## 6. Canary

- 1 propiedad y 1 agente autorizados explicitamente por el cliente antes de empezar.
- Activar unicamente el subconjunto de workflows necesario para esa propiedad/agente (WF10 -> WF12/WF13 dirigidos, sin abrir el resto de fuentes).
- Fuente gradual: iniciar solo con Inmuebles24 (bandeja unica) antes de sumar EasyBroker (que sigue pausado por decision de cliente, ver §4).
- Revision diaria por 7 dias: `SELECT * FROM routing_v2_ops_view` + `get_routing_v2_kpis()` cada dia, comparado contra el registro manual de la propiedad/agente piloto.

## 7. Go/no-go

Criterios de salida del contrato (`docs/superpowers/specs/2026-08-12-lead-routing-v2-contract.md`), evaluados a los 14 dias o 100 oportunidades, lo que ocurra primero:

- [ ] Cero doble asignacion (verificar con `SELECT opportunity_id, count(*) FROM lead_routing_events WHERE event_type='assigned' GROUP BY opportunity_id HAVING count(*) > 1` — debe devolver 0 filas).
- [ ] Cero oportunidad capturada sin estado terminal o alerta activa.
- [ ] 100% de asignaciones con evidencia de responsable y timestamps (`assigned_agent_id` y `delivered_at`/`claimed_at` no nulos en toda fila `state='assigned'`).
- [ ] Late claims nunca reasignan (verificar eventos `late_claim_rejected` sin mutacion de `assigned_agent_id` asociada).
- [ ] Rollback probado (ver §8) y documentado con evidencia de ejecucion real, no solo de disponibilidad del procedimiento.

Solo con las 5 casillas marcadas y aprobacion explicita del supervisor/cliente se activa el rollout gradual por fuente mas alla del canary.

## 8. Rollback

### Por capa: workflows

1. Localizar el snapshot correspondiente: `wf_<ID>_backup_20260812T083420Z.json` en la raiz del repo (integridad verificada en §1/§6).
2. Reimportar como inactivo: `n8n.rollback_from_backup(backup_path, base_url, api_key, workflow_id)` (§7) — nunca activa por si sola.
3. Solo si el estado pre-incidente era activo, ejecutar `n8n.activate(workflow_id, base_url, api_key)` como paso separado y explicito, con confirmacion humana entre el paso 2 y el paso 3.

### Por capa: migraciones

**Nunca en caliente sin backup.** Cada migracion de la serie que requiere reversion documenta sus propios `DROP` en el header:

- `0028_routing_safe_mode.sql`: DROPs de RPCs/estado de modo seguro documentados en el header del archivo.
- `0029_routing_v2_metrics.sql`: DROPs de vista/RPCs de metricas documentados en el header del archivo.
- `0033_easybroker_attend_effect_lease.sql`: DROPs del lease de evidencia EasyBroker documentados en el header del archivo.

El rollback de migraciones es **forward-fix**: aplicar un nuevo archivo `.sql` que ejecuta los `DROP`/reversion documentados, nunca editar ni volver a ejecutar una migracion ya aplicada. Tomar un backup de base de datos completo (pg_dump o snapshot del proveedor) inmediatamente antes de cualquier forward-fix.

### Por capa: flags operativos

- `EB_MARK_ATTENDED`: revertir a `false` para detener el marcado de Atendida en EasyBroker sin revertir migraciones ni workflows.
- `MARK_CONTACTED`: revertir a `0`/`false` para detener el marcado de Contactado en Inmuebles24.

Ambos flags son interruptores de app (scraper/monitor), no requieren rollback de n8n ni de DB — es el mecanismo de contencion mas rapido disponible si el problema esta en el efecto hacia el portal, no en el ruteo.

## 9. Checklist final de autorizacion

Cada punto requiere el OK humano explicito del supervisor/cliente, en este orden de ejecucion. Ninguno se ejecuta por default ni queda implicito en este runbook:

1. [ ] Confirmar `SELECT agent_id FROM agents WHERE agent_id='agent_manager_2'` en produccion antes de tocar cualquier migracion.
2. [ ] Autorizar aplicacion de `0021`→`0033` en produccion (psql session pooler, una a la vez, con backup previo).
3. [ ] Autorizar configuracion manual de la credencial `headerAuth` de WF10 en la instancia n8n destino.
4. [x] Reconciliacion drift WF20 fuente/export COMPLETADA en repo (2026-08-13, test de paridad total activo); no requiere accion productiva.
5. [ ] Autorizar reconciliacion del drift `active:true` de WF12 antes de cualquier importacion de ese workflow.
6. [ ] Autorizar importacion de los workflows de §4 como inactivos (uno por uno o en lote, siempre inactivos).
7. [ ] Autorizar inicio de shadow mode (sin notificaciones).
8. [ ] Autorizar activacion del canary (1 propiedad/agente).
9. [ ] Autorizar expansion gradual por fuente tras evaluacion diaria de 7 dias del canary.
10. [ ] Autorizar evaluacion formal de 14 dias/100 oportunidades y decision go/no-go final.
11. [ ] Solo tras go: autorizar activacion completa y desactivacion del flujo v1 equivalente.

---

## Anexo: capacidades verificadas de `scripts/n8n_control.py`

Antes de esta serie, `n8n_control.py` era 100% offline (`validate`, `drift`, `inventory`, `manifest-check` sobre archivos locales — sin ningun cliente HTTP). Se agregaron las funciones minimas necesarias para diff/import-inactivo/rollback contra la API real de n8n, siempre inyectables con un cliente mock para pruebas sin red:

| Funcion | Linea aprox. | Que hace |
|---|---|---|
| `fetch_live(base_url, api_key, workflow_id, client=None)` | `scripts/n8n_control.py` | `GET /workflows/{id}`. Read-only. |
| `diff_local_vs_live(local, base_url, api_key, workflow_id, client=None)` | `scripts/n8n_control.py` | Dry-run: descarga el workflow vivo y compara contra un archivo local con `normalized()`/`drift_detail()` ya existentes. Nunca escribe. |
| `import_inactive(workflow, base_url, api_key, workflow_id=None, client=None)` | `scripts/n8n_control.py` | Crea (`POST /workflows`, sin `workflow_id`) o actualiza (`PUT /workflows/{id}`). El body enviado **nunca incluye `active` ni `id`** — coincide con el contrato real de n8n observado en `deploy_owner_first.py` (`put_wf`/`post_wf`), donde un workflow nuevo nace inactivo y activar es siempre una llamada aparte. |
| `activate(workflow_id, base_url, api_key, client=None)` | `scripts/n8n_control.py` | `POST /workflows/{id}/activate`. Paso explicito y separado; ninguna otra funcion lo invoca implicitamente. |
| `rollback_from_backup(backup, base_url, api_key, workflow_id, client=None)` | `scripts/n8n_control.py` | Reimporta un snapshot `wf_*_backup_*.json` via `import_inactive` (queda inactivo); reactivar requiere una llamada separada a `activate()`. |

Todas aceptan `client: httpx.Client | None` — en pruebas se inyecta un `httpx.Client(transport=httpx.MockTransport(handler))`, que nunca abre un socket. `tests/test_n8n_control.py::N8nApiTests` cubre los 6 casos (fetch OK/error, diff sin/con cambios, import create/update sin `active`, activate como llamada separada, rollback sin activar, rollback con snapshot invalido) — 10 pruebas nuevas, 0 llamadas de red reales. `uv run pytest tests/test_n8n_control.py -q` → 30 passed.
