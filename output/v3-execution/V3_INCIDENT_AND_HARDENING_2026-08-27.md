# Lead Routing V3 — incidente, correcciones y estado de reactivación

**Fecha:** 2026-08-27  
**Zona operativa:** `America/Mexico_City`  
**Veredicto actual:** `PARCIAL — producción estabilizada; WF23 permanece inactivo hasta gate explícito y canary real`.

## 1. Incidente observado

Entre `2026-08-27T17:29:30Z` y `2026-08-27T17:45:00Z`
(`11:29:30–11:45:00` CDMX) se observaron:

- 31 errores de WF23;
- 31 errores de WF3c;
- 62 ejecuciones de WF21 que enviaron 62 correos de error;
- 62 mensajes WhatsApp duplicados a Sandy, cada uno con WAMID distinto.

La causa fue doble:

1. WF23 reclamaba intentos `sent/requested` antiguos aunque la oportunidad ya
   estuviera asignada o hubiera avanzado de tier.
2. La rama `assigned` de WF3c atravesaba el aviso antiguo a Sandy y después un
   nodo de confirmación inválido por una conexión JSON duplicada.

WF23 se despublicó durante la contención y no se ha reactivado.

## 2. Correcciones aplicadas

- WF3c: la asignación Sandy termina en la transición durable y el aviso se
  procesa como `assigned_notice`, sin pasar por la alerta antigua.
- WF23: el timeout exige oportunidad V3 no asignada, intento vigente y tier
  coincidente. La RPC de claim recibió una migración incremental equivalente.
- Supabase `20260827184755`: aplicada a
  `wkaeutndwawkdhswisqe` el `2026-08-27T18:53:21.806328Z`; RPC `SECURITY
  INVOKER`, sin ejecución para `anon/authenticated`, seis guardas verificadas y
  cero candidatos vigentes al aplicar.
- WF21: dedupe por firma durante 15 minutos y tope global de tres correos por
  cada ventana de 15 minutos.
- WF22: respuesta 200 para payloads vacíos/desconocidos, soporte `read`, rutas
  explícitas 500 para fallos de procesamiento y lectura correcta del body
  binario para verificar `X-Hub-Signature-256`.
- Exports WF22/WF23: `activeVersion` embebida se eliminó para no importar una
  foto publicada obsoleta.

## 3. Estado productivo verificado

Auditoría n8n `2026-08-27T19:23:23.336052Z`:

| Workflow | ID | Estado | Versión activa/publicada |
| --- | --- | --- | --- |
| WF21 | `He95yJflKVspGFyb` | activo | `67cba6ae-e466-4c13-8ee3-152c11a71cdc` |
| WF22 | `Z89IQDw1fgWlqXEW` | activo | `19f8ecec-6b65-4ee2-88ba-0bcee9651d0f` |
| WF23 | `MjfHw3tYE2qYgJfM` | **inactivo** | `activeVersionId = null` |

WF22 tiene registrados GET y POST en
`/webhook/whatsapp-delivery-status`. La prueba GET devolvió el challenge exacto
y un POST vacío con firma HMAC válida devolvió HTTP 200 sin crear efectos de
lead.

Después del hotfix, Meta entregó 28 eventos reales, todos procesados una sola
vez: 4 `sent`, 9 `delivered` y 15 `read`; fallidos/exhausted = 0. Esto prueba
que la validación de firma y el procesamiento durable funcionan.

Desde el hotfix hasta `2026-08-27T19:23:23Z`:

- WF21: cero ejecuciones/correos de error;
- WF23: cero ejecuciones;
- WF22: cero filas retenidas como error o running en la ventana final.

Respaldos VPS relevantes:

- `/root/backups/wf21-wf22-safety-pre-20260827T190159Z`
- `/root/backups/wf21-wf22-safety-post-20260827T190159Z`
- `/root/backups/wf22-signature-fix-pre-20260827T191552Z`
- `/root/backups/wf22-signature-fix-post-20260827T191552Z`

## 4. Evidencia de pruebas

- Suite completa: `305 passed, 2 xfailed, 415 warnings` en `1.57 s`.
- JUnit: `output/v3-execution/pytest-full.xml`.
- Graphify: `55,919` nodos, `131,833` aristas, `1,994` comunidades.
- Supabase claim seguro:
  `output/v3-execution/supabase-safe-offer-claim-apply.json`.
- n8n posterior al hotfix:
  `output/v3-execution/n8n-post-hotfix-audit-20260827T192323Z.json`.
- callbacks Meta:
  `output/v3-execution/meta-callback-audit-20260827T192452Z.json`.
- avisos asignados 179/180:
  `output/v3-execution/assigned-notice-audit-20260827T192619Z.json`.

## 5. Lo que todavía no puede declararse correcto

- WF23 sigue inactivo por seguridad; por tanto la subasta automática no está
  operando de punta a punta todavía.
- Los avisos asignados 179/180 permanecen `sent`/Meta-accepted, sin callback
  `delivered`; no se reenvían porque hacerlo duplicaría un envío ambiguo.
- Los leads 489/490 no tienen una solicitud EasyBroker exacta correlacionada;
  no se puede escribir nota ni marcar `Atendida` sin inventar una solicitud.
- Falta un canary real nuevo que pruebe, para un lead elegible: `Contactado` →
  WhatsApp dirigido → responsable final → nota única EasyBroker → `Atendida`.

## 6. Gate restante

La siguiente acción productiva requiere la orden explícita `REACTIVA WF23`.
Después de esa orden se debe:

1. activar WF23 con una sola versión publicada;
2. verificar inmediatamente que no reclama filas antiguas;
3. observar un lead nuevo real sin reintentar ejecuciones anteriores;
4. demostrar cada efecto del criterio de éxito V3;
5. desactivar y hacer rollback si aparece cualquier duplicado, error o claim
   fuera del intento vigente.
