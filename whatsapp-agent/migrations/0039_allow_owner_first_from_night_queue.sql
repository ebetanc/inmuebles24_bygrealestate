-- 0039_allow_owner_first_from_night_queue.sql
-- Night-queue drain must execute the same owner-first state machine as daytime intake.
-- Rollback: reapply the function bodies from 0036 (route_missing_owner_data) and
-- 0030 (create_delivery_attempt), then reapply their REVOKE/GRANT statements.

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

  IF v_opp.state NOT IN ('captured', 'resolved', 'queued_night') THEN
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

CREATE OR REPLACE FUNCTION public.create_delivery_attempt(
  p_opportunity_id BIGINT,
  p_tier TEXT,
  p_client_request_id TEXT,
  p_target_agent_id TEXT,
  p_target_number TEXT
) RETURNS TABLE (
  attempt_id BIGINT, opportunity_id BIGINT, routing_tier TEXT, client_request_id TEXT,
  provider_message_id TEXT, status TEXT, target_agent_id TEXT, target_number TEXT,
  claimed_at TIMESTAMPTZ, lease_expires_at TIMESTAMPTZ, lease_token TEXT,
  requested_at TIMESTAMPTZ, bound_at TIMESTAMPTZ, delivered_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ, created_at TIMESTAMPTZ, should_send BOOLEAN
) AS $$
DECLARE
  v_attempt public.lead_routing_delivery_attempts;
  v_opportunity public.lead_routing_opportunities;
  v_event public.lead_routing_events;
  v_should_send BOOLEAN := false;
BEGIN
  IF p_tier NOT IN ('owner','primary_guard','backup_guard')
     OR NULLIF(btrim(p_client_request_id),'') IS NULL
     OR NULLIF(btrim(p_target_number),'') IS NULL
  THEN RAISE EXCEPTION 'invalid delivery attempt'; END IF;

  SELECT o.* INTO v_opportunity
  FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR v_opportunity.state IN ('assigned','unassigned_alerted','closed_won','closed_lost')
  THEN RAISE EXCEPTION 'opportunity cannot request delivery'; END IF;

  INSERT INTO public.lead_routing_events AS e(
    opportunity_id,event_type,routing_tier,idempotency_key,external_evidence
  ) VALUES(
    p_opportunity_id,'delivery_requested',p_tier,
    'delivery-requested:'||p_client_request_id,
    jsonb_build_object('client_request_id',p_client_request_id)
  ) ON CONFLICT(idempotency_key) DO NOTHING;

  SELECT e.* INTO v_event FROM public.lead_routing_events e
  WHERE e.idempotency_key='delivery-requested:'||p_client_request_id;
  IF v_event.opportunity_id IS DISTINCT FROM p_opportunity_id
     OR v_event.event_type<>'delivery_requested'
     OR v_event.routing_tier IS DISTINCT FROM p_tier
  THEN RAISE EXCEPTION 'delivery request event collision'; END IF;

  INSERT INTO public.lead_routing_delivery_attempts AS a(
    opportunity_id,routing_tier,client_request_id,target_agent_id,target_number,
    claimed_at,lease_expires_at,lease_token
  ) VALUES(
    p_opportunity_id,p_tier,p_client_request_id,p_target_agent_id,p_target_number,
    NOW(),NOW()+INTERVAL '2 minutes',gen_random_uuid()::text
  ) ON CONFLICT ON CONSTRAINT lead_routing_delivery_attempts_client_request_id_key
  DO NOTHING RETURNING * INTO v_attempt;
  v_should_send := FOUND;

  IF NOT v_should_send THEN
    SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts a
    WHERE a.client_request_id=p_client_request_id FOR UPDATE;
    IF v_attempt.opportunity_id IS DISTINCT FROM p_opportunity_id
       OR v_attempt.routing_tier IS DISTINCT FROM p_tier
       OR v_attempt.target_agent_id IS DISTINCT FROM p_target_agent_id
       OR v_attempt.target_number IS DISTINCT FROM p_target_number
    THEN RAISE EXCEPTION 'client_request_id collision'; END IF;
    IF v_attempt.status='requested'
       AND v_attempt.provider_message_id IS NULL
       AND v_attempt.lease_expires_at<=NOW()
       AND v_opportunity.current_delivery_attempt_id=v_attempt.attempt_id THEN
      UPDATE public.lead_routing_delivery_attempts a
      SET claimed_at=NOW(),lease_expires_at=NOW()+INTERVAL '2 minutes',lease_token=gen_random_uuid()::text
      WHERE a.attempt_id=v_attempt.attempt_id RETURNING a.* INTO v_attempt;
      v_should_send := true;
    END IF;
  END IF;

  IF v_should_send THEN
    UPDATE public.lead_routing_opportunities o
    SET state='delivery_requested',routing_tier=p_tier,delivery_status='requested',
        delivery_requested_at=NOW(),current_delivery_attempt_id=v_attempt.attempt_id,updated_at=NOW()
    WHERE o.opportunity_id=p_opportunity_id AND o.delivered_at IS NULL
      AND (
        (p_tier='owner' AND (
          o.state IN ('captured','resolved','queued_night')
          OR (o.state='delivery_requested' AND o.routing_tier='owner'
              AND (o.current_delivery_attempt_id IS NULL OR o.current_delivery_attempt_id=v_attempt.attempt_id))
        ))
        OR (p_tier IN ('primary_guard','backup_guard')
            AND o.routing_tier=p_tier AND o.state='guard_delivery_pending')
      );
    IF NOT FOUND THEN RAISE EXCEPTION 'stale delivery attempt tier/state'; END IF;
  END IF;

  RETURN QUERY SELECT
    v_attempt.attempt_id,v_attempt.opportunity_id,v_attempt.routing_tier,
    v_attempt.client_request_id,v_attempt.provider_message_id,v_attempt.status,
    v_attempt.target_agent_id,v_attempt.target_number,v_attempt.claimed_at,
    v_attempt.lease_expires_at,v_attempt.lease_token,v_attempt.requested_at,
    v_attempt.bound_at,v_attempt.delivered_at,v_attempt.failed_at,
    v_attempt.created_at,v_should_send;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.create_delivery_attempt(bigint,text,text,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_delivery_attempt(bigint,text,text,text,text)
  TO service_role;
