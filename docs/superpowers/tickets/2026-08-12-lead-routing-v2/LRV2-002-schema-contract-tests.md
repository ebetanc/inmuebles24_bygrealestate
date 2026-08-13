# LRV2-002: drift de esquema y pruebas de contrato

**Perfil:** budget+review | **Dependencias:** LRV2-001 | **Estado:** completed

**Gate:** verification/security/quality PASS, 2026-08-12; `production_changes_authorized=false`.

## Resultado

Capturar schema real de forma sanitizada y dejar pruebas rojas para identidad, horario, tiers, entrega y claim.

## Archivos permitidos

- Crear `whatsapp-agent/scripts/03_capture_routing_v2_baseline.sql`
- Crear `tests/test_routing_v2_contract.py`
- Crear `tests/fixtures/routing_v2/README.md`
- Modificar `whatsapp-agent/scripts/02_verify_production.sql` solo con checks aditivos.

## Pasos

1. Copiar patrones de inspección de `02_verify_production.sql`; consultar columnas, constraints, funciones e índices sin datos personales.
2. Incluir drift conocido: índice `conversations_i24_lead_id_uniq`, firmas de `is_daytime`, `get_on_shift_agents`, `mark_assigned` y `resolve_agent_from_tags`.
3. Escribir pruebas contractuales marcadas por escenarios S-01 a S-12, alcance inmediato: 20:00, 08:00, 08:05, misma persona/propiedad, otra propiedad, primer tag, entrega, claim simultáneo/tardío y tiers. S-13 y S-14 quedan mapeados explícitamente a `LRV2-013`; no se implementan ni se declaran verdes en este ticket.
4. Las pruebas deben fallar por comportamiento faltante, no por imports inexistentes.

## Verificación

- `uv run pytest tests/test_routing_v2_contract.py -q` produce fallos esperados documentados.
- SQL es read-only: no contiene `INSERT|UPDATE|DELETE|ALTER|DROP` fuera de comentarios.
- Supervisor confirma que cada fallo corresponde al contrato.

## Handoff

Handoff lista schema real, drift repo/prod y mapa prueba -> ticket que la volverá verde, incluidos S-13/S-14 -> `LRV2-013`. Desbloquea `LRV2-003` y `LRV2-004`.
