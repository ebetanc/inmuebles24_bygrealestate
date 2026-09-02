# Reparación live WF23 / WF3c — 2026-08-23

## Diagnóstico confirmado

- WF23 `MjfHw3tYE2qYgJfM`
  - Ejecuciones `529544` y `529546`: `Sweep Delivery Timeouts` — `Connection timed out`.
  - Ejecuciones `536748` y `536750`: estado `crashed`; `536750` terminó en `Sweep Delivery Timeouts` con `Workflow did not finish, possible out-of-memory issue`.
- WF3c `UNIKqyAvIUAZkNIs`
  - Ejecuciones `529545` y `529547`: `Claim Pending Guard Deliveries` — `Connection timed out`.
  - Ejecuciones `536749` y `536752`: estado `crashed`; último nodo `Claim Pending Guard Deliveries`, con posible out-of-memory.

## Cambios publicados

- WF21 Error Handler
  - Version activa/publicada: `da1296bd-174f-454a-8bd1-14d902fb3ca4`.
  - Fallbacks seguros para workflow, nodo, execution ID, mensaje y URL.
- WF23 Delivery Timeout Sweeper
  - Version activa/publicada: `7741b8fc-224f-4e95-b358-2b5563d82f5a`.
  - Barrido en segundo `0` de cada minuto.
  - Eliminados tres nodos inalcanzables sin efecto runtime.
- WF3c Tiered Escalation Sweeper
  - Version activa/publicada: `e7724afe-5776-45ee-afa8-6ba6b1176314`.
  - Advance: segundo `15`.
  - Claim de alertas: segundo `30`.
  - Claim de guardias: segundo `45`.
  - Retry limitado a `Record Retryable Unassigned Alert`: maximo 3 intentos, espera 5 segundos.
  - Sin retry automatico de Gmail, WhatsApp, claims, barridos ni ejecuciones antiguas.

Las credenciales live se preservaron durante el despliegue. El token temporal no se guardó en archivos.

## Backups

- `backups/live-sweeper-repair-2026-08-23T18-08-55-136Z`
- `backups/live-sweeper-repair-2026-08-23T18-09-53-566Z`

Cada backup contiene definiciones `before` y, cuando la API completó el cambio, definiciones `after`.

## Verificación

- WF21, WF23 y WF3c: `active=true`.
- En los tres: `activeVersionId == versionId`.
- Source/export local: JSON válido y paridad de nodos, conexiones y settings.
- Validador estático n8n:
  - WF21: 0 errores, 0 warnings.
  - WF23: 0 errores, 0 warnings.
  - WF3c: 0 errores, 0 warnings.
- Varias ventanas de cron posteriores al despliegue: sin nuevas ejecuciones guardadas en estado `error` o `crashed`.
- Flujos principales live activos/publicados: WF1, WF3b, WF3c, WF6, WF7, WF10, WF12, WF13, WF20, WF21, WF22 y WF23.
- WF20 Watchdog registró ejecuciones exitosas cada 30 minutos hasta `2026-08-23T18:00:00Z`.

## Supervisión del 24 de agosto

Automación Codex: `subasta-leads-preflight`.

Tres gates en zona local America/Los_Angeles:

- 05:30
- 08:30
- 10:30

Cada gate revisa activación/publicación, errores nuevos, estados crashed/canceled/waiting/queued, versiones WF23/WF3c, offsets, colas, leases, duplicados y alertas pendientes cuando exista acceso DB. No envía mensajes reales ni reintenta ejecuciones antiguas.

## Límite operativo

No existe garantía técnica de cero fallos externos: n8n/Hostinger, Supabase, Meta, Gmail y red pueden fallar. La reparación elimina la ráfaga conocida, mejora recuperación segura y deja detección temprana. Después de rotar la API key, el conector n8n usado por Codex debe recibir la nueva key para que la supervisión autenticada funcione.
