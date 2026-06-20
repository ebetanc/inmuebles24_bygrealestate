# Templates WhatsApp a enviar en Meta — BYG Inmobiliaria24

Enviar en **WhatsApp Manager → Plantillas de mensajes → Crear plantilla**. Idioma **Español (México)**.

## Dos reglas de Meta que ya chocamos
1. **"too many variables for its length"** → necesita más texto fijo por cada `{{n}}`. Por eso los cuerpos abajo son largos y descriptivos.
2. **"Category does not match" (rechazo)** → el clasificador lee tono promocional como **Marketing**. Para que pase como **Utility**: lenguaje neutro/operacional, sin "¡Alerta!", "disponible", "¡oferta!", urgencia hype; enmarcarlo como notificación sobre la cuenta/tarea del asesor.

## Cómo proceder ante "Category does not match"
- **Opción A (rápida):** click **Continue** → se envía como **Marketing**. Aprueba y entrega proactivo fuera de 24h igual. Sin desventaja real para avisos internos a ~9 asesores. Úsala para no atorarte.
- **Opción B (Utility, más barato/confiable largo plazo):** usa los cuerpos NEUTROS de abajo y reintenta Utility.

Tras aprobación: en n8n cambiar cada nodo de envío proactivo de `type:"text"` a `type:"template"` (`template.name` + `language` + `components[body].parameters`). Las RESPUESTAS dentro de 24h (confirmación de claim) se quedan `type:"text"`.

---

## 1. `lead_subasta_notify`  (intentar Utility; si rechaza, Marketing)
Uso: aviso proactivo de lead a asesor (guardia WF3a; owner WF13 cuando exista).

**Body (neutro, largo):**
```
Tienes un nuevo lead asignable en tu cuenta BYG.
Propiedad: {{1}}
Precio listado: {{2}}
Nombre del prospecto: {{3}}

Para asignarte este lead, responde a este mensaje con el código {{4}}.
Este código de asignación vence en {{5}} minutos. Si no respondes, el lead se ofrecerá a otro asesor del equipo.
```
Params: {{1}} propiedad · {{2}} precio · {{3}} nombre lead · {{4}} código TOMO · {{5}} minutos.
Ejemplo Meta: `Casa Bosque Real 320m2` · `$6,500,000` · `Juan Pérez` · `TOMO-AB12` · `5`

---

## 2. `lead_seguimiento_prompt`  (Utility — debería pasar)
Uso: recordatorio proactivo de seguimiento al asesor asignado (WF14).

**Body:**
```
Recordatorio de seguimiento de un lead asignado a tu cuenta BYG.
Cliente: {{1}}
Teléfono de contacto: {{2}}
Propiedad de interés: {{3}}

Acción sugerida: {{4}}
Responde a este mensaje con el estado actual del lead para mantener actualizado tu seguimiento.
```
Params: {{1}} nombre lead · {{2}} teléfono lead · {{3}} propiedad · {{4}} acción (ej. `Confirmar primer contacto`).

---

## 3. `lead_escalacion_manager`  (Utility — debería pasar)
Uso: aviso proactivo al manager cuando nadie tomó el lead (WF3c).

**Body:**
```
Notificación de un lead sin asignar en la cuenta BYG.
Propiedad: {{1}}
Cliente: {{2}}
Teléfono de contacto: {{3}}

Ningún asesor reclamó este lead dentro del tiempo establecido. Por favor asígnalo manualmente desde el panel de administración.
```
Params: {{1}} propiedad · {{2}} nombre lead · {{3}} teléfono lead.

---

## 4. `reporte_semanal_marusa`  (Utility — debería pasar)
Uso: reporte semanal proactivo a Marusa (WF16, lunes 08:00). Solo números como params.

**Body:**
```
Resumen semanal de actividad de leads en tu cuenta BYG.
Leads nuevos recibidos esta semana: {{1}}
Leads ganados (cierre exitoso): {{2}}
Leads perdidos: {{3}}
Visitas agendadas: {{4}}

Puedes revisar el detalle completo por asesor en el panel del dashboard.
```
Params: {{1}} leads semana · {{2}} closed_won · {{3}} closed_lost · {{4}} visitas.
Confirmar `MANAGER_PHONE` = `5215583377338` (Marusa).

---

## Notas
- Si Meta sigue marcando Marketing en #1 con el texto neutro, acepta Marketing (Continue) — funciona igual para el flujo.
- NO elijas "Authentication" (esa categoría es solo para códigos OTP de login; rechazaría).
- Tiempo de revisión Meta: minutos a 24h.
- Demo de hoy NO depende de templates (se usa ventana 24h). Ver `DEMO_RUNBOOK_2026-06-20.md`.
