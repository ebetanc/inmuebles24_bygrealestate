-- ============================================================================
-- 01_update_agents_template.sql
-- Actualiza agentes con datos reales de BYG
--
-- INSTRUCCIONES:
--   1. Reemplaza cada NUMERO_REAL con el WhatsApp (formato: 5215XXXXXXXXX)
--   2. Reemplaza cada EMAIL_REAL con el email de EasyBroker del agente
--   3. Reemplaza NOMBRE_MANAGER y NUMERO_MANAGER
--   4. Ejecuta en Supabase SQL Editor
-- ============================================================================

BEGIN;

-- Lupita
UPDATE agents SET
  whatsapp_number = '521XXXXXXXXXX',  -- <-- REEMPLAZAR
  easybroker_email = 'lupita@ejemplo.com',  -- <-- REEMPLAZAR
  on_shift = false,
  is_available = true,
  shift_slot = NULL
WHERE agent_id = 'agent_lupita';

-- Paty
UPDATE agents SET
  whatsapp_number = '521XXXXXXXXXX',  -- <-- REEMPLAZAR
  easybroker_email = 'paty@ejemplo.com',  -- <-- REEMPLAZAR
  on_shift = false,
  is_available = true,
  shift_slot = NULL
WHERE agent_id = 'agent_paty';

-- Yol
UPDATE agents SET
  whatsapp_number = '521XXXXXXXXXX',  -- <-- REEMPLAZAR
  easybroker_email = 'yol@ejemplo.com',  -- <-- REEMPLAZAR
  on_shift = false,
  is_available = true,
  shift_slot = NULL
WHERE agent_id = 'agent_yol';

-- Gina
UPDATE agents SET
  whatsapp_number = '521XXXXXXXXXX',  -- <-- REEMPLAZAR
  easybroker_email = 'gina@ejemplo.com',  -- <-- REEMPLAZAR
  on_shift = false,
  is_available = true,
  shift_slot = NULL
WHERE agent_id = 'agent_gina';

-- Carol
UPDATE agents SET
  whatsapp_number = '521XXXXXXXXXX',  -- <-- REEMPLAZAR
  easybroker_email = 'carol@ejemplo.com',  -- <-- REEMPLAZAR
  on_shift = false,
  is_available = true,
  shift_slot = NULL
WHERE agent_id = 'agent_carol';

-- Moni
UPDATE agents SET
  whatsapp_number = '521XXXXXXXXXX',  -- <-- REEMPLAZAR
  easybroker_email = 'moni@ejemplo.com',  -- <-- REEMPLAZAR
  on_shift = false,
  is_available = true,
  shift_slot = NULL
WHERE agent_id = 'agent_moni';

-- Manager (siempre activo)
UPDATE agents SET
  name = 'Manager',  -- <-- REEMPLAZAR con nombre real
  whatsapp_number = '521XXXXXXXXXX',  -- <-- REEMPLAZAR
  on_shift = true,
  is_available = true
WHERE agent_id = 'agent_manager';

-- Verificar resultados
SELECT agent_id, name, whatsapp_number, easybroker_email, on_shift, is_available
FROM agents
ORDER BY agent_id;

COMMIT;
