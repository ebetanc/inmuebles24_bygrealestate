# LRV2-007: resolver ejecutivo por código EB y primer tag

**Perfil:** budget | **Dependencias:** LRV2-006 | **Estado:** completed

**Gate:** verification/security/quality PASS, PG17 dynamic PASS y pytest directed/full PASS (8 passed; futuros 0026/0027 expected red), 2026-08-13; `production_changes_authorized=false`.

## Resultado

Resolver exactamente el responsable aprobado y producir una razón explícita cuando no sea posible.

## Archivos permitidos

- Crear `whatsapp-agent/migrations/0025_resolve_first_property_tag.sql`
- Modificar `whatsapp-agent/workflows/WF12_owner_resolver.json`, `WF10_scraper_intake.json`
- Modificar `tests/test_routing_v2_contract.py`

## Implementación

1. Reutilizar extracción de código EB de `src/inmobiliaria24/scraper.py:473-481`.
2. Implementar semántica de primer tag decidida en LRV2-001; no cambiar silenciosamente a segundo tag.
3. Validar agente activo y teléfono.
4. Devolver `resolved`, `reason`, tag observado y agente, sin asignar manager por defecto.

## Verificación

- Primer tag conocido, desconocido, vacío, agente inactivo y sin teléfono.
- Segundo tag conocido no gana si el contrato eligió `tags[0]` estricto.
- Fallback produce evento/razón y ruta acordada.

## Handoff

Adjuntar fixtures sanitizados de respuesta EB y desbloquear `LRV2-008`.

Recovery WF10: usar credencial nativa n8n `headerAuth`; conservar placeholder de credencial hasta configuración controlada. No hardcodear secretos, activar ni importar el workflow.
