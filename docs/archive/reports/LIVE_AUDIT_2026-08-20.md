# Auditoría en vivo — Lead Routing V2

Fecha de revisión: 2026-08-20. Ventana auditada desde 2026-08-18 14:20 UTC.

## Veredicto

NO-GO para afirmar que la promesa al cliente está funcionando de extremo a extremo.

- El Pi detectó 15 prospectos nuevos y n8n aceptó 14 solicitudes HTTP con respuesta 200 (una solicitud contenía más de un prospecto).
- Los 15 registros quedaron en `manual_non_deduplicable`; ninguno generó conversación, revisión de propiedad/tag, resolución de propietario, guardia, claim o mensaje WhatsApp.
- Causa confirmada: el Pi entrega teléfonos con formato `525...`; la versión activa de WF10 exige que el valor original comience literalmente con `+`. Los teléfonos se convierten a `identity_phone=null` y la ruta los clasifica como `invalid_or_missing_e164_phone`.
- Perfil de los registros: 14 conservaron email y uno quedó sin identidad; 0 conservaron teléfono enrutable, propiedad, identificador de portal o conversación.

## Estado de componentes

- WF7, WF10, WF12, WF13, WF22, WF23, WF3b, WF3c y WF19: activos.
- WF10 activeVersionId: `3ca10f1c-1c8c-40c1-b572-07d90d4386c2`.
- EasyBroker WF8 `ZI5mD6269xSZhltN` y WF8b `Mu3YTTH8IgtaH7Ml`: inactivos.
- Pi `inmobiliaria24.timer`: activo y habilitado, 08:00–20:00 CDMX cada 15 minutos; `easybroker.timer`: inactivo y deshabilitado.
- Supabase: `safe_mode=normal`; 0 entregas, callbacks, claims, alertas, colas o pendientes al corte.

## Errores observados

- WF23: ejecuciones `525511`, `525657`, `525659`, `522038`, `522040`, `522042` con timeout al pooler o crash.
- WF3c: ejecuciones `525656`, `525660`, `522039`, `522041` con timeout al pooler o crash.
- Los fallos recientes ocurrieron aproximadamente entre 01:01 y 01:08 CDMX / 09:01 y 09:08 París. No había entregas pendientes, por lo que no se observó pérdida adicional.
- El Pi tuvo cinco corridas fallidas por autenticación del portal; posteriormente se recuperó. Desde la activación terminó 95 corridas, detectó 15 prospectos nuevos y no registró fallos del webhook.

## Clasificación

- P0 funcional: prospectos reales aceptados por el webhook no llegan a routing ni WhatsApp por incompatibilidad de formato telefónico.
- P1 operativo: fallos repetidos de conexión de WF23/WF3c con Supabase.
- Ruta positiva observada: ninguna.
- Ruta configurada pero no ejercida: propiedad/tag → propietario → WhatsApp; missing owner → primaria → Sandy.

Esta auditoría fue exclusivamente de lectura. No se modificó producción ni se enviaron mensajes.
# REPORTE SUPERADO

Este corte fue previo a la reparación. El estado vigente está documentado en `LIVE_REPAIR_REPORT_2026-08-20.md`.
