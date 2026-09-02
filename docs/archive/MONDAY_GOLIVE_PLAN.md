# Plan Go-Live Lunes — BYG (inmuebles24 + EasyBroker en vivo)

Demo con la clienta: ÉXITO (subasta → claim → datos del lead → seguimiento ciclo completo). Data demo limpia. Estado actual: 0 leads, 0 agentes en turno, Pi NO en vivo, EasyBroker NO en vivo.

## ⚠️ PRERREQUISITO CRÍTICO (antes de poner el Pi en vivo)
**Cablear los templates aprobados en los nodos de envío (text → template).**
- Hoy todos los envíos proactivos son `type:"text"`. Funcionan SOLO dentro de la ventana 24h.
- En el demo funcionó porque tu teléfono tenía la ventana abierta. **Los asesores reales NO tendrán ventana abierta** cuando entre un lead → el aviso de subasta **fallará en silencio** (error 131047, lo traga `continueOnFail`) → el lead se pierde.
- Por eso: ANTES del Pi en vivo, cambiar a `type:"template"` los nodos proactivos: WF3a (subasta), WF14 (seguimiento), WF3c (escalación manager), WF16 (reporte). Templates ya aprobados es_MX: `lead_subasta_notify`, `lead_seguimiento_prompt`, `lead_escalacion_manager`, `reporte_semanal_marusa`.
- La confirmación de claim (WF3b) y respuestas dentro de 24h se quedan `type:"text"`.
- **Esto es trabajo de dev (~2-3h). Sin esto, el go-live del lunes falla en silencio.**

## LUNES — Pasos (config/ops)

### 1. Calendario (clienta)
- La clienta/Marusa llena `/calendario` con los turnos reales de la semana (mañana/tarde por asesor).
- WF6 sincroniza `agents.on_shift` desde el calendario automáticamente a las **08:00 / 14:00 / 21:00 MX**. (Para activar de inmediato un turno, se puede correr WF6 manual o esperar al siguiente corte.)
- Aliases de propiedad (owner routing) ya cargados: 8 agentes / 14 tags. Ajustar en `/agentes` si falta alguno.

### 2. Pi en vivo (cada 15 min)
En el Raspberry Pi (`/opt/inmobiliaria24`):
1. `systemctl status gost-proxy.service` — el proxy mobile MX debe estar arriba (sin esto, Cloudflare bloquea).
2. Verificar `.env`: `INMUEBLES24_EMAIL`, `INMUEBLES24_PASSWORD`, `WEBHOOK_URL=https://n8n.srv856940.hstgr.cloud/webhook/scraper-leads`, `CHROME_PROXY=127.0.0.1:18080`.
3. Smoke test: `cd /opt/inmobiliaria24 && .venv/bin/python -m inmobiliaria24 --limit 1`.
4. Cambiar cadencia a 15 min: `sudo systemctl edit --full inmobiliaria24.timer` → `OnCalendar=*-*-* *:00/15:00`.
5. (Opcional) limpiar `data/state.db` si quieren capturar los Pendientes actuales.
6. `sudo systemctl daemon-reload && sudo systemctl enable --now inmobiliaria24.timer`; verificar `systemctl list-timers | grep inmobiliaria`.
7. Vigilar primeras 2-3 corridas: `journalctl -u inmobiliaria24 -f` + ejecuciones WF10 en n8n.

### 3. EasyBroker en vivo
- **Requiere construir WF8b primero** (~1 día de dev — ver `EASYBROKER_AUCTION_PROPOSAL.md`): revivir WF8, Cloud API, filtro `source!='Inmuebles24'`, owner-first, dedup Postgres. **No estará listo el lunes salvo que se construya antes.**
- Una vez construido: setear env `EASYBROKER_API_KEY`, activar WF8b (polling 15 min), smoke test con 1 lead real EB (source MLS/web).

### 4. Smoke test final (lunes, con asesores en turno)
- Esperar/forzar 1 lead real de inmuebles24 → confirmar subasta → un asesor real toma → recibe datos → seguimiento.
- Idem EasyBroker cuando WF8b esté vivo.

## Resumen de dependencias
| Item | Estado | Bloquea |
|---|---|---|
| Templates aprobados | ✅ es_MX | — |
| **Templates cableados en nodos** | ❌ pendiente (dev ~2-3h) | **Pi y EB en vivo** |
| Owner-first desplegado | ❌ (hoy subasta plana) | mejora, no bloquea |
| WF8b EasyBroker | ❌ por construir (~1 día) | EB en vivo |
| Calendario lleno | ⏳ lunes (clienta) | que haya asesores en turno |
| Pi 15 min | ⏳ lunes (config) | leads inmuebles24 |

## Para terminar limpio: 2 tareas de dev que conviene hacer ANTES del lunes
1. **Cablear templates** (~2-3h) — sin esto el lunes falla en silencio.
2. **Construir WF8b EasyBroker** (~1 día) — para que EB entre el lunes.

Owner-first (opcional): la clienta quedó feliz con la subasta plana; owner-first es mejora posterior.

## Pendientes de higiene
- Rotar API keys filtradas en chat: n8n + EasyBroker.
- Pushear nada nuevo (todo commiteado/pusheado).
