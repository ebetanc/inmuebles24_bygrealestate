# Rotación de secretos filtrados — checklist

Generado por auditoría de código+infra el 2026-07-06. **Ningún secreto fue rotado** —
esto es el mapa de "dónde vive cada uno" y los pasos exactos para rotarlos sin
romper nada. Tiempo estimado: ~10 min por secreto si sigues el orden.

Regla general: rota primero en el proveedor (EasyBroker / Meta / n8n), copia el
valor nuevo, actualízalo en TODOS los consumidores listados abajo, y solo
entonces verifica. Si actualizas un consumidor y no otro, ese componente queda
roto con un secreto viejo revocado.

---

## 1. EasyBroker API key

**Dónde vive (2 consumidores reales, confirmado por grep + inspección de n8n):**

1. VPS n8n (`root@69.62.108.2`, contenedor `root-n8n-1`) — `/root/docker-compose.yml`,
   variable `EASYBROKER_API_KEY` en texto plano dentro del bloque `environment:`
   del servicio `n8n`. La consumen (vía `{{ $env.EASYBROKER_API_KEY }}` en headers
   HTTP) los workflows: `WF8 - EasyBroker Contact Polling`, `WF8b - EasyBroker Lead
   Intake`, `WF3b - Claim Handler` (patch de contacto), `WF18 - EB Owner Sync`.
2. Dashboard (Next.js en Vercel, proyecto `dashboard`, `prj_VHgIXrAqUPgVDNLdX9R4wAjRYx9o`,
   team `team_2DypbUIAyfX1kqhAD4tNmUZA`) — env var `EASYBROKER_API_KEY`, leída en
   `dashboard/src/app/api/easybroker/contacts/route.ts:14`. Copia local en
   `dashboard/.env.local` (gitignored, no está en el repo).

**NO está** en el `.env` del Pi (`/opt/inmobiliaria24/.env`) — ese archivo solo
tiene `EASYBROKER_EMAIL`/`EASYBROKER_PASSWORD` para el login UI del bot de
Buzón, que es un mecanismo separado y no se ve afectado por esta rotación.

### Pasos

1. Entra a `https://app.easybroker.com` → Configuración de cuenta → API →
   regenera/rota el API key. Copia el valor nuevo.
2. VPS: `ssh root@69.62.108.2` (o vía Pi como jump: `ssh esteban@100.88.225.103`
   luego `sshpass -p '<pass del Pi: /root/.vps_pass>' ssh root@69.62.108.2`),
   edita `/root/docker-compose.yml`, reemplaza el valor de `EASYBROKER_API_KEY=`
   en el bloque del servicio `n8n`, luego:
   ```
   cd /root && docker compose up -d n8n
   ```
   (esto reinicia solo el contenedor n8n con el env var nuevo; no toca los
   otros ~250 workflows de otros clientes que corren en el mismo compose).
3. Vercel: `vercel env rm EASYBROKER_API_KEY production` seguido de
   `vercel env add EASYBROKER_API_KEY production` con el valor nuevo (o desde
   el dashboard: vercel.com → team → proyecto `dashboard` → Settings →
   Environment Variables), luego redeploy (`vercel --prod` o desde el dashboard).
4. Local: actualiza `dashboard/.env.local` a mano (no se commitea, solo para
   dev local).

### Verificación

- En n8n UI (`https://n8n.srv856940.hstgr.cloud`), ejecuta manualmente
  `WF8 - EasyBroker Contact Polling` → debe traer contactos sin error 401.
- Abre el dashboard en prod → sección EasyBroker/contactos → debe cargar sin
  error 500/401 en la Network tab.

---

## 2. Meta / WhatsApp Cloud API

**Dónde vive (1 solo consumidor, confirmado):** VPS n8n, mismo
`/root/docker-compose.yml`, bloque `environment:` del servicio `n8n`:
- `WA_ACCESS_TOKEN` — token de acceso (el secreto real a rotar)
- `WA_PHONE_NUMBER_ID` — no es secreto, es el ID del número, no cambia al rotar
- `WA_VERIFY_TOKEN` — string arbitrario elegido por nosotros (`byg_wa_verify_2026`),
  no lo emite Meta; solo debe coincidir entre este env var y la config del
  webhook en Meta.

Lo consumen (headers `Authorization: Bearer {{$env.WA_ACCESS_TOKEN}}` contra
`graph.facebook.com`) los workflows: WF1, WF2, WF3a, WF3c, WF4, WF5, WF7, WF8,
WF8b, WF10, WF13, WF14, WF15, WF16 (todos los nodos "Send ... via
Evolution"/"Send to Owner (Cloud API)" pese al nombre "Evolution" heredado del
proveedor viejo — ya usan Graph API de Meta directamente).

**Nota importante:** no encontramos ningún "Meta App Secret" (el usado para
verificar la firma HMAC de webhooks, `X-Hub-Signature-256`) configurado en
ningún lado del repo ni de n8n — solo el `WA_ACCESS_TOKEN`. Si el secreto que
se filtró es específicamente el App Secret (no el access token), confírmalo
antes de rotar: probablemente solo aplica al Access Token de abajo, y el App
Secret en sí no está en uso activo (revísalo en el dashboard de Meta de
cualquier forma, por higiene).

**Pi `.env` y `server.py`:** el Pi NO tiene `WA_ACCESS_TOKEN` ni
`WA_WEBHOOK_VERIFY_TOKEN` configurados (confirmado, 0 matches). `server.py`
tiene su propio `WA_WEBHOOK_VERIFY_TOKEN` con default `"inmobiliaria24_verify"`,
pero el servicio systemd correspondiente (`inmobiliaria24-server.service`) no
está activo en el Pi — no es un consumidor real en producción hoy. Si en algún
momento se activa ese servicio, agrégalo a este checklist.

### Pasos

1. `https://developers.facebook.com` → tu App → WhatsApp → API Setup → genera
   un token de acceso nuevo (permanente, vía System User si ya está
   configurado así, o temporal + luego permanente).
2. VPS: mismo archivo `/root/docker-compose.yml`, reemplaza `WA_ACCESS_TOKEN=`,
   luego `cd /root && docker compose up -d n8n`.
3. Si además rotas el App Secret desde Meta (Configuración → Básica → Restablecer
   secreto de la app): esto invalida TODOS los tokens de acceso emitidos con la
   app anterior, así que genera el token de acceso nuevo *después* de resetear
   el App Secret, no antes.
4. Si cambias `WA_VERIFY_TOKEN`, actualízalo también en la config del webhook
   en Meta (App → WhatsApp → Configuration → Webhook → Verify token) para que
   coincidan.

### Verificación

- Manda un WhatsApp de prueba al número de negocio → confirma que `WF1 -
  Inbound Router` lo recibe (revisa ejecuciones en n8n).
- Ejecuta manualmente `WF13` o `WF3a` contra una conversación de prueba →
  confirma que el mensaje saliente llega (sin error 401/190 de Graph API en
  el log de ejecución de n8n).

---

## 3. n8n API key

**Corrección de un hallazgo previo:** una auditoría anterior concluyó que no
existía ninguna n8n API key guardada en ningún lado — **eso ya no es cierto**.
Consultando `user_api_keys` en el sqlite de n8n (`/var/lib/docker/volumes/n8n_data/_data/database.sqlite`,
solo lectura, sin exponer valores) aparecen **14 keys activas**, todas bajo el
mismo usuario admin (`df13e6c2-...`) — este n8n es compartido entre ~250
clientes y no hay separación de permisos: cada key tiene scopes de
administrador total (crear/borrar workflows, credenciales, usuarios, etc.)
sobre **todo el servidor**, no solo BYG.

De esas 14, el naming sugiere que estas 6 son las de este proyecto (búscalas
en n8n UI por estos labels exactos):

| Label | Creada |
|---|---|
| `byg_api` | 2026-04-30 |
| `byg_project` | 2026-05-08 |
| `inmuebles` | 2026-06-14 |
| `inmuebles 2` | 2026-06-20 |
| `inmuebles3` | 2026-06-23 |
| `inm3` | 2026-06-23 |

Las otras 8 (`MCP Server API Key`, `backup_api`, `voice control center 2`,
`chirey_voice_control`, `360 kommo`, `Vivian Community`, `yael_mkt`, `chirey2`)
tienen nombres de otros clientes/proyectos — **no las toques** salvo que tú
mismo confirmes que también son tuyas y las reusas entre proyectos.

**Hallazgo adicional:** encontré una copia en texto plano de una de estas keys
(formato JWT, `jti e1b750e2-5c83-4771-8731-521ae9efa6d9`, generada ~2026-07-02)
en `C:\Users\esteb\AppData\Local\Temp\n8nkey.txt` — la usaba
`deploy_owner_first.py` (`KEY = open(os.path.join(os.environ["TEMP"],
"n8nkey.txt")).read().strip()`). **Ya la borré** durante esta auditoría (era
una copia local sin cifrar de un secreto vivo, cero riesgo borrarla). No pude
determinar sin exponer el valor cuál de las 6 keys de la tabla es exactamente
esa — por eso la recomendación es revocar las 6, no solo una.

### Pasos

1. `https://n8n.srv856940.hstgr.cloud` → Settings → n8n API (o API Keys) →
   busca cada uno de los 6 labels de la tabla → Revoke/Delete en cada una.
2. Si algún script local (`deploy_owner_first.py`,
   `whatsapp-agent/scripts/deploy_node.py`, `deploy_wf10_c2.py`,
   `update_wf2.py`) necesita seguir usando la API de n8n, genera **una key
   nueva** con scopes acotados si la versión de n8n lo permite (esta instancia
   ya tiene columna `scopes`/`audience`, así que sí soporta API keys con
   permisos limitados — úsalo en vez de repetir el patrón de key
   todopoderosa). Guárdala en un archivo local nuevo, nunca la pegues en el
   chat ni la commitees.
3. Considera además si vale la pena, a futuro, mover
   `/root/docker-compose.yml` a usar un `.env` separado (con permisos 600) en
   vez de tener los 6+ secretos en texto plano dentro del compose — no es
   parte de esta rotación, pero reduce el radio de exposición la próxima vez
   que alguien necesite pegar ese archivo en un chat de soporte.

### Verificación

```
curl -H "X-N8N-API-KEY: <key-vieja>" https://n8n.srv856940.hstgr.cloud/api/v1/workflows
```
Debe devolver 401 después de revocar. Con la key nueva (si generaste una),
el mismo curl debe devolver 200.
