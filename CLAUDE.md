## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## Proyecto

Lead Routing V3 en producción (desde 2026-09-02). Ver `README.md` para el detalle.

Flujo vivo: scraper en Raspberry Pi (`/opt/inmobiliaria24`, `inmobiliaria24.timer`
cada 15 min 24/7) lee las bandejas `mensajes` y `whatsapp` de Inmuebles24 —la de
`telefono` ("Vió teléfono") se ignora desde el 2026-09-04, no es una consulta—
→ `v3_intake` en Supabase → marca
`Contactado` (verificado) → `POST https://n8n.srv856940.hstgr.cloud/webhook/scraper-leads`
→ WF10 → WF12 (dueño por tag de EasyBroker) → WF13 (plantilla Meta `lead_subasta_v3`,
botón único "Tomo", requiere URL pública de EB) → callbacks Meta → WF22 (HMAC, inbox
durable) → WF1 → WF3b (primer clic válido gana, atómico). WF23 (cron 30 s) es el
**único** motor de tiempos: 2 min sin `delivered` o 5 min tras `delivered` → WF3c →
guardia del turno → 5 min → Sandy (`agent_manager`, plantilla `lead_asignado_v3`).
Noche 20:00–08:00 CDMX: `queued_night`, liberado por WF7 a las 08:05. El worker
`src/easybroker` (cada minuto) escribe nota `RESPONSABLE: <nombre>` + `Atendida` en la
solicitud EB exacta.

Workflows vivos (13): WF10 `Obr38705ZZYS3FB8`, WF12 `w7yJr7naWoxPq6Pw`,
WF13 `Bo2YbbUpmBzRbhDa`, WF22 `Z89IQDw1fgWlqXEW`, WF1 `snF6Sr9CBJIevMVD`,
WF3b `JM2HxJxl53k4zlki`, WF23 `MjfHw3tYE2qYgJfM`, WF3c `UNIKqyAvIUAZkNIs`,
WF7 `xzBG0GIsHCUd44DC`, WF20 `pYV88ntxI0Lc4NCB`, WF21 `He95yJflKVspGFyb`,
WF24 `WF24V3MonitorDia`, WF17 `YkhDEps0WbqaszMX`.

Reglas de operación:

- **n8n solo por CLI.** La API key está muerta. `ssh root@69.62.108.2`, contenedor
  `root-n8n-1`: `docker exec root-n8n-1 n8n export:workflow --id=<ID> --output=/tmp/x.json`,
  `import:workflow --input=` (el JSON **debe** traer `id`), y como el import desactiva,
  siempre `publish:workflow --id=` + `docker restart root-n8n-1`.
  **Los JSON del repo traen credenciales placeholder** (`REPLACE_WITH_POSTGRES_CREDENTIAL_ID`):
  nunca importes el JSON del repo tal cual; parte del export vivo y aplica solo el cambio.
- En la tabla `execution_entity` de n8n, las filas `running` con `deletedAt` NO son ejecuciones
  colgadas: son ejecuciones exitosas soft-deleted (`saveDataSuccessExecution: none`) esperando
  al pruner. Antes de declarar "cuelgue", mira `deletedAt` y el consumo de memoria.
- **Nunca modifiques producción sin exportar primero el workflow vivo y compararlo
  contra `whatsapp-agent/workflows/`.** Producción puede haber divergido del repo.
  `scripts/n8n_control.py` hace el diff/dry-run offline.
- Pi: `ssh esteban@100.88.225.103` (Tailscale). Deploy: `sudo bash /opt/inmobiliaria24/deploy/deploy.sh`
  (git pull + pip install + restart de `inmobiliaria24.timer`); `easybroker.timer` se
  reinicia aparte.
- Tests: `PYTHONPATH=src python -m pytest -q` (380 passed, 2 xfailed).

Fuentes de verdad: `docs/superpowers/specs/2026-08-26-lead-routing-v3-contract.md`,
`docs/superpowers/plans/2026-08-26-lead-routing-v3-execution-plan.md`,
`supabase/V3_PRODUCTION_MIGRATION_STATUS.md`, `src/easybroker/README.md`,
`whatsapp-agent/workflows/*.json` (canónico) vs `n8n-export/*.json` (snapshot semanal).

Legacy a ignorar: WF2/WF4/WF5 (bot IA), WF6, WF8/WF8b (polling EB), WF3a,
WF14/WF15/WF16 (seguimientos), WF19 (guard-direct, sigue activo en el VPS pero fuera
del camino V3 → desactivar), Evolution API, Lead Routing V2/LRV2 (solo shadow,
`routing_safe_mode_state` es ignorado por V3), adaptador HubSpot, bot de calificación
en `src/inmobiliaria24/whatsapp`, `whatsapp-agent/migrations/` (V1/V2), y los planes
históricos movidos a `docs/archive/`.
