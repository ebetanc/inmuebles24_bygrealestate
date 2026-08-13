# LRV2-006: oportunidad canónica en intake

**Perfil:** budget+review | **Dependencias:** LRV2-003, LRV2-005 | **Estado:** completed

**Gate:** verification/security/quality PASS, PG17 dynamic PASS y pytest final PASS, 2026-08-13; `production_changes_authorized=false`.

## Resultado

Todos los canales hacen upsert idempotente por persona+propiedad antes de disparar routing.

## Archivos permitidos

- Crear `whatsapp-agent/migrations/0024_upsert_lead_opportunity.sql`
- Modificar `whatsapp-agent/workflows/WF2_lead_intake.json`, `WF8_easybroker_polling.json`, `WF10_scraper_intake.json`
- Modificar `tests/test_routing_v2_contract.py`
- Modificar exports versionados equivalentes de WF2, WF8b y WF10 bajo `n8n-export/`.

Los exports son artefactos de despliegue de las fuentes permitidas. Se sincronizan
mecÃ¡nicamente para impedir que una importaciÃ³n futura restaure inserts separados;
esto no autoriza importar, activar ni desplegar workflows.

## Implementación

1. Crear RPC única `upsert_lead_opportunity` usando identidad definida en LRV2-001.
2. Tratar IDs externos como idempotency keys, no como identidad de negocio.
3. Reemplazar inserts separados de WF2/WF8/WF10 por la RPC.
4. Emitir evento `detected` o `deduplicated`; solo una creación puede iniciar routing.

## Verificación

- Retry mismo payload no duplica.
- Dos canales para misma persona+propiedad convergen.
- Misma persona+otra propiedad crea otra oportunidad.
- Prueba concurrente usa conexiones reales, no llamadas secuenciales.

## Handoff

Reviewer confirma límites de identidad y desbloquea `LRV2-007` y `LRV2-011`.
