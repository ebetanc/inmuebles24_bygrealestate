# LRV2-004: guardia primaria y respaldo

**Perfil:** budget+review | **Dependencias:** LRV2-002 | **Estado:** completed

**Gate:** verification/security/quality PASS, 2026-08-12; `production_changes_authorized=false`.

## Resultado

Modelar dos slots ordenados por turno y editarlos sin inferir prioridad por `agent_id`.

## Archivos permitidos

- Crear `whatsapp-agent/migrations/0022_guard_coverage_slots.sql`
- Modificar `whatsapp-agent/workflows/WF6_guard_schedule.json`
- Modificar `dashboard/src/app/(dashboard)/calendario/calendar-editor.tsx`
- Modificar `dashboard/src/lib/queries.ts`, `dashboard/src/lib/types.ts`

## Implementación

1. Extender schedule con rol/posición `primary|backup` y unicidad por fecha+turno+rol.
2. Crear helper documentado que devuelva ambos slots en orden, sin `ORDER BY agent_id` como negocio.
3. Adaptar sync WF6 y UI para leer/escribir los dos slots.
4. Validar que primaria y respaldo sean agentes distintos, activos y con WhatsApp.

## Verificación

- Pruebas SQL para ambos slots, duplicados y faltantes.
- `npm run lint` y `npm run build` desde `dashboard`.
- UI conserva ambos agentes tras reload.
- Reviewer confirma compatibilidad con calendarios existentes.

## Handoff

Documentar fallback exacto acordado cuando falta uno de los slots. Desbloquea `LRV2-010` cuando `LRV2-009` termine.

Predeploy: regenerar `n8n-export/WF6_-_Guard_Schedule_Sync__Supabase__.json` desde `whatsapp-agent/workflows/WF6_guard_schedule.json`; no activar ni importar.
