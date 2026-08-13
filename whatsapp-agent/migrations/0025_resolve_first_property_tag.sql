-- Strict EasyBroker owner resolution and durable missing-owner fallback.
-- Emergency rollback (approved runbook only): DROP FUNCTION public.route_missing_owner_data(bigint,text,text);
-- DROP FUNCTION public.resolve_first_property_tag(text,text[]);

CREATE OR REPLACE FUNCTION public.resolve_first_property_tag(
  p_property_public_id text,
  p_tags text[]
) RETURNS TABLE (
  resolved boolean,
  reason text,
  failure_detail text,
  observed_tag text,
  owner_agent_id text,
  owner_name text,
  owner_number text
) AS $$
DECLARE
  v_code text := NULLIF(upper(btrim(p_property_public_id)), '');
  v_tag text := NULLIF(lower(btrim(p_tags[1])), '');
  v_agent public.agents;
BEGIN
  resolved := false;
  reason := 'missing_owner_data';
  observed_tag := NULLIF(btrim(p_tags[1]), '');

  IF v_code IS NULL OR v_code !~ '^EB-[A-Z0-9]{4,}$' THEN failure_detail := 'missing_code'; RETURN NEXT; RETURN; END IF;
  IF v_tag IS NULL THEN failure_detail := 'missing_tag'; RETURN NEXT; RETURN; END IF;

  SELECT a.* INTO v_agent
  FROM public.property_agent_alias alias
  JOIN public.agents a ON a.agent_id = alias.agent_id
  WHERE alias.tag_normalized = v_tag;

  IF NOT FOUND THEN failure_detail := 'missing_alias'; RETURN NEXT; RETURN; END IF;
  IF v_agent.role = 'manager' THEN failure_detail := 'inactive_agent'; RETURN NEXT; RETURN; END IF;
  IF NOT v_agent.is_available THEN failure_detail := 'inactive_agent'; RETURN NEXT; RETURN; END IF;
  IF NULLIF(btrim(v_agent.whatsapp_number), '') IS NULL
     OR btrim(v_agent.whatsapp_number) !~ '^\+?[1-9][0-9 ()-]{6,13}[0-9]$'
     OR regexp_replace(btrim(v_agent.whatsapp_number), '[ +()-]', '', 'g') !~ '^[1-9][0-9]{7,14}$'
  THEN failure_detail := 'missing_phone'; RETURN NEXT; RETURN; END IF;

  resolved := true;
  reason := 'resolved';
  failure_detail := NULL;
  owner_agent_id := v_agent.agent_id;
  owner_name := v_agent.name;
  owner_number := regexp_replace(btrim(v_agent.whatsapp_number), '[ +()-]', '', 'g');
  RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog, public;

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
  IF p_reason = 'missing_owner_data' THEN NULL;
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
  v_target_state := CASE v_coverage.coverage_role WHEN 'primary' THEN 'primary_guard_open' WHEN 'backup' THEN 'backup_guard_open' ELSE 'unassigned_alerted' END;
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
    RETURN QUERY SELECT v_opp.opportunity_id,
      v_existing_event.metadata->>'state', v_existing_event.routing_tier,
      v_existing_event.metadata->>'agent_id', v_existing_event.metadata->>'agent_number';
    RETURN;
  END IF;

  UPDATE public.lead_routing_opportunities o
  SET state = v_target_state, routing_tier = v_target_tier, updated_at = now()
  WHERE o.opportunity_id = p_opportunity_id RETURNING * INTO v_opp;

  RETURN QUERY SELECT v_opp.opportunity_id, v_opp.state, v_opp.routing_tier,
    v_coverage.agent_id::text, v_coverage.whatsapp_number::text;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.resolve_first_property_tag(text,text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.route_missing_owner_data(bigint,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_first_property_tag(text,text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.route_missing_owner_data(bigint,text,text) TO service_role;

DROP POLICY IF EXISTS alias_read ON public.property_agent_alias;
REVOKE ALL ON TABLE public.property_agent_alias FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.property_agent_alias FROM service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.property_agent_alias TO service_role;
