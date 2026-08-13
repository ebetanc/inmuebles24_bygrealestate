# LRV2-008: oferta con botón y SLA desde entrega

**Perfil:** budget+review | **Dependencias:** LRV2-007 | **Estado:** completed

**Gate:** verification/security/quality PASS, PG17 `0030` apply/reapply PASS, 6 dynamic blocks PASS y directed 3 passed, 2026-08-13; `production_changes_authorized=false`.

## Resultado

Enviar `Tomar prospecto`, correlacionar estado de entrega e iniciar 5 minutos únicamente al confirmar `delivered`.

## Archivos permitidos

- Modificar `whatsapp-agent/workflows/WF13_directed_notify.json`, `WF1_inbound_router.json`
- Crear `whatsapp-agent/workflows/WF22_delivery_status.json`
- Crear/modificar fixture de workflow bajo `tests/fixtures/routing_v2/`
- Modificar `tests/test_routing_v2_contract.py`
- Crear `whatsapp-agent/migrations/0030_delivery_attempts.sql` (`0026`-`0029` quedan reservadas por LRV2-009, LRV2-010, LRV2-013 y LRV2-014).
- Crear `n8n-export/WF22_-_Delivery_Status_.json` y sincronizar exports versionados de WF1/WF13.
- Crear `whatsapp-agent/workflows/WF23_delivery_timeout_sweeper.json` para callback ausente; una sola URL Meta entra por WF22 y los mensajes autenticados se pasan a WF1.

## Implementación

1. Reutilizar parser button/list/template de WF1; definir ID estable no ambiguo que incluya oportunidad/tier.
2. Enviar oferta interactiva y persistir `delivery_requested_at` + external message ID.
3. WF22 deduplica callbacks y, solo en `delivered`, fija `delivered_at` y `expires_at = delivered_at + 5 min`.
4. Fallo/no callback aplica retry/fallback decidido, sin consumir SLA.

## Verificación

- Callback duplicado es inocuo.
- `sent`/`accepted` no inician reloj si contrato exige `delivered`.
- Botón viejo no opera sobre otro tier.
- Reviewer valida que no haya secreto/host hardcoded nuevo.

## Handoff

Entregar fixtures de estados del proveedor y desbloquear `LRV2-009`.

Scope completado: nuevos WF22/WF23, autenticación/env y migración `0030`. No se importaron/activaron workflows ni se aplicó migración en producción.
