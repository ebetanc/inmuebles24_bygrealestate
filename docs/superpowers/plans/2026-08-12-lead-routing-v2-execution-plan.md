# Plan de implementación: flujo de atención de leads v2

**Fecha:** 12 de agosto de 2026  
**Estado:** convertido a tickets; implementación no iniciada  
**Objetivo:** alinear el sistema productivo con el flujo aprobado: una oportunidad por persona y propiedad, primera opción para el ejecutivo de la propiedad, aceptación atómica, escalamiento secuencial a guardia primaria y respaldo, operación nocturna silenciosa y trazabilidad completa.

**Paquete ejecutable:** `docs/superpowers/tickets/2026-08-12-lead-routing-v2/README.md`

## 1. Contrato de negocio bloqueado

Estas reglas son la fuente de verdad. Ningún ticket puede reinterpretarlas:

1. El scraper revisa **Mensajes, Teléfono y WhatsApp cada 15 minutos**.
2. La misma persona interesada en la misma propiedad produce una sola oportunidad. La misma persona interesada en otra propiedad produce otra oportunidad.
3. Entre **20:00 y 08:00** se captura sin enviar mensajes. A las **08:05** inicia la atención de lo acumulado.
4. La propiedad se resuelve por su **código EB** y el **primer tag** de EasyBroker define al ejecutivo responsable.
5. El ejecutivo recibe WhatsApp con el botón **Tomar prospecto**.
6. Su ventana es de **5 minutos contados desde la entrega confirmada**, no desde la creación interna del lead.
7. Al iniciar el proceso, Inmuebles24 cambia a **Contactado**.
8. La primera aceptación válida gana. Toda aceptación posterior queda rechazada y nunca cambia al responsable.
9. Si vence la ventana del ejecutivo, la oportunidad pasa a la **guardia primaria**. Si esta falla, pasa a la **guardia de respaldo**.
10. La asignación final se anota en la conversación exacta de EasyBroker y se marca **Atendida**.
11. Se registran detección, entrega, aceptación, escalamiento, asignación y tiempo total.
12. Habrá revisión diaria durante 7 días y evaluación formal a los 14 días o 100 oportunidades, lo que ocurra primero.
13. Ante una falla crítica se conserva la captura y los casos nuevos se envían directo a guardia. Dashboard y correo alertan cualquier caso sin asignar.

Fuente de sesión: `tmp/client-one-slide/build.mjs:91-114` y `tmp/client-one-slide/build_pdf.py:84-103`.

## 2. Diferencias verificadas contra el sistema actual

La referencia de producción no son los JSON históricos del repositorio. Los backups tomados el 12 de agosto muestran que el intake activo llama directo a WF19 y que WF19 selecciona una sola guardia, la asigna inmediatamente y no ofrece primero el caso al ejecutivo de la propiedad. Los artefactos owner-first `WF3a`, `WF3b`, `WF3c`, `WF12` y `WF13` existen localmente, pero aparecen inactivos en ese snapshot. Por eso se reutilizan como patrones probados, no se asume que ya formen el flujo productivo.

| Área | Ya existe | Diferencia que debe corregirse |
|---|---|---|
| Owner-first | Hay artefactos reutilizables en `0011_owner_routing.sql`, `0018_owner_first_routing.sql`, `WF12`, `WF13` | Producción activa omite al ejecutivo; al reactivar el patrón, `WF13` debe pasar de 2 a 5 minutos desde entrega confirmada |
| Aceptación | `WF3b_claim_handler.json` usa `UPDATE ... WHERE status='open' AND expires_at > NOW()` | Debe validar además destinatario/tier vigente y nunca permitir reasignación tardía |
| Escalamiento | WF19 activo elige una sola guardia y asigna de inmediato; `WF3c_expiry_sweeper.json` histórico mueve owner a subasta y luego manager | Debe ser secuencial: ejecutivo, guardia primaria, guardia de respaldo; sin asignación anticipada ni fan-out competitivo |
| Nocturno | `night_queue`, WF7 y ramas night de WF8 | `is_daytime()` aún usa 08:00-21:00; debe fijarse 20:00-08:00 y despacho 08:05 con orden e idempotencia |
| Dedupe | `WF8_easybroker_polling.json` distingue returning_same y propiedad distinta | Debe compartir una identidad canónica entre las tres bandejas y evitar crear dos oportunidades por carreras |
| Inmuebles24 | `mark_lead_contacted()` en `src/inmobiliaria24/scraper.py` | El cambio a Contactado debe quedar ligado al inicio de procesamiento, con reintento y evidencia |
| EasyBroker | `src/easybroker/inbox.py` puede marcar Atendida y agregar nota | Debe usar el identificador de la conversación exacta y guardar confirmación independiente de ambos pasos |
| Observabilidad | `weekly_lead_report()` y dashboard existente | Faltan eventos de entrega confirmada, escalamiento por tier, late claim, modo seguro y lead sin asignar |
| Calendario | UI actual conserva una sola persona por turno | Debe modelar guardia primaria y respaldo sin inferir la segunda por orden alfabético o `agent_id` |

## 3. Estrategia de ejecución con skills y modelos

### Secuencia Matt Pocock

1. `setup-matt-pocock-skills`: verificar disponibilidad del plugin en el runner que ejecutará los tickets.
2. `grill-with-docs`: validar únicamente las decisiones todavía abiertas y actualizar contexto, sin reabrir las reglas bloqueadas.
3. `to-spec`: convertir este documento y el HTML de escenarios en especificación versionada.
4. `to-tickets`: crear tickets tracer-bullet con dependencias explícitas y un criterio de aceptación observable por ticket.
5. `wayfinder`: ordenar tickets para mantener un flujo vertical funcional tras cada lote.
6. `prototype`: probar primero el contrato de estados, el reloj basado en entrega y el claim atómico.
7. `implement` + `tdd`: ejecutar cada ticket en un contexto aislado, con prueba roja, cambio mínimo y prueba verde.
8. `code-review`: gate obligatorio al cerrar cada fase, usando ejes de especificación, concurrencia, seguridad e idempotencia.
9. `diagnosing-bugs`: usar solo cuando una prueba o señal productiva no explique la causa.
10. `handoff`: cerrar cada fase con estado, evidencia, riesgos y próximo ticket.

### Política de costo y supervisión

- Modelos de bajo costo ejecutan descubrimiento acotado, cambios mecánicos de JSON/SQL, pruebas unitarias, documentación y ajustes repetitivos.
- El supervisor principal conserva: decisiones de arquitectura, estado de la especificación, reparto de tickets, revisión de diffs, gates de concurrencia, verificación E2E y autorización de despliegue.
- Un modelo más capaz se usa solo si ocurre una de estas condiciones: ambigüedad que cambia negocio, carrera no reproducible, migración destructiva, fallo cruzado entre tres sistemas o dos intentos fallidos del worker.
- Ningún worker despliega, activa workflows, aplica migraciones productivas ni modifica credenciales sin gate del supervisor.
- Cada worker entrega: fuentes, diff, pruebas, supuestos, deuda conocida y rollback.

## 4. Fase 0: documentación y contrato ejecutable

### Qué implementar

- Copiar el contrato de negocio de la sección 1 a una especificación de estados y eventos.
- Inventariar los workflows productivos por ID y hash, no solo por nombre de archivo.
- Confirmar las firmas reales de DB y consumidores antes de crear la siguiente migración.
- Convertir cada escenario del HTML detallado en un ID estable `S-XX` usado por pruebas y telemetría.

### APIs y patrones permitidos

- Claim atómico: copiar el predicado de `whatsapp-agent/workflows/WF3b_claim_handler.json:21-27`.
- Parsing interactivo: reutilizar extracción de respuestas button/list/template de `whatsapp-agent/workflows/WF1_inbound_router.json:24`, agregando un ID estable para **Tomar prospecto**; el regex `TOMO-XXXX` de la línea 92 queda solo como compatibilidad.
- Resolver de responsable: copiar `resolve_agent_from_tags(text[])` de `whatsapp-agent/migrations/0011_owner_routing.sql:62-72`, conservando ordinalidad del primer tag.
- Asignación: reutilizar `mark_assigned(UUID, TEXT, TEXT)` de `whatsapp-agent/migrations/0010_crm_helpers.sql:24-64` después de ampliar valores permitidos de forma documentada.
- Cola nocturna: copiar tabla e índice parcial de `whatsapp-agent/migrations/0005_v5_24h_system.sql:134-161`.
- Estado Inmuebles24: reutilizar `mark_lead_contacted()` de `src/inmobiliaria24/scraper.py:863`.
- Cierre EasyBroker: reutilizar `process_lead()` de `src/easybroker/inbox.py:279`.

### Verificación

- Existe matriz escenario, estado inicial, evento, estado final y evidencia.
- Cada workflow local se mapea al ID productivo del manifiesto.
- Toda API mencionada existe en archivo o DB inspeccionada.

### Anti-patrones

- No planear desde exports obsoletos llamados `live_*`.
- No asumir que nombre local equivale a versión activa.
- No inventar nodos n8n, columnas, RPC ni parámetros.

## 5. Fase 1: modelo de estados, eventos e idempotencia

### Qué implementar

Crear migración aditiva `0021_lead_routing_v2.sql` con el mínimo estado faltante:

- Identidad canónica de oportunidad por `persona_normalizada + property_public_id`.
- Tier vigente: `owner`, `primary_guard`, `backup_guard`, `assigned`, `safe_mode`.
- Timestamps separados: detectado, entrega solicitada, entrega confirmada, vencimiento, aceptación, asignación y finalización externa.
- Evidencia de entrega con ID externo del proveedor.
- Guardias primaria y respaldo resueltas para la fecha/turno.
- Eventos append-only para auditoría, evitando usar logs de n8n como fuente de verdad.
- Restricción o índice que impida dos oportunidades activas para la misma persona y propiedad.

La migración debe ser aditiva, idempotente y compatible con filas existentes. Backfill solo de campos derivables; lo desconocido permanece `NULL`.

### Verificación

- Pruebas SQL: misma persona+propiedad converge en una fila; otra propiedad crea otra fila.
- Dos inserciones concurrentes no generan dos oportunidades activas.
- Una conversación existente puede migrar sin pérdida.
- Rollback ensayado sobre copia o entorno preview.

### Anti-patrones

- No deduplicar solo por teléfono.
- No iniciar SLA con `created_at` o `tier_notified_at` si no existe entrega confirmada.
- No sobrecargar `auctions.status` para representar todos los estados externos.
- No eliminar columnas ni constraints existentes en esta fase.

## 6. Fase 2: tracer bullet de punta a punta

### Qué implementar

Construir un recorrido mínimo en entorno de prueba:

1. Inyectar un lead sintético con persona y código EB conocidos.
2. Resolver el primer tag a ejecutivo.
3. Crear una notificación dirigida de prueba.
4. Registrar entrega confirmada y calcular vencimiento a +5 minutos.
5. Aceptar con operación atómica.
6. Persistir responsable final.
7. Simular nota y estado EasyBroker sin escribir producción.

El objetivo es probar contratos y seams, no diseñar mensajes finales ni completar todos los fallbacks.

### Verificación

- Un comando o fixture reproduce el recorrido.
- El reloj empieza con `delivered_at`.
- Dos claims simultáneos producen un ganador.
- El segundo recibe resultado `already_assigned` sin mutar responsable.

### Anti-patrones

- No probar concurrencia con llamadas secuenciales.
- No usar `sleep(300)`; controlar reloj o timestamps del fixture.
- No escribir en Inmuebles24/EasyBroker reales durante prototype.

## 7. Fase 3: intake, dedupe y ventana nocturna

### Qué implementar

- Reutilizar el scraper actual para leer las tres bandejas cada 15 minutos.
- Normalizar identidad de persona con prioridad a IDs externos; teléfono/email son señales de respaldo.
- Resolver el código EB antes de crear la oportunidad definitiva.
- Hacer el upsert idempotente en DB antes de disparar n8n.
- Fijar zona horaria de negocio en un único helper compartido.
- Entre 20:00 y 08:00 crear/actualizar oportunidad y cola, sin WhatsApp.
- A las 08:05 drenar la cola con orden estable, límite de lote, retry y marca idempotente.
- Cambiar Inmuebles24 a Contactado al iniciar procesamiento; registrar éxito o error sin perder captura.

### Verificación

- Pruebas en límites: 19:59:59, 20:00:00, 07:59:59, 08:00:00 y 08:05:00.
- Reprocesar el mismo payload no duplica oportunidad ni notificación.
- La misma persona con dos códigos EB crea dos oportunidades.
- Un fallo al marcar Contactado conserva la oportunidad y genera retry/alerta.

### Anti-patrones

- No tener reglas horarias distintas en Python, SQL y n8n.
- No marcar la cola como procesada antes de crear el siguiente evento durable.
- No descartar una captura porque falte código EB; enrutar a contingencia con razón explícita.

## 8. Fase 4: resolución de ejecutivo y notificación dirigida

### Qué implementar

- Reutilizar WF12/tabla `eb_property_owner` para localizar propiedad por código EB.
- Aplicar literalmente el primer tag, manteniendo orden original.
- Resolver alias a agente activo con WhatsApp válido.
- Si código, propiedad, tag, alias o teléfono faltan, entrar a fallback documentado y alertar.
- Modificar WF13 para mensaje interactivo **Tomar prospecto**.
- Registrar `delivery_requested_at`, ID de mensaje y `delivered_at` confirmado por webhook/estado del proveedor.
- Crear el vencimiento a `delivered_at + 5 minutos`.

### Verificación

- Primer tag conocido resuelve al ejecutivo correcto.
- Segundo tag nunca sustituye al primero silenciosamente.
- Entrega fallida no consume los 5 minutos y dispara retry/fallback.
- Reintento con mismo idempotency key no crea dos ventanas.

### Anti-patrones

- No mantener el timeout de 2 minutos de WF13.
- No iniciar timer cuando n8n construye el payload.
- No inferir responsable desde el detalle de EB si la fuente aprobada es primer tag.

## 9. Fase 5: aceptación atómica y bloqueo de respuestas tardías

### Qué implementar

- Encapsular el claim en una sola operación DB/RPC con condiciones: oportunidad abierta, tier vigente, agente autorizado, entrega confirmada, antes del vencimiento y sin responsable final.
- Cerrar/invalidar cualquier intento abierto anterior al cambiar de tier.
- Persistir ganador y asignación en la misma transacción.
- Responder de forma determinística: `accepted`, `already_assigned`, `expired`, `not_authorized`, `delivery_pending`.
- Mantener historial del intento tardío como evento, sin mutar asignación.

### Verificación

- Prueba concurrente con al menos dos conexiones.
- Claim exactamente en el límite usa una regla inclusiva/exclusiva documentada.
- Respuesta del ejecutivo después de pasar a guardia no reasigna.
- Retry del ganador devuelve resultado idempotente.

### Anti-patrones

- No separar claim y asignación en dos nodos sin transacción.
- No confiar en orden de llegada de n8n.
- No permitir que un botón viejo opere sobre tier nuevo.

## 10. Fase 6: guardia primaria, respaldo y modo seguro

### Qué implementar

- Sustituir el fan-out de WF3c/WF3a por resolución secuencial de guardia primaria.
- Definir la condición exacta de “falla” de guardia con configuración, no con una constante duplicada.
- Al fallar primaria, invalidar su ventana y notificar solo a respaldo.
- Si no existe guardia válida, entrar a modo seguro y alertar.
- Cuando salud de scraper/n8n/Supabase/proveedor cruce el umbral crítico, conservar intake y enrutar nuevos casos directo a guardia.
- Mantener un mecanismo manual documentado para salir de modo seguro.

### Pendientes que requieren confirmación antes del ticket final

- Duración de la ventana de guardia primaria.
- Duración de la ventana de respaldo.
- Responsable final si también falla respaldo.
- Fuente exacta de guardia primaria/respaldo cuando el calendario tiene datos incompletos.

### Verificación

- Ejecutivo vence, solo primaria recibe el caso.
- Primaria falla, solo respaldo recibe el caso.
- Claim tardío de cualquier tier anterior no modifica responsable.
- Modo seguro no pierde intake y deja alerta visible.

### Anti-patrones

- No volver a subasta grupal por reutilizar WF3a sin adaptación.
- No autoasignar manager si no está en el contrato aprobado.
- No ocultar fallback bajo un nombre de estado genérico.

## 11. Fase 7: finalización en EasyBroker e Inmuebles24

### Qué implementar

- Usar el identificador persistido de la conversación exacta de EasyBroker.
- Reemplazar el lookup actual por teléfono en `src/easybroker/inbox.py:276-291` por navegación/correlación mediante `eb_contact_id`; teléfono queda solo como fallback explícito y auditable.
- Escribir nota con responsable final y evidencia de asignación.
- Marcar Atendida como operación separada pero idempotente.
- Guardar confirmación de nota y estado; reintentar solo el paso faltante.
- Mantener Contactado en Inmuebles24 con la misma disciplina de evidencia.

### Verificación

- La conversación correcta recibe nota y Atendida.
- Reejecución no duplica nota.
- Si nota funciona y estado falla, retry solo cambia estado.
- Si portal no está disponible, asignación interna permanece válida y visible.

### Anti-patrones

- No buscar conversación por texto visible cuando existe ID externo.
- No considerar completado porque el click fue enviado; verificar estado resultante.
- No bloquear la asignación interna por indisponibilidad del portal.

## 12. Fase 8: observabilidad, dashboard y alertas

### Qué implementar

- Eventos mínimos: detected, deduplicated, queued_night, processing_started, delivery_requested, delivered, delivery_failed, accepted, claim_rejected, escalated, assigned, i24_contacted, eb_noted, eb_attended, safe_mode_entered, unassigned_alerted.
- KPIs: tiempo detección, tiempo a entrega, tiempo a aceptación, tiempo total, tasa de aceptación por tier, escalamiento, late claims, fallos por integración y casos sin asignar.
- Vista operativa con estado actual, responsable, SLA restante y última evidencia.
- Correo inmediato para casos sin asignar y resumen diario durante piloto.
- Extender `weekly_lead_report()` de forma aditiva, conservando claves existentes.

### Verificación

- Cada escenario S-XX deja los eventos esperados.
- Dashboard deriva estado desde DB, no desde memoria del workflow.
- Una alerta tiene dedupe y acknowledge.
- Métricas no mezclan `created_at`, `delivered_at` y `assigned_at`.

### Anti-patrones

- No calcular KPIs desde logs efímeros de n8n.
- No añadir claves rompedoras a consumidores existentes.
- No enviar correos repetidos por el mismo incidente.

## 13. Fase 9: pruebas completas y rollout

### Suite mínima

- Unitarias: normalización, identidad de oportunidad, horario, primer tag, resolución de guardias.
- DB: concurrencia, uniqueness, transición de tiers, idempotencia y late claim.
- Contrato: payloads scraper/n8n/Supabase/EasyBroker.
- Integración: happy path, duplicado, nocturno, entrega fallida, timeout owner, timeout primaria, claim simultáneo, claim tardío, portal caído y modo seguro.
- E2E controlado: una oportunidad real autorizada por canal, con evidencia antes/después.

### Rollout

1. Shadow mode sin notificaciones: comparar decisiones nuevas contra flujo actual.
2. Piloto con propiedad/agente controlados.
3. Activación gradual por fuente.
4. Revisión diaria 7 días.
5. Gate formal a los 14 días o 100 oportunidades.

### Criterios de salida

- Cero doble asignación.
- Cero oportunidad capturada sin estado terminal o alerta activa.
- 100% de asignaciones con evidencia de responsable y timestamps.
- Late claims nunca reasignan.
- Rollback probado y documentado.

## 14. Gates de supervisión

| Gate | Evidencia requerida | Autoriza |
|---|---|---|
| G0 Contrato | spec, escenarios, APIs permitidas, pendientes explícitos | crear tickets |
| G1 Datos | migración, pruebas SQL, rollback | prototype |
| G2 Concurrencia | prueba simultánea y reloj por entrega | integrar workflows |
| G3 Integraciones | contratos y retries por sistema | E2E |
| G4 Operación | dashboard, alertas, modo seguro | shadow mode |
| G5 Piloto | métricas y revisión de casos | rollout gradual |
| G6 Producción | diff final, backups, rollback, aprobación del usuario | activar |

## 15. Decisiones todavía abiertas

No bloquean la escritura del plan, pero sí los tickets afectados:

1. SLA exacto de guardia primaria y respaldo.
2. Destino final si falla respaldo.
3. Regla operacional cuando no existe primer tag o no resuelve a agente activo.
4. Fuente autoritativa y formato del calendario primaria/respaldo.
5. Señales y umbrales exactos para entrar/salir de modo seguro.
6. Proveedor y webhook confiable para confirmar entrega de WhatsApp.
7. Identidad canónica cuando no hay teléfono ni ID estable del portal.
8. Si “primer tag” significa estrictamente `tags[0]` o el primer tag que tenga alias; el resolver actual aplica la segunda semántica.
9. Si el alcance de las mismas reglas incluye leads originados directamente en EasyBroker además de las tres bandejas de Inmuebles24.

## 16. Definición de terminado

El flujo se considera implementado cuando los escenarios del HTML pasan en test, el recorrido real autorizado conserva evidencia en ambos portales, el dashboard muestra cada transición, el correo alerta cualquier caso sin asignar, el rollback fue ensayado y el gate G6 tiene aprobación explícita.
