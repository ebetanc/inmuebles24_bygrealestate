# LRV2-001: congelar contrato y baseline productivo

**Perfil:** supervisor | **Dependencias:** ninguna | **Estado:** completed

**Gate:** verification/security/quality PASS, 2026-08-12; `production_changes_authorized=false`.

## Resultado

Cerrar decisiones que afectan código y producir un manifiesto reproducible de workflows productivos antes de editar.

## Archivos permitidos

- Crear `docs/superpowers/specs/2026-08-12-lead-routing-v2-contract.md`
- Crear `.planning/lead-routing-v2-production-baseline.json`
- Leer `n8n-workflow-manifest.json`, backups `wf_*_backup_20260812T083420Z.json`, plan y HTML.

## Decisiones obligatorias

Registrar una respuesta inequívoca para: SLA primaria; SLA respaldo; destino si falla respaldo; primer tag estricto vs primer tag resoluble; fallback sin código/tag/teléfono; identidad sin teléfono; periodo de unión de duplicados; fuentes incluidas; señal de entrega WhatsApp; umbral/owner de modo seguro.

Recomendaciones por defecto: 5 min primaria, 5 min respaldo, luego alerta sin reasignar; `tags[0]` estricto; fallback directo a primaria; identidad portal ID o email normalizado; duplicar solo al cambiar propiedad; incluir i24 y EasyBroker; `delivered` del proveedor; modo seguro tras 2 fallos consecutivos de routing.

## Pasos

1. Revisar cada recomendación con owner y registrar `confirmed` o valor alterno.
2. Inventariar ID, nombre, activo, versión/hash y callers de cada workflow productivo.
3. Marcar exports locales reutilizables pero inactivos.
4. Prohibir secretos, hosts y credenciales en ambos artefactos.

## Verificación

- `rg -n "TBD|por definir|pendiente" docs/superpowers/specs/2026-08-12-lead-routing-v2-contract.md` no devuelve decisiones de negocio.
- Baseline es JSON válido y contiene WF7, WF10, WF19 y todo caller activo.
- Ningún valor coincide con patrones `apikey|service_role|X-Authorization` seguido de secreto.

## Handoff

- Owner aprueba contrato.
- Supervisor acepta firma estructurada en `supervisor_approval`: `status=approved`, `approved_at`, `approved_scope=contract_and_baseline_only`, `production_changes_authorized=false` y `approved_by`; lista también workflows que no deben activarse todavía.
- Handoff incluye decisiones finales y desbloquea `LRV2-002`.
