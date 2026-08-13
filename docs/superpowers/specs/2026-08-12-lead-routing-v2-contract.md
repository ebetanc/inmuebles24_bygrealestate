# Contrato operativo: Lead Routing v2

**Estado:** confirmado por autorizacion de ejecucion de LRV2-001, 2026-08-12.  
**Alcance:** contrato de negocio para tickets LRV2-002 a LRV2-015. No autoriza activar workflows, aplicar migraciones ni desplegar.

**Firma del gate documental:** `.planning/lead-routing-v2-production-baseline.json > supervisor_approval`, aprobada por `codex_supervisor` el 2026-08-12 solo para contrato y baseline. `production_changes_authorized=false`.

## Fuentes reproducibles

Todas las rutas son relativas a la raiz del repositorio `Inmobiliaria24`:

- Manifiesto: `n8n-workflow-manifest.json`.
- Snapshots: `wf_*_backup_20260812T083420Z.json`, ubicados en la raiz del repositorio.
- Plan: `docs/superpowers/plans/2026-08-12-lead-routing-v2-execution-plan.md`.
- Flujo visual: `docs/cliente/flujo-atencion-leads-detallado.html`.
- Baseline firmado: `.planning/lead-routing-v2-production-baseline.json`.

Los SHA-256 del baseline se calculan sobre el contenido binario de cada snapshot fuente, sin normalizar saltos de linea ni serializar de nuevo el JSON.

## Decisiones bloqueadas

| Tema | Decision confirmada |
|---|---|
| Fuentes incluidas | Las tres bandejas de Inmuebles24 y leads directos de EasyBroker. WhatsApp directo queda fuera de este flujo v2, salvo intake ya existente. |
| Ventana nocturna | Capturar sin mensajes entre 20:00 y 08:00; iniciar atencion a las 08:05. |
| Oportunidad | Una oportunidad activa por persona y propiedad. Propiedad distinta siempre crea otra. Se unen duplicados mientras la oportunidad no este `closed_won` ni `closed_lost`. |
| Identidad | Prioridad: `portal_person_id`; si falta, email normalizado; si falta, telefono E.164. Sin ninguna senal se crea caso manual no deduplicable. |
| Responsable de propiedad | Resolver por codigo EB; usar literalmente `tags[0]`. No buscar un tag posterior resoluble. |
| Fallback de resolucion | Si falta codigo, tag, alias o telefono, enviar directo a guardia primaria; si no existe, a respaldo; despues alertar. No inferir responsable. |
| SLA ejecutivo | 5 minutos desde webhook del proveedor con `status=delivered`. Ningun intento de envio inicia reloj. |
| SLA guardia primaria | 5 minutos desde entrega confirmada. |
| SLA guardia respaldo | 5 minutos desde entrega confirmada. |
| Falla de guardia | Entrega fallida o ausencia de aceptacion dentro de sus 5 minutos. |
| Despues de respaldo | Queda sin asignar y dispara alerta inmediata. No se asigna manager ni se reasigna automaticamente. |
| Claim | Primera aceptacion valida gana; intentos tardios o de tier anterior se registran sin mutar responsable. |
| Cierre externo | Anotar responsable final y marcar `Atendida` en conversacion exacta de EasyBroker; pasos separados, idempotentes y con evidencia propia. |
| Inmuebles24 | Al iniciar procesamiento, marcar `Contactado`; error conserva oportunidad y genera retry/alerta. |
| Modo seguro | Tras 2 fallos consecutivos de routing en 5 minutos, owner operativo es manager. Casos nuevos van directo a guardia. Salida solo manual tras health check verde. |

## Estados y evidencia

`captured` -> `deduplicated` o `resolved` -> `delivery_requested` -> `delivered` -> `owner_open` -> `primary_guard_open` -> `backup_guard_open` -> `assigned` o `unassigned_alerted`.

Estados complementarios: `queued_night`, `manual_non_deduplicable`, `safe_mode`, `closed_won`, `closed_lost`.

Cada transicion registra evento append-only, oportunidad, tier, actor, timestamp y evidencia externa cuando exista. `delivered_at` es unica base de reloj SLA. `assigned` es inmutable frente a claims posteriores.

## Matriz de escenarios

| ID | Entrada / evento | Resultado requerido | Evidencia minima |
|---|---|---|---|
| S-01 | Persona, propiedad, codigo EB y `tags[0]` valido | Oferta dirigida a ejecutivo; 5 min desde entrega | detectado, entregado, vencimiento, claim/asignacion |
| S-02 | Misma persona y propiedad activa | Una sola oportunidad; no reinicia oferta | identidad, evento `deduplicated` |
| S-03 | Misma persona, otra propiedad | Nueva oportunidad | identidad comun, propiedad distinta |
| S-04 | Captura 20:00-08:00 | Cola silenciosa; activacion 08:05 | captura, cola, activacion |
| S-05 | Vence ejecutivo | Solo primaria recibe oferta | vencimiento owner, entrega primaria |
| S-06 | Falla primaria | Solo respaldo recibe oferta | causa, entrega respaldo |
| S-07 | Falla respaldo | Sin asignar y alerta inmediata | causa, alerta, oportunidad preservada |
| S-08 | Dos claims validos concurrentes | Un ganador; otro rechazo inocuo | resultado atomico de ambos |
| S-09 | Claim tardio | No cambia responsable | evento de rechazo tardio |
| S-10 | Falla de entrega | No inicia SLA; captura preservada | fallo proveedor, retry/fallback |
| S-11 | Sin codigo/tag/alias/telefono | Guardia primaria, luego respaldo y alerta | razon de fallback, evidencia entrega |
| S-12 | Sin senal de identidad | Caso manual no deduplicable | razon, identificador de caso |
| S-13 | Dos fallos routing en 5 min | `safe_mode`; owner operativo manager; nueva captura a guardia | fallos, entrada modo seguro, health check |
| S-14 | Recuperacion | Salida manual solo con health check verde; reconciliacion idempotente | autorizacion, health check, eventos reconciliados |

## Limites de integracion

- Portal externo: usar identificador de conversacion exacta de EasyBroker; telefono solo fallback auditable.
- Proveedor WhatsApp: `status=delivered` recibido por webhook es evidencia de entrega.
- No se incluyen URLs, hosts, tokens, API keys, cabeceras de autorizacion ni credenciales en artefactos del ticket.
- Activacion productiva queda bloqueada hasta gate LRV2-015.

## Gaps no decisionales para implementacion

- El contrato fija comportamiento; LRV2-002 debe capturar firmas reales de DB, RPC y payloads antes de migrar.
- Numero de retries de envio y texto de mensajes no son decisiones de asignacion; se definen como parametros tecnicos sin cambiar estas transiciones.
- Snapshot identifica llamadas por ID cuando estan materializadas. Referencias por variables de entorno se conservan como dependencias no resueltas, sin inventar IDs.

## Rollback

Revertir artefactos de tickets posteriores al hash de baseline. No activar ni restaurar workflow desde este contrato. Cualquier rollback productivo requiere runbook de LRV2-015.
