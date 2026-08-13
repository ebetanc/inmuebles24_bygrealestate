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

-- 7b. Capturar drift de contrato routing v2 (solo metadata; no datos de leads)
SELECT '7b. ROUTING V2 DRIFT' AS check_name;
SELECT indexname, tablename, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname = 'conversations_i24_lead_id_uniq';

SELECT n.nspname AS function_schema,
  p.proname,
  pg_get_function_identity_arguments(p.oid) AS arguments,
  pg_get_function_result(p.oid) AS result,
  p.provolatile,
  p.prosecdef,
  p.prokind
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'is_daytime', 'get_on_shift_agents', 'mark_assigned', 'resolve_agent_from_tags'
  )
ORDER BY p.proname, arguments;

SELECT p.proname,
  CASE WHEN p.proname = 'is_daytime' THEN
    position('cdmx_hour < 20' IN lower(pg_get_functiondef(p.oid))) > 0
  END AS has_hour_lt_20,
  CASE WHEN p.proname = 'is_daytime' THEN
    position('cdmx_hour < 21' IN lower(pg_get_functiondef(p.oid))) > 0
  END AS has_hour_lt_21,
  CASE WHEN p.proname = 'resolve_agent_from_tags' THEN
    lower(pg_get_functiondef(p.oid)) ~ 'p_tags\s*\[\s*1\s*\]'
  END AS uses_first_array_element,
  CASE WHEN p.proname = 'resolve_agent_from_tags' THEN
    position('unnest' IN lower(pg_get_functiondef(p.oid))) > 0
  END AS uses_unnest
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('is_daytime', 'resolve_agent_from_tags')
ORDER BY p.proname;

-- 7c. Routing v2 migration checks (metadata only; no lead data)
SELECT '7c. ROUTING V2 SCHEMA' AS check_name;
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('lead_routing_opportunities', 'lead_routing_events')
ORDER BY table_name;

SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname = 'lead_routing_opportunities_active_identity_uniq';

SELECT c.relname AS table_name, c.relrowsecurity AS rls_enabled
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('lead_routing_opportunities', 'lead_routing_events')
ORDER BY c.relname;

SELECT p.proname,
  pg_get_function_identity_arguments(p.oid) AS arguments,
  p.prosecdef
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('mark_offer_delivered', 'mark_offer_delivery_failed')
ORDER BY p.proname, arguments;

SELECT trigger_name, event_manipulation, action_timing, action_statement
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table = 'lead_routing_events'
  AND trigger_name = 'lead_routing_events_append_only'
ORDER BY event_manipulation;

SELECT grantee, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN ('lead_routing_opportunities', 'lead_routing_events')
ORDER BY table_name, grantee, privilege_type;

SELECT grantee, object_name AS sequence_name, privilege_type
FROM information_schema.role_usage_grants
WHERE object_schema = 'public'
  AND object_name IN (
    'lead_routing_opportunities_opportunity_id_seq',
    'lead_routing_events_event_id_seq'
  )
ORDER BY sequence_name, grantee, privilege_type;

SELECT
  has_table_privilege('service_role', 'public.lead_routing_opportunities', 'SELECT')
    AND has_table_privilege('service_role', 'public.lead_routing_opportunities', 'INSERT')
    AND has_table_privilege('service_role', 'public.lead_routing_opportunities', 'UPDATE')
    AS service_role_can_use_opportunities,
  has_table_privilege('service_role', 'public.lead_routing_events', 'SELECT')
    AND has_table_privilege('service_role', 'public.lead_routing_events', 'INSERT')
    AS service_role_can_append_events,
  NOT has_table_privilege('service_role', 'public.lead_routing_events', 'UPDATE')
    AND NOT has_table_privilege('service_role', 'public.lead_routing_events', 'DELETE')
    AS service_role_cannot_mutate_events,
  NOT has_table_privilege('service_role', 'public.lead_routing_opportunities', 'DELETE')
    AND NOT has_table_privilege('service_role', 'public.lead_routing_opportunities', 'TRUNCATE')
    AND NOT has_table_privilege('service_role', 'public.lead_routing_opportunities', 'REFERENCES')
    AND NOT has_table_privilege('service_role', 'public.lead_routing_opportunities', 'TRIGGER')
    AS service_role_has_only_required_opportunity_access,
  NOT has_table_privilege('service_role', 'public.lead_routing_events', 'UPDATE')
    AND NOT has_table_privilege('service_role', 'public.lead_routing_events', 'DELETE')
    AND NOT has_table_privilege('service_role', 'public.lead_routing_events', 'TRUNCATE')
    AND NOT has_table_privilege('service_role', 'public.lead_routing_events', 'REFERENCES')
    AND NOT has_table_privilege('service_role', 'public.lead_routing_events', 'TRIGGER')
    AS service_role_has_only_required_event_access,
  NOT has_table_privilege('anon', 'public.lead_routing_events', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.lead_routing_events', 'INSERT')
    AND NOT has_table_privilege('anon', 'public.lead_routing_events', 'UPDATE')
    AND NOT has_table_privilege('anon', 'public.lead_routing_events', 'DELETE')
    AS anon_cannot_access_events,
  NOT has_table_privilege('authenticated', 'public.lead_routing_events', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.lead_routing_events', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.lead_routing_events', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.lead_routing_events', 'DELETE')
    AS authenticated_cannot_access_events;

SELECT
  has_sequence_privilege('service_role', 'public.lead_routing_opportunities_opportunity_id_seq', 'USAGE')
    AND has_sequence_privilege('service_role', 'public.lead_routing_opportunities_opportunity_id_seq', 'SELECT')
    AND NOT has_sequence_privilege('service_role', 'public.lead_routing_opportunities_opportunity_id_seq', 'UPDATE')
    AS service_role_can_use_opportunity_sequence,
  has_sequence_privilege('service_role', 'public.lead_routing_events_event_id_seq', 'USAGE')
    AND has_sequence_privilege('service_role', 'public.lead_routing_events_event_id_seq', 'SELECT')
    AND NOT has_sequence_privilege('service_role', 'public.lead_routing_events_event_id_seq', 'UPDATE')
    AS service_role_can_use_event_sequence;

SELECT
  NOT has_function_privilege(
    'service_role', 'public.mark_offer_delivered(bigint,text,jsonb)', 'EXECUTE'
  ) AS service_role_cannot_bypass_delivery_attempt,
  NOT has_function_privilege(
    'service_role', 'public.mark_offer_delivery_failed(bigint,text,jsonb)', 'EXECUTE'
  ) AS service_role_cannot_bypass_delivery_failure_attempt,
  has_function_privilege(
    'service_role', 'public.record_delivery_callback(text,text,timestamptz,jsonb)', 'EXECUTE'
  ) AS service_role_can_record_delivery_callback,
  NOT has_function_privilege(
    'anon', 'public.mark_offer_delivered(bigint,text,jsonb)', 'EXECUTE'
  ) AS anon_cannot_mark_delivered,
  NOT has_function_privilege(
    'authenticated', 'public.mark_offer_delivery_failed(bigint,text,jsonb)', 'EXECUTE'
  ) AS authenticated_cannot_mark_delivery_failed;

-- 7d. Delivery outbox/inbox least privilege (LRV2-008)
SELECT '7d. ROUTING V2 DELIVERY SECURITY' AS check_name;
SELECT
  has_table_privilege('service_role','public.lead_routing_delivery_attempts','SELECT,INSERT,UPDATE')
    AND NOT has_table_privilege('service_role','public.lead_routing_delivery_attempts','DELETE,TRUNCATE,REFERENCES,TRIGGER')
    AS service_role_has_only_required_delivery_attempt_access,
  has_table_privilege('service_role','public.lead_routing_delivery_callbacks','SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('service_role','public.lead_routing_delivery_callbacks','TRUNCATE,REFERENCES,TRIGGER')
    AS service_role_has_only_required_delivery_callback_access,
  NOT has_table_privilege('anon','public.lead_routing_delivery_attempts','SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated','public.lead_routing_delivery_attempts','SELECT,INSERT,UPDATE,DELETE')
    AS clients_cannot_access_delivery_attempts,
  NOT has_table_privilege('anon','public.lead_routing_delivery_callbacks','SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated','public.lead_routing_delivery_callbacks','SELECT,INSERT,UPDATE,DELETE')
    AS clients_cannot_access_delivery_callbacks;

SELECT
  has_sequence_privilege('service_role','public.lead_routing_delivery_attempts_attempt_id_seq','USAGE,SELECT')
    AND NOT has_sequence_privilege('service_role','public.lead_routing_delivery_attempts_attempt_id_seq','UPDATE')
    AS service_role_can_use_delivery_attempt_sequence,
  has_sequence_privilege('service_role','public.lead_routing_delivery_callbacks_callback_id_seq','USAGE,SELECT')
    AND NOT has_sequence_privilege('service_role','public.lead_routing_delivery_callbacks_callback_id_seq','UPDATE')
    AS service_role_can_use_delivery_callback_sequence,
  NOT has_sequence_privilege('anon','public.lead_routing_delivery_attempts_attempt_id_seq','USAGE,SELECT,UPDATE')
    AND NOT has_sequence_privilege('authenticated','public.lead_routing_delivery_callbacks_callback_id_seq','USAGE,SELECT,UPDATE')
    AS clients_cannot_use_delivery_sequences;

SELECT
  has_function_privilege('service_role','public.create_delivery_attempt(bigint,text,text,text,text)','EXECUTE')
    AND has_function_privilege('service_role','public.bind_delivery_message(bigint,text,text)','EXECUTE')
    AND has_function_privilege('service_role','public.fail_unbound_delivery_attempt(bigint,text,text)','EXECUTE')
    AND has_function_privilege('service_role','public.record_delivery_callback(text,text,timestamptz,jsonb)','EXECUTE')
    AND has_function_privilege('service_role','public.claim_pending_guard_deliveries(integer)','EXECUTE')
    AS service_role_can_run_delivery_pipeline,
  NOT has_function_privilege('anon','public.create_delivery_attempt(bigint,text,text,text,text)','EXECUTE')
    AND NOT has_function_privilege('authenticated','public.create_delivery_attempt(bigint,text,text,text,text)','EXECUTE')
    AND NOT has_function_privilege('anon','public.record_delivery_callback(text,text,timestamptz,jsonb)','EXECUTE')
    AND NOT has_function_privilege('authenticated','public.claim_pending_guard_deliveries(integer)','EXECUTE')
    AS clients_cannot_run_delivery_pipeline;

SELECT
  has_function_privilege(
    'service_role','public.claim_lead_opportunity(bigint,text,text,text,text)','EXECUTE'
  ) AS service_role_can_claim_routing_opportunity,
  NOT has_function_privilege(
    'anon','public.claim_lead_opportunity(bigint,text,text,text,text)','EXECUTE'
  ) AND NOT has_function_privilege(
    'authenticated','public.claim_lead_opportunity(bigint,text,text,text,text)','EXECUTE'
  ) AS clients_cannot_claim_routing_opportunity;

SELECT
  has_table_privilege('service_role','public.conversations','SELECT,UPDATE')
    AND NOT has_table_privilege('service_role','public.conversations','INSERT,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    AS service_role_has_only_required_claim_conversation_access;

SELECT
  has_table_privilege('service_role','public.agents','SELECT')
    AND NOT has_table_privilege('service_role','public.agents','INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    AS service_role_has_only_required_claim_agent_access;

-- 8. Verificar timezone
SELECT '8. TIMEZONE' AS check_name;
SELECT
  NOW() AS utc_now,
  NOW() AT TIME ZONE 'America/Mexico_City' AS cdmx_now,
  EXTRACT(HOUR FROM NOW() AT TIME ZONE 'America/Mexico_City') AS cdmx_hour;
