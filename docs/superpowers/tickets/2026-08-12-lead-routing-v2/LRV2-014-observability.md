# LRV2-014: eventos, KPIs, dashboard y alertas

**Perfil:** budget | **Dependencias:** LRV2-013 | **Estado:** done

**Gate:** verification/security/quality PASS, 2026-08-13; `production_changes_authorized=false`. Migración `0029_routing_v2_metrics.sql` (slot lexical pre-0030; KPI en plpgsql para validación diferida de columnas 0033): vista ops `routing_v2_ops_view` (security_invoker, SLA solo desde `delivered_at`, nunca `created_at`), `get_routing_v2_kpis`, dedupe/ack de alertas sin-asignar (`incident_key` UNIQUE, DB-enforced), `weekly_lead_report()` reemplazada aditivamente (copia byte-exacta de 0020 + clave `routing_v2`; aditividad probada contra DB legacy 0001→0028: 11 claves preservadas). PG17: apply/reapply idempotente, 6 fixtures verdes, dedupe/ack verificados, anon/authenticated denegados y service_role OK en vista+RPCs, SECURITY INVOKER + search_path fijado. WF17 (fuente nueva creada desde export) + WF20 rama sin-asignar alert-only; mirrors sincronizados. Fixes P0 post-review: jsCode `Build HTML` de WF17 tenía TDZ (`card` usado antes de declarar → ReferenceError en cada corrida) y `rv2Section` inyectado dentro de atributo `style` → ambos corregidos en fuente y export (jsCode byte-idéntico) + test que EJECUTA el jsCode en Node (payload con y sin `routing_v2`, footer intacto). Fix P1: panel dashboard ahora renderiza vista operativa completa (tier, responsable, SLA m:ss, última evidencia) además de la lista sin-asignar; `npm run build` OK. Pytest total dirigido 88 passed. Residuales P2: drift preexistente WF20 fuente↔export (gate off-hours `i24_active_window` + `EB_ENABLED` solo en export — reconciliar en ticket futuro antes de reimportar desde fuente); `failures_by_integration.easybroker` cuenta estado actual, no ventana (0033 sin `failed_at`, comentario ponytail con upgrade path); lint dashboard con 1 error preexistente en `source-chart.tsx` (no tocado). Rollback: nada aplicado; DROPs en header de 0029.

## Resultado

Hacer observable cada transición y alertar casos sin asignar sin crear nueva lógica de asignación.

## Archivos permitidos

- Crear `whatsapp-agent/migrations/0029_routing_v2_metrics.sql`
- Modificar `whatsapp-agent/migrations/0020_weekly_report_claim_rate.sql` mediante nueva migración, no reescribir aplicada
- Modificar `dashboard/src/lib/queries.ts`, `types.ts` y páginas/componentes estrictamente necesarios
- Modificar `whatsapp-agent/workflows/WF17_weekly_email_report.json`, `WF20_watchdog.json`

## Implementación

1. Exponer eventos: detected, deduplicated, queued_night, processing_started, delivery_requested, delivered, delivery_failed, accepted, claim_rejected, escalated, assigned, i24_contacted, eb_noted, eb_attended, safe_mode y unassigned_alerted.
2. KPIs usan timestamps correctos, no intercambian created/delivered/assigned.
3. Vista operativa muestra tier, responsable, SLA restante, última evidencia y casos sin asignar.
4. Email inmediato tiene dedupe/ack; reporte semanal se amplía de forma aditiva.

## Verificación

- Fixture por escenario produce secuencia esperada.
- `npm run lint && npm run build` en dashboard.
- Render del reporte tolera nuevas claves.
- Alerta repetida del mismo incidente no duplica correo.

## Handoff

Adjuntar matriz escenario -> eventos/KPI y desbloquear `LRV2-015`.

