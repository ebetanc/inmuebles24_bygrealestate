# Preflight live n8n — WF23 / WF3c

Fecha UTC: 2026-08-23T17:44:28.5887705Z  
Alcance: solo lectura. Sin retry de ejecuciones, sin activar/desactivar, sin updates, sin secretos.

## Objetivos  

- WF23: `MjfHw3tYE2qYgJfM`
- WF3c: `UNIKqyAvIUAZkNIs`
- Intentar respaldo live de definiciones y consultar 3 ejecuciones recientes por workflow.

## Evidencia exacta

### Vía MCP n8n

`n8n_health_check({})` respondió:

- `success: true`
- `status: ok`
- `apiUrl: https://n8n.srv856940.hstgr.cloud`
- `mcpVersion: 2.73.0`

Lecturas intentadas (una por operación y workflow):

- `n8n_get_workflow({id:"MjfHw3tYE2qYgJfM",mode:"full"})`
- `n8n_get_workflow({id:"MjfHw3tYE2qYgJfM",mode:"active"})`
- `n8n_executions({action:"list",workflowId:"MjfHw3tYE2qYgJfM",limit:3,includeData:false})`
- `n8n_get_workflow({id:"UNIKqyAvIUAZkNIs",mode:"full"})`
- `n8n_get_workflow({id:"UNIKqyAvIUAZkNIs",mode:"active"})`
- `n8n_executions({action:"list",workflowId:"UNIKqyAvIUAZkNIs",limit:3,includeData:false})`

Las seis respondieron exactamente:

```text
success: false
error: Failed to authenticate with n8n. Please check your API key.
code: AUTHENTICATION_ERROR
```

Resultado: no se pudo respaldar definición live ni obtener IDs, mensajes, nodos o ejecuciones live.

### Vía directa local

Se ejecutó `.codex-tmp/read_n8n_metadata.mjs` una vez, sin imprimir variables de entorno ni secretos. Falló antes de respuesta HTTP:

```text
TypeError: fetch failed
code: EACCES
syscall: connect
port: 443
```

Resultado: la red del proceso local impide conexión saliente; no constituye evidencia de estado n8n.

## Artefactos

- Este informe: `preflight_live_WF23_WF3c_20260823T174428Z.md`
- No se creó backup live: autenticación n8n no autorizada.
- Backups locales históricos existentes no se presentan como live actual.

## Bloqueo

Bloqueo único: credencial/API key n8n configurada en el conector no autentica (`AUTHENTICATION_ERROR`). La vía directa además tiene `EACCES` de red. Próximo paso operativo requiere restaurar acceso autenticado; no repetir ejecuciones antiguas ni mutar workflows.
