# LRV2-015: shadow, canary y rollout

**Perfil:** supervisor | **Dependencias:** LRV2-014 | **Estado:** ready-for-production

**Gate (fase pre-producción):** verification/security/quality PASS, 2026-08-13; `production_changes_authorized=false`. Suite completa **193 passed**; `npm run build` OK (lint: 1 error preexistente en `source-chart.tsx`); validación JSON/nodos/conexiones 55/55 archivos OK; cadena PG17 release-candidate re-verificada (apply 0001→0033, reapply 0028/0029/0033 idempotente, 6 fixtures verdes individualmente); integridad baseline 25/25 snapshots SHA-256 exactos. `scripts/n8n_control.py` extendido offline-testeable: `fetch_live`, `diff_local_vs_live` (dry-run), `import_inactive` (body sin `active`/`id`, settings filtrados por whitelist de deploy_owner_first — fix P1 del gate), `activate` explícito separado, `rollback_from_backup` (nunca auto-activa); 11 tests con MockTransport, red imposible en tests. Runbook `docs/superpowers/plans/2026-08-12-lead-routing-v2-rollout-runbook.md` con orden de migraciones, artefactos de importación, shadow, canary, go/no-go, rollback por capa y checklist de 11 autorizaciones humanas. Fix rojo del gate: bloque de rollback añadido al header de 0033 (antes el runbook lo afirmaba sin existir). Riesgos abiertos documentados: export WF12 con `active:true` vs baseline `do_not_activate_yet` (trampa de import; mitigada porque `import_inactive` nunca envía `active`); drift WF20 fuente↔export (`i24_active_window` + `EB_ENABLED` solo en export — reconciliar antes de importar desde fuente); fixture `test_atomic_claims.sql` sin BEGIN/ROLLBACK (fuga en corridas acumulativas; correr fixtures sobre DB fresca). NO ejecutado (requiere autorización humana explícita): aplicar migraciones productivas, importar/activar workflows, shadow real, canary, WhatsApp/portales reales, commit/push/deploy. Pasa a `done` solo tras rollout aprobado + observación 14 días o 100 oportunidades.

## Resultado

Verificar historia completa, ensayar rollback y activar gradualmente solo con aprobación explícita.

## Archivos permitidos

- Crear `docs/superpowers/plans/2026-08-12-lead-routing-v2-rollout-runbook.md`
- Modificar `scripts/n8n_control.py`, `tests/test_n8n_control.py` si falta soporte no destructivo para diff/import inactivo/rollback.
- No modificar producción hasta gate final aprobado.

## Pasos

1. Ejecutar suite: `uv run pytest -q`; dashboard `npm run lint` y `npm run build`.
2. Validar JSON n8n, migraciones idempotentes y diff contra baseline LRV2-001.
3. Importar workflows inactivos a entorno controlado; smoke de S01-S12.
4. Shadow mode: comparar decisión v2 vs producción sin notificar.
5. Canary con una propiedad/agente autorizados.
6. Ensayar rollback de workflows, flags y migraciones forward-fix.
7. Solicitar aprobación explícita antes de activar o migrar producción.

## Verificación y criterios de salida

- Cero doble asignación.
- Cero captura sin estado terminal o alerta activa.
- 100% asignaciones con evidencia/timestamps.
- Late claim nunca reasigna.
- Revisión diaria 7 días y evaluación día 14 o 100 oportunidades.

## Handoff

Incluir versiones/IDs activados, comandos, backups, evidencia E2E, métricas iniciales, incidencias, rollback probado y decisión go/no-go. Sin aprobación explícita, estado queda `ready-for-production`, no `done`.
