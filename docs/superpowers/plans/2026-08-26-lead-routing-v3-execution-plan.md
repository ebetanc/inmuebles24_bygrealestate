# Plan de implementación: Lead Routing V3

**Estado:** listo para aprobación.  
**Contrato vinculante:** `docs/superpowers/specs/2026-08-26-lead-routing-v3-contract.md`.  
**Fecha:** 26 de agosto de 2026.  
**Autoridad actual:** documentación y planeación solamente. Aprobar este documento no equivale a autorizar escrituras en Supabase, publicación de n8n, alta de templates Meta, mensajes reales, cambios en EasyBroker/Inmuebles24 ni despliegues.

## 1. Resultado que debe entregar V3

V3 debe convertir cada solicitud de Inmuebles24 en un proceso único, dirigido y demostrable:

`captura durable → Contactado en I24 → propietario → guardia → Sandy → nota exacta en EasyBroker → Atendida`

No todos los leads recorren todas las rondas. Las decisiones confirmadas determinan cuándo saltar propietario, cuándo omitir guardia y cuándo conservar un responsable anterior. El sistema debe poder explicar, con IDs y timestamps, por qué tomó cada camino.

La implementación queda terminada sólo cuando una prueba autorizada y luego la observación de producción demuestran los efectos externos completos. Los tests y la validación estructural son necesarios, pero no sustituyen esa evidencia.

## 2. SLA operativo del flujo

Estos tiempos describen la operación de cada lead, no el esfuerzo de programación:

| Paso | Inicio del reloj | Tiempo/regla V3 | Evidencia requerida |
|---|---|---|---|
| Detección I24 | Entrada del lead al portal | El siguiente poll comienza en ≤15 min; se suma el runtime medido hasta llegar a esa bandeja | Bandeja, cuenta, ID externo, inicio/fin del poll y `captured_at`. |
| Captura durable | Lead detectado | Operación inmediata e idempotente | Evento/intake persistido y disposición atómica. |
| Cambio a `Contactado` | Captura confirmada | Inmediato; es gate antes de WhatsApp | Efecto verificado en I24. |
| Cola nocturna | Captura entre 20:00 y 08:00 CDMX | Liberación a las 08:05 | `queued_at`, zona y `released_at`. |
| Resolución del propietario | Lead listo para enrutar | Inmediata; si falta/no coincide, no hay espera de 5 min | ID de propiedad, tag, comparación y resultado. |
| Prueba de entrega Meta | Meta acepta el mensaje | Deadline a los 2 min desde `provider_accepted_at`; el sweeper actúa en su siguiente ciclo | WAMID y estado `delivered`, `read`, `failed` o timeout técnico. |
| Ronda propietario | `delivered` al propietario | Máximo 5 min | `delivered_at`, `expires_at`, clic o expiración. |
| Ronda guardia | `delivered` a la guardia | Máximo 5 min | Guardia vigente, WAMID, `delivered_at`, clic o expiración. |
| Fallback Sandy | Guardia agotada o ruta inválida | Asignación inmediata; aviso posterior no bloqueante | Asignación final y resultado independiente del aviso. |
| Ingestión EasyBroker | Solicitud creada en EasyBroker | Poll cada 5 min, con watermark solapado y dedupe | `contact_request.id`, cuenta y checkpoint cubierto. |
| Correlación EasyBroker | Evento I24 y solicitud EB disponibles | No espera responsable; asíncrona, idempotente y nunca por conjetura | `contact_request.id`, evento exacto, candidato único y base de match. |
| Nota + `Atendida` | Correlación exacta y responsable final | Efecto inmediato; si falla: deadlines +1, +5, +15 y +30 min | Evidencia separada de nota y estado. |
| Alerta final | Ambigüedad o reintentos agotados | Inmediata para ambigüedad; al agotar errores técnicos | Alerta durable y resultado de notificación a Sandy. |

Camino máximo normal después de una entrega demostrada, cuando nadie toma: 5 minutos de propietario + 5 minutos de guardia, más latencias técnicas. Si falta propietario, se elimina su ronda; si falta guardia, Sandy se asigna sin esperar una ronda inexistente.

## 3. Diferencias verificadas entre V2 y V3

| Área | Estado V2 verificado | V3 requerido |
|---|---|---|
| I24 `Contactado` | Se intenta después de la asignación en `src/inmobiliaria24/main.py` y la migración `0032` exige asignado | Ejecutarlo y verificarlo después de captura durable, antes de cualquier oferta. |
| Nota I24 | Existe ruta de nota en `src/inmobiliaria24/main.py` | Retirarla del flujo V3; no escribir nota en I24. |
| Escalera | Propietario, guardia primaria, respaldo y no asignado | Propietario, una guardia y Sandy. |
| Sandy | El cierre actual puede depender del acuse del aviso | Asignar primero; el aviso es informativo y no bloquea. |
| Template Meta | WF13 construye `button_id`, pero envía sólo parámetros de cuerpo | Nuevo template aprobado y componente `quick_reply` con payload por intento. |
| Claims | WF1 acepta botones y códigos escritos V2 | V3 acepta sólo botón autenticado para intentos V3; legado limitado al drenaje. |
| Datos WhatsApp | Faltan operación, zona y URL EasyBroker en el contrato de datos | Preservar y mostrar los ocho campos acordados. |
| Tag de propiedad | Hay resolución por alias/manager | Un único nombre; igualdad sin distinguir mayúsculas y recortando extremos. |
| Dedupe | Hay base por oportunidad, pero no disposición V3 completa | Una decisión atómica: nueva, duplicado activo, recurrente asignado o no enrutable. |
| EasyBroker | La columna legada `conversations.eb_contact_id` guarda un request ID pese a su nombre; el worker sólo registra `Linked 0` | Separar `eb_request_id = contact_request.id` de `eb_person_contact_id = contact_id`, con candidatos y motivos auditables. |
| Fetch EasyBroker | Ventana de 48 h y máximo 500 registros, sin checkpoint durable | Inbox request-level con watermark/checkpoint interno, solapamiento y dedupe por request. |
| Reintentos EB | No hay límite final de negocio claro | Reintentos finitos del efecto faltante y alerta durable. |
| Éxito | Una parte técnica puede parecer verde sin efectos finales | Éxito sólo con Contactado + responsable + WhatsApp + nota + Atendida. |

Antecedente medible: 17/17 quedaron sin vínculo. Tres no tenían responsable final. Cinco no tenían `property_public_id`; dos de esos cinco estaban dentro de los tres no-finales. Entre los 14 asignados, tres carecían de propiedad y 11 sí la tenían, pero el motivo de no-match no quedó registrado porque el worker sólo conserva `Linked 0`. V3 debe corregir tanto el modelo como la observabilidad antes de volver a declarar éxito.

## 4. Principios de implementación

### 4.1 Módulos profundos y orquestadores delgados

La lógica de competencia, idempotencia y correlación vive en operaciones transaccionales de base de datos. n8n coordina, no decide carreras con nodos `IF` separados. Python adapta los portales y confirma efectos; no duplica la máquina de estados.

Fronteras propuestas:

| Módulo | Responsabilidad única |
|---|---|
| Intake V3 | Normalizar identidad, persistir captura y devolver una disposición atómica. |
| I24 effects | Cambiar/verificar `Contactado`, con lease e idempotencia. |
| Routing V3 | Resolver ronda vigente, expiración, fallback y responsable final. |
| Delivery attempts | Vincular destinatario, ronda, WAMID, callbacks y expiración. |
| Meta callback inbox | Verificar firma, persistir antes del HTTP 200 y procesar replays una sola vez. |
| Claim V3 | Validar sender+intento+WAMID y decidir al primer ganador atómicamente. |
| EasyBroker inbox | Descargar cada `contact_request` con watermark/checkpoint por fuente, solapamiento y dedupe. |
| EasyBroker correlation | Producir candidato único o revisión manual con motivo. |
| EasyBroker effects | Nota y `Atendida` como efectos independientes e idempotentes. |
| Alerts | Mantener incidentes durables y notificar sin borrar evidencia. |

### 4.2 Cambios quirúrgicos

- Reutilizar las invariantes sanas de migraciones `0021`, `0024`, `0026`, `0030` y `0045`.
- Crear migraciones forward-only; nunca editar migraciones ya aplicadas.
- No reactivar WF8/WF8b para el flujo de Inmuebles24.
- No agregar una segunda guardia, fuzzy matching, mensajes al prospecto ni servicios nuevos.
- No usar el proyecto `GAD Clocking App` como sustituto de BYG Real Estate.

### 4.3 Skills, costo y revisión

La ejecución seguirá la secuencia de Matt Pocock ya aplicada al plan:

1. `grilling`: contrato cerrado antes de escribir código;
2. `domain-modeling`: términos, estados e invariantes compartidos;
3. `codebase-design`: interfaces profundas y mínima superficie pública;
4. `karpathy-guidelines`: cambios pequeños, supuestos explícitos y éxito verificable;
5. skills oficiales de Supabase y n8n para migraciones, nodos, errores y publicación;
6. `graphify` antes de cada ticket de código y `graphify update .` después de modificarlo.

Para reducir tokens, subagentes de bajo costo pueden preparar auditorías acotadas, fixtures o diffs mecánicos. El agente principal debe leer cada resultado, revisar todos los cambios, ejecutar las pruebas y conservar la responsabilidad de cada gate. Ningún subagente publica, migra ni envía mensajes por cuenta propia.

## 5. Dependencias y tickets

| Ticket | Entregable | Depende de | Gate externo | Estimación de ingeniería |
|---|---|---|---|---|
| V3-00 | Baseline, backups y APIs congeladas | Plan aprobado | Acceso de sólo lectura | 3–4 h |
| V3-01 | Contrato ejecutable y fixtures | V3-00 | Ninguno | 4–6 h |
| V3-02 | Inbox/correlación request-level y mapping de propiedades | V3-01 | Lote sanitizado I24↔EB | 8–12 h |
| V3-03 | Intake/dedupe y `Contactado` temprano | V3-01 | Ninguno | 6–8 h |
| V3-04 | Máquina propietario→guardia→Sandy | V3-01, V3-02, V3-03 | Ninguno | 8–12 h |
| V3-05 | Templates Meta y contrato de botón/callback | V3-01 | Aprobación Meta | 4–6 h + espera externa |
| V3-06 | Rewire de workflows n8n en borrador | V3-02..V3-05 | Lectura autenticada n8n | 8–12 h |
| V3-07 | Cierre EasyBroker y reintentos | V3-02, V3-04 | Credencial EB disponible, no expuesta | 6–8 h |
| V3-08 | Cola operativa, calendario, alertas y reporte | V3-02..V3-07 | Ninguno | 4–6 h |
| V3-09 | Pruebas integrales y shadow | V3-08 | Datos sanitizados | 8–12 h |
| V3-10 | Canary, cutover y rollback preparado | V3-09, Meta aprobado | Autorización inmediata | 4–6 h + observación |
| V3-11 | Validación 7/15 días y Excalidraw final | V3-10 | Producción estable | 2–4 h de cierre + monitoreo |

Estimación total de ingeniería: 65–96 horas, ejecutables en paralelo donde las dependencias lo permiten. El tiempo calendario depende principalmente de la aprobación de los templates por Meta y de la evidencia de producción; prometer una fecha más corta no elimina esos gates.

## 6. Fase 0 — Baseline reproducible y contrato de APIs

### Qué implementar

1. Confirmar que el proyecto Supabase correcto es BYG Real Estate, ref `wkaeutndwawkdhswisqe`.
2. Obtener inventario de schema, funciones, constraints, índices, timers y variables por presencia, sin mostrar secretos.
3. Leer en n8n cada workflow afectado, su `activeVersionId`, versión publicada, settings y hash/export; no confiar en snapshots locales como autoridad.
4. Exportar backups frescos y fechados de workflows, migraciones/schema relevante, servicio Raspberry Pi y configuración sanitizada.
5. Confirmar la versión de código desplegada en Raspberry Pi y el remoto/commit del proyecto antes de modificar.
6. **Waiver aprobado por el usuario el 2026-08-27:** no se exigirá un lote histórico de 20–50 pares conocidos I24↔EasyBroker. La correlación operará en modo conservador: propiedad exacta, identidad compatible, ausencia de contradicción y candidato único. Cero o múltiples candidatos quedan en revisión sin nota ni cambio a `Atendida`. La precisión se medirá en shadow/canary antes de G4.
7. Obtener una respuesta sanitizada real de `GET /properties/{public_id}` y congelar la matriz fuente→variable para título, operación, zona, precio, ID y URL canónica.
8. Probar en sólo lectura endpoint, header de autenticación, paginación y respuesta 200 del inbox EasyBroker; registrar la capacidad real del API sin asumir cursor compuesto server-side.
9. Demostrar en sólo lectura el origen y cobertura del mapping “Mis avisos” listing I24→`property_public_id`, con paginación e IDs sanitizados. Si no existe ese origen, congelar una alternativa verificable antes de migrar.
10. Verificar la suscripción WABA, callback URL y formatos de payload reales; demostrar con un cuerpo sintético que la versión live de n8n puede acceder al secreto HMAC y validar una firma, sin mostrarlo ni enviar mensajes.
11. Si el callback URL cambia, verificar además GET `hub.challenge` y la suscripción al campo `messages` antes del canary.
12. Congelar las firmas de las nuevas operaciones de base de datos antes de construir workflows.
13. Crear un ledger de riesgos y un archivo de evidencia por ticket.

### APIs y patrones permitidos

- Base existente: `upsert_lead_opportunity`, `claim_lead_opportunity`, delivery attempts/callbacks y leases de efectos.
- Nuevas funciones deben exponer resultados de dominio, no booleanos ambiguos: disposición, estado, responsable, motivo y siguiente acción.
- Supabase: generar migraciones con `supabase migration new`; el nombre numérico real lo decide la CLI.
- n8n: consultar primero los tipos/versiones de nodos disponibles, validar la definición completa y publicar sólo después de los gates.
- EasyBroker: lectura de inbox y efectos por URL/ID exacto; nunca por búsqueda de nombre. El checkpoint compuesto es interno y se implementa con watermark solapado si el API sólo ofrece `happened_after`.
- Meta: templates V3 versionados; el template/receptor V2 permanece únicamente para drenar intentos pre-cutover, nunca para volver a crear subastas V2.

### Verificación

- Backups legibles, con hashes y timestamps.
- Lista exacta de versiones live, o bloqueo explícito si n8n sigue respondiendo `AUTHENTICATION_ERROR`.
- Evidencia GET EasyBroker sanitizada y reglas conservadoras documentadas. La falta de pares históricos queda aceptada como limitación; shadow/canary debe medir candidatos únicos, cero candidatos, ambigüedades y falsos enlaces antes de G4.
- Respuesta de propiedad suficiente para mapear las ocho variables, con límites y fallback `No disponible`.
- Mapping “Mis avisos” demostrado con cobertura/paginación, o alternativa documentada antes de V3-02.
- Firmas V3 revisadas contra el contrato antes del primer cambio.
- `git status` capturado para distinguir cambios previos del usuario.

### Anti-patrones

- No usar el backup del 24 de agosto como prueba de versión activa actual.
- No interpretar una ejecución antigua `running` como éxito.
- No usar `Retry execution` sobre ejecuciones previas.
- No copiar ni imprimir API keys.
- No editar un workflow live mientras todavía se descubre su contrato.
- No avanzar el checkpoint EasyBroker si una página falla o no fue persistida completamente.

## 7. Fase 1 — Contrato ejecutable antes del comportamiento

### Qué implementar

1. Crear `tests/test_v3_flow_contract.py` con la matriz de decisiones confirmada.
2. Actualizar, sin romper evidencia V2 histórica:
   - `tests/test_routing_v2_contract.py`
   - `tests/test_guard_coverage_slots.py`
   - `tests/test_claim_gate.py`
   - `tests/test_lrv2_e2e_regression.py`
   - `tests/test_scraper_property_mapping.py`
3. Agregar fixtures SQL para disposición atómica, claims simultáneos, intentos de entrega, expiración, cola nocturna, correlación y leases de efectos.
4. Congelar `non_routable`: sólo evento sin ID externo estable, sin ninguna identidad normalizable del prospecto o sin ninguna identidad de propiedad. Los campos descriptivos ausentes y `property_public_id` reparable no lo activan.
5. Codificar una tabla de transición esperada que cada adaptador pueda consultar en tests.
6. Marcar con precisión qué tests deben fallar antes de implementar cada ticket.

### Verificación

- Cada regla del contrato aparece al menos en un test nombrado por escenario.
- Todos los adaptadores producen la misma disposición para cada combinación límite de `non_routable`.
- Los nuevos tests fallan por el hueco esperado, no por fixtures inválidos.
- La suite V2 que representa comportamiento todavía soportado permanece verde.
- No hay mocks que conviertan `accepted` de Meta en `delivered`.

### Anti-patrones

- No modificar producción para “hacer pasar” una prueba.
- No probar sólo el camino feliz.
- No comparar JSON completos de n8n si basta afirmar las propiedades críticas.
- No inventar un resultado EasyBroker cuando falta una muestra real.

## 8. Fase 2 — Inbox y correlación request-level de EasyBroker

### Qué implementar

1. Crear por migración una entidad de inbox para cada solicitud EasyBroker, con al menos:
   - `eb_request_id BIGINT PRIMARY KEY` = `contact_request.id`;
   - `eb_person_contact_id BIGINT NULL` = `contact_id` de la persona;
   - `property_public_id`;
   - teléfono/email normalizados y hashes/evidencia sanitizada;
   - `happened_at` y `fetched_at`;
   - estado y motivo de correlación.
2. Crear una entidad separada de vínculos con `i24_capture_event_id` obligatorio y `opportunity_id` sólo contextual; exigir `UNIQUE(eb_request_id)` y `UNIQUE(i24_capture_event_id)` para la relación uno-a-uno.
3. Crear checkpoint por cuenta/fuente. Avanzarlo atómicamente sólo después de persistir el lote completo; usar `happened_after` con solapamiento temporal y dedupe por `eb_request_id` cuando el API no soporte cursor compuesto.
4. Reemplazar la ventana fija/máximo 500 de `src/easybroker/supa.py` por paginación completa reanudable y tolerante a timestamps iguales/arribos tardíos.
5. Ejecutar la ingestión EasyBroker cada 5 minutos. La correlación se intenta cuando existen evento I24 y request EB suficientes, aunque la subasta siga abierta; el responsable final sólo habilita nota y `Atendida`.
6. Implementar correlación exacta: propiedad + identidad no contradictoria + ventana calibrada + candidato único.
7. Normalizar email con `trim+lower`; normalizar teléfono a E.164 sólo con país explícito. Campo ausente no contradice; campos comparables contradictorios impiden auto-link.
8. Distinguir `awaiting_eb_request` antes de cubrir el horizonte, `manual_review:no_eb_request` después del horizonte y `manual_review:ambiguous` para múltiples candidatos.
9. Refrescar y paginar completamente el mapeo “Mis avisos” I24 listing→`property_public_id`, persistir evidencia de origen, rechazar conflictos y reintentar el backfill antes de declarar `missing_property`.
10. Etiquetar `conversations.eb_contact_id` como `legacy_request_id` en documentación/compatibilidad; no reutilizarla como `contact_id` de persona ni como vínculo V3.

### Archivos/patrones a tocar

- Nueva migración generada después de inspeccionar la última migración real.
- `src/easybroker/supa.py`
- `src/easybroker/main.py`
- `src/easybroker/inbox.py` sólo si el contrato de lectura/sanitización lo requiere.
- Adaptador/mapeo de propiedades de `src/inmobiliaria24/` que hoy alimenta `property_public_id`.
- Pruebas nuevas de paginación, checkpoint, mapping, normalización, correlación y conflictos.

Patrón reutilizable: lease token-bound y evidencia parcial de `whatsapp-agent/migrations/0033_easybroker_attend_effect_lease.sql`. De `0045_finalize_easybroker_manager_assignment.sql` sólo se reutilizan guards/advisory locks compatibles; no su vínculo singular dentro de `conversations`.

### Verificación

- Dos solicitudes de la misma persona y propiedad pueden coexistir con IDs request-level distintos.
- Repetir una página del inbox no duplica registros.
- Dos workers intentando enlazar el mismo request/evento producen un solo vínculo inmutable.
- Reiniciar el worker continúa desde el checkpoint; una página fallida no lo avanza.
- Un request todavía no visible permanece `awaiting_eb_request`; sólo pasa a revisión después de cobertura completa del horizonte.
- Propiedad ausente intenta backfill; si no se resuelve, el routing continúa a guardia y el cierre EasyBroker queda pendiente/revisión sin efectos.
- Identidad contradictoria y múltiples candidatos quedan en revisión y no producen efectos.
- Cada correlación automática muestra candidato único, base de match y delta temporal.
- La cobertura del mapping de propiedades se mide por cuenta; los huecos tienen IDs y alerta, no sólo un conteo.
- Tests incluyen teléfono mexicano de 10 dígitos frente a E.164 `+52`, país ambiguo, extensión, email con case/espacios e identidad doble contradictoria.

### Anti-patrones

- No correlacionar por nombre del prospecto.
- No usar sólo timestamp o `contact_id`.
- No elegir el candidato “más cercano” si todavía hay más de uno válido.
- No registrar teléfonos/emails completos en logs de error.
- No borrar solicitudes antiguas para conseguir unicidad.
- No tratar el primer poll sin candidato como ausencia definitiva.

## 9. Fase 3 — Intake atómico, dedupe y `Contactado` temprano

### Qué implementar

1. Crear una operación transaccional de intake V3 que devuelva exactamente:
   - `created_new`
   - `active_duplicate`
   - `returning_assigned`
   - `non_routable`
2. Mantener la unicidad existente de oportunidades, extendiéndola sólo donde sea necesario para eventos recurrentes.
3. Separar el lease de `Contactado` de la condición “ya asignado” de `0032_i24_contact_effect_lease.sql` mediante una migración forward-only.
4. Definir para `Contactado` un lease y reintentos absolutos desde el primer fallo a +15, +30 y +60 minutos; después, `manual_review:i24_contact_failed` y una alerta durable. La subasta permanece bloqueada.
5. Reordenar `src/inmobiliaria24/main.py`: persistir → cambiar/verificar `Contactado` → emitir intake listo.
6. Retirar del camino V3 la escritura de nota I24 en `src/inmobiliaria24/main.py`; conservar `notes.py` sin invocarlo si otras rutas lo requieren.
7. Persistir un `offer_context` durable con los ocho campos, fuente/cuenta y evidencia de origen. Propietario, guardia, Sandy, recurrentes y cola nocturna renderizan desde DB, no desde datos transitivos de n8n.
8. Cambiar `deploy/inmobiliaria24.timer` de la ventana diurna actual a cada 15 minutos, 24/7. Reducir `RandomizedDelaySec` de 60 s a ≤5 s y medir el runtime por cada bandeja; la ventana 20:00–08:00 sólo difiere notificaciones/subastas.
9. Conservar cola nocturna 20:00–08:00 y release 08:05 con disposición ya decidida; el aviso de `returning_assigned` también espera hasta 08:05.

### Verificación

- Dos capturas concurrentes del mismo evento producen una sola oportunidad y un solo efecto `Contactado`.
- Ningún delivery attempt puede crearse si `Contactado` no está verificado.
- Un duplicado activo no reenvía oferta.
- Un recurrente asignado conserva responsable y no entra a subasta.
- Un recurrente nocturno conserva responsable sin avisarle hasta las 08:05.
- La misma persona con propiedad distinta crea oportunidad nueva.
- Falta de `property_public_id` intenta backfill; si sigue ausente, salta owner y continúa a guardia sin convertir el lead en `non_routable`.
- No aparece ninguna nota nueva en I24.
- Los campos faltantes se transforman a `No disponible` al renderizar, no se pierden silenciosamente.
- Un fallo persistente de `Contactado` alerta una sola vez y nunca deja salir WhatsApp.
- Ningún workflow de I24 puede usar el teléfono del prospecto como destinatario de WhatsApp.

### Anti-patrones

- No usar una consulta seguida de insert sin constraint/transacción.
- No marcar `Contactado` antes de persistir.
- No enviar WhatsApp mientras el efecto I24 está pendiente.
- No deduplicar únicamente por teléfono, ignorando la propiedad.
- No confiar en un payload n8n en memoria para una ronda que puede ocurrir horas después.

## 10. Fase 4 — Máquina de estados propietario→guardia→Sandy

### Qué implementar

1. Crear una migración V3 que represente exactamente una guardia vigente por fecha/turno y elimine del camino nuevo la ronda de respaldo.
2. Migrar/prevalidar las filas `primary/backup` actuales y actualizar en esta fase `dashboard/src/app/(dashboard)/calendario/calendar-editor.tsx`, `dashboard/src/app/(dashboard)/calendario/actions.ts`, `dashboard/src/lib/types.ts` y la parte de calendario de `dashboard/src/lib/queries.ts` para que UI/API ya no transporten ni creen dos guardias.
3. Exigir unicidad de nombres activos bajo `lower(btrim(name))`; dos nombres canónicos iguales bloquean resolución automática.
4. Resolver el único tag por propiedad con `trim` + igualdad case-insensitive. Si `tag_count != 1`, no tomar `tags[1]`: saltar owner y alertar la anomalía.
5. Congelar el `agent_id` estable de Sandy, su rol manager y estado activo. Su teléfono sólo afecta el aviso, no la capacidad de asignarla.
6. Tratar a Sandy como propietario válido cuando el tag coincida.
7. Saltar propietario por tag ausente/no coincidente, agente inactivo o teléfono inválido.
8. Crear intentos de entrega por destinatario con expiración calculada desde `delivered_at`; un `read` sin `delivered` puede establecer la entrega una sola vez y nunca extender el reloj.
9. Escalar de inmediato en Meta `failed`, incluidos errores de rechazo. El deadline sin callback es 2 minutos desde `provider_accepted_at`; configurar el sweeper con ciclo máximo de 30 segundos y medir la latencia posterior al deadline.
10. Omitir la ronda guardia si coincide con el propietario.
11. Asignar Sandy atómicamente cuando la ruta se agote o no exista guardia válida; luego encolar aviso informativo.
12. Implementar la ruta `returning_assigned` como conservación del responsable y aviso directo sin botón, respetando la cola nocturna.
13. Mantener el responsable final inmutable ante reintentos o fallas externas.

### Base reutilizable

- `0022_guard_coverage_slots.sql`
- `0026_claim_lead_opportunity.sql`
- `0027_advance_routing_tier.sql`
- `0030_delivery_attempts.sql`
- `0036_route_missing_owner_delivery_pending.sql`
- `0044_allow_manager_property_alias_resolution.sql`
- `0045_finalize_easybroker_manager_assignment.sql`

Se reutilizan invariantes, no necesariamente las rondas V2. Las nuevas funciones deben distinguir `owner`, `guard` y `manager_fallback` explícitamente.

### Verificación

- La expiración de 5 minutos comienza sólo en `delivered_at`.
- Un `accepted` sin `delivered` no abre el reloj de negocio.
- El sweeper marca el intento vencido al llegar al deadline de 2 minutos, actúa en el siguiente ciclo ≤30 s y no crea dos rondas.
- Sin propietario se llega a guardia sin 5 minutos ficticios.
- Sin guardia se asigna Sandy de inmediato.
- Si owner==guard, sólo existe un envío a esa persona.
- Falla del aviso a Sandy deja su asignación intacta.
- El calendario impide guardar dos guardias en el mismo turno y la migración rechaza cobertura ambigua.
- Dos agentes activos con el mismo nombre normalizado bloquean el cutover hasta corregir datos.

### Anti-patrones

- No usar esperas (`Wait`) de n8n como fuente de verdad.
- No calcular expiraciones sólo en memoria.
- No hacer fallback a un grupo masivo.
- No convertir una falla no relacionada en motivo para omitir a un propietario válido.
- No buscar a Sandy por nombre visible ni depender de su número para confirmar la asignación.

## 11. Fase 5 — Template Meta V3 y claim autenticado

### Qué implementar

1. Consultar primero por nombre para evitar colisiones y después crear, sin editar templates productivos, tres templates `es_MX`, categoría propuesta `UTILITY`:
   - `lead_subasta_v3`: propietario/guardia, ocho datos y un botón `Tomo`;
   - `lead_asignado_v3`: Sandy/recurrente, mismos ocho datos, texto informativo y cero botones;
   - `alerta_routing_v3`: incidente operativo para Sandy y cero botones.
2. Congelar el mapa de `lead_subasta_v3` y `lead_asignado_v3`:
   - `{{1}}` prospecto;
   - `{{2}}` teléfono;
   - `{{3}}` propiedad;
   - `{{4}}` operación;
   - `{{5}}` zona;
   - `{{6}}` precio;
   - `{{7}}` ID público;
   - `{{8}}` URL EasyBroker.
3. Definir límites deterministas por campo y `No disponible`; usar ejemplos sintéticos sin PII para el alta.
4. Usar literalmente los tres copies del contrato V3. `lead_asignado_v3` termina en `Este lead fue asignado directamente a ti.`; `alerta_routing_v3` sólo contiene tipo, IDs, estado y acción requerida.
5. Para cada oferta, respetar este orden obligatorio:

   ```text
   crear delivery_attempt
   → recibir delivery_attempt_id
   → construir payload V3
   → enviar BODY + BUTTON a Meta
   → persistir/bindear WAMID al intento
   → aceptar callbacks
   ```

6. Hidratar el botón con:

   ```text
   claim:v3:<opportunity_id>:<delivery_attempt_id>
   ```

7. Actualizar el receptor para validar:
   - formato/version del payload;
   - teléfono del remitente igual al destinatario;
   - intento perteneciente a la oportunidad y todavía vigente;
   - `context.id` igual al WAMID guardado;
   - claim atómico todavía ganable.
8. Si Meta acepta el envío pero falla el bind del WAMID, no reenviar automáticamente: reintentar sólo el bind usando el WAMID obtenido o elevar a revisión si se perdió.
9. Mantener los códigos V2 sólo para intentos creados antes del cutover y durante el drenaje; ningún intento V3 acepta texto manual.

### Documentación oficial a verificar en ejecución

- [Meta — envío de template interactivo](https://www.postman.com/meta/whatsapp-business-platform/request/lwtlz1k/send-message-template-interactive)
- [Meta — creación con quick reply](https://www.postman.com/meta/whatsapp-business-platform/request/uzphwqw/create-template-w-text-header-text-body-text-footer-and-2-quick-reply-buttons)
- [Meta — consulta por nombre/estado](https://www.postman.com/meta/whatsapp-business-platform/request/7whkjje/get-template-by-name-default-fields)
- [Meta — referencia de payloads de webhook](https://www.postman.com/meta/whatsapp-business-platform/folder/vzaxn16/webhook-payload-reference)

### Verificación

- Preview con los ocho campos y `No disponible` donde aplique.
- Un solo botón visible y payload distinto por intento.
- Los tres templates están en estado `APPROVED` antes del canary/cutover.
- Botón viejo, remitente incorrecto, WAMID incorrecto e intento expirado son rechazados.
- Dos callbacks simultáneos dejan un solo ganador.
- Un `read` sin `delivered` demuestra entrega una vez; callbacks duplicados o fuera de orden no extienden el SLA.
- El caso “Meta aceptó y el bind WAMID falló” no crea un segundo mensaje.

### Anti-patrones

- No considerar el preview o el alta enviada como aprobación.
- No incluir secretos en el payload.
- No usar un payload por tier que pueda reutilizarse en otro intento.
- No afirmar entrega con estado `accepted`.
- No enviar un mensaje real sin autorización inmediata del usuario. El envío de definiciones sintéticas a revisión Meta usa un gate separado.

## 12. Fase 6 — Rewire de n8n en borrador

### Workflows afectados

| Workflow | ID | Cambio V3 |
|---|---|---|
| WF10 Scraper Intake | `Obr38705ZZYS3FB8` | Contrato de datos completo y disposición de intake. |
| WF12 Owner Resolver | `w7yJr7naWoxPq6Pw` | Tag único, canonicalización simple y salto inmediato. |
| WF13 Directed Notify | `Bo2YbbUpmBzRbhDa` | Template V3, botón dinámico e intento exacto. |
| WF1 Inbound Router | `snF6Sr9CBJIevMVD` | Subworkflow tipado para mensajes; parseo V3 y compatibilidad V2 acotada al drenaje. |
| WF3b Claim Handler | `JM2HxJxl53k4zlki` | Claim sender+attempt+WAMID atómico. |
| WF3c Expiry/Fallback Transition | `UNIKqyAvIUAZkNIs` | Subworkflow sin Schedule; aplica transición/fallback atómicos y encola, sin escribir EasyBroker. |
| WF7 Night Queue | `xzBG0GIsHCUd44DC` | Release 08:05 y conservación de disposición V3. |
| WF23 Delivery Sweeper | `MjfHw3tYE2qYgJfM` | Único scheduler/lease claimer para deadlines de 2/5 min; invoca WF3c. |
| WF22 Meta Webhook | `Z89IQDw1fgWlqXEW` | Único ingreso Meta: HMAC, batch parsing, statuses y mensajes normalizados. |
| WF20/WF21 | IDs a confirmar live | Únicamente alertas/error V3 requeridos. |

### Qué implementar

1. Leer las versiones activas antes de editar y guardar backup/hash.
2. Guardar drafts sobre los IDs existentes; no mezclar clones con workflows originales. Si un ID debe cambiar por una limitación real, documentar el reemplazo y todas sus llamadas antes de guardar.
3. Convertir WF22 en el único webhook Meta: validar `X-Hub-Signature-256` contra el raw body antes de normalizar.
4. Persistir el callback crudo/sanitizado en un inbox durable idempotente antes del acuse HTTP:
   - firma inválida → `401/403`, sin mutación;
   - payload inválido → `400`;
   - falla la persistencia → `500`;
   - firma válida + insert/upsert durable → `200` inmediato.
5. Procesar después desde ese inbox: aplanar todos los `entry[]`, `changes[]`, `statuses[]` y `messages[]`; un replay debe producir exactamente una transición.
6. Conservar `msg.id` para dedupe y `msg.context.id` por separado como `reply_to_wamid`. Enviar mensajes normalizados a WF1 mediante `Execute Workflow Trigger`; retirar o marcar explícitamente legado el endpoint `evolution-webhook` para tráfico Meta.
7. Aceptar un claim V3 sólo desde `msg.type === 'button'` y `msg.button.payload`; no desde texto ni desde un tipo interactivo genérico.
8. Convertir WF23 en el único scheduler y reclamador de leases de 2/5 minutos. Quitar los Schedule de WF3c y llamarlo como subworkflow tipado para ejecutar una transición ya reclamada.
9. Mantener n8n como orquestador: una operación de DB por transición, sin duplicar lógica de carrera.
10. Añadir manejo explícito de errores por nodo y correlation IDs.
11. Guardar exports canónicos en `n8n-export/`; actualizar el espejo de `whatsapp-agent/workflows/` sólo donde el proyecto realmente lo use.
12. Reemplazar bearer tokens/API keys embebidos o `$env` dentro de nodos HTTP por credenciales n8n; documentar el secreto HMAC sin exponerlo.
13. Validar conexiones, settings de retención y contrato de cada subworkflow.
14. Publicar únicamente en Fase 10.

### Verificación

- Para cada workflow: `validate_workflow`, lectura posterior de detalles y comparación manual de `connections`.
- `prepare_workflow_pin_data` + `test_workflow` con Postgres, HTTP, subworkflows y efectos externos completamente simulados.
- Cada nodo HTTP/RPC tiene timeout, política de retry segura y rama de error.
- Tests con payloads sanitizados recorren callbacks duplicados, firma inválida, arrays con varios eventos, statuses fuera de orden, `read` sin `delivered`, botón viejo y bind WAMID fallido.
- DB no disponible antes del acuse produce `500`, nunca `200`; el replay posterior persiste y procesa exactamente una vez.
- Existe exactamente un Schedule para deadlines de delivery y una sola transición durable por intento vencido.
- `activeVersionId`, published version y workflow version quedan registrados antes/después.
- Tras publicar, cada ejecución canary usa `workflowVersionId` igual al `activeVersionId` aprobado.
- No se reactivan WF8/WF8b.
- Si n8n sigue respondiendo `AUTHENTICATION_ERROR`, G3 queda bloqueado y no se publica por una ruta alternativa no auditada.

### Anti-patrones

- No editar sólo el JSON local y asumir que n8n live cambió.
- No publicar una versión draft por accidente.
- No reintentar claims o escrituras no idempotentes desde n8n de forma ciega.
- No afirmar que una ejecución fue exitosa si la retención no conserva evidencia.

## 13. Fase 7 — Cierre EasyBroker exacto, parcial e idempotente

### Qué implementar

1. Crear el lease y ledger de cierre keyed por `eb_request_id`, no por oportunidad. Cada request espera a su responsable canónico y se cierra exactamente una vez; una oportunidad puede tener varios requests.
2. Escribir `RESPONSABLE: <primer nombre canónico>` una vez.
3. Marcar la misma solicitud `Atendida`.
4. Guardar efectos separados: estado, intentos, respuesta sanitizada y confirmación.
5. Reintentar sólo el paso faltante en deadlines absolutos +1, +5, +15 y +30 minutos desde el primer fallo.
6. Cambiar `deploy/easybroker.timer` a ciclo de efectos de un minuto; el propio worker limita el fetch del inbox a cada 5 minutos mediante checkpoint/`next_fetch_at`. Reducir cualquier random delay para que no invalide el SLA y medir la latencia real.
7. Tras agotar, dejar unresolved durable y emitir una sola alerta a Sandy.
8. Para ambigüedad, alertar inmediatamente. Para cero candidatos, esperar hasta que el checkpoint cubra el horizonte; sólo entonces alertar `no_eb_request`.
9. Hacer que múltiples workers/reinicios compartan leases sin duplicar nota.

### Verificación

- Reejecutar un cierre completo no agrega otra nota ni repite `Atendida`.
- Caída después de nota y antes de status recupera sólo el status.
- Caída después de status y antes de registrar evidencia reconcilia sin duplicar.
- Request ID inexistente/ambiguo no causa escritura.
- Sandy como responsable produce exactamente `RESPONSABLE: Sandy`.
- Dos requests distintos de la misma persona+propiedad comparten una sola subasta, pero producen dos cierres exactos e independientes.
- Un request correlacionado antes de asignar queda `awaiting_responsible` y se cierra cuando aparece el responsable, sin recorrelar.
- Los deadlines se evalúan por timestamp durable; reiniciar el servicio no reinicia el backoff.

### Anti-patrones

- No usar `contact_id` como destino del cierre.
- No marcar `Atendida` en una solicitud “parecida”.
- No reabrir la oportunidad por una falla EasyBroker.
- No tener retries infinitos silenciosos.

## 14. Fase 8 — Cola operativa, alertas y reporte de negocio

### Qué implementar

1. Crear una vista/cola operativa mínima para `manual_review`, efectos pendientes, retries agotados y alertas. Debe mostrar IDs exactos, responsable, motivo y próxima acción.
2. Exponer en el reporte por lead: `Contactado`, responsable/origen, evidencia de WhatsApp, `eb_request_id`, nota y `Atendida` por separado.
3. Actualizar `dashboard/src/lib/types.ts`, `dashboard/src/lib/queries.ts` y la superficie mínima existente que consuma esa cola. El cambio del calendario de una guardia pertenece a V3-04, no se posterga a esta fase.
4. Crear alertas durables con dedupe por incidente y envío mediante `alerta_routing_v3` a Sandy.
5. Un dashboard exhaustivo con toda la línea de tiempo es una mejora posterior opcional; no bloquea V3 si la cola mínima y el reporte verificable existen.
6. Nunca mostrar secretos ni PII innecesaria en logs técnicos.

### Verificación

- Un operador puede explicar el camino de un lead desde el reporte y abrir cada excepción desde la cola mínima, sin logs crudos.
- `cero verificado` se distingue de `sin datos por retención/acceso`.
- Una alerta fallida de WhatsApp sigue visible en DB/dashboard.
- Los conteos del reporte se reconcilian con IDs individuales.

### Anti-patrones

- No declarar verde por una ejecución n8n sin efectos externos.
- No ocultar manual_review dentro de un conteo genérico de “pendientes”.
- No enviar al usuario alertas operativas que él pidió dirigir a Sandy.

## 15. Fase 9 — Verificación offline, integración y shadow

### Suite mínima

1. Tests unitarios Python para normalización, payloads, checkpoint/watermark y efectos.
2. Tests SQL transaccionales para intake, claim, rondas, fallback, correlación y leases.
3. Validación estática de cada workflow y su contrato de entrada/salida.
4. E2E local/sintético sin llamadas reales a Meta, I24 ni EasyBroker.
5. Shadow read-only con eventos reales: calcular decisiones y compararlas, sin WhatsApp ni escrituras de portal.
6. Reconciliación de los 17 leads históricos sólo para hechos demostrables: 5 sin propiedad, 3 no-finales y 11 con causa desconocida. No reconstruir candidatos EasyBroker que nunca se conservaron.
7. Pruebas positivas de correlación con el lote anonimizado de pares conocidos I24↔EB; no usar los 17 históricos como evidencia positiva.

### Matriz obligatoria de escenarios

| # | Escenario | Resultado esperado |
|---:|---|---|
| 1 | Owner válido toma | Owner único; nota/Atendida exactos. |
| 2 | Owner expira, guardia toma | Guardia única. |
| 3 | Owner y guardia expiran | Sandy automática. |
| 4 | Owner faltante | Guardia inmediata. |
| 5 | Guardia faltante | Sandy inmediata. |
| 6 | Owner==guard | Un solo envío a esa persona; luego Sandy. |
| 7 | Sandy es owner y toma | Sandy por origen owner. |
| 8 | Dos clics simultáneos | Un ganador, un rechazo tardío. |
| 9 | Click de otro teléfono/WAMID | Rechazo sin mutación. |
| 10 | Callback Meta `failed`, incluido error de rechazo | Escalación inmediata. |
| 11 | Sin callback 2 min | Escalación técnica una sola vez. |
| 12 | Duplicado activo | Sin nueva oferta. |
| 13 | Recurrente asignado | Mismo responsable, sin subasta. |
| 14 | Misma persona/otra propiedad | Nueva oportunidad. |
| 15 | Noche/fin de semana | Contactado y cola; release 08:05. |
| 16 | Falta dato descriptivo | Mensaje con `No disponible`. |
| 17 | Correlación EB única | Cierre exacto. |
| 18 | Correlación EB ambigua | Cero escrituras y alerta. |
| 19 | Falla nota, status funciona | Retry sólo nota. |
| 20 | Falla status, nota funciona | Retry sólo status. |
| 21 | Aviso Sandy falla | Sandy sigue asignada. |
| 22 | Reinicio a mitad del flujo | Reanudación sin duplicados. |
| 23 | Dos requests EB, misma oportunidad | Una subasta; dos cierres request-level exactos. |
| 24 | Request EB tarda en aparecer | `awaiting_eb_request`; sin alerta prematura. |
| 25 | `read` llega sin `delivered` | Entrega válida una vez; SLA no se extiende. |
| 26 | Firma HMAC inválida | Callback rechazado sin mutación. |
| 27 | Webhook con múltiples entries/messages/statuses | Todos se procesan y deduplican. |
| 28 | Meta acepta y falla bind WAMID | No reenvío; bind-only retry o revisión. |
| 29 | Falta `property_public_id` | Backfill; si no resuelve, guardia y cierre pendiente seguro. |
| 30 | Teléfono del prospecto como destinatario | Test falla; ningún mensaje se envía al prospecto. |
| 31 | DB no disponible antes de acuse Meta | HTTP 500; replay posterior procesa una vez. |
| 32 | Dos sweepers intentan el mismo deadline | Un lease y una sola transición; WF23 es único scheduler. |
| 33 | Faltan campos descriptivos | Lead enrutable con `No disponible`. |
| 34 | Falta ID estable del evento, o toda identidad de persona, o toda identidad de propiedad | `non_routable` determinista, sin oferta. |

### Gate de salida

- 100% de tests contractuales y de regresión verdes.
- Cero validaciones n8n críticas.
- Shadow sin efectos externos y sin divergencias inexplicadas.
- Correlación EasyBroker evaluada con fixture real sanitizado.
- Rollback ensayado localmente.

## 16. Fase 10 — Canary, drenaje y cutover controlado

### Preflight obligatorio

1. Pedir autorización inmediata justo antes de cualquier prueba que envíe WhatsApp o escriba en I24/EasyBroker.
2. Capturar backups y hashes frescos el mismo día.
3. Confirmar `lead_subasta_v3`, `lead_asignado_v3` y `alerta_routing_v3` en `APPROVED`, con IDs, lenguaje, categoría final, variables y botones exactos.
4. Confirmar Supabase correcto, migraciones aplicadas y advisors sin hallazgos críticos nuevos.
5. Confirmar workflows active/published y sus versiones exactas, callback WABA suscrito y secreto HMAC por presencia.
6. Confirmar servicios/timers Raspberry `enabled` y `active`, incluidos scraper 24/7, poll EB 5 min y ciclo de efectos 1 min.
7. Confirmar una sola guardia por turno, nombres activos normalizados únicos y `agent_id` estable de Sandy.
8. Probar compatibilidad de las firmas V3 del schema con el estado seguro de rollback.
9. Seleccionar un canary nuevo, inequívoco y recuperable; no reutilizar un lead histórico.

### Secuencia de cutover

1. Aplicar migraciones forward-only.
2. Desplegar código/adaptadores con creación V3 todavía apagada.
3. Publicar primero WF22, WF1 y WF3b compatibles con intentos V2 pre-cutover y V3.
4. Publicar WF10, WF12, WF13, WF3c, WF7 y WF23 con el feature flag de creación V3 apagado.
5. Verificar `activeVersionId` de todos los receptores, productores y orquestadores publicados.
6. Detener la creación de ofertas V2.
7. Esperar hasta que exista cero delivery attempts V2 abiertos/reclamables. Veinte minutos es sólo el límite de observación: si queda alguno, abortar el cutover y reconciliarlo; no retirar el parser V2.
8. Habilitar V3 únicamente para el canary exacto autorizado.
9. Verificar de punta a punta:
   - captura;
   - `Contactado` visible;
   - WAMID `delivered`;
   - claim o fallback correcto;
   - request EasyBroker exacto;
   - una nota;
   - `Atendida`.
10. Verificar que cada ejecución canary tenga `workflowVersionId` igual al `activeVersionId` aprobado.
11. Sólo después de G5 y con el canary completo, activar nuevas ofertas V3 para las tres bandejas.
12. Mantener compatibilidad de claim V2 únicamente para intentos pre-cutover hasta su expiración; después cerrarla.

### Criterios de abortar

- cualquiera de los tres templates no aprobado o con contrato distinto;
- n8n live no verificable;
- migración parcial o advisors críticos;
- `Contactado` no demostrado;
- botón sin payload/contexto exacto;
- más de un responsable;
- correlación EasyBroker ambigua;
- nota o `Atendida` sobre request incorrecto;
- secreto expuesto;
- ausencia de rollback comprobado.

### Rollback

1. Apagar sólo la creación de nuevas ofertas V3.
2. Mantener captura/evidencia en modo seguro y enviar nuevas oportunidades a cola manual; no reactivar la creación de subastas V2.
3. Restaurar sólo componentes anteriores que sean compatibles con el schema V3 y no vuelvan a crear ofertas V2; usar backups/hashes confirmados.
4. Mantener activos los receptores V2 únicamente hasta cerrar/expirar intentos pre-cutover.
5. No revertir efectos externos irreversibles ya correctos: `Contactado`, nota o `Atendida`.
6. No borrar filas V3; marcarlas con estado de rollback y conservar evidencia.
7. Reconciliar cada lead en vuelo antes de reintentar.
8. Las migraciones se corrigen con una nueva migración; nunca se modifica ni revierte destructivamente el historial aplicado.

## 17. Fase 11 — Observación, aceptación y diagrama final

### Operación supervisada

- Primeras 24 horas: revisar cada lead individualmente contra los ocho criterios de éxito.
- Día 7, 2 de septiembre de 2026: checkpoint formal con conteos y excepciones.
- Día 15: cierre de observación y decisión de estabilidad.
- Reportar por separado correctos, pendientes, manual_review, fallas técnicas y evidencia no disponible.
- No reparar automáticamente una ambigüedad que pueda escribir en la solicitud equivocada.

### Entregables finales para la clienta

1. Reporte verificable con IDs, timestamps, responsables, estado I24, WhatsApp, nota y `Atendida`.
2. Un único diagrama de flujo actualizado al comportamiento realmente desplegado.
3. JSON Excalidraw válido y autocontenido en:

   `output/diagrams/flujo-operativo-inmobiliaria24-v3.excalidraw.json`

4. El diagrama debe incluir tiempos operativos, decisiones, excepciones, cola nocturna, duplicados, propietario, guardia, Sandy, correlación exacta y cierre EasyBroker.
5. No se entrega como “final” antes de comparar el diagrama con la versión live y el canary; así la clienta valida el sistema real, no una intención.
6. Actualizar documentación operativa que todavía describa dos guardias, códigos escritos o correlación legada, como mínimo:
   - `WHATSAPP_TEMPLATES_SUBMIT.md`
   - `whatsapp-agent/README.md`
   - `src/easybroker/README.md`
   - `docs/cliente/flujo-atencion-leads-detallado.html`

## 18. Evidencia exigida por ticket

Cada ticket termina con un paquete mínimo:

- commit/diff limitado a archivos declarados;
- tests ejecutados y resultado exacto;
- migración y verificación forward-only, si aplica;
- workflow ID, activeVersionId, published version y hash, si aplica;
- IDs/timestamps de cualquier efecto externo autorizado;
- secretos sanitizados;
- riesgos pendientes y rollback;
- `graphify update .` después de cambios de código, con salida registrada.

Un ticket no se cierra con frases como “parece correcto”, “accepted” o “workflow verde”.

## 19. Gates de supervisión y autoridad

| Gate | Momento | Qué debe aprobar/verificar el usuario |
|---|---|---|
| G0 | Antes de implementar | Este plan y el contrato V3. |
| G1 | Antes de migrar Supabase | Backup, proyecto/ref correctos, migraciones exactas y rollback. |
| G2A | Antes de enviar templates a revisión Meta | Copy literal y variables de los tres templates, botón `Tomo`, categoría y ejemplos 100% sintéticos; no autoriza mensajes. |
| G2B | Antes del canary | Lectura de template IDs, `es_MX`, categoría final, estado `APPROVED`, variables y botón exactos. |
| G3 | Antes de publicar n8n | IDs/diffs, `validate_workflow`, detalles/connections posteriores, pin-data tests simulados, credenciales n8n, webhook/HMAC, `hub.challenge` si cambia URL, suscripción `messages`, `versionId` y `activeVersionId`. |
| G4 | Justo antes del canary | Lead/cuentas/destinatarios exactos, template IDs/lenguaje y escrituras I24/EasyBroker exactas; autorización de esos efectos reales. |
| G5 | Antes del rollout total | Evidencia completa del canary, no sólo envío aceptado. |
| G6 | Cierre | Reporte 7/15 días y JSON Excalidraw final. |

La aprobación de G0 no adelanta ningún gate posterior. Cada gate con efectos externos se vuelve a pedir en el momento de ejecutarlo.

## 20. Definición de terminado

V3 está terminada cuando se cumplen simultáneamente:

- contrato funcional representado en tests;
- tres bandejas capturadas cada 15 minutos, 24/7, sin duplicados;
- `Contactado` verificado antes de WhatsApp;
- ventana nocturna y release 08:05 correctos en CDMX;
- owner por tag único y comparación acordada;
- guardia única y Sandy fallback sin bloqueo por aviso;
- tres templates aprobados; subasta con botón `Tomo` y payload por intento, asignación/alerta sin botón;
- primer claim válido gana atómicamente;
- duplicados/recurrentes siguen la disposición correcta;
- correlación por `contact_request.id` exacto y auditable;
- mapping de `property_public_id` medido, con backfill y conflictos visibles;
- una sola nota `RESPONSABLE: <nombre>` y estado `Atendida`;
- reintentos parciales finitos y alertas durables;
- n8n, Supabase, Raspberry y código desplegado con versiones verificadas;
- canary y producción demuestran el resultado completo;
- checkpoint de 7 días sin fallas críticas no resueltas;
- observación de 15 días cerrada;
- reporte y un único JSON Excalidraw final entregados.

## 21. Próxima acción después de aprobar este plan

Ejecutar solamente V3-00 en modo de sólo lectura: baseline vivo, backups frescos, lote sanitizado I24↔EasyBroker, muestra de propiedad y contrato de APIs. Al terminar V3-00 se presenta la evidencia y se solicita G1 antes de la primera migración o modificación externa.
