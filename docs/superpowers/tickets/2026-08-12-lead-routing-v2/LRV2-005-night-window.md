# LRV2-005: ventana nocturna y drenado 08:05

**Perfil:** budget | **Dependencias:** LRV2-003 | **Estado:** completed

**Gate:** verification/security/quality PASS y PG17 dynamic PASS, 2026-08-12; `production_changes_authorized=false`.

## Resultado

Una única regla CDMX: silencio 20:00-08:00; activación idempotente a las 08:05.

## Archivos permitidos

- Crear `whatsapp-agent/migrations/0023_routing_business_time.sql`
- Modificar `whatsapp-agent/workflows/WF7_morning_report.json`
- Modificar `whatsapp-agent/workflows/WF10_scraper_intake.json`
- Modificar `tests/test_routing_v2_contract.py`
- Modificar `n8n-export/WF7_-_Morning_Report___Night_Queue_Processing_.json`
- Modificar `n8n-export/WF10_-_Scraper_Lead_Intake_.json`

Los dos exports son artefactos de despliegue versionados de los workflows permitidos;
se mantienen sincronizados para que una importacion futura no restaure la semantica
pre-lease. Esta ampliacion no autoriza importar, activar ni desplegar workflows.

Scope completado: exports WF7/WF10 sincronizados con sus fuentes.

## Implementación

1. Reemplazar semántica 08:00-21:00 de `0005` mediante nueva migración, sin editar migraciones aplicadas.
2. Centralizar `is_daytime()`/turno en DB con `America/Mexico_City`.
3. Hacer claim de cola por lote antes de procesar y marcar `processed` solo tras evento durable de routing.
4. Reintento no crea segunda oferta ni salta orden estable.

## Verificación

- Casos 19:59:59, 20:00:00, 07:59:59, 08:00:00 y 08:05:00.
- Dos ejecuciones WF7 sobre misma cola producen una sola activación.
- JSON válido y `uv run pytest tests/test_routing_v2_contract.py -q` pasa casos nocturnos.

## Handoff

Entregar tabla entrada/hora/ruta y desbloquear `LRV2-006`.
