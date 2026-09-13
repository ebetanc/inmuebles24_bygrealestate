## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## Proyecto

Lead Routing V3 en producción (desde 2026-09-02). Flujo, IDs de los 13 workflows vivos y
horarios: `README.md` (sección «Flujo» y tabla de workflows).

Reglas de operación:

- **n8n solo por CLI.** La API key está muerta. Receta exacta (export/import/publish,
  restart): skill `ops-deploy`. **Los JSON del repo traen credenciales placeholder**
  (`REPLACE_WITH_POSTGRES_CREDENTIAL_ID`): nunca importes el JSON del repo tal cual;
  parte del export vivo y aplica solo el cambio.
- En la tabla `execution_entity` de n8n, las filas `running` con `deletedAt` NO son ejecuciones
  colgadas: son ejecuciones exitosas soft-deleted (`saveDataSuccessExecution: none`) esperando
  al pruner. Antes de declarar "cuelgue", mira `deletedAt` y el consumo de memoria.
- **Nunca modifiques producción sin exportar primero el workflow vivo y compararlo
  contra `whatsapp-agent/workflows/`.** Producción puede haber divergido del repo.
  `scripts/n8n_control.py` hace el diff/dry-run offline.
- Pi y tests: accesos y comandos en el skill `ops-deploy`.
- **En expresiones de n8n nunca uses `JSON.stringify({...})` con llaves anidadas
  (`}}` cierra la expresión):** cuerpo JSON literal con islas `{{ }}`.

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
