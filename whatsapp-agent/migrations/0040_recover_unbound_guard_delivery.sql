-- Recover a guard delivery that failed before the provider accepted it.
-- Rollback: DROP FUNCTION public.recover_unbound_guard_delivery(bigint,bigint,text);
-- then restore claim_pending_guard_deliveries(integer) from 0030.

CREATE OR REPLACE FUNCTION public.claim_pending_guard_deliveries(p_limit INTEGER DEFAULT 100)
RETURNS SETOF public.lead_routing_delivery_attempts AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_coverage RECORD;
  v_attempt public.lead_routing_delivery_attempts;
  v_previous_attempt public.lead_routing_delivery_attempts;
  v_key TEXT;
  v_base_key TEXT;
  v_event public.lead_routing_events;
  v_tier TEXT;
  v_meta JSONB;
BEGIN
  FOR v_opp IN
    SELECT * FROM public.lead_routing_opportunities
    WHERE state='guard_delivery_pending' AND current_delivery_attempt_id IS NULL
    ORDER BY updated_at,opportunity_id FOR UPDATE SKIP LOCKED LIMIT p_limit
  LOOP
    v_tier:=v_opp.routing_tier;
    SELECT * INTO v_coverage FROM public.get_guard_coverage_slots() c
    WHERE c.coverage_role=CASE v_tier WHEN 'primary_guard' THEN 'primary' WHEN 'backup_guard' THEN 'backup' END
    LIMIT 1;
    IF v_coverage.agent_id IS NULL AND v_tier='primary_guard' THEN
      v_tier:='backup_guard';
      SELECT * INTO v_coverage FROM public.get_guard_coverage_slots() c
      WHERE c.coverage_role='backup' LIMIT 1;
    END IF;
    IF v_coverage.agent_id IS NULL THEN
      v_key:='guard-coverage-unavailable:'||v_opp.opportunity_id::text||':'||v_opp.routing_tier;
      v_meta:=jsonb_build_object('reason','guard_coverage_unavailable');
      INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,metadata)
      VALUES(v_opp.opportunity_id,'unassigned_alerted',NULL,v_key,v_meta)
      ON CONFLICT(idempotency_key) DO NOTHING;
      SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key=v_key;
      IF v_event.opportunity_id IS DISTINCT FROM v_opp.opportunity_id
         OR v_event.event_type<>'unassigned_alerted'
         OR v_event.routing_tier IS NOT NULL
         OR v_event.metadata IS DISTINCT FROM v_meta THEN
        RAISE EXCEPTION 'guard coverage event collision';
      END IF;
      UPDATE public.lead_routing_opportunities
      SET state='unassigned_alerted',routing_tier=NULL,delivery_status='failed',
          current_delivery_attempt_id=NULL,expires_at=NULL,updated_at=NOW()
      WHERE opportunity_id=v_opp.opportunity_id;
      CONTINUE;
    END IF;

    v_base_key:='guard-offer:'||v_opp.opportunity_id::text||':'||v_tier;
    SELECT * INTO v_previous_attempt
    FROM public.lead_routing_delivery_attempts
    WHERE opportunity_id=v_opp.opportunity_id AND routing_tier=v_tier
    ORDER BY attempt_id DESC LIMIT 1 FOR UPDATE;
    v_key:=CASE
      WHEN FOUND AND v_previous_attempt.status='failed'
        THEN v_base_key||':retry:'||v_previous_attempt.attempt_id::text
      ELSE v_base_key
    END;
    v_meta:=jsonb_build_object('client_request_id',v_key,'agent_id',v_coverage.agent_id);
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,metadata)
    VALUES(v_opp.opportunity_id,'delivery_requested',v_tier,'delivery-requested:'||v_key,v_meta)
    ON CONFLICT(idempotency_key) DO NOTHING;
    SELECT * INTO v_event FROM public.lead_routing_events
    WHERE idempotency_key='delivery-requested:'||v_key;
    IF v_event.opportunity_id IS DISTINCT FROM v_opp.opportunity_id
       OR v_event.event_type<>'delivery_requested'
       OR v_event.routing_tier IS DISTINCT FROM v_tier
       OR v_event.metadata IS DISTINCT FROM v_meta THEN
      RAISE EXCEPTION 'guard delivery event collision';
    END IF;
    INSERT INTO public.lead_routing_delivery_attempts(
      opportunity_id,routing_tier,client_request_id,target_agent_id,target_number,
      claimed_at,lease_expires_at,lease_token
    ) VALUES(
      v_opp.opportunity_id,v_tier,v_key,v_coverage.agent_id,v_coverage.whatsapp_number,
      NOW(),NOW()+INTERVAL '2 minutes',gen_random_uuid()::text
    ) ON CONFLICT(client_request_id) DO NOTHING RETURNING * INTO v_attempt;
    IF NOT FOUND THEN
      SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts
      WHERE client_request_id=v_key FOR UPDATE;
      IF v_attempt.opportunity_id IS DISTINCT FROM v_opp.opportunity_id
         OR v_attempt.routing_tier IS DISTINCT FROM v_tier
         OR v_attempt.target_agent_id IS DISTINCT FROM v_coverage.agent_id
         OR v_attempt.target_number IS DISTINCT FROM v_coverage.whatsapp_number THEN
        RAISE EXCEPTION 'guard delivery request collision';
      END IF;
      IF v_attempt.status='requested' AND v_attempt.lease_expires_at<=NOW() THEN
        UPDATE public.lead_routing_delivery_attempts
        SET claimed_at=NOW(),lease_expires_at=NOW()+INTERVAL '2 minutes',lease_token=gen_random_uuid()::text
        WHERE attempt_id=v_attempt.attempt_id RETURNING * INTO v_attempt;
      ELSE
        CONTINUE;
      END IF;
    END IF;
    UPDATE public.lead_routing_opportunities
    SET state='delivery_requested',routing_tier=v_tier,delivery_status='requested',
        delivery_requested_at=NOW(),current_delivery_attempt_id=v_attempt.attempt_id,updated_at=NOW()
    WHERE opportunity_id=v_opp.opportunity_id
      AND state='guard_delivery_pending' AND current_delivery_attempt_id IS NULL;
    IF FOUND THEN RETURN NEXT v_attempt; END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=pg_catalog,public;

REVOKE ALL ON FUNCTION public.claim_pending_guard_deliveries(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_pending_guard_deliveries(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.recover_unbound_guard_delivery(
  p_opportunity_id BIGINT,
  p_failed_attempt_id BIGINT,
  p_reason TEXT
) RETURNS public.lead_routing_opportunities AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_event public.lead_routing_events;
  v_key TEXT;
  v_meta JSONB;
BEGIN
  IF p_opportunity_id IS NULL OR p_failed_attempt_id IS NULL
     OR NULLIF(btrim(p_reason),'') IS NULL THEN
    RAISE EXCEPTION 'invalid guard recovery request';
  END IF;
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts
  WHERE attempt_id=p_failed_attempt_id FOR UPDATE;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=p_opportunity_id FOR UPDATE;
  IF v_attempt.attempt_id IS NULL OR v_opp.opportunity_id IS NULL
     OR v_attempt.opportunity_id IS DISTINCT FROM p_opportunity_id
     OR v_attempt.routing_tier NOT IN ('primary_guard','backup_guard')
     OR v_attempt.status<>'failed' OR v_attempt.provider_message_id IS NOT NULL
     OR v_opp.assigned_agent_id IS NOT NULL OR v_opp.current_delivery_attempt_id IS NOT NULL
     OR EXISTS (
       SELECT 1 FROM public.lead_routing_delivery_attempts newer
       WHERE newer.opportunity_id=p_opportunity_id AND newer.attempt_id>p_failed_attempt_id
     ) THEN
    RAISE EXCEPTION 'guard recovery is not safe';
  END IF;
  v_key:='delivery-recovery:'||p_failed_attempt_id::text;
  v_meta:=jsonb_build_object(
    'reason',left(btrim(p_reason),120),
    'failed_attempt_id',p_failed_attempt_id,
    'tier',v_attempt.routing_tier
  );
  SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key=v_key;
  IF FOUND THEN
    IF v_event.opportunity_id IS DISTINCT FROM p_opportunity_id
       OR v_event.event_type<>'delivery_recovered'
       OR v_event.routing_tier IS DISTINCT FROM v_attempt.routing_tier
       OR v_event.metadata IS DISTINCT FROM v_meta THEN
      RAISE EXCEPTION 'guard recovery event collision';
    END IF;
    RETURN v_opp;
  END IF;
  IF v_opp.state<>'unassigned_alerted' THEN
    RAISE EXCEPTION 'opportunity is not unassigned';
  END IF;
  INSERT INTO public.lead_routing_events(
    opportunity_id,event_type,routing_tier,idempotency_key,metadata
  ) VALUES(
    p_opportunity_id,'delivery_recovered',v_attempt.routing_tier,v_key,v_meta
  ) RETURNING * INTO v_event;
  UPDATE public.lead_routing_opportunities
  SET state='guard_delivery_pending',routing_tier=v_attempt.routing_tier,
      delivery_status='failed',current_delivery_attempt_id=NULL,
      delivered_at=NULL,expires_at=NULL,updated_at=NOW()
  WHERE opportunity_id=p_opportunity_id RETURNING * INTO v_opp;
  RETURN v_opp;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=pg_catalog,public;

REVOKE ALL ON FUNCTION public.recover_unbound_guard_delivery(bigint,bigint,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recover_unbound_guard_delivery(bigint,bigint,text)
  TO service_role;
