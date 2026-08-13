# LRV2-013: modo seguro y guardia directa

**Perfil:** budget+review | **Dependencias:** LRV2-010, LRV2-011, LRV2-012 | **Estado:** done

**Gate:** verification/security/quality PASS, 2026-08-13; `production_changes_authorized=false`. Migración `0028_routing_safe_mode.sql`: estado singleton durable + eventos append-only (trigger reutilizado de 0021) + RPCs `report_routing_failure`/`get_routing_safe_mode`/`exit_routing_safe_mode` (SECURITY INVOKER, search_path fijado, REVOKE PUBLIC/anon/authenticated, GRANT service_role). PG17 (contenedor efímero, receta LRV2-012 + `ALTER ROLE service_role BYPASSRLS`): apply 0001→0033 + reapply 0028 x2 PASS; fixture `test_safe_mode.sql` PASS; trip exactamente una vez con 2 fallos <5 min (FOR UPDATE singleton, carrera concurrente real sin double-trip); tercer fallo sin segunda entrada; idempotency_key dedupe; exit exige actor + health verde y preserva historial; re-entrada OK; anon/authenticated denegados, service_role OK; append-only en capa grant + trigger. Fix P1 post-review: razón de auditoría `routing_safe_mode` propia (override `route_missing_owner_data` en 0028 aceptando ambas razones — verificado que 0030-0033 no lo revierten; fixtures tier_escalation y easybroker re-verdes) y mirrors sincronizados `n8n-export/WF10` + `BYG_WF20_Watchdog_` con test de paridad WF20 (igualdad total de connections). Pytest 45 passed. Residuales P2: `check_routing_safe_mode` en monitor.py sin caller en `src/` (patrón preexistente `check_webhook_health`; WF20 ya alerta por Gmail); drift preexistente no relacionado en 3 nodos WF20 fuente↔export (ej. cron `*/30 8-20` vs `*/30 *`); tests S-13/S-14 en pytest son string-match, el comportamiento real se prueba en la fixture PG17 (patrón de la serie). Rollback: nada aplicado; revertir archivos del working tree.

## Resultado

Circuit breaker durable que conserva intake y deriva nuevas oportunidades según contrato cuando routing está degradado.

## Archivos permitidos

- Crear `whatsapp-agent/migrations/0028_routing_safe_mode.sql`
- Modificar `whatsapp-agent/workflows/WF20_watchdog.json`, `WF10_scraper_intake.json`
- Modificar `src/inmobiliaria24/monitor.py`
- Modificar `tests/test_monitor.py`, `tests/test_routing_v2_contract.py`

## Implementación

1. Estado durable con motivo, inicio, owner, acknowledge y salida manual/automática acordada.
2. WF20 evalúa señales definidas en LRV2-001; transición es idempotente.
3. Intake sigue guardando oportunidad y evento; omite owner y va a cobertura segura acordada.
4. Recuperación reconcilia sin reenviar oferta a oportunidades ya asignadas.

## Verificación

- Dos fallos/umbral acordado activan una vez; recuperación no borra historial.
- Caída simulada de cada componente conserva captura.
- Modo seguro nunca produce segunda asignación.
- Reviewer valida que dashboard/email alertan, no asignan por sí solos.

## Handoff

Entregar runbook entrada/salida y desbloquear `LRV2-014`.

