# Lead Routing V3 — auditoría preactivación

Verificación de solo lectura realizada el `2026-08-27` antes de autorizar la
reactivación de WF23.

## Resultado

- WF13, WF21, WF22 y WF3c continúan activos con la versión publicada esperada.
- WF23 continúa inactivo, con `activeVersionId = null`.
- Desde `2026-08-27T19:15:52Z`, WF21 y WF23 tienen cero ejecuciones y cero
  errores retenidos. No reapareció el bombardeo.
- n8n conserva 10 filas de WF22 como `running`; no se interpretan como éxito.
- La evidencia durable de Supabase registra 49 callbacks posteriores al hotfix:
  9 `sent`, 21 `delivered` y 19 `read`.
- Los 49 callbacks están `processed`, con máximo un intento y sin códigos de
  error. No hay callbacks `pending`, `leased`, `failed` ni `exhausted`.

## Evidencia

- `output/v3-execution/n8n-preactivation-audit-20260827T194344Z.json`
- `output/v3-execution/meta-preactivation-audit-20260827T194541Z.json`

## Gate

La subasta automática aún no está activa. La siguiente acción productiva es
publicar/reactivar WF23 y observar un lead nuevo real. Requiere la orden
explícita `REACTIVA WF23`; cualquier claim antiguo, duplicado o error obliga a
desactivar inmediatamente y restaurar el respaldo.
