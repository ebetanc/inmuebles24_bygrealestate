# Confirmación del flujo dirigido V3 — 7 de septiembre de 2026

El usuario confirmó y autorizó continuar la implementación en esta sesión.
Esta aclaración conserva el contrato V3 y descarta las propuestas de registrar
atención manual, cambiar horarios o reducir la frecuencia a cinco minutos.

1. Revisar las tres bandejas de Inmuebles24 cada 15 minutos.
2. Persistir cada solicitud de forma idempotente y verificar Contactado antes
   de cualquier oferta de WhatsApp.
3. Resolver la referencia exacta de EasyBroker y el ejecutivo de la propiedad.
4. Ofrecer primero al dueño, después a la guardia vigente y finalmente asignar
   a Sandy. Se mantienen las ventanas de cinco minutos desde entrega, el
   timeout técnico de dos minutos y la cola nocturna existente (libera 08:05 CDMX).
5. El equipo sólo acepta con Tomo; no registra notas ni atención en otro tablero.
6. El robot escribe y verifica RESPONSABLE y Atendida en la solicitud exacta EB.

Las llamadas y conversaciones personales no intervienen en esta asignación.
Contactado significa procesado por el flujo; no prueba una llamada al prospecto.
La prioridad del dueño se aplica a nuevas oportunidades. Permanecen las reglas
V3 de deduplicación, responsable final inmutable y recurrentes ya asignados.

Si la propiedad no puede identificarse, no se inventa referencia ni ejecutivo.
La excepción debe mostrarse como pendiente; un reparto interno o HTTP 200 no
demuestran el cierre completo de negocio. La confirmación no autoriza mensajes
sintéticos a personas reales ni reabrir casos históricos cerrados.

## Correcciones de ejecución

- Reservar un trabajo cuando el worker va a ejecutarlo, evitando que las
  reservas del resto del lote caduquen mientras esperan al navegador o a HTTP.
- Exigir el recibo durable de WF10 con accepted=true e IDs coincidentes antes
  de finalizar un despacho. Reintentos mantienen la misma clave idempotente.
- Esperar de forma acotada el render del panel y recuperar una sesión abierta
  antes de intentar rellenar el formulario de ingreso.
- Mostrar capturas detenidas y cierres EB sin evidencia después de 30 minutos.
  Ese umbral sólo afecta al diagnóstico; no modifica los tiempos de reparto.

No se reemplaza el motor V3: la comparación del 7 de septiembre confirmó las
conexiones y parámetros de WF10/WF12/WF13/WF3b/WF23/WF3c/WF7 contra producción.
