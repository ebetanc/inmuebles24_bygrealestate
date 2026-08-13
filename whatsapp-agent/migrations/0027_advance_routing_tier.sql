-- LRV2-010: one locked transition per expired routing tier.
CREATE OR REPLACE FUNCTION public.advance_routing_tier(
  p_opportunity_id BIGINT,
  p_expected_tier TEXT,
  p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS public.lead_routing_opportunities AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  -- RECORD keeps migration creation compatible with clean lexical runs where
  -- durable delivery tables (0030) are installed after this reserved slot.
  v_attempt RECORD;
  v_coverage RECORD;
  v_target_agent_id TEXT;
  v_next_tier TEXT;
  v_next_state TEXT;
  v_event_type TEXT;
  v_event public.lead_routing_events;
  v_key TEXT;
  v_metadata JSONB;
BEGIN
  IF p_expected_tier NOT IN ('owner','primary_guard','backup_guard') OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid routing tier';
  END IF;

  SELECT o.* INTO v_opp
  FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id=p_opportunity_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_opp.assigned_agent_id IS NOT NULL
     OR v_opp.state='assigned'
     OR v_opp.routing_tier IS DISTINCT FROM p_expected_tier
     OR v_opp.state IS DISTINCT FROM (CASE p_expected_tier
          WHEN 'owner' THEN 'owner_open'
          WHEN 'primary_guard' THEN 'primary_guard_open'
          ELSE 'backup_guard_open' END)
     OR v_opp.delivered_at IS NULL
     OR v_opp.expires_at IS NULL
     OR v_opp.expires_at>p_now THEN
    RETURN v_opp;
  END IF;

  SELECT a.* INTO v_attempt
  FROM public.lead_routing_delivery_attempts a
  WHERE a.attempt_id=v_opp.current_delivery_attempt_id
    AND a.opportunity_id=v_opp.opportunity_id
    AND a.routing_tier=p_expected_tier
    AND a.status='delivered'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'current delivered attempt missing'; END IF;

  v_next_tier:=CASE p_expected_tier
    WHEN 'owner' THEN 'primary_guard'
    WHEN 'primary_guard' THEN 'backup_guard'
    ELSE NULL END;

  IF v_next_tier IS NOT NULL THEN
    SELECT * INTO v_coverage
    FROM public.get_guard_coverage_slots() c
    WHERE c.coverage_role=(CASE v_next_tier WHEN 'primary_guard' THEN 'primary' ELSE 'backup' END)
    LIMIT 1;
    v_target_agent_id:=v_coverage.agent_id;
  END IF;
  IF v_target_agent_id IS NULL AND p_expected_tier='owner' THEN
    v_next_tier:='backup_guard';
    SELECT * INTO v_coverage FROM public.get_guard_coverage_slots() c
    WHERE c.coverage_role='backup' LIMIT 1;
    v_target_agent_id:=v_coverage.agent_id;
  END IF;
  IF v_target_agent_id IS NULL THEN v_next_tier:=NULL; END IF;

  v_next_state:=CASE WHEN v_next_tier IS NULL THEN 'unassigned_alerted' ELSE 'guard_delivery_pending' END;
  v_event_type:=CASE WHEN v_next_tier IS NULL THEN 'unassigned_alerted' ELSE 'escalated' END;
  v_key:='tier-expired:'||v_attempt.attempt_id::TEXT;
  v_metadata:=jsonb_strip_nulls(jsonb_build_object(
    'reason','sla_expired','from_tier',p_expected_tier,'to_tier',v_next_tier,
    'expired_at',v_opp.expires_at,'agent_id',v_target_agent_id));

  INSERT INTO public.lead_routing_events(
    opportunity_id,event_type,routing_tier,idempotency_key,metadata)
  VALUES(v_opp.opportunity_id,v_event_type,v_next_tier,v_key,v_metadata)
  ON CONFLICT(idempotency_key) DO NOTHING;
  SELECT e.* INTO v_event FROM public.lead_routing_events e WHERE e.idempotency_key=v_key;
  IF v_event.opportunity_id IS DISTINCT FROM v_opp.opportunity_id
     OR v_event.event_type IS DISTINCT FROM v_event_type
     OR v_event.routing_tier IS DISTINCT FROM v_next_tier
     OR v_event.metadata IS DISTINCT FROM v_metadata THEN
    RAISE EXCEPTION 'tier transition event collision';
  END IF;

  UPDATE public.lead_routing_delivery_attempts
  SET lease_token=NULL,lease_expires_at=NULL
  WHERE attempt_id=v_attempt.attempt_id;
  UPDATE public.lead_routing_opportunities
  SET state=v_next_state,routing_tier=v_next_tier,assigned_agent_id=NULL,
      current_delivery_attempt_id=NULL,delivery_status=CASE WHEN v_next_tier IS NULL THEN 'failed' ELSE 'requested' END,
      delivery_requested_at=NULL,delivered_at=NULL,expires_at=NULL,updated_at=p_now
  WHERE opportunity_id=v_opp.opportunity_id
    AND routing_tier=p_expected_tier
    AND assigned_agent_id IS NULL
  RETURNING * INTO v_opp;
  RETURN v_opp;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

CREATE OR REPLACE FUNCTION public.sweep_expired_routing_tiers(
  p_limit INTEGER DEFAULT 100,
  p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS SETOF public.lead_routing_opportunities AS $$
DECLARE v_opp public.lead_routing_opportunities;
BEGIN
  IF p_limit IS NULL OR p_limit<1 OR p_limit>1000 OR p_now IS NULL THEN RAISE EXCEPTION 'invalid sweep input'; END IF;
  FOR v_opp IN
    SELECT o.* FROM public.lead_routing_opportunities o
    WHERE o.state IN ('owner_open','primary_guard_open','backup_guard_open')
      AND o.assigned_agent_id IS NULL AND o.delivered_at IS NOT NULL
      AND o.expires_at IS NOT NULL AND o.expires_at<=p_now
    ORDER BY o.expires_at,o.opportunity_id
    FOR UPDATE SKIP LOCKED LIMIT p_limit
  LOOP
    RETURN NEXT public.advance_routing_tier(v_opp.opportunity_id,v_opp.routing_tier,p_now);
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

REVOKE ALL ON FUNCTION public.advance_routing_tier(BIGINT,TEXT,TIMESTAMPTZ),
  public.sweep_expired_routing_tiers(INTEGER,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.advance_routing_tier(BIGINT,TEXT,TIMESTAMPTZ),
  public.sweep_expired_routing_tiers(INTEGER,TIMESTAMPTZ) TO service_role;

-- Direct channels have no EasyBroker owner metadata. Queue exactly one guard
-- tier; the existing durable claim/sender pipeline performs delivery.
CREATE OR REPLACE FUNCTION public.queue_guard_routing(
  p_opportunity_id BIGINT,
  p_reason TEXT,
  p_idempotency_key TEXT
)
RETURNS public.lead_routing_opportunities AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_coverage RECORD;
  v_tier TEXT;
  v_state TEXT;
  v_event public.lead_routing_events;
  v_metadata JSONB;
BEGIN
  IF p_reason<>'whatsapp_direct_missing_owner'
     OR NULLIF(btrim(p_idempotency_key),'') IS NULL THEN
    RAISE EXCEPTION 'invalid guard routing request';
  END IF;
  SELECT o.* INTO v_opp FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'opportunity unavailable for guard routing'; END IF;

  SELECT e.* INTO v_event FROM public.lead_routing_events e
  WHERE e.idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF v_event.opportunity_id IS DISTINCT FROM p_opportunity_id
       OR v_event.event_type NOT IN ('escalated','unassigned_alerted')
       OR v_event.metadata->>'reason' IS DISTINCT FROM p_reason THEN
      RAISE EXCEPTION 'guard routing event collision';
    END IF;
    RETURN v_opp;
  END IF;

  SELECT * INTO v_coverage FROM public.get_guard_coverage_slots() c
  ORDER BY CASE c.coverage_role WHEN 'primary' THEN 1 ELSE 2 END LIMIT 1;
  v_tier:=CASE v_coverage.coverage_role WHEN 'primary' THEN 'primary_guard' WHEN 'backup' THEN 'backup_guard' END;
  v_state:=CASE WHEN v_tier IS NULL THEN 'unassigned_alerted' ELSE 'guard_delivery_pending' END;
  v_metadata:=jsonb_strip_nulls(jsonb_build_object(
    'reason',p_reason,'agent_id',v_coverage.agent_id,'state',v_state));

  INSERT INTO public.lead_routing_events(
    opportunity_id,event_type,routing_tier,idempotency_key,metadata)
  VALUES(p_opportunity_id,CASE WHEN v_tier IS NULL THEN 'unassigned_alerted' ELSE 'escalated' END,
    v_tier,p_idempotency_key,v_metadata)
  ON CONFLICT(idempotency_key) DO NOTHING;
  SELECT e.* INTO v_event FROM public.lead_routing_events e WHERE e.idempotency_key=p_idempotency_key;
  IF v_event.opportunity_id IS DISTINCT FROM p_opportunity_id
     OR v_event.event_type IS DISTINCT FROM (CASE WHEN v_tier IS NULL THEN 'unassigned_alerted' ELSE 'escalated' END)
     OR v_event.routing_tier IS DISTINCT FROM v_tier
     OR v_event.metadata IS DISTINCT FROM v_metadata THEN
    RAISE EXCEPTION 'guard routing event collision';
  END IF;

  IF v_opp.state IN ('captured','resolved') THEN
    UPDATE public.lead_routing_opportunities
    SET state=v_state,routing_tier=v_tier,assigned_agent_id=NULL,
        current_delivery_attempt_id=NULL,delivered_at=NULL,expires_at=NULL,updated_at=NOW()
    WHERE opportunity_id=p_opportunity_id RETURNING * INTO v_opp;
  ELSIF v_opp.state IS DISTINCT FROM v_state OR v_opp.routing_tier IS DISTINCT FROM v_tier THEN
    RAISE EXCEPTION 'guard routing cannot regress opportunity';
  END IF;
  RETURN v_opp;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

REVOKE ALL ON FUNCTION public.queue_guard_routing(BIGINT,TEXT,TEXT)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.queue_guard_routing(BIGINT,TEXT,TEXT)
  TO service_role;
