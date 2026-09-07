# Demora de Uriel y omisión de Fabiola — 2026-09-07

## Evidencia

Horas CDMX (UTC−6). La hora de llegada y respuesta humana proviene de las
capturas entregadas por el usuario; los pasos posteriores, de Supabase y journal
de la Pi consultados durante esta revisión.

| Paso Uriel | Hora |
|---|---|
| Mensaje original del prospecto | 08:00, captura del usuario |
| Captura durable 304, oportunidad 783, solicitud I24 266475678 | 08:02:21.459637 |
| Contactado verificado | 08:02:40.741123 |
| Respuesta humana | 08:05, captura del usuario |
| Liberación nocturna | 08:05:00.329077 |
| Scraper falla: panel/permissionserror; menú autenticado pero panel no listo | corridas 08:15 y 08:19 |
| Solicitud de oferta al dueño, intento 415 | 08:32:04.846626 |
| Meta acepta | 08:32:06.511730 |
| Meta confirma delivered | 08:32:09.838554 |
| Marusa acepta; asignación final | 08:32:59.601726 |
| Nota RESPONSABLE verificada en ledger | 08:34:32.801882 |
| Atendida verificada en ledger | 08:35:26.439353 |

Un solo intento de entrega consultado para Uriel, a nivel owner. La espera de
27 minutos entre liberación y envío ocurrió antes de Meta: el despacho estaba
dentro de async_main, después de autenticar y recorrer el portal. Un fallo de
sesión bloqueaba trabajos ya verificados. La regla SQL viva retiene hasta las
08:05, incluida una captura a las 08:02; no es un error de conversión de zona.

Fabiola: solicitud I24 **266475835**, propiedad **149622600**, llegada 08:04 según
captura del usuario. En inspección posterior de solo lectura, su fila está
Contactado. No existe captura para ese external_event_id. Las corridas exitosas
posteriores leyeron cero pendientes. La lista original excluye Contactado; no hay
evidencia del actor ni de la hora exacta del cambio. No atribuirlo a una asesora
específica ni reenviar como si nadie la atendiera.

## Corrección

1. Consumidor independiente `python -m inmobiliaria24.dispatch`, cada minuto por
   systemd, usando las mismas reservas y la misma clave `v3-route:<capture>`.
   No abre navegador. La captura conserva 15 minutos y el reparto conserva sus
   rondas y horarios. El camino inmediato al terminar Contactado sigue vigente.
2. Reconocer explícitamente permissionserror como página inválida y comprobar
   la ruta autenticada Interesados antes de forzar login. La inspección viva
   comprobó que esa ruta sí permite leer las filas del portal.
3. Comparación de todas las filas Contactado observadas contra capturas V3:
   advertencia persistida en los logs de corrida, con IDs exactos, sin inferir
   quién atendió ni emitir otra oferta. Consulta limitada a la cuenta y fuente.

## Validación y límites

- Suite local completa: 304 passed, 2 xfailed; incluye despachar con navegador
  inutilizable, no repetir la captura terminada, recuperación de Interesados y
  detección de Contactado sin escritura ni reasignación.
- No se modifica SQL ni n8n. No se reabre Uriel ni se envían mensajes de prueba.
- La espera de detección del portal sigue siendo de hasta un ciclo de 15 minutos,
  más extracción. No equivale a captura instantánea.
- Fabiola requiere confirmar quién ya la atiende antes de un rescate específico.
- Los avisos de observación van a scrape_logs; no son WhatsApp nuevos a Sandy.
- Despliegue y corridas posteriores deben verificarse por separado: tests no
  prueban una entrega nueva de WhatsApp.

## Reversión

Desactivar inmobiliaria24-dispatch.timer y esperar a que termine el servicio;
restaurar archivos del respaldo previo del incidente. El consumidor original del
scraper sigue existiendo. Conservar capturas, reservas, asignaciones y perfiles.
