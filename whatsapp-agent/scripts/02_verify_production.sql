-- ============================================================================
-- 02_verify_production.sql
-- Ejecutar DESPUES de cleanup + update de agentes
-- Verifica que todo esta listo para produccion
-- ============================================================================

-- 1. Verificar agentes (NO deben tener numeros placeholder)
SELECT '1. AGENTES' AS check_name;
SELECT agent_id, name, whatsapp_number,
  CASE
    WHEN whatsapp_number LIKE '521550000%' THEN 'PLACEHOLDER - ACTUALIZAR'
    WHEN whatsapp_number ~ '^\d{12,13}$' THEN 'OK'
    ELSE 'FORMATO INVALIDO'
  END AS phone_status,
  easybroker_email,
  CASE
    WHEN easybroker_email IS NULL AND agent_id != 'agent_manager' THEN 'FALTA EMAIL'
    ELSE 'OK'
  END AS email_status
FROM agents
ORDER BY agent_id;

-- 2. Verificar que no hay data de prueba
SELECT '2. DATA DE PRUEBA' AS check_name;
SELECT
  (SELECT count(*) FROM conversations) AS conversations,
  (SELECT count(*) FROM auctions) AS auctions,
  (SELECT count(*) FROM messages) AS messages,
  (SELECT count(*) FROM night_queue) AS night_queue,
  (SELECT count(*) FROM agent_schedule) AS agent_schedule;

-- 3. Verificar funciones de DB
SELECT '3. FUNCIONES' AS check_name;
SELECT is_daytime() AS is_day, current_shift() AS current_shift;

-- 4. Verificar indices criticos
SELECT '4. INDICES' AS check_name;
SELECT indexname, tablename
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
    'idx_agent_schedule_date',
    'idx_night_queue_pending',
    'idx_conversations_lead_phone',
    'idx_conversations_lead_email',
    'idx_conversations_phone_property'
  )
ORDER BY tablename;

-- 5. Verificar RLS
SELECT '5. RLS POLICIES' AS check_name;
SELECT tablename, policyname, cmd
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename;

-- 6. Verificar tablas existen
SELECT '6. TABLAS' AS check_name;
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;

-- 7. Verificar on-shift agents (deberia estar vacio si no hay schedule cargado)
SELECT '7. AGENTES EN TURNO' AS check_name;
SELECT * FROM get_on_shift_agents();

-- 8. Verificar timezone
SELECT '8. TIMEZONE' AS check_name;
SELECT
  NOW() AS utc_now,
  NOW() AT TIME ZONE 'America/Mexico_City' AS cdmx_now,
  EXTRACT(HOUR FROM NOW() AT TIME ZONE 'America/Mexico_City') AS cdmx_hour;
