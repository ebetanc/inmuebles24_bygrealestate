# LRV2-011: marcar Contactado en Inmuebles24

**Perfil:** budget | **Dependencias:** LRV2-006 | **Estado:** completed

**Gate:** verification/security/quality PASS, PG17 apply/reapply y dinámicas de lease, concurrencia, drift y recovery PASS, pytest dirigido PASS, 2026-08-13; `production_changes_authorized=false`.

## Resultado

Marcar Contactado al inicio durable del procesamiento, con evidencia y retry idempotente.

## Archivos permitidos

- Modificar `src/inmobiliaria24/main.py`, `scraper.py`, `supa.py`
- Crear/modificar una migración solo si LRV2-003 no incluyó evidencia i24
- Modificar `tests/test_pipeline_integration.py`, `tests/test_claim_gate.py`

## Implementación

1. Reutilizar `mark_lead_contacted()`; no duplicar selectors.
2. Encolar side effect después de crear oportunidad durable y antes de oferta, según contrato aprobado.
3. Persistir intento, éxito/error y screenshot de error sin datos sensibles.
4. Retry solo pendientes; estado ya Contactado cuenta como éxito idempotente.

## Verificación

- Falla portal no pierde oportunidad ni bloquea routing.
- Retry no repite trabajo terminado.
- `uv run pytest tests/test_pipeline_integration.py tests/test_claim_gate.py -q`.

## Handoff

Completado con lease durable exclusivo, revalidación antes y después del efecto externo, auditoría event-first y reconciliación idempotente de estado ya `Contactado`. Desbloqueo parcial de LRV2-013; sigue esperando LRV2-012. No se aplicaron migraciones ni escrituras en producción.

Entregar evidencia mock/preview. No ejecutar escritura real sin autorización de LRV2-015.
