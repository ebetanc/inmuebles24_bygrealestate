# Incidente de asignación y avisos — 31 de agosto de 2026

## Conclusión ejecutiva

La observación del cliente era correcta. El contacto sí llegaba de i24 a EasyBroker, pero una toma válida de guardia podía perderse y terminar mostrando `RESPONSABLE: Sandy`. Esa nota no fue generada por inteligencia artificial: la escribió el worker de EasyBroker de forma determinista después de que el flujo asignó incorrectamente el fallback de gerente.

La afirmación previa de que “todo estaba correcto” fue incorrecta. Se había comprobado estructura, activación y rutas nominales, pero no una interacción real que atravesara credenciales, deduplicación, restricciones append-only y reintentos. Eso permitió que un fallo de ejecución se confundiera con éxito operativo.

## Caso exacto reportado

- Oportunidad: `681`.
- Captura: `200` / solicitud i24 `265994338` / propiedad `EB-WR3892`.
- Guardia: Lety (`agent_lety`).
- Intento: `255`.
- Notificación entregada: `2026-08-31 16:38:06.590472Z`.
- Vencimiento: `2026-08-31 16:43:06.590472Z`.
- Clic `Tomo`: webhook `369`, recibido `2026-08-31 16:41:38.355Z` y persistido `16:41:38.363117Z`, aproximadamente 88 segundos antes del límite.
- WAMID entrante: `wamid.HBgNNTIxMjIyMjM5MzQxNhUCABIYFDNBQTRDRjBCMjIyRTU3MTVFNThFAA==`.
- WAMID de la oferta: `wamid.HBgNNTIxMjIyMjM5MzQxNhUCABEYEkJDOTUxNjY3NDVBM0E3OUNDRAA=`.
- Cadena n8n: WF22 `578239` → WF1 `578240` → WF3b `578241`.
- Fallo: WF3b terminó en 56 ms en `Claim V3 Delivery` con `Node does not have any credentials set`.
- Efecto: el clic válido no se convirtió en asignación; el reintento encontró el mensaje duplicado, salió antes del claim y WF22 marcó el webhook como procesado a `16:45:34.689994Z`.
- Resultado incorrecto: Sandy fue asignada a `16:43:30.120312Z` y EasyBroker recibió la nota en la solicitud `40549695`.

## Por qué dejaron de llegar avisos

Los últimos movimientos de las 13:54 correspondían a callbacks de estado/lectura de notificaciones anteriores; no eran solicitudes nuevas. El barrido WF23 mostró esperas de conexión Postgres de 133–143 segundos. Su timeout general de 20 segundos no interrumpía la adquisición de conexión, por lo que el flujo podía quedarse esperando y dejar de producir avisos.

## Reparaciones aplicadas

### Asignación y toma de guardia

- WF3b ahora ejecuta `claim_v3_delivery_from_webhook($1)` con `webhook_event_id` y la credencial Postgres correcta.
- WF1 revisa una toma V3 verificable antes de descartar un mensaje por duplicado.
- Versiones productivas publicadas:
  - WF1: `2cf5ba14-9486-4e17-8a54-10028d15bfb5`.
  - WF3b: `d56d93c0-4679-4900-9171-e61195613272`.
  - WF22: `19f8ecec-6b65-4ee2-88ba-0bcee9651d0f`.
- Backup n8n previo: `/root/backups/n8n-client-feedback-round3-pre-20260831T173407Z`.
- Backup n8n posterior: `/root/backups/n8n-client-feedback-round3-post-20260831T173407Z`.

### Base de datos y evidencia durable

- Migración base aplicada: `20260831170000_fix_v3_verified_webhook_claim_time.sql`.
- La revisión adversarial detectó antes de un clic real que esa primera versión intentaba actualizar el ledger append-only. Se corrigió con una migración nueva, sin reescribir la ya aplicada:
  - `20260831182500_fix_v3_append_only_claim_evidence.sql`.
  - SHA-256: `98c877506df0d532dfa9837d1e5e994da1bcb43bc28cf22e7ee87822c61f6e69`.
  - Aplicada a `2026-08-31 18:35:35.116848Z`.
- El claim utiliza la hora durable de ingreso del webhook y agrega un evento idempotente `claim_webhook_verified`; no modifica el ledger append-only.
- Backup/rollback: `backups/lead-routing-v3/20260831T183210Z/supabase/`.

### Corrección del caso del cliente

- Oportunidad `681` reconciliada a Lety con el tiempo original del clic válido.
- Estado final: `assigned`, tier `primary_guard`, responsable `agent_lety`, intento `255`.
- Eventos: `1636 accepted`, `1637 historical_assignment_reconciled`, `1639 provider_note_correction_verified`.
- EasyBroker solicitud `40549695`: se añadió `CORRECCIÓN OPERATIVA: la nota anterior "RESPONSABLE: Sandy" no aplica. Responsable confirmado: Lety.`
- Estado de EasyBroker conservado: `Atendida`.
- Evidencia en el runtime correcto: `/opt/inmobiliaria24/logs/easybroker-correction-40549695-20260831T175548Z.json`.
- SHA-256 de evidencia: `dd2efd700a289687d528ea47946fba3808070df549dde401222940dce32ff75e`.
- No se envió un WhatsApp adicional durante la corrección.

### Avisos y barrido WF23

- Los nodos Postgres de WF23 ahora tienen `connectionTimeout: 8` segundos para no quedar bloqueados durante minutos.
- Versión base: `056c7096-bf9e-484b-b958-2c42ea0cc4e4`.
- Versión productiva nueva: `1a88fb7e-d5d5-4102-866c-749d49157aca`; `current`, `published` y `activeVersionId` coinciden.
- Gate previo de Supabase a `2026-08-31 18:55:15.859112Z`: cero avisos accionables y cero avisos de asignación pendientes.
- Reinicio solicitado `18:56:08.851218Z` y completado `18:56:09.660725Z`; contenedor `Running=true`, `OOMKilled=false`.
- Monitor natural: `18:56:09.383387Z` → `19:01:34.371590Z`, 300.775 segundos y 148 muestras.
- Resultado del monitor: diez ciclos naturales exitosos, cero `error/crashed/canceled`, cero errores de conexión y cero errores ajenos a conexión.
- Snapshot final `19:05:42.315220Z`: cero ejecuciones vivas, cero fallos terminales y 18 ciclos naturales desde el reinicio.
- Backups/evidencia: `/root/backups/wf23-connection-timeout-pre-20260831T185543Z` y `/root/backups/wf23-connection-timeout-post-20260831T185543Z`.
- No se ejecutó manualmente el workflow, no se cambió SQL/RPC/cron y no se generó WhatsApp artificial.

## Verificación

- Suite local: `354 passed, 2 xfailed`.
- Prueba transaccional real bajo rol `service_role`, totalmente revertida:
  - primer claim `claimed`;
  - replay `already_assigned`;
  - exactamente un evento `accepted` y uno `claim_webhook_verified`;
  - el trigger append-only sigue habilitado y rechaza `UPDATE`;
  - el sweeper posterior conserva al asesor y no asigna Sandy;
  - HMAC, contexto, remitente, intento, vencimiento exacto y permisos negativos verificados.
- Tráfico natural posterior: la oportunidad `683` generó el intento `257`; Meta registró `sent` y `delivered` mediante webhooks `373` y `374` entre `18:05:43.015Z` y `18:05:43.661873Z`.
- No se generó tráfico artificial ni se reenvió una notificación para fabricar evidencia.

## Límite de la evidencia

La entrega natural posterior sí está comprobada. Todavía no ocurrió un nuevo clic humano natural después de la publicación, por lo que no se presenta la prueba transaccional ni la activación del workflow como si fueran un recorrido humano real de extremo a extremo. El próximo clic natural será la prueba operativa final de WF1 → WF3b.
