# LRV2-012: cerrar conversación exacta en EasyBroker

**Perfil:** budget | **Dependencias:** LRV2-009 | **Estado:** done

**Gate:** verification/security/quality PASS, 2026-08-13; `production_changes_authorized=false`. PG17 (contenedor `postgres:17` efímero `lrv2-012-gate`, DB `gate`, roles anon/authenticated/service_role): apply 0001→0033 + reapply 0033 PASS; fixture `tests/fixtures/routing_v2/test_easybroker_effect_lease.sql` PASS; concurrencia real 2 conexiones (SKIP LOCKED, worker B obtiene 0 filas con lease vigente) PASS; lease vencido recuperado con token nuevo distinto PASS; token viejo no finaliza ni muta evidencia PASS; evidencia parcial nota/estado idempotente PASS; anon/authenticated `permission denied`, service_role EXECUTE OK; ambas funciones SECURITY INVOKER con `search_path=pg_catalog, public`. Pytest dirigido 24 passed + compileall OK, incluye tests nuevos `--once`→REQUEST_ID conductual, ausencia de `allow_phone_fallback=True` en poll y `--once`, y regresión del P1 (`test_add_note_reports_failure_when_note_not_visible_after_save`). Fix P1 del gate: `add_note()` ahora verifica con `note_exists()` tras Guardar en vez de retornar `True` incondicional. Residuales P2: interpolación de filtro PostgREST en `supa.py:_agent_names` (FK-constrained hoy), seed dev sin `agent_manager_2` rompe 0011/0018 en DB desde cero (gap de fixture, stub documentado en receta del gate).

## Resultado

Usar `eb_contact_id`/request ID para escribir nota y Atendida en la oportunidad correcta, sin búsqueda primaria por teléfono.

## Archivos permitidos

- Modificar `src/easybroker/inbox.py`, `main.py`, `supa.py`
- Modificar `tests/test_claim_gate.py`, `tests/test_pipeline_integration.py`
- Crear migración aditiva solo si falta evidencia separada de nota/estado.

## Implementación

1. `fetch_pending_attend()` entrega ID exacto.
2. `attend_lead()` navega/correlaciona por ese ID; teléfono solo fallback aprobado y registrado.
3. Nota y cambio a Atendida son pasos idempotentes con flags separados.
4. Retry ejecuta solo el paso incompleto.

## Verificación

- Dos oportunidades con mismo teléfono cierran solo request indicado.
- Nota exitosa + estado fallido reintenta solo estado.
- Estado ya Atendida no duplica nota.
- Pruebas Playwright mockean navegación por ID.

## Handoff

No escribir EasyBroker real. Adjuntar antes/después de fixture y desbloquear `LRV2-013` junto con 010/011.

