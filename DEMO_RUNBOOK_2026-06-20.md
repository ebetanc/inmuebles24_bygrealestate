# Runbook Demo en Vivo — BYG (2026-06-20, con tu teléfono)

Demuestra el flujo REAL desplegado: lead entra → subasta TOMO por WhatsApp → reclamo → el asesor recibe nombre + teléfono del lead → seguimiento. (Subasta plana a turno; owner-first es roadmap.)

Blast radius: SOLO `agent_test_fr` (Esteban, `33628457768`) está `on_shift` → la subasta DM solo a tu teléfono. Ningún asesor real ni Marusa recibe nada.

## PRE-FLIGHT (hacer ANTES de que llegue la clienta)
1. **Confirma** que `33628457768` es tu WhatsApp activo. (Si usas otro número, dime y lo pongo on_shift en vez de ese.)
2. **Abre tu ventana 24h**: desde tu teléfono manda CUALQUIER mensaje (ej. "hola") al número del bot BYG. Sin esto, el aviso proactivo de subasta falla en silencio (regla Meta 24h). Verifico que WF1 lo registró.
3. **Confirmo** que es horario "día" en la lógica de WF10 (si es noche, el lead va a cola nocturna y no subasta). Demo debe correr en horario hábil MX.
4. **Confirmo** solo tu teléfono on_shift (✓ ya verificado) y que WF10/WF3a/WF3b/WF1 activos (✓).

## EJECUCIÓN (cuando digas "arrancamos")
5. **Yo disparo** 1 lead de prueba al webhook `https://n8n.srv856940.hstgr.cloud/webhook/scraper-leads`:
```json
[{
  "lead_id": "DEMO-001",
  "name": "Cliente Demo",
  "phone": "5215512345678",
  "email": "demo@lead.local",
  "message": "Hola, me interesa esta propiedad, ¿sigue disponible?",
  "listing_id": "EB-DEMO",
  "property": "Casa Demo Bosque Real 320m2",
  "address": "Av. Demo 123, CDMX",
  "price": "$6,500,000",
  "listing_type": "venta",
  "source_tab": "mensajes"
}]
```
6. **Tu teléfono recibe** el aviso de subasta con propiedad + precio + nombre del lead + `TOMO-XXXX`.
7. **Respondes** `TOMO-XXXX` desde tu teléfono. → WF1 → WF3b reclamo.
8. **Recibes la confirmación** con: `✅ Asignado` + nombre del lead + 📱 `5215512345678` (teléfono del lead) + propiedad. → Le muestras a la clienta: el asesor ya tiene todo para contactar.
9. (Opcional seguimiento) muestro una corrida manual de WF14 o explico la cadencia automática.

## NARRATIVA PARA LA CLIENTA
- "El scraper detecta el lead en inmuebles24 y lo manda solo."
- "El sistema lo subasta por WhatsApp al equipo en turno."
- "El primero que responde TOMO se lo queda — y al instante recibe el teléfono y datos del lead para contactarlo."
- "Después el sistema da seguimiento hasta el cierre, y Marusa recibe el reporte semanal."
- Roadmap (próximos días): owner-first (al dueño del inmueble primero), templates Meta (envíos proactivos confiables 24/7), Pi cada 15 min.

## LIMPIEZA (después del demo)
- Borro la conversación + subasta + mensajes DEMO-001 de la DB. Tu lado queda limpio.

## SI ALGO FALLA EN VIVO
- No llega el TOMO a tu tel → tu ventana 24h se cerró: re-manda un msg al bot y reintento.
- No llega y la ventana está abierta → reviso la respuesta del nodo HTTP (continueOnFail enmascara errores 131047).
- Lead no subasta → cayó en cola nocturna (horario) o WF10 lo marcó returning; reviso ejecución en n8n.
