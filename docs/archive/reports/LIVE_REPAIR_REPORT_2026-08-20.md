# Reparación y auditoría en vivo — Lead Routing V2

Fecha: 2026-08-20  
Sistema: Inmobiliaria24 / Inmuebles24 / n8n / Supabase / WhatsApp Cloud API

## Veredicto

Lead Routing V2 quedó operativo para prospectos nuevos de Inmuebles24. La ruta real `sin tag/owner -> guardia primaria -> Sandy` fue observada con entregas confirmadas por Meta. EasyBroker continúa pausado.

La ruta `tag reconocido -> propietario` está publicada y validada estructuralmente, pero no fue ejercida por los prospectos auditados porque ninguno traía `property_public_id` ni tag de EasyBroker. No se inventó propietario.

## Errores encontrados y resueltos

1. WF12 fallaba con `there is no parameter $2` al resolver el primer tag de propiedad. Se corrigió el binding de `property_public_id` y `tags_pg`. Versión publicada: `a38b2424-6e76-4ccb-860a-90c30d2d7ef5`.
2. Meta rechazaba ofertas interactivas fuera de la ventana de 24 horas con error `131047`. WF13 ahora usa la plantilla aprobada `lead_subasta_notify`; WF1 reconoce el código de toma `TOMO-V2-<oportunidad>-<nivel>`. Versiones publicadas: WF13 `d44e6e34-c9be-4e5b-9e64-aa5d854f3632`; WF1 `6b8541fa-06a7-4672-bcb1-bd58ca351ab3`.
3. WF10 perdía `conversation_id`, `opportunity_id` y `property_public_id` después de consultar safe mode. Se corrigió la consulta para preservar ese contexto. Versión publicada: `98c2c26c-abea-4267-a657-64370fefa225`.
4. Los reintentos de entregas fallidas necesitaban conservar el historial. La migración `0042_retry_failed_guard_delivery.sql` crea intentos nuevos e idempotentes sin reescribir intentos ni callbacks anteriores.

Ejecuciones de error asociadas: WF10/WF12 `527087/527088`, `527421/527422`, `527479/527480`; WF10 `527723`. No aparecieron errores posteriores de Lead Routing en la auditoría final. El error más reciente de n8n era de otro sistema: `Content Generation - Vive Healthy`, ejecución `527730`.

## Evidencia de prospectos

| Oportunidad | Prospecto I24 | Propiedad I24 | Tag/owner | Resultado observado |
|---|---:|---:|---|---|
| 416 | 265216743 | 148537145 | Sin código/tag; owner no resoluble | Lety entregado; luego Sandy entregado; sin claim; alerta final |
| 417 | 265224871 | 150398087 | Sin código/tag; owner no resoluble | Lety entregado; luego Sandy entregado; sin claim; alerta final |
| 418 | 265226017 | 148421650 | Sin código/tag; owner no resoluble | Registro rezagado recuperado idempotentemente; Lety entregado; luego Sandy entregado; SLA de Sandy abierto al corte |
| 419 | 265234670 | 150012140 | Sin código/tag; owner no resoluble | Lety entregado; luego Sandy entregado |
| 420 | 265240039 | 148245016 | Sin código/tag; owner no resoluble | Prospecto nuevo posterior al arreglo: enrutamiento automático, Lety y Sandy entregados; sin claim; alerta final |

Entregas confirmadas por Meta:

- 416: intentos `37` y `39`; callbacks sent/delivered `35/36` y `39/40`.
- 417: intentos `38` y `40`; callbacks `37/38` y `41/42`.
- 419: intentos `41` y `43`; callbacks `45/46` y `49/50`.
- 420: intentos `42` y `44`; callbacks `47/48` y `51/52`.
- 418: intentos `45` y `46`; callbacks `53/54` y `57/58`.

No hubo claims aceptados ni solicitudes duplicadas. La ausencia de claim significa que ningún asesor respondió con el código de toma durante su SLA; no significa fallo de entrega.

Alertas finales confirmadas por proveedor, un solo intento cada una: `3` (416), `4` (417), `5` (419) y `6` (420).

## Estado operativo

- Activos: WF1, WF7, WF10, WF12, WF13, WF19, WF22, WF23, WF3b y WF3c.
- Pausados: WF8 y WF8b de EasyBroker.
- `safe_mode=normal`.
- Guardia vigente: Lety primaria; Sandy (`agent_manager`) respaldo.
- Duplicados por `client_request_id`: `0`.
- El scraper sigue corriendo: run `5062` terminó `ok`, revisó 5 registros y detectó 1 nuevo; ese prospecto produjo la oportunidad automática 420. El run posterior `5063` también terminó `ok` y no encontró prospectos nuevos.

## Horarios de referencia

- Oportunidad 420 creada: 15:03:23 CDMX / 23:03:23 París.
- Mensaje a Lety entregado: 15:03:57 CDMX / 23:03:57 París.
- Mensaje a Sandy entregado: 15:10:58 CDMX / 23:10:58 París.
- Oportunidad 418 recuperada; mensaje a Lety entregado: 15:13:57 CDMX / 23:13:57 París; mensaje a Sandy entregado: 15:20:58 CDMX / 23:20:58 París.

## Validaciones y artefactos

- Verificador local WF10: `WF10_CONTEXT_FIX_PASS`.
- Verificador del export vivo: `contextQueryExact=true`, `credentialsPreserved=true`, 29 nodos.
- `git diff --check` de los archivos afectados: PASS.
- Validación transaccional de migración 0042 en PostgreSQL 17 y en producción con ROLLBACK previo: PASS.
- `graphify update .`: no pudo ejecutarse por el error ambiental existente `uv trampoline failed to canonicalize script path`; no invalida las verificaciones dinámicas anteriores.
- Backup previo y exports de WF10: `backups/lead-routing-v2/20260820T205139Z/n8n/`.

## Seguridad pendiente

La llave API de n8n fue compartida en el chat y debe rotarse. También conviene rotar la contraseña de base de datos por precaución. Ningún secreto se reproduce en este reporte.
