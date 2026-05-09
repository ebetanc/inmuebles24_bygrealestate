-- ============================================================================
-- 00_cleanup_test_data.sql
-- Limpia TODA la data de prueba antes de go-live
-- EJECUTAR SOLO UNA VEZ antes de produccion
-- ============================================================================

-- Orden importa por foreign keys
BEGIN;

DELETE FROM messages;
DELETE FROM night_queue;
DELETE FROM auctions;
DELETE FROM conversations;
DELETE FROM agent_schedule;
DELETE FROM scrape_logs;
DELETE FROM listings;
DELETE FROM properties_cache;

-- Verificar que todo esta vacio
DO $$
DECLARE
  r RECORD;
  total INTEGER := 0;
BEGIN
  FOR r IN
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename NOT IN ('agents')
  LOOP
    EXECUTE format('SELECT count(*) FROM %I', r.tablename) INTO total;
    IF total > 0 THEN
      RAISE WARNING 'Tabla % todavia tiene % filas', r.tablename, total;
    ELSE
      RAISE NOTICE 'Tabla % limpia', r.tablename;
    END IF;
  END LOOP;
END $$;

COMMIT;
