-- Read-only routing-v2 schema capture. Run only with separately authorized DB access.
-- Emits metadata only: no lead, phone, email, message, or workflow data.

SELECT 'routing_v2_columns' AS capture,
       table_schema,
       table_name,
       column_name,
       data_type,
       is_nullable,
       is_identity,
       identity_generation
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN (
    'agents', 'agent_schedule', 'auctions', 'conversations', 'eb_property_owner',
    'lead_status', 'lead_status_history', 'night_queue', 'property_agent_alias'
  )
ORDER BY table_name, ordinal_position;

SELECT 'routing_v2_constraints' AS capture,
       c.conrelid::regclass::text AS table_name,
       c.conname,
       c.contype,
       pg_get_constraintdef(c.oid, true) AS definition
FROM pg_constraint c
JOIN pg_namespace n ON n.oid = c.connamespace
WHERE n.nspname = 'public'
  AND c.conrelid::regclass::text IN (
    'agents', 'agent_schedule', 'auctions', 'conversations', 'eb_property_owner',
    'lead_status', 'lead_status_history', 'night_queue', 'property_agent_alias'
  )
ORDER BY table_name, c.conname;

SELECT 'routing_v2_indexes' AS capture,
       tablename,
       indexname,
       indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND (
    tablename IN ('agents', 'agent_schedule', 'auctions', 'conversations', 'night_queue')
    OR indexname = 'conversations_i24_lead_id_uniq'
  )
ORDER BY tablename, indexname;

SELECT 'routing_v2_functions' AS capture,
       n.nspname AS function_schema,
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
    'is_daytime', 'get_on_shift_agents', 'resolve_agent_from_tags'
  )
ORDER BY p.proname, arguments;

-- Boolean drift indicators only. Function source is inspected server-side and never returned.
SELECT 'routing_v2_behavior_indicators' AS capture,
       p.proname,
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
