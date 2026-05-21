-- ============================================================================
-- 01_update_agents_real.sql
-- Datos reales BYG (2026-05-20)
--
-- NOTAS:
--   - Formato WhatsApp: 52 + 1 + 10 dígitos (sin +, sin espacios)
--   - Gina: falta email (verificar con cliente)
--   - 2 managers con turnos diferentes — requiere migración 0009 antes
--   - EasyBroker email: asumido = gmail proporcionado (CONFIRMAR con cliente)
-- ============================================================================

BEGIN;

-- ---------- Agentes ----------
UPDATE agents SET whatsapp_number = '5215554132332', easybroker_email = 'Glozoya.byg@gmail.com',
  on_shift = false, is_available = true, shift_slot = NULL
WHERE agent_id = 'agent_lupita';

UPDATE agents SET whatsapp_number = '5215523007051', easybroker_email = 'Patriferreiro1206@gmail.com',
  on_shift = false, is_available = true, shift_slot = NULL
WHERE agent_id = 'agent_paty';

UPDATE agents SET whatsapp_number = '5215554094398', easybroker_email = 'Yolandaserrano2711@gmail.com',
  on_shift = false, is_available = true, shift_slot = NULL
WHERE agent_id = 'agent_yol';

UPDATE agents SET whatsapp_number = '5215530090468', easybroker_email = NULL,  -- PENDIENTE: email Gina
  on_shift = false, is_available = true, shift_slot = NULL
WHERE agent_id = 'agent_gina';

UPDATE agents SET whatsapp_number = '5215554311526', easybroker_email = 'Carol.byg@gmail.com',
  on_shift = false, is_available = true, shift_slot = NULL
WHERE agent_id = 'agent_carol';

UPDATE agents SET whatsapp_number = '5215527373935', easybroker_email = 'Mónica.byg@gmail.com',
  on_shift = false, is_available = true, shift_slot = NULL
WHERE agent_id = 'agent_moni';

-- ---------- Manager 1 (Sandy — L-V 8:30-18:00) ----------
UPDATE agents SET
  name = 'Sandy',
  whatsapp_number = '5215554349448',
  easybroker_email = 'Sandraacostabyg@gmail.com',
  on_shift = true,
  is_available = true
WHERE agent_id = 'agent_manager';

-- ---------- Manager 2 (Marusa — L-V 18:00-22:00 + Sáb/Dom) ----------
-- Requiere migración 0009 que añada fila agent_manager_2
INSERT INTO agents (agent_id, name, whatsapp_number, easybroker_email, on_shift, is_available)
VALUES ('agent_manager_2', 'Marusa', '5215583377338', 'Marusabobadilla@gmail.com', true, true)
ON CONFLICT (agent_id) DO UPDATE SET
  name = EXCLUDED.name,
  whatsapp_number = EXCLUDED.whatsapp_number,
  is_available = EXCLUDED.is_available;

-- Nota: Benjamin Bobadilla (+52 1 55 1953 6555) = cliente/owner, NO manager.

-- Verificación
SELECT agent_id, name, whatsapp_number, easybroker_email, on_shift, is_available
FROM agents
ORDER BY agent_id;

COMMIT;
