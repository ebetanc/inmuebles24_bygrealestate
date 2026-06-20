# E2E Test Plan — TOMO Lead Follow-up (agent = tu número)

Date: 2026-06-20
Channel: Meta WhatsApp Cloud API (post-migration)

## Roles
- **AGENT** = tu WhatsApp `33628457768` (ya registrado como `agent_test_fr`). Recibe WhatsApp real.
- **LEAD** = número dummy `5215500000001` (simulado: yo hago POST al webhook como si fuera el lead; los envíos del bot al lead NO entregan — se verifican en DB).
- **BOT** = `5215620516625` (Cloud API).

## Por qué LEAD simulado
Tienes 1 solo número. No puede ser lead y agente a la vez (WF1 lo clasificaría como agente). Entonces el lead es un número dummy y yo inyecto sus mensajes vía webhook (idéntico a lo que manda Meta). El bot intenta responderle (queda logueado) aunque no entregue a un número falso.

## Pre-flight (yo)
1. Purgar data de prueba vieja (conversación `544cad05` Mario Arroyo, auction BB0F, followups) → pizarra limpia.
2. `agent_test_fr`: `on_shift=true`, `is_available=true`. Confirmar que NINGÚN otro agente esté on-shift (para que solo tú recibas el fan-out).
3. **Tú**: manda cualquier WhatsApp al bot al empezar → abre ventana 24h (necesaria para que TOMO/follow-ups proactivos te lleguen, porque el número está en tier LIMITED).

## Etapas

### 1. Extracción de lead → subasta
- Yo hago POST a WF10 (`/webhook/scraper-leads`) con un lead sintético (phone=dummy, listing real de `listings` si hay, o inventado).
- **Espera**: WF10 crea conversación (día→`pending_assignment`+ llama WF3a; noche→cola). WF3a crea auction `TOMO-XXXX` + fan-out a agentes on-shift → **te llega WhatsApp**: "Nuevo lead… responde TOMO-XXXX".
- **Éxito**: fila en `conversations` + `auctions(status=open)`; recibiste el WhatsApp.

### 2. Claim
- Tú respondes `TOMO-XXXX` al bot.
- **Espera**: WF1→WF3b atomic claim → `auction.status=claimed`, `conversation.assigned_agent_id=tú`, `mode=ai`. Recibes confirmación "Ganaste el lead…".
- **Éxito**: auction claimed, conversación asignada+ai, te notificó.

### 3. Lead conversa (modo AI)
- Yo POST como lead: "Hola, sigue disponible? cuánto es la renta?".
- **Espera**: WF1 ai_conversation → WF4 (OpenRouter `anthropic/claude-sonnet-4`) genera respuesta → envía al lead (no entrega, dummy) + loguea.
- **Éxito**: WF4 success, respuesta AI logueada en `messages` (outbound).

### 4. Handoff a humano
- Yo POST como lead algo que requiere humano: "quiero agendar visita mañana 5pm".
- **Espera**: AI marca `needs_handoff` → WF5 → `mode=human` → te llega resumen + aviso.
- **Éxito**: `mode=human`, te notificó con resumen.
- ⚠️ **GAP A CONFIRMAR**: en modo human, lead→agente se reenvía, pero agente→lead NO tiene ruta en WF1 (tus mensajes que no son TOMO van a WF15 follow-up, no al lead). A validar si es bug o diseño (agente contacta al lead por fuera).

### 5. Cadencia de follow-up (el "seguimiento hasta el final")
- Disparo WF14 manual (en vez de esperar el cron cada 2h) → te manda "¿cómo va el lead X?".
- Tú respondes en lenguaje natural: "ya lo contacté, agendamos visita el sábado".
- **Espera**: WF1 agent_followup_reply → WF15 → LLM parsea → `lead_status.stage` avanza (new→contacted→visit→…).
- Repetir por etapas: "fue a la visita, le gustó" → "está negociando" → "se cerró, rentó".
- **Éxito**: `lead_status.stage` avanza correcto en cada respuesta.

### 6. Cierre
- Tú: "se cerró la venta / ya rentó" → stage=won/closed.
- **Éxito**: stage final; `leads_needing_followup` ya no lo incluye (no más nudges).

## Observabilidad (yo monitoreo cada etapa)
- n8n `execution_entity`/`execution_data` (success/error por workflow).
- Supabase: `conversations`, `auctions`, `messages`, `lead_status`, `lead_followups`.

## Riesgos conocidos
- **Proactivo (TOMO + follow-up)** depende de tu ventana 24h abierta (número LIMITED + display name DECLINED). Mantente mandando algo cada <24h.
- Envíos bot→lead (dummy) no entregan — solo verifico en DB.
- Gap agente→lead en modo human (etapa 4) — a discutir.
- Calidad AI (WF4) según modelo OpenRouter.

## Teardown
Purgar conversación/auction/followups del test + restaurar `agent_test_fr` shift al estado previo.

## Decisiones a confirmar contigo
1. **Lead**: ¿simulado (dummy, recomendado) o corremos el scraper real del Pi? (real = riesgo de contactar prospecto real, hay que override del phone).
2. **Disparo follow-up**: ¿WF14 manual (rápido) o esperamos el cron real?
3. **Gap agente→lead** (etapa 4): ¿lo investigamos/arreglamos ahora o lo anotamos y seguimos?
