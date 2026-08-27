-- 0036_route_missing_owner_delivery_pending.sql
-- Align owner-fallback intake with the durable guard-delivery queue introduced by 0030.
-- Rollback (forward-fix migration in a maintenance window): redefine this same signature
-- from 0028, restoring primary_guard_open/backup_guard_open in v_target_state, then reapply
-- the function REVOKE/GRANT statements below; also run exactly:
--   REVOKE SELECT (schedule_date, shift, agent_id, coverage_role)
--     ON public.agent_schedule FROM service_role;
--   REVOKE SELECT (agent_id, name, whatsapp_number, is_available)
--     ON public.agents FROM service_role;
-- Never edit an already-applied migration.

REVOKE SELECT (schedule_date, shift, agent_id, coverage_role)
  ON public.agent_schedule FROM PUBLIC, anon, authenticated;
REVOKE SELECT (agent_id, name, whatsapp_number, is_available)
  ON public.agents FROM PUBLIC, anon, authenticated;
GRANT SELECT (schedule_date, shift, agent_id, coverage_role)
  ON public.agent_schedule TO service_role;
GRANT SELECT (agent_id, name, whatsapp_number, is_available)
  ON public.agents TO service_role;

CREATE OR REPLACE FUNCTION public.route_missing_owner_data(
  p_opportunity_id bigint,
  p_reason text,
  p_idempotency_key text
) RETURNS TABLE (
  opportunity_id bigint,
  state text,
  routing_tier text,
  primary_agent_id text,
  primary_number text
) AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_coverage record;
  v_target_state text;
  v_target_tier text;
  v_metadata jsonb;
  v_event_id bigint;
  v_existing_event public.lead_routing_events;
BEGIN
  IF p_reason IN ('missing_owner_data', 'routing_safe_mode') THEN NULL;
  ELSE RAISE EXCEPTION 'invalid owner fallback reason'; END IF;
  IF NULLIF(btrim(p_idempotency_key), '') IS NULL THEN RAISE EXCEPTION 'idempotency key required'; END IF;

  SELECT * INTO v_opp FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id = p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'opportunity unavailable for owner fallback'; END IF;

  -- Replay is bound to originally persisted evidence, never today's coverage.
  SELECT * INTO v_existing_event FROM public.lead_routing_events e
  WHERE e.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing_event.opportunity_id <> p_opportunity_id
       OR v_existing_event.event_type <> 'missing_owner_data'
       OR v_existing_event.metadata->>'reason' <> p_reason
    THEN RAISE EXCEPTION 'owner fallback idempotency collision'; END IF;
    IF v_existing_event.metadata->>'state' = 'unassigned_alerted' THEN
      PERFORM * FROM public.record_unassigned_alert(
        p_opportunity_id, 'route-missing-owner-alert:' || btrim(p_idempotency_key)
      );
    END IF;
    RETURN QUERY SELECT v_opp.opportunity_id,
      v_existing_event.metadata->>'state', v_existing_event.routing_tier,
      v_existing_event.metadata->>'agent_id', v_existing_event.metadata->>'agent_number';
    RETURN;
  END IF;

  SELECT c.coverage_role, c.agent_id, c.whatsapp_number INTO v_coverage
  FROM public.get_guard_coverage_slots() c
  ORDER BY CASE c.coverage_role WHEN 'primary' THEN 1 WHEN 'backup' THEN 2 END
  LIMIT 1;
  v_target_tier := CASE v_coverage.coverage_role WHEN 'primary' THEN 'primary_guard' WHEN 'backup' THEN 'backup_guard' END;
  v_target_state := CASE
    WHEN v_coverage.coverage_role IN ('primary', 'backup') THEN 'guard_delivery_pending'
    ELSE 'unassigned_alerted'
  END;
  v_metadata := jsonb_strip_nulls(jsonb_build_object(
    'reason', p_reason, 'state', v_target_state,
    'coverage_role', v_coverage.coverage_role, 'agent_id', v_coverage.agent_id,
    'agent_number', v_coverage.whatsapp_number
  ));

  IF v_opp.state NOT IN ('captured', 'resolved') THEN
    RAISE EXCEPTION 'owner fallback cannot regress state: %', v_opp.state;
  END IF;

  INSERT INTO public.lead_routing_events (
    opportunity_id, event_type, routing_tier, idempotency_key, metadata
  ) VALUES (
    p_opportunity_id, 'missing_owner_data', v_target_tier, btrim(p_idempotency_key), v_metadata
  ) ON CONFLICT (idempotency_key) DO NOTHING RETURNING event_id INTO v_event_id;
  IF v_event_id IS NULL THEN
    SELECT * INTO v_existing_event FROM public.lead_routing_events e
    WHERE e.idempotency_key = btrim(p_idempotency_key);
    IF v_existing_event.opportunity_id <> p_opportunity_id
       OR v_existing_event.event_type <> 'missing_owner_data'
       OR v_existing_event.routing_tier IS DISTINCT FROM v_target_tier
       OR v_existing_event.metadata IS DISTINCT FROM v_metadata
    THEN RAISE EXCEPTION 'owner fallback idempotency collision'; END IF;
    IF v_existing_event.metadata->>'state' = 'unassigned_alerted' THEN
      PERFORM * FROM public.record_unassigned_alert(
        p_opportunity_id, 'route-missing-owner-alert:' || btrim(p_idempotency_key)
      );
    END IF;
    RETURN QUERY SELECT v_opp.opportunity_id,
      v_existing_event.metadata->>'state', v_existing_event.routing_tier,
      v_existing_event.metadata->>'agent_id', v_existing_event.metadata->>'agent_number';
    RETURN;
  END IF;

  UPDATE public.lead_routing_opportunities o
  SET state = v_target_state, routing_tier = v_target_tier, updated_at = now()
  WHERE o.opportunity_id = p_opportunity_id RETURNING * INTO v_opp;

  IF v_target_state = 'unassigned_alerted' THEN
    PERFORM * FROM public.record_unassigned_alert(
      p_opportunity_id, 'route-missing-owner-alert:' || btrim(p_idempotency_key)
    );
  END IF;

  RETURN QUERY SELECT v_opp.opportunity_id, v_opp.state, v_opp.routing_tier,
    v_coverage.agent_id::text, v_coverage.whatsapp_number::text;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.route_missing_owner_data(bigint,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.route_missing_owner_data(bigint,text,text) TO service_role;
