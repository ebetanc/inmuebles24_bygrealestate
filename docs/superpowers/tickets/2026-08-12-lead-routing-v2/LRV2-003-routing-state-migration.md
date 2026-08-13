# LRV2-003: migración de estado, eventos e identidad

**Perfil:** budget+review | **Dependencias:** LRV2-002 | **Estado:** completed

**Gate:** verification/security/quality PASS, 2026-08-12; `production_changes_authorized=false`.

## Resultado

Migración aditiva e idempotente que soporte una oportunidad por persona+propiedad, eventos auditables y estado de routing v2.

## Archivos permitidos

- Crear `whatsapp-agent/migrations/0021_lead_routing_v2.sql`
- Modificar `tests/test_routing_v2_contract.py`
- Modificar `whatsapp-agent/scripts/02_verify_production.sql`

## Implementación

1. Añadir clave/columnas mínimas derivadas del contrato: identidad canónica, tier, timestamps de detección/solicitud/entrega/vencimiento/aceptación/asignación/cierre y evidencia externa.
2. Añadir tabla append-only de eventos con idempotency key.
3. Crear índice parcial que impida dos oportunidades activas para misma persona+propiedad.
4. Backfill solo valores derivables; desconocidos quedan `NULL`.
5. Mantener compatibilidad con columnas y consumers actuales.

## Verificación

- Aplicar dos veces en DB temporal sin error.
- Dos inserts concurrentes para misma persona+propiedad convergen; otra propiedad crea fila distinta.
- `uv run pytest tests/test_routing_v2_contract.py -q` vuelve verdes solo casos de schema/identidad base.
- Revisión supervisor de constraints, RLS, rollback y ausencia de operaciones destructivas.

## Anti-patrones

No deduplicar solo por teléfono. No usar logs n8n como fuente de verdad. No desplegar migración.

## Handoff

Adjuntar SQL de rollback de emergencia, aunque la migración normal sea forward-only. Desbloquea `LRV2-005`.
