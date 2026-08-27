# Contrato operativo: Lead Routing V3

**Estado:** confirmado por el usuario el 26 de agosto de 2026.  
**Alcance de este documento:** definición funcional; no autoriza cambios en producción, mensajes reales, escrituras en portales ni publicación de workflows.  
**Zona horaria de negocio:** `America/Mexico_City`.

## 1. Objetivo

Convertir cada solicitud nueva detectada en Inmuebles24 en una atención trazable y sin ambigüedad:

1. capturarla de forma durable;
2. marcarla `Contactado` en Inmuebles24;
3. asignarla al ejecutivo correcto mediante propietario, guardia o Sandy;
4. registrar una sola nota final en la solicitud exacta de EasyBroker;
5. marcar esa solicitud `Atendida`;
6. conservar evidencia de cada decisión y efecto.

El flujo se considera exitoso únicamente cuando el resultado completo de negocio está demostrado. Un envío de WhatsApp aceptado por Meta, una ejecución verde de n8n o una asignación interna aislada no bastan por sí solos.

## 2. Fuentes de verdad

Este contrato consolida:

- las notas y transcripción de la reunión con la clienta del 26 de agosto de 2026;
- las confirmaciones posteriores del usuario, realizadas una por una;
- el contrato y plan V2 existentes;
- la lectura del scraper de Inmuebles24, integraciones EasyBroker, migraciones SQL, dashboard y exports locales de n8n;
- la revisión específica del template de Meta, correlación EasyBroker y diferencias V2→V3.

Las fuentes locales principales son:

- `meetings/BYG + AI - 2026_08_26 16_59 CEST - Notes by Gemini (Spanish).md`
- `docs/superpowers/specs/2026-08-12-lead-routing-v2-contract.md`
- `docs/superpowers/plans/2026-08-12-lead-routing-v2-execution-plan.md`
- `src/inmobiliaria24/`
- `src/easybroker/`
- `whatsapp-agent/migrations/`
- `n8n-export/`
- `whatsapp-agent/workflows/`

Si una definición local de n8n contradice la versión activa publicada, la versión activa es la autoridad operativa y debe verificarse antes de implementar.

## 3. Glosario del dominio

| Término | Definición V3 |
|---|---|
| Evento de captura | Aparición durable de una solicitud detectada en una de las tres bandejas de Inmuebles24. |
| Solicitud EasyBroker | `contact_request.id` exacto sobre el que se escribe la nota y se marca `Atendida`. No es el `contact_id` de la persona. |
| Oportunidad | Unidad de asignación formada por una persona y una propiedad. |
| Subasta | Secuencia dirigida de ofrecimientos: propietario y, si no toma, una sola guardia. No es difusión masiva. |
| Intento de entrega | Envío individual de WhatsApp a un destinatario dentro de una ronda, con identidad y WAMID propios. |
| Propietario | Ejecutivo indicado por el único tag de la propiedad en EasyBroker. Sandy puede ser propietaria aunque también sea manager. |
| Guardia | Única persona válida que está de guardia al momento de escalar. |
| Responsable final | Primera persona que gana válidamente o Sandy cuando se activa el fallback. Es inmutable. |
| Cierre EasyBroker | Una nota `RESPONSABLE: <primer nombre>` más estado `Atendida` en la solicitud exacta. |

## 4. Invariantes no negociables

1. Cada captura se identifica de manera idempotente; reintentar el mismo evento no crea otra oportunidad ni otros efectos.
2. `Contactado` en Inmuebles24 ocurre después de la captura durable y antes de cualquier oferta por WhatsApp.
3. Inmuebles24 no recibe nota automatizada.
4. Una oportunidad tiene como máximo un responsable final.
5. La primera aceptación válida gana de forma atómica y permanente.
6. Ninguna respuesta tardía, repetida o perteneciente a otro intento puede cambiar al responsable.
7. Cada solicitud EasyBroker exacta recibe como máximo una nota final de responsabilidad.
8. La nota sólo se escribe cuando ya existe responsable final.
9. El estado `Atendida` sólo se aplica a la solicitud EasyBroker exacta; nunca se adivina la solicitud.
10. Un error posterior de EasyBroker no reabre la subasta ni cambia al responsable.
11. Un error de entrega del aviso informativo a Sandy no revierte su asignación.
12. Los reintentos ejecutan únicamente el efecto faltante y nunca duplican los efectos ya confirmados.

## 5. Flujo principal

### 5.1 Captura

- El scraper revisa las tres bandejas de Inmuebles24 cada 15 minutos, las 24 horas, incluidos fines de semana y días festivos.
- Cada solicitud se persiste antes de interactuar con Inmuebles24, WhatsApp o EasyBroker.
- Una captura repetida del mismo evento externo devuelve el resultado durable anterior.
- Tras persistirla, el sistema solicita el cambio `Pendiente`→`Contactado` y verifica el efecto.
- Ninguna oferta sale antes de que `Contactado` esté confirmado. Si el portal falla, se conserva un efecto pendiente idempotente con reintentos finitos; la oportunidad no avanza a la subasta y, al agotarlos, queda en revisión con alerta.

### 5.2 Disposición atómica de duplicados

La captura debe devolver exactamente una de estas disposiciones:

| Disposición | Condición | Resultado |
|---|---|---|
| `created_new` | Persona+propiedad sin oportunidad activa ni asignación previa aplicable | Crear una nueva oportunidad y continuar a resolución. |
| `active_duplicate` | Misma persona+propiedad ya en proceso | Asociar el evento sin abrir otra subasta ni reenviar ofertas. |
| `returning_assigned` | Misma persona+propiedad con responsable final anterior | Conservar ese responsable, notificarle directamente y no abrir subasta. |
| `non_routable` | Datos mínimos insuficientes o captura inválida | No enviar oferta; conservar motivo y alertar/revisar según corresponda. |

Reglas complementarias:

- misma persona y propiedad distinta = nueva oportunidad y nueva subasta;
- una nueva solicitud EasyBroker real se conserva como entidad propia aunque se asocie a una oportunidad existente;
- repetir el mismo evento técnico no crea otra solicitud lógica;
- la ausencia inicial de `property_public_id` no vuelve al lead `non_routable`: primero se intenta reparar el mapeo de la propiedad y, mientras tanto, el propietario se considera no resoluble para poder continuar a guardia.

`non_routable` se limita a criterios objetivos: evento sin identificador externo estable, ausencia total de identidad utilizable del prospecto (ni teléfono ni email normalizables) o ausencia total de identidad de propiedad (ni listing I24 ni ID EasyBroker). Nombre, título, operación, zona, precio o URL ausentes no bloquean; se muestran como `No disponible`.

### 5.3 Ventana nocturna

- La ventana nocturna es diaria, incluidos fines de semana y días festivos.
- Horario: desde las 20:00:00 hasta antes de las 08:00:00 en `America/Mexico_City`.
- La captura y el cambio a `Contactado` pueden ocurrir dentro de la ventana.
- Las nuevas subastas quedan en cola y se liberan a las 08:05.
- Los avisos directos de `returning_assigned` también esperan hasta las 08:05; conservar al responsable no autoriza molestarlo de madrugada.
- La cola conserva los datos y decisiones necesarios para reanudar sin recalcular de forma contradictoria.

### 5.4 Resolución del propietario

- La propiedad debe resolverse por su ID público de EasyBroker, no por el ID numérico de Inmuebles24.
- La propiedad contiene exactamente un tag, según el compromiso operativo de Sandy.
- El tag se compara contra el nombre del dashboard ignorando mayúsculas/minúsculas y espacios sólo al inicio o final.
- No se aplican coincidencias parciales, fuzzy matching ni transformaciones especiales de acentos.
- El nombre canónico y su capitalización provienen del dashboard.
- Sandy es un propietario válido si el tag de la propiedad corresponde a Sandy.
- Sandy se identifica por un `agent_id` estable con rol manager; no por una búsqueda mágica del texto `Sandy`.
- Si el contrato externo se incumple y la propiedad trae cero o más de un tag, no se elige el primero: el propietario se considera inválido y se alerta la anomalía.
- Si el tag falta, no coincide de forma única, el agente está inactivo o no tiene teléfono válido, se omite la ronda de propietario y se escala inmediatamente a guardia.

### 5.5 Subasta dirigida

La única escalera válida es:

`Propietario → una guardia vigente → Sandy`

Reglas temporales:

- El propietario dispone de 5 minutos contados desde el callback `delivered` de Meta.
- Si no toma, la única guardia vigente dispone de 5 minutos desde su propio callback `delivered`.
- Un estado Meta `failed`, incluidos errores que representen rechazo del proveedor, escala inmediatamente. `rejected` sólo puede conservarse como alias interno si el adaptador real lo emite.
- Un callback `read` cuenta como prueba de entrega cuando se perdió `delivered`, pero nunca reinicia ni extiende un `expires_at` ya fijado.
- Un mensaje aceptado/enviado sin callback concluyente vence técnicamente a los 2 minutos desde `provider_accepted_at`; el sweeper ejecuta la escalación en su siguiente ciclo y registra por separado esa latencia de detección.
- Si propietario y guardia son la misma persona, no se envía una segunda ronda a esa persona y se pasa a Sandy.
- Si no existe guardia válida, turno válido o teléfono válido, se asigna Sandy inmediatamente.
- No existe ronda de guardia de respaldo en V3.

### 5.6 Aceptación

- Propietario y guardia reciben un template de Meta con un único botón visible: `Tomo`.
- El payload oculto identifica la versión, oportunidad e intento exacto:

```text
claim:v3:<opportunity_id>:<delivery_attempt_id>
```

- La aceptación sólo es válida si coinciden el remitente, destinatario, oportunidad, intento vigente y WAMID/contexto del mensaje.
- La base de datos resuelve la competencia en una sola operación atómica.
- Respuesta al ganador: `✅ Lead asignado a ti`.
- Respuesta a un clic posterior a otro ganador: `Este lead ya fue asignado`.
- Respuesta a un clic fuera de vigencia: `La oferta ya expiró`.
- Escribir manualmente `TOMO`, usar códigos V2 o reutilizar botones viejos no permite reclamar una oferta V3.

### 5.7 Fallback Sandy

- Cuando termina la ronda de guardia sin ganador, o no existe una ronda válida, Sandy se convierte en responsable final de forma automática.
- Primero se confirma la asignación en la base de datos; después se intenta el aviso informativo.
- El aviso a Sandy contiene la información completa del lead y no incluye botón de toma.
- La entrega del aviso no es condición para cerrar EasyBroker.

### 5.8 Lead recurrente ya asignado

- Para la misma persona y la misma propiedad con responsable anterior, el responsable se conserva sin nueva subasta.
- El responsable recibe un aviso directo con la información del nuevo evento, sin competencia ni botón de toma.
- La nueva solicitud EasyBroker exacta, si existe, se cierra con ese mismo responsable.

## 6. Contrato del mensaje de WhatsApp

Propietario y guardia ven el mismo contenido:

```text
🏠 Nuevo lead

Prospecto: <nombre>
Teléfono: <teléfono>

Propiedad: <título o referencia>
Operación: <venta o renta>
Zona: <colonia o ubicación>
Precio: <precio>
ID: <ID público>
EasyBroker: <URL>

Tienes 5 minutos para aceptarlo.
```

Sandy fallback y un responsable recurrente reciben `lead_asignado_v3`, sin botones:

```text
🏠 Lead asignado

Prospecto: <nombre>
Teléfono: <teléfono>

Propiedad: <título o referencia>
Operación: <venta o renta>
Zona: <colonia o ubicación>
Precio: <precio>
ID: <ID público>
EasyBroker: <URL>

Este lead fue asignado directamente a ti.
```

Las alertas a Sandy usan `alerta_routing_v3`, sin botones y sin PII innecesaria:

```text
⚠️ Incidencia de routing

Tipo: <tipo>
Lead ID: <ID interno>
Propiedad ID: <ID público o No disponible>
Estado: <estado>
Acción requerida: <acción>
```

Reglas:

- todos los datos se muestran en WhatsApp; no se obliga al agente a abrir EasyBroker;
- la URL de EasyBroker también se incluye como conveniencia;
- cualquier dato descriptivo ausente se muestra como `No disponible`;
- los campos largos se truncan de forma determinista para respetar los límites aprobados por Meta;
- no se envía ningún mensaje automatizado al prospecto;
- `lead_subasta_v3` se usa sólo para propietario/guardia y contiene el botón `Tomo`;
- `lead_asignado_v3` contiene los mismos datos, la indicación de que el lead ya fue asignado y no tiene botones; se usa para Sandy fallback y recurrentes;
- `alerta_routing_v3` es un template sin botones y separado de los mensajes de lead; se usa para incidentes dirigidos a Sandy;
- ningún template V3 sustituye al anterior ni se usa hasta estar aprobado por Meta.

## 7. Correlación con la solicitud exacta de EasyBroker

### 7.1 Identidad externa correcta

- `contact_request.id` identifica la solicitud sobre la que se ejecutan nota y cambio de estado.
- `contact_id` identifica a la persona y se persiste como `eb_person_contact_id`; sólo es una señal de identidad y no identifica una solicitud concreta.
- El nombre `conversations.eb_contact_id` es legado y actualmente contiene un request ID pese a su nombre; V3 no reutiliza esa columna con una semántica nueva.
- Cada solicitud descargada se persiste por `eb_request_id = contact_request.id` y con evidencia sanitizada.
- El checkpoint pertenece a la cuenta/fuente de ingestión, no a una fila individual. Internamente usa watermark, solapamiento temporal y dedupe por `eb_request_id`; sólo avanza después de persistir un lote completo.

### 7.2 Condiciones para autocorrelacionar

Una correlación automática requiere simultáneamente:

1. propiedad pública EasyBroker exacta;
2. al menos una identidad exacta comparable, teléfono o email normalizado;
3. ninguna identidad comparable contradictoria;
4. diferencia temporal dentro de una ventana calibrada con datos reales;
5. exactamente un candidato válido;
6. relación uno-a-uno entre solicitud EasyBroker y evento capturado.

La correlación puede ocurrir mientras la subasta sigue abierta; no espera al responsable final. El responsable sólo habilita el cierre. El nombre del prospecto y el tiempo por sí solos nunca autorizan una escritura.

Normalización exacta:

- email: `trim` + minúsculas;
- teléfono: E.164 con país explícito; un número ambiguo, una extensión no separable o un país inferido sin evidencia no se usa como identidad;
- un campo ausente no contradice;
- si ambos lados tienen un teléfono o email comparable y alguno contradice, no hay auto-link.

### 7.3 Resultados de correlación

| Resultado | Acción |
|---|---|
| Un candidato exacto | Crear vínculo durable e inmutable con el `contact_request.id`. |
| Cero candidatos antes de cubrir el horizonte calibrado | `awaiting_eb_request`; no alertar ni escribir todavía. |
| Cero candidatos después de que el checkpoint cubrió el horizonte completo | `manual_review:no_eb_request`; no escribir ni marcar `Atendida`. |
| Más de un candidato | `manual_review:ambiguous`; alertar y no elegir arbitrariamente. |
| Solicitud ya vinculada | Devolver el vínculo anterior o conflicto explícito; nunca reasignarla silenciosamente. |

Motivos sanitizados mínimos:

- `missing_property`
- `no_eb_request`
- `property_mismatch`
- `identity_mismatch`
- `time_outside_window`
- `ambiguous`
- `already_linked`

`awaiting_responsible` es un estado del cierre, no un motivo de fallo de correlación.

## 8. Cierre final en EasyBroker

Cuando existen responsable final y solicitud exacta correlacionada, cada `eb_request_id` se cierra por separado aunque varios requests compartan persona, propiedad u oportunidad:

1. agregar exactamente una nota:

   ```text
   RESPONSABLE: <primer nombre canónico>
   ```

2. marcar la misma solicitud como `Atendida`;
3. registrar evidencia independiente para la nota y para el estado.

La nota sólo contiene el primer nombre canónico del dashboard. Ejemplo válido: `RESPONSABLE: Sandy`.

Los efectos son idempotentes e independientes:

- si la nota existe pero falta `Atendida`, se reintenta sólo `Atendida`;
- si `Atendida` existe pero falta la nota, se reintenta sólo la nota;
- si ambos existen, no se repiten;
- si falla la correlación, no se ejecuta ninguno.

Política de reintento acordada para errores técnicos: intento inicial y deadlines absolutos de reintento a +1, +5, +15 y +30 minutos desde el primer fallo. Un worker de efectos revisa los deadlines al menos cada minuto. Tras agotarlos, el request permanece visible como no resuelto y se alerta a Sandy una sola vez. Una ambigüedad de correlación alerta inmediatamente porque repetirla no la corrige; la ausencia temporal de un request sigue en `awaiting_eb_request` hasta cubrir su horizonte.

## 9. Alertas y evidencia

- Las alertas se almacenan primero en una cola durable y después se intenta enviarlas por WhatsApp a Sandy.
- Fallar el WhatsApp de alerta no borra la alerta durable.
- Cada transición conserva: IDs internos y externos, timestamps con zona, estado anterior/nuevo, intento, WAMID cuando exista, actor/responsable y motivo sanitizado.
- No se almacenan secretos en logs ni reportes.
- El dashboard debe distinguir `cero verificado`, `pendiente`, `falló` y `dato no disponible`.

## 10. Matriz de decisiones

| Escenario | Decisión |
|---|---|
| Propietario válido y entrega demostrada | Esperar hasta 5 minutos por `Tomo`. |
| Propietario toma primero | Asignar propietario y cerrar rondas. |
| Propietario no toma | Ofrecer a la única guardia vigente. |
| Propietario no existe/no coincide/no está activo | Ir a guardia sin esperar 5 minutos. |
| Propietario Meta `failed`, incluido rechazo reportado como error | Ir a guardia inmediatamente. |
| Propietario llega a `read` sin `delivered` previo | Tratar como entregado sin reiniciar/extender el reloj existente. |
| Propietario sin callback al cumplirse 2 minutos desde aceptación del proveedor | Ir a guardia con motivo técnico en el siguiente ciclo del sweeper. |
| Guardia toma primero | Asignar guardia y cerrar rondas. |
| Guardia no toma | Asignar Sandy. |
| Guardia inválida o inexistente | Asignar Sandy inmediatamente. |
| Propietario y guardia son la misma persona | Omitir ronda duplicada; asignar Sandy al vencer propietario. |
| Sandy es propietaria y toma | Sandy gana como propietaria. |
| Sandy es propietaria y no toma | Continuar a guardia; sólo vuelve como fallback si nadie toma. |
| Dos clics simultáneos | Sólo el primer commit válido gana. |
| Clic de botón viejo o usuario distinto | Rechazar sin cambiar responsable. |
| Duplicado activo persona+propiedad | No abrir ni reenviar subasta. |
| Recurrente ya asignado persona+propiedad | Mantener responsable anterior y notificar directamente. |
| Misma persona, otra propiedad | Abrir nueva oportunidad. |
| Solicitud EasyBroker todavía no visible dentro del horizonte | Esperar sin escribir ni alertar. |
| Solicitud EasyBroker ambigua o ausente después del horizonte | No escribir; revisión manual y alerta. |
| Falla un efecto EasyBroker | Reintentar sólo el efecto faltante; no reabrir asignación. |

## 11. Criterio de éxito por lead

Un lead es `CORRECTO` sólo cuando existe evidencia verificable de:

1. captura durable;
2. Inmuebles24 en `Contactado`;
3. una sola decisión final: propietario, guardia o Sandy;
4. evidencia real de la ruta de WhatsApp aplicable, incluidos delivery/clic/escalación;
5. vínculo con el `contact_request.id` exacto de EasyBroker;
6. una sola nota `RESPONSABLE: <nombre>`;
7. la misma solicitud en `Atendida`;
8. cero asignaciones, notas o cierres incorrectos/duplicados.

Si alguno falta, el resultado no puede reportarse como éxito completo. Debe distinguirse entre pendiente, revisión manual, fallo técnico y evidencia no disponible.

## 12. Fuera de alcance de V3

- Integración con Toco u otro sistema externo adicional.
- Mensajes automáticos al prospecto.
- Subasta masiva o simultánea a varios agentes.
- Guardia de respaldo.
- Fuzzy matching de nombres o interpretación de múltiples tags por propiedad; si ocurre la anomalía se falla cerrado hacia guardia.
- Reapertura de oportunidades ya asignadas por fallas de sistemas externos.
- Escrituras basadas solamente en nombre, tiempo o `contact_id`.

## 13. Gates de autorización

Este contrato no autoriza:

- crear o enviar el template real de Meta;
- enviar WhatsApp de prueba o producción;
- cambiar datos en Inmuebles24 o EasyBroker;
- ejecutar migraciones en Supabase;
- publicar o activar workflows n8n;
- reiniciar servicios de Raspberry Pi;
- desplegar código.

Cada acción real se realizará únicamente dentro del plan aprobado y con el gate explícito correspondiente, incluida una autorización inmediata antes de cualquier prueba que transmita datos reales a Meta o a un CRM.

## 14. Decisiones abiertas

No quedan decisiones funcionales abiertas. Durante la ejecución deben verificarse, sin reinterpretar el negocio:

- un lote representativo sanitizado de 20–50 pares conocidos I24↔EasyBroker, con positivos, repetidos, negativos, zonas y delays, para calibrar la ventana temporal;
- una respuesta sanitizada de propiedad EasyBroker para congelar el origen de los ocho campos del mensaje;
- la aprobación de `lead_subasta_v3`, `lead_asignado_v3` y `alerta_routing_v3` por Meta;
- las versiones activas y publicadas de los workflows n8n;
- los IDs reales de las migraciones nuevas generados por la CLI;
- la evidencia del canary autorizado antes del rollout general.
