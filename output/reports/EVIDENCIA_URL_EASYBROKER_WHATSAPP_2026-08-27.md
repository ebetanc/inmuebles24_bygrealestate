# Evidencia — URL de EasyBroker en WhatsApp

Fecha de verificación: 27 de agosto de 2026.

## Resultado

La corrección está publicada en producción en n8n. WF10 conserva los datos del inmueble, WF12 obtiene de EasyBroker el `public_url` y los datos comerciales reales, y WF13 exige una URL HTTPS de EasyBroker antes de construir o enviar el template `lead_subasta_v3`.

Si falta el ID público o EasyBroker no devuelve un URL válido, el flujo falla cerrado y no llama a Meta. La validación no envió WhatsApp, no agregó notas y no modificó solicitudes reales.

## Versiones activas verificadas

| Workflow | ID | Versión activa | Estado |
|---|---|---|---|
| WF10 | `Obr38705ZZYS3FB8` | `d4cbb829-6bb0-4095-9e0b-02d787883e99` | Activo |
| WF12 | `w7yJr7naWoxPq6Pw` | `f5042c41-22ae-4245-a8d2-847edefd0f79` | Activo |
| WF13 | `Bo2YbbUpmBzRbhDa` | `103aa634-b699-47e6-bf21-518ef1f9baf3` | Activo |

En los tres casos, `activeVersionId` coincide con `versionId`. El endpoint de salud respondió `{"status":"ok"}`.

Respaldo previo al cambio: `/root/n8n-url-fix-backup-20260827T205750Z`.

## Prueba real de datos, sin envío

Se hizo un GET de solo lectura a EasyBroker para `EB-WT7538` y se ejecutó el JavaScript publicado de WF12 → WF10 → WF13 sin invocar Meta.

Resultado exacto que produciría el template:

```text
🏠 Nuevo lead

Prospecto: Prospecto de evidencia
Teléfono: +52XXXXXXXXXX

Propiedad: PRIVADA EXCLUSIVA DE 5 CASAS, EN BOSQUES DE LAS LOMAS CON CANCHA DE TENIS
Operación: Venta / Renta
Zona: Bosque de las Lomas, Miguel Hidalgo, Ciudad de México
Precio: $38,000,000 MXN / $200,000 MXN
ID: EB-WT7538
EasyBroker: https://www.easybroker.com/mx/listings/privada-exclusiva-de-5-casas-en-bosques-de-las-lomas-con-cancha-de-tenis-d16b424f-dcb3-4447-a831-3b6d5c16f6bb

Tienes 5 minutos para aceptarlo.
```

La prueba confirmó:

- tag propietario: `Marusa`;
- template: `lead_subasta_v3`;
- 8 parámetros, en el orden aprobado;
- `missing_url_blocked=true`;
- `provider_called=false`;
- `whatsapp_sent=false`;
- ningún secreto fue impreso.

## Verificación automatizada

- Pruebas enfocadas: `23 passed, 1 warning`.
- Suite completa: `307 passed, 2 xfailed, 415 warnings`.
- Todos los nodos Code modificados compilan como JavaScript válido.

## Raspberry Pi

La misma validación temprana del `property_public_id` está implementada en el código local del scraper. Su copia a Raspberry Pi está pendiente porque Tailscale SSH exige reautenticación. Esto no deja abierto el envío: la barrera de n8n ya publicada impide que cualquier mensaje sin URL válido alcance Meta.
