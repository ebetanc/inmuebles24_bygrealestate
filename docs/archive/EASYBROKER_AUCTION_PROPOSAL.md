# Propuesta — Subastar también leads de EasyBroker

Objetivo: que los leads que llegan a EasyBroker (web de la agencia + otros portales) entren al mismo motor de subasta WhatsApp que hoy usan los leads de inmuebles24.

## Estado actual
- **inmuebles24:** scraper (Pi) → WF10 → ruteo owner-first → subasta TOMO.
- **EasyBroker:** ya existe **WF8 "EasyBroker Contact Polling"** que hace casi todo... pero está **dormido** y desalineado:
  - Polling `GET /contact_requests` cada 15 min, dedup por `lastEbContactId` (en memoria de n8n).
  - Normaliza y **sí manda a subasta**, pero al **WF3a viejo (plano)**, no al owner-first (WF12→WF13) que usa el scraper hoy.
  - Usa **Evolution API** (no Meta Cloud API) y credencial Postgres placeholder.
  - Sin export `live_` → no está en el set desplegado.

## Realidad de la API EasyBroker (investigado)
- **NO hay webhooks.** Único camino = **polling** `GET /contact_requests` con cursor `happened_after` + dedup por `id`. Latencia ≈ intervalo de polling.
- Cada lead trae: `id`, `name`, `phone`, `email`, `property_id` (EB-XXXX), `message`, `source`, `happened_at`, `contact_id`. **Todo lo que la subasta necesita.**
- Rate limit 20 req/s (sobra). Base prod `api.easybroker.com`, staging `api.stagingeb.com` (llaves distintas). Llave **por cuenta** (ve todos los leads de la agencia), no por agente → el ruteo por agente se deriva por propiedad (tags), que ya tienen resuelto.

## Riesgo principal: doble subasta — RESUELTO por el campo `source`
Validado contra la cuenta real (API key, 200 leads recientes). `GET /contact_requests` devuelve un `source` **confiable y enumerado** en esta cuenta:

| source | % (últimos 200) | ¿ya cubierto? |
|---|---|---|
| Inmuebles24 | 155 (77%) | ✅ por el scraper |
| MLS | 34 (17%) | ❌ net-new |
| Proppit by Lamudi | 6 (3%) | ❌ net-new |
| Pincali | 4 (2%) | ❌ net-new |
| Propiedades.com | 1 (<1%) | ❌ net-new |

**Solución limpia:** WF8b subasta solo `source != 'Inmuebles24'`. Eso da exactamente "los otros leads" (~23%: MLS + Lamudi + Pincali + Propiedades.com) **sin doble-subasta**, porque los de inmuebles24 ya entran por el scraper.

**Cinturón + tirantes (defensa en profundidad):** además del filtro por source, conservar el check `find_returning_lead(phone,email,property_id)` antes de subastar → si el mismo teléfono+propiedad ya tiene conversación (cualquier source), cae como `returning_same` y no re-subasta. Cubre el caso raro de un lead que EB etiquete distinto.

Campos reales confirmados por lead: `id, name, phone, email, contact_id, property_id (EB-XXXX), message, source, happened_at (ISO8601 -06:00)`. Cursor de polling = `happened_at`. Historial total ≈ 26,228 contact_requests; último lead 2026-06-19.

## Propuesta de diseño (reutiliza el motor actual)
Revivir + modernizar WF8 → **"WF8b EasyBroker Lead Intake"**, espejo de WF10:
1. **Polling** `GET /contact_requests?happened_after=<cursor>` cada **15 min** (decidido — igual que el Pi; EasyBroker no tiene webhooks/triggers push, así que 15 min es la cadencia). Paginar hasta alcanzar el cursor. Límite 20 req/s no estorba.
2. **Filtro por source**: descartar `source = 'Inmuebles24'` (ya los trae el scraper); subastar el resto (MLS, Lamudi, Pincali, Propiedades.com, futuros).
3. **Dedup durable** por `contact_request.id` en **Postgres** (tabla nueva `eb_seen_contact`), no en memoria de n8n (sobrevive reinicios). Más el check `find_returning_lead` cross-source como respaldo.
4. **Ruteo owner-first idéntico al scraper:** producir el shape de `Prepare Routing Data` (con `property_public_id` + `conversation_id`) y llamar **WF12 → WF13** (owner 2 min) → fallback WF3a (guardia). Mismo claim/seguimiento/reporte que ya existe.
5. **Meta Cloud API** en los envíos (no Evolution) + credencial Postgres real.
6. `source='easybroker'` (ya soportado en el schema).

Resultado: leads de EB entran por el mismo flujo probado (subasta → claim → teléfono del lead → seguimiento → reporte a Marusa), sin reinventar nada.

## Dependencias / bloqueadores
- Mismo bloqueador de **templates Meta** para envíos proactivos (ya en trámite) — aplica igual a leads EB.
- Owner-first debe estar desplegado (hoy NO lo está en vivo — ver `GO_LIVE_READINESS`). WF8b dependería de WF12→WF13. Si owner-first no se construye, WF8b puede ir al WF3a plano (como ahora) de forma interina.
- `EASYBROKER_BASE` no está en `.env.example` (WF12 lo usa, WF8 hardcodea la URL) → estandarizar.

## Esfuerzo estimado
- WF8b (revivir + Cloud API + dedup Postgres + owner-first): ~0.5–1 día.
- Tabla dedup + ventana cross-source: ~2 h.
- Pruebas E2E (lead EB real → subasta → claim): ~2 h.

## Estado de inputs
- ✅ **API key** recibida y validada (solo lectura). ROTAR después (quedó en chat).
- ✅ **Cómo llegan los leads**: confirmado por datos — EB agrega inmuebles24 (77%), MLS (17%), Lamudi, Pincali, Propiedades.com. Los "otros leads" = todo menos inmuebles24.
- ✅ **Cadencia**: 15 min (decidido). Sin webhooks → polling.

## Decisión pendiente (1)
- **¿Qué sources subastar?** Recomiendo: TODOS menos `Inmuebles24`. (Alternativa: lista explícita, ej. solo MLS + web.) Confirmar.

## Bloqueadores compartidos (no específicos de EB)
- Templates Meta proactivos (en trámite).
- Owner-first desplegado (hoy no en vivo). Interino: WF8b → WF3a plano.
