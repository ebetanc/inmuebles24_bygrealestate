# Tickets ejecutables: Lead Routing v2

Fuente: `docs/superpowers/plans/2026-08-12-lead-routing-v2-execution-plan.md`  
Flujo visual: `docs/cliente/flujo-atencion-leads-detallado.html`  
Estado inicial: implementación no iniciada; producción no debe modificarse hasta `LRV2-015`.

Gate `LRV2-001`: verification/security/quality PASS, 2026-08-12; `production_changes_authorized=false`.
Gate `LRV2-002`: verification/security/quality PASS, 2026-08-12; `production_changes_authorized=false`.
Gate `LRV2-003`: verification/security/quality PASS, 2026-08-12; `production_changes_authorized=false`.
Gate `LRV2-004`: verification/security/quality PASS, 2026-08-12; `production_changes_authorized=false`.
Gate `LRV2-005`: verification/security/quality PASS y PG17 dynamic PASS, 2026-08-12; `production_changes_authorized=false`.
Gate `LRV2-006`: verification/security/quality PASS, PG17 dynamic PASS y pytest final PASS, 2026-08-13; `production_changes_authorized=false`.
Gate `LRV2-007`: verification/security/quality PASS, PG17 dynamic PASS y pytest directed/full PASS (8 passed; futuros 0026/0027 expected red), 2026-08-13; `production_changes_authorized=false`.
Gate `LRV2-008`: verification/security/quality PASS, PG17 `0030` apply/reapply PASS, 6 dynamic blocks PASS y directed 3 passed, 2026-08-13; `production_changes_authorized=false`.
Gate `LRV2-009`: verification/security/quality PASS, PG17 clean/reapply/concurrent con `service_role` PASS y pytest directed 2 passed/full 11 passed con solo futuro `0027` expected red, 2026-08-13; `production_changes_authorized=false`.
Gate `LRV2-010`: verification/security/quality PASS, PG17 apply/reapply y fixture dinámica S-05–S-07 PASS, pytest dirigido 11 passed y paridad source/export PASS, 2026-08-13; `production_changes_authorized=false`.
Gate `LRV2-011`: verification/security/quality PASS, PG17 apply/reapply y dinámicas de lease, concurrencia, drift y recovery PASS, pytest dirigido PASS, 2026-08-13; `production_changes_authorized=false`.
Gate `LRV2-012`: verification/security/quality PASS, PG17 apply/reapply 0033 + fixture lease + concurrencia real 2 conexiones + recovery/stale-token + privilegios runtime (anon/authenticated denegados, service_role OK, SECURITY INVOKER) PASS, pytest dirigido 24 passed (incl. regresión P1), 2026-08-13; fix P1 `add_note` verifica con `note_exists`; `production_changes_authorized=false`.
Gate `LRV2-013`: verification/security/quality PASS, PG17 apply/reapply 0028 + fixture safe_mode + carrera concurrente de trip sin doble entrada + exit manual con health verde + privilegios runtime PASS, re-gate delta tras fix P1 (razón `routing_safe_mode` vía override de `route_missing_owner_data` en 0028; mirrors WF10/WF20 sincronizados con test de paridad WF20) PASS, pytest 45 passed, 2026-08-13; `production_changes_authorized=false`. Receta gate: añadir `ALTER ROLE service_role BYPASSRLS` y `MSYS_NO_PATHCONV=1` en Git Bash.
Gate `LRV2-014`: verification/security/quality PASS, PG17 apply/reapply 0029 + 6 fixtures + aditividad weekly_lead_report vs DB legacy + dedupe/ack + privilegios runtime PASS, fixes P0 WF17 Build HTML (TDZ + style-attribute splice, con test que ejecuta el jsCode en Node) y P1 vista operativa dashboard, pytest 88 passed + npm build OK, 2026-08-13; `production_changes_authorized=false`.
Gate `LRV2-015` (pre-producción): verification/security/quality PASS, suite completa 193 passed, JSON 55/55, PG17 release-candidate PASS, baseline 25/25 íntegro, n8n_control con diff/import-inactivo/rollback offline-testeado (settings whitelist P1 corregido), rollback 0033 documentado (rojo corregido), runbook con checklist de 11 autorizaciones, 2026-08-13; `production_changes_authorized=false`; estado `ready-for-production` hasta aprobación humana.

Predeploy: regenerar `n8n-export/WF6_-_Guard_Schedule_Sync__Supabase__.json` desde `whatsapp-agent/workflows/WF6_guard_schedule.json`; no activar ni importar.
Scope LRV2-005: exports WF7/WF10 sincronizados con sus fuentes; no activar ni importar.
Recovery LRV2-007: WF10 requiere credencial nativa `headerAuth`; mantener placeholder de credencial hasta configuración controlada, sin secreto hardcoded ni activación/importación.
Scope LRV2-008: nuevos WF22/WF23, autenticación/env y migración `0030` documentados; ningún workflow importado/activado ni migración aplicada en producción.

## Contrato para cada worker

1. Leer este índice, el ticket asignado y sus fuentes citadas.
2. Confirmar dependencias terminadas en sus handoffs.
3. Trabajar solo en `Archivos permitidos`. Si otro archivo es indispensable, parar y pedir ampliación.
4. Empezar con una prueba roja cuando el ticket cambia lógica.
5. Hacer el cambio mínimo. Reutilizar helpers existentes.
6. Ejecutar verificaciones del ticket y las pruebas vecinas afectadas.
7. No desplegar, activar workflows, aplicar migraciones remotas ni usar credenciales reales.
8. Entregar handoff con: diff, comandos/resultados, supuestos, riesgos, rollback y siguiente ticket desbloqueado.

## Política de modelos y supervisión

- `budget`: modelo de bajo costo; ejecución acotada, mecánica o repetitiva.
- `budget+review`: modelo de bajo costo implementa; supervisor revisa contrato, concurrencia o migración.
- `supervisor`: requiere decisión de negocio, revisión arquitectónica o autorización operativa.
- Escalar al supervisor tras dos intentos fallidos, una migración destructiva, una carrera no reproducible o una ambigüedad que cambie asignación/SLA.

## DAG y oleadas

```text
Oleada 0:  LRV2-001
              |
Oleada 1:  LRV2-002
              |
Oleada 2:  LRV2-003  |  LRV2-004
              |
Oleada 3:  LRV2-005
              |
Oleada 4:  LRV2-006
              |
Oleada 5:  LRV2-007  |  LRV2-011
              |
Oleada 6:  LRV2-008
              |
Oleada 7:  LRV2-009
              |
Oleada 8:  LRV2-010  |  LRV2-012
              |
Oleada 9:  LRV2-013
              |
Oleada 10: LRV2-014
              |
Oleada 11: LRV2-015
```

`LRV2-003` y `LRV2-004` pueden ejecutarse en paralelo después de `LRV2-002`. `LRV2-007` y `LRV2-011` pueden ejecutarse en paralelo después de `LRV2-006`; `LRV2-010` y `LRV2-012`, después de `LRV2-009` y las dependencias adicionales de cada uno. `LRV2-013` espera `LRV2-010`, `LRV2-011` y `LRV2-012`.

## Índice

| ID | Resultado | Modelo | Depende de | Estado |
|---|---|---|---|---|
| [LRV2-001](LRV2-001-freeze-contract.md) | Decisiones abiertas cerradas + baseline productivo congelado | supervisor | ninguna | done |
| [LRV2-002](LRV2-002-schema-contract-tests.md) | Drift documentado + pruebas de contrato rojas | budget+review | 001 | done |
| [LRV2-003](LRV2-003-routing-state-migration.md) | Estado, eventos e identidad durable | budget+review | 002 | done |
| [LRV2-004](LRV2-004-guard-slots.md) | Guardia primaria/respaldo en DB y UI | budget+review | 002 | done |
| [LRV2-005](LRV2-005-night-window.md) | 20:00-08:00 + drenado 08:05 idempotente | budget | 003 | done |
| [LRV2-006](LRV2-006-canonical-opportunity.md) | Upsert persona+propiedad en intake | budget+review | 003,005 | done |
| [LRV2-007](LRV2-007-owner-resolution.md) | Código EB + primer tag estricto | budget | 006 | done |
| [LRV2-008](LRV2-008-delivered-offer.md) | Botón y SLA 5 min desde entrega | budget+review | 007 | done |
| [LRV2-009](LRV2-009-atomic-claim.md) | Claim transaccional y tardíos inocuos | budget+review | 008 | done |
| [LRV2-010](LRV2-010-tier-escalation.md) | Ejecutivo, primaria, respaldo | budget+review | 004,009 | done |
| [LRV2-011](LRV2-011-i24-contacted.md) | Inmuebles24 Contactado con evidencia | budget | 006 | done |
| [LRV2-012](LRV2-012-easybroker-exact-close.md) | Nota + Atendida en conversación exacta | budget | 009 | done |
| [LRV2-013](LRV2-013-safe-mode.md) | Circuit breaker y guardia directa | budget+review | 010,011,012 | done |
| [LRV2-014](LRV2-014-observability.md) | Eventos, KPIs, dashboard y correo | budget | 013 | done |
| [LRV2-015](LRV2-015-shadow-canary-rollout.md) | Shadow, canary, rollback y gates | supervisor | 014 | ready-for-production |

## Gate de cierre por ticket

- `implemented`: diff mínimo terminado.
- `verified`: todos los comandos requeridos pasan o la limitación queda reproducible.
- `reviewed`: revisión del perfil indicado completada.
- `handoff`: evidencia guardada en la sección final del ticket o archivo `LRV2-XXX-HANDOFF.md`.
- Solo entonces cambiar estado a `done` y desbloquear dependientes.
