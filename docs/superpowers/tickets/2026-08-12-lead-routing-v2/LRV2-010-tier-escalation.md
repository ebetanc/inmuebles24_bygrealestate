# LRV2-010: escalamiento ejecutivo, primaria y respaldo

**Perfil:** budget+review | **Dependencias:** LRV2-004, LRV2-009 | **Estado:** completed

**Gate:** verification/security/quality PASS, PG17 apply/reapply y fixture dinámica S-05–S-07 PASS, pytest dirigido 11 passed y paridad source/export PASS, 2026-08-13; `production_changes_authorized=false`.

## Resultado

Reemplazar asignación inmediata/fan-out por máquina secuencial de tres tiers.

## Archivos permitidos

- Crear `whatsapp-agent/migrations/0027_advance_routing_tier.sql`
- Modificar `whatsapp-agent/workflows/WF3c_expiry_sweeper.json`, `WF3a_auction_launcher.json`, `WF19_guard_notify.json` o export canónico equivalente definido en baseline
- Modificar `tests/test_routing_v2_contract.py`

## Implementación

1. RPC bloquea oportunidad, verifica tier/vencimiento y avanza exactamente una vez.
2. Owner vencido notifica solo primaria; primaria vencida notifica solo respaldo.
3. Invalida tokens del tier anterior.
4. Falla de entrega y falta de agente siguen decisión LRV2-001.
5. Eliminar orden por `agent_id` y autoasignación anticipada.

## Verificación

- Ejecuciones concurrentes del sweeper producen una sola transición.
- Solo destinatario vigente puede aceptar.
- Primaria y respaldo reciben una oferta cada uno, nunca fan-out.
- No reactivar workflows ni editar IDs productivos durante este ticket.

## Handoff

Reviewer comparó diagrama de estados con contrato. La dependencia 010 de `LRV2-013` está satisfecha; `LRV2-013` permanece bloqueado hasta que 011/012 terminen.
