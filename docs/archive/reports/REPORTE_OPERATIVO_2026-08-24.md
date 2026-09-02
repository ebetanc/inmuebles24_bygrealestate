# Reporte operativo final — subasta de leads

**Periodo:** 2026-08-24 00:00:00–23:59:59, `America/Los_Angeles`  
**Equivalente UTC auditado:** 2026-08-24 07:00:00–2026-08-25 06:59:59  
**Modo:** solo lectura; no se reintentaron ejecuciones ni se enviaron WhatsApp, Gmail, webhooks o datos reales.

## Veredicto

**CON FALLAS; operación parcialmente verificable.**

- n8n registró **45 incidentes** en los workflows objetivo: **9 `crashed`** y **36 `error`**.
- WF3c/WF23 sí se recuperaron y tuvieron una ventana comprobada de **225 ejecuciones `success`** después de la reparación, pero hubo otra falla DNS de WF3c a las 18:57 PT.
- No se puede certificar cuántos leads o subastas completaron el flujo extremo a extremo: la mayoría de los workflows guarda errores pero no éxitos (`saveDataSuccessExecution=none`) y el conector Supabase disponible solo expone **GAD Clocking App**, que no corresponde a Inmobiliaria24.
- Por lo tanto, ausencia de filas para WF1/WF3b/WF7/WF10/WF12/WF13/WF22 **no significa cero ejecuciones**.

## Inventario de ejecuciones retenidas

| Workflow | Estado y cantidad | IDs / ventana UTC |
|---|---:|---|
| WF20 `pYV88ntxI0Lc4NCB` | 62 success | `541575–548221`; 07:00:00–06:55:00 |
| WF21 `He95yJflKVspGFyb` | 45 success | `541804–546930`; 07:11:30–01:57:50 |
| WF23 `MjfHw3tYE2qYgJfM` | 2 crashed | `541798`, `541802`; 07:07:00 y 07:08:00 |
| WF23 | 56 success | `545429–545696`; 20:39:00–21:34:00 |
| WF23 | 6 running al cierre | `548217–548239`; 06:54:00–06:59:00 |
| WF3c `UNIKqyAvIUAZkNIs` | 7 crashed | `541795–541803` excluyendo los dos IDs de WF23; 07:06:15–07:08:15 |
| WF3c | 36 error | `544777–546929`; 18:15:30–01:57:45 |
| WF3c | 169 success | `545428–545704`; 20:38:45–21:34:45 |
| WF3c | 19 running al cierre | `548216–548242`; 06:53:45–06:59:45 |
| WF6 `LHQukWVhcmSfPwQb` | 3 success | `543555–547198`; 14:00:00–03:00:00 |
| WF1, WF3b, WF7, WF10, WF12, WF13, WF22 | sin filas retenidas | falta de retención; no demuestra cero actividad |

No aparecieron estados retenidos `canceled`, `waiting` o `queued` dentro del periodo. Las 25 filas `running` de los últimos minutos del día no tienen `stoppedAt`; con `saveDataSuccessExecution=none` son ambiguas y no deben contarse como 25 trabajos realmente bloqueados.

## Incidente de medianoche

Todos estos crashes quedaron como `WorkflowCrashedError: Workflow did not finish, possible out-of-memory issue`:

| Hora PT | ID | Workflow | Último nodo |
|---|---:|---|---|
| 00:06:15 | 541795 | WF3c | Advance Expired Tiers |
| 00:06:30 | 541796 | WF3c | Claim Unassigned Alert Lease |
| 00:06:45 | 541797 | WF3c | Claim Pending Guard Deliveries |
| 00:07:00 | 541798 | WF23 | Sweep Delivery Timeouts |
| 00:07:15 | 541799 | WF3c | Advance Expired Tiers |
| 00:07:30 | 541800 | WF3c | Claim Unassigned Alert Lease |
| 00:07:45 | 541801 | WF3c | Claim Pending Guard Deliveries |
| 00:08:00 | 541802 | WF23 | Sweep Delivery Timeouts |
| 00:08:15 | 541803 | WF3c | Advance Expired Tiers |

La etiqueta “possible out-of-memory” es genérica de n8n; **no prueba un OOM del kernel**. Los logs del contenedor muestran la secuencia observable:

- 00:04:15: task offer expiró sin ser aceptado.
- 00:06:05 y 00:06:10: el runner tardó demasiado en aceptar tareas.
- 00:07:40: conexión abortada.
- 00:08:27: conexión agotó timeout.
- 00:11:06: `Last session crashed`.
- 00:11:16–00:11:25: n8n inicializó, quedó listo y registró un nuevo JS runner.
- 00:11:50–00:11:57: se reactivaron los workflows de Inmobiliaria24.

**Causa demostrada:** atasco del task runner junto con fallos de conexión; OOM real no confirmado.

## Fallas posteriores de WF3c

| Hora PT | Cantidad / IDs | Nodo | Mensaje |
|---|---|---|---|
| 11:15:30–12:28:30 | 30; `544777–545223` | WhatsApp Sandy Unassigned Alert | `Invalid URL: =https://...` |
| 12:31:30 y 12:34:30 | `545233`, `545246` | WhatsApp Sandy Unassigned Alert | JSON Body no válido |
| 12:37:30, 12:39:30, 12:42:30 | `545258`, `545267`, `545282` | WhatsApp Sandy Unassigned Alert | Meta HTTP 404; plantilla solicitada no encontrada |
| 18:57:45 | `546929` | ruta de segundo 45; por grafo corresponde a `Claim Pending Guard Deliveries` | log exacto: `The DNS server returned an error, perhaps the server is offline` |

La atribución del último nodo de `546929` es una inferencia explícita y sólida: comenzó exactamente en el offset `:45`, y la definición publicada conecta `Guard Delivery Schedule` directamente con `Claim Pending Guard Deliveries`. Se evitó una segunda lectura pesada de SQLite para no aumentar la carga live.

WF21 terminó 45 veces en `success`, el mismo número que la suma de crashes y errores, por lo que el manejador recibió los incidentes; esto no demuestra que todos los correos hayan sido recibidos por una persona.

## Reparación y ventana saludable comprobada

- Se corrigió el doble prefijo `=` de URL/expresiones y después el JSON del nodo WhatsApp.
- La plantilla inexistente se sustituyó por la plantilla históricamente aceptada `nuevo_lead_i24`, idioma `es_MX` y parámetros compatibles.
- El usuario actualizó la credencial `Postgres account BYG project`; n8n mostró `Connection tested successfully`.
- Un preflight de la base correcta comprobó las cinco funciones consultadas y, a las 13:41:50 PT, devolvió cero en colas/leases/alertas/duplicados abiertos.
- Entre 13:38:45 y 14:34:45 PT quedaron retenidas **169 ejecuciones success de WF3c** y **56 de WF23**, sin nuevos `error/crashed` en esa ventana.
- La retención de éxitos volvió después a `none`; por eso esa ventana no puede extrapolarse al resto del día.

## Versiones y publicación

Los 12 workflows fueron vistos `active=true` en el chequeo live autenticado. Versiones finales o últimas verificadas:

| Workflow | ID | Versión activa/publicada o efectiva |
|---|---|---|
| WF1 | `snF6Sr9CBJIevMVD` | `335da4a3-3400-4356-b170-0988adfcebc1` |
| WF3b | `JM2HxJxl53k4zlki` | `b5e05cf4-0d69-4709-a2ed-f101e205bb8e` |
| WF3c | `UNIKqyAvIUAZkNIs` | final re-descargada activa `432e5ce1-899f-467c-aa35-658e091da7d5`; versión corregida previa `831da332-8450-48ae-bc2b-382b24f5eda3`; ejecuciones healthy retenidas en draft `af99a375-69ca-4f82-a102-61cf2646c145` |
| WF6 | `LHQukWVhcmSfPwQb` | `ec06e3f1-7a0b-49b4-854a-38a3ccc38c62` |
| WF7 | `xzBG0GIsHCUd44DC` | `899f7389-1143-4728-a632-faf1fe89109a` |
| WF10 | `Obr38705ZZYS3FB8` | `6e968814-2c76-4f27-9895-4e7a154e9991`, publicado 23:27 PT |
| WF12 | `w7yJr7naWoxPq6Pw` | `efa0890f-dc8d-4ed1-ac0b-5cc3756f500a` |
| WF13 | `Bo2YbbUpmBzRbhDa` | `c09427a4-82ba-464e-b250-92d25d7d9e98` |
| WF20 | `pYV88ntxI0Lc4NCB` | activa `4bab3892-4b30-4aa2-96b8-13cfd00a8b78`; draft `95784492-6c43-4714-bf13-99bca4f70d8a` no demostrado publicado |
| WF21 | `He95yJflKVspGFyb` | `da1296bd-174f-454a-8bd1-14d902fb3ca4` |
| WF22 | `Z89IQDw1fgWlqXEW` | `18f1e246-0afd-4e53-ac5d-a9bf60e69587` |
| WF23 | `MjfHw3tYE2qYgJfM` | `activeVersionId` verificado `7741b8fc-224f-4e95-b358-2b5563d82f5a`; definición/ejecución efectiva `4777492e-6238-4c61-9f6f-7f3388ec1dfa` |

La divergencia entre `activeVersionId` y la versión efectiva de WF23 debe permanecer visible: no es correcto reducirla a una sola versión sin explicar ambas superficies de n8n.

## Offsets

- WF23: `0 * * * * *`.
- WF3c Advance: `15 * * * * *`.
- WF3c Unassigned Alert: `30 * * * * *`.
- WF3c Guard Delivery: `45 * * * * *`.

Los offsets `0/15/30/45` están confirmados en la definición publicada y en los timestamps de ejecución.

## Métricas de leads y subastas

| Métrica solicitada | Resultado verificable del día |
|---|---|
| Leads entrantes / clasificados | **No verificable**: WF10 success no se retiene y no hay Supabase correcto en el conector |
| Dedupe / duplicados | Cero **solo en snapshot 13:41:50 PT**; total diario no verificable |
| Owner resuelto / ruta dirigida | No verificable |
| Guardia primaria / respaldo | No verificable |
| Sin asignar / expirados / alertas | Cero **solo en snapshot 13:41:50 PT**; total diario no verificable |
| Colas y night queue | Cero **solo en snapshot 13:41:50 PT**; cierre 23:59 no verificable |
| Leases vencidos / entregas pendientes | Cero **solo en snapshot 13:41:50 PT**; cierre no verificable |
| WhatsApp sent/delivered/read | No verificable sin callbacks de la base correcta |
| Claims / ganador único | No verificable |

El snapshot puntual comprobó:

`expired_routing=0`, `guard_delivery_pending=0`, `expired_delivery_leases=0`, `sent_without_callback=0`, `open_unassigned_alerts=0`, `claimable_unassigned_alerts=0`, `night_queue_pending=0`, `expired_night_leases=0`, `active_duplicate_groups=0`.

No se consultó GAD Clocking App.

## Acciones concretas

1. Dar al auditor acceso **read-only** al Supabase correcto de Inmobiliaria24 o publicar una función KPI diaria sin PII; sin eso no existe certificación E2E.
2. Mantener telemetría verificable: `saveDataSuccessExecution=all` durante una ventana controlada o persistir contadores operativos externos; `none` impide distinguir éxito de ausencia.
3. Investigar el DNS/pooler que causó `546929`; aplicar retry solo a operaciones seguras e idempotentes y conservar timeout acotado.
4. Resolver y documentar la divergencia `activeVersionId`/versión efectiva de WF23.
5. Publicar y verificar WF20 solo si se aprueba su draft corregido; hoy la versión activa anterior produjo 62 ejecuciones y no es evidencia de subasta.
6. Con autorización inmediata, ejecutar un único lead sintético E2E: intake, dedupe, owner, primary, backup, claim, callbacks y limpieza. Esta auditoría no lo hizo porque implicaría mensajes/datos reales.
7. No reintentar ninguna ejecución histórica.

## Evidencia local

- `backups/live-readonly-20260824T221753Z/README.md`
- `backups/live-readonly-20260824T221753Z/published/WF3c_published.json`
- `backups/live-readonly-20260824T221753Z/WF23_live.json`
- `backups/live-wf10-template-fix-20260825T0605Z/WF10_after_publish.json`
- `whatsapp-agent/workflows/WF3c_expiry_sweeper.json`

Graphify fue intentado primero y falló con `uv trampoline failed to canonicalize script path`; se usó revisión directa de los artefactos y evidencia live de solo lectura.
