-- LRV2: preserve failed attempts and create a new immutable attempt on an
-- explicitly authorized guard-delivery retry.
-- Rollback: restore claim_pending_guard_deliveries from 0040, then drop
-- requeue_failed_guard_delivery(bigint,text,text).

CREATE OR REPLACE FUNCTION public.claim_pending_guard_deliveries(
  p_limit INTEGER DEFAULT 100
) RETURNS SETOF public.lead_routing_delivery_attempts AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_coverage RECORD;
  v_attempt public.lead_routing_delivery_attempts;
  v_key TEXT;
  v_base_key TEXT;
  v_retry_no INTEGER;
  v_event public.lead_routing_events;
  v_tier TEXT;
  v_meta JSONB;
BEGIN
  FOR v_opp IN
    SELECT *
    FROM public.lead_routing_opportunities
    WHERE state = 'guard_delivery_pending'
      AND current_delivery_attempt_id IS NULL
    ORDER BY updated_at, opportunity_id
    FOR UPDATE SKIP LOCKED
    LIMIT p_limit
  LOOP
    v_tier := v_opp.routing_tier;
    SELECT * INTO v_coverage
    FROM public.get_guard_coverage_slots() c
    WHERE c.coverage_role = CASE v_tier
      WHEN 'primary_guard' THEN 'primary'
      WHEN 'backup_guard' THEN 'backup'
    END
    LIMIT 1;

    IF v_coverage.agent_id IS NULL AND v_tier = 'primary_guard' THEN
      v_tier := 'backup_guard';
      SELECT * INTO v_coverage
      FROM public.get_guard_coverage_slots() c
      WHERE c.coverage_role = 'backup'
      LIMIT 1;
    END IF;

    IF v_coverage.agent_id IS NULL THEN
      v_key := 'guard-coverage-unavailable:' || v_opp.opportunity_id::text || ':' || v_opp.routing_tier;
      v_meta := jsonb_build_object('reason', 'guard_coverage_unavailable');
      INSERT INTO public.lead_routing_events(
        opportunity_id, event_type, routing_tier, idempotency_key, metadata
      ) VALUES (
        v_opp.opportunity_id, 'unassigned_alerted', NULL, v_key, v_meta
      ) ON CONFLICT (idempotency_key) DO NOTHING;
      SELECT * INTO v_event
      FROM public.lead_routing_events
      WHERE idempotency_key = v_key;
      IF v_event.opportunity_id IS DISTINCT FROM v_opp.opportunity_id
        OR v_event.event_type <> 'unassigned_alerted'
        OR v_event.routing_tier IS NOT NULL
        OR v_event.metadata IS DISTINCT FROM v_meta THEN
        RAISE EXCEPTION 'guard coverage event collision';
      END IF;
      UPDATE public.lead_routing_opportunities
      SET state = 'unassigned_alerted', routing_tier = NULL,
          delivery_status = 'failed', current_delivery_attempt_id = NULL,
          expires_at = NULL, updated_at = NOW()
      WHERE opportunity_id = v_opp.opportunity_id;
      CONTINUE;
    END IF;

    -- Resume an abandoned requested attempt. Failed/sent/delivered attempts are
    -- immutable and therefore force creation of a new retry-keyed attempt.
    SELECT * INTO v_attempt
    FROM public.lead_routing_delivery_attempts a
    WHERE a.opportunity_id = v_opp.opportunity_id
      AND a.routing_tier = v_tier
      AND a.status = 'requested'
      AND a.provider_message_id IS NULL
    ORDER BY a.requested_at DESC, a.attempt_id DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      IF v_attempt.lease_expires_at > NOW() THEN
        CONTINUE;
      END IF;
      UPDATE public.lead_routing_delivery_attempts
      SET claimed_at = NOW(),
          lease_expires_at = NOW() + INTERVAL '2 minutes',
          lease_token = gen_random_uuid()::text
      WHERE attempt_id = v_attempt.attempt_id
      RETURNING * INTO v_attempt;
    ELSE
      v_base_key := 'guard-offer:' || v_opp.opportunity_id::text || ':' || v_tier;
      IF EXISTS (
        SELECT 1 FROM public.lead_routing_delivery_attempts
        WHERE client_request_id = v_base_key
           OR client_request_id LIKE v_base_key || ':retry:%'
      ) THEN
        SELECT COALESCE(MAX(NULLIF(substring(client_request_id FROM ':retry:([0-9]+)$'), '')::integer), 0) + 1
        INTO v_retry_no
        FROM public.lead_routing_delivery_attempts
        WHERE client_request_id LIKE v_base_key || ':retry:%';
        v_key := v_base_key || ':retry:' || v_retry_no::text;
      ELSE
        v_key := v_base_key;
      END IF;

      v_meta := jsonb_build_object(
        'client_request_id', v_key,
        'agent_id', v_coverage.agent_id,
        'retry', v_key <> v_base_key
      );
      INSERT INTO public.lead_routing_events(
        opportunity_id, event_type, routing_tier, idempotency_key, metadata
      ) VALUES (
        v_opp.opportunity_id, 'delivery_requested', v_tier,
        'delivery-requested:' || v_key, v_meta
      ) ON CONFLICT (idempotency_key) DO NOTHING;
      SELECT * INTO v_event
      FROM public.lead_routing_events
      WHERE idempotency_key = 'delivery-requested:' || v_key;
      IF v_event.opportunity_id IS DISTINCT FROM v_opp.opportunity_id
        OR v_event.event_type <> 'delivery_requested'
        OR v_event.routing_tier IS DISTINCT FROM v_tier
        OR v_event.metadata IS DISTINCT FROM v_meta THEN
        RAISE EXCEPTION 'guard delivery event collision';
      END IF;

      INSERT INTO public.lead_routing_delivery_attempts(
        opportunity_id, routing_tier, client_request_id,
        target_agent_id, target_number,
        claimed_at, lease_expires_at, lease_token
      ) VALUES (
        v_opp.opportunity_id, v_tier, v_key,
        v_coverage.agent_id, v_coverage.whatsapp_number,
        NOW(), NOW() + INTERVAL '2 minutes', gen_random_uuid()::text
      ) RETURNING * INTO v_attempt;
    END IF;

    UPDATE public.lead_routing_opportunities
    SET state = 'delivery_requested', routing_tier = v_tier,
        delivery_status = 'requested', delivery_requested_at = NOW(),
        current_delivery_attempt_id = v_attempt.attempt_id, updated_at = NOW()
    WHERE opportunity_id = v_opp.opportunity_id
      AND state = 'guard_delivery_pending'
      AND current_delivery_attempt_id IS NULL;
    IF FOUND THEN
      RETURN NEXT v_attempt;
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public;

CREATE OR REPLACE FUNCTION public.requeue_failed_guard_delivery(
  p_opportunity_id BIGINT,
  p_reason TEXT,
  p_idempotency_key TEXT
) RETURNS public.lead_routing_opportunities AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_event public.lead_routing_events;
  v_failed_attempts INTEGER;
  v_meta JSONB;
BEGIN
  IF p_opportunity_id IS NULL
    OR NULLIF(btrim(p_reason), '') IS NULL
    OR NULLIF(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'opportunity_id, reason and idempotency_key required';
  END IF;

  SELECT * INTO v_opp
  FROM public.lead_routing_opportunities
  WHERE opportunity_id = p_opportunity_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opportunity not found';
  END IF;
  IF v_opp.assigned_agent_id IS NOT NULL OR v_opp.state = 'assigned' THEN
    RAISE EXCEPTION 'assigned opportunity cannot be requeued';
  END IF;

  IF v_opp.state = 'guard_delivery_pending'
    AND v_opp.routing_tier = 'primary_guard'
    AND v_opp.current_delivery_attempt_id IS NULL THEN
    RETURN v_opp;
  END IF;
  IF v_opp.state <> 'unassigned_alerted'
    OR v_opp.current_delivery_attempt_id IS NOT NULL THEN
    RAISE EXCEPTION 'opportunity is not eligible for failed-delivery requeue';
  END IF;

  SELECT count(*) INTO v_failed_attempts
  FROM public.lead_routing_delivery_attempts
  WHERE opportunity_id = p_opportunity_id
    AND status = 'failed';
  IF v_failed_attempts = 0 THEN
    RAISE EXCEPTION 'failed delivery evidence required';
  END IF;

  v_meta := jsonb_build_object(
    'reason', left(btrim(p_reason), 120),
    'failed_attempts_preserved', v_failed_attempts
  );
  INSERT INTO public.lead_routing_events(
    opportunity_id, event_type, routing_tier, idempotency_key, metadata
  ) VALUES (
    p_opportunity_id, 'delivery_retry_requeued', 'primary_guard',
    p_idempotency_key, v_meta
  ) ON CONFLICT (idempotency_key) DO NOTHING;
  SELECT * INTO v_event
  FROM public.lead_routing_events
  WHERE idempotency_key = p_idempotency_key;
  IF v_event.opportunity_id IS DISTINCT FROM p_opportunity_id
    OR v_event.event_type <> 'delivery_retry_requeued'
    OR v_event.routing_tier IS DISTINCT FROM 'primary_guard'
    OR v_event.metadata IS DISTINCT FROM v_meta THEN
    RAISE EXCEPTION 'delivery retry event collision';
  END IF;

  UPDATE public.lead_routing_opportunities
  SET state = 'guard_delivery_pending', routing_tier = 'primary_guard',
      delivery_status = NULL, delivery_requested_at = NULL,
      delivered_at = NULL, expires_at = NULL,
      current_delivery_attempt_id = NULL, updated_at = NOW()
  WHERE opportunity_id = p_opportunity_id
  RETURNING * INTO v_opp;
  RETURN v_opp;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.claim_pending_guard_deliveries(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_pending_guard_deliveries(INTEGER) TO service_role;
REVOKE ALL ON FUNCTION public.requeue_failed_guard_delivery(BIGINT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.requeue_failed_guard_delivery(BIGINT, TEXT, TEXT) TO service_role;
