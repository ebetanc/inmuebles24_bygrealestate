# LRV2-009: aceptación atómica y tardíos inocuos

**Perfil:** budget+review | **Dependencias:** LRV2-008 | **Estado:** completed

**Gate:** verification/security/quality PASS, PG17 clean/reapply/concurrent con `service_role` PASS y pytest directed 2 passed/full 11 passed con solo futuro `0027` expected red, 2026-08-13; `production_changes_authorized=false`.

## Resultado

Una sola transacción valida y asigna; toda respuesta simultánea, vieja o tardía devuelve resultado determinista sin reasignar.

## Archivos permitidos

- Crear `whatsapp-agent/migrations/0026_claim_lead_opportunity.sql`
- Modificar `whatsapp-agent/workflows/WF3b_claim_handler.json`, `WF1_inbound_router.json`
- Modificar `tests/test_routing_v2_contract.py`, `tests/test_claim_gate.py`

## Implementación

1. Convertir predicado de WF3b en RPC transaccional.
2. Validar oportunidad abierta, tier vigente, agente autorizado, entrega confirmada, no expirada y sin responsable.
3. Persistir claim, responsable y evento en la misma transacción.
4. Responder `accepted|already_assigned|expired|not_authorized|delivery_pending`.
5. Retry del ganador es idempotente; tardío solo agrega evento.

## Verificación

- Dos conexiones simultáneas producen un ganador.
- Claim en límite obedece regla documentada.
- Claim owner tras escalamiento no reasigna.
- `uv run pytest tests/test_claim_gate.py tests/test_routing_v2_contract.py -q`.

## Handoff

Supervisor revisa aislamiento y bloqueo. Desbloquea `LRV2-010` y `LRV2-012`.
