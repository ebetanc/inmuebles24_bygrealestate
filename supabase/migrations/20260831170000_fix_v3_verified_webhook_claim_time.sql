-- A verified Meta claim is ordered by the durable database ingress time, not
-- by the time an n8n worker eventually reaches the claim node.  This keeps a
-- transient workflow failure from turning an in-window click into a late one.

CREATE OR REPLACE FUNCTION public.claim_v3_delivery_from_webhook(
  p_webhook_event_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_webhook public.lead_routing_meta_webhook_inbox;
  v_event JSONB;
  v_message_type TEXT;
  v_button_payload TEXT;
  v_claim_parts TEXT[];
  v_opportunity_id BIGINT;
  v_attempt_id BIGINT;
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_capture public.i24_capture_events;
  v_agent public.agents;
  v_event_wamid TEXT;
  v_context_wamid TEXT;
  v_sender_number TEXT;
  v_target_number TEXT;
  v_agent_number TEXT;
  v_result JSONB;
BEGIN
  IF p_webhook_event_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'invalid_webhook_event_id');
  END IF;

  SELECT i.* INTO v_webhook
  FROM public.lead_routing_meta_webhook_inbox i
  WHERE i.webhook_event_id = p_webhook_event_id
  FOR SHARE;
  IF NOT FOUND OR v_webhook.event_kind IS DISTINCT FROM 'message'
     OR v_webhook.hmac_verified IS DISTINCT FROM TRUE
     OR v_webhook.created_at IS NULL
     OR jsonb_typeof(v_webhook.sanitized_payload) IS DISTINCT FROM 'object'
     OR jsonb_typeof(v_webhook.sanitized_payload->'event') IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'verified_webhook_not_found');
  END IF;

  v_event := v_webhook.sanitized_payload->'event';
  v_message_type := NULLIF(v_event->>'type', '');
  v_event_wamid := NULLIF(BTRIM(v_event->>'id'), '');
  v_context_wamid := NULLIF(BTRIM(v_event #>> '{context,id}'), '');
  v_sender_number := NULLIF(BTRIM(v_event->>'from'), '');
  v_button_payload := CASE v_message_type
    WHEN 'button' THEN NULLIF(BTRIM(v_event #>> '{button,payload}'), '')
    WHEN 'interactive' THEN NULLIF(BTRIM(v_event #>> '{interactive,button_reply,id}'), '')
    ELSE NULL
  END;

  IF v_event_wamid IS NULL OR v_event_wamid IS DISTINCT FROM v_webhook.wamid
     OR v_context_wamid IS NULL
     OR v_webhook.sanitized_payload->>'context_id' IS DISTINCT FROM v_context_wamid
     OR v_sender_number IS NULL OR v_button_payload IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'verified_webhook_mismatch');
  END IF;

  -- The bounded groups make the bigint casts total for untrusted button text.
  v_claim_parts := regexp_match(
    v_button_payload,
    '^claim:v3:([1-9][0-9]{0,17}):([1-9][0-9]{0,17})$'
  );
  IF v_claim_parts IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'invalid_claim_payload');
  END IF;
  v_opportunity_id := v_claim_parts[1]::BIGINT;
  v_attempt_id := v_claim_parts[2]::BIGINT;

  -- Match claim_v3_delivery's lock order so the wrapper and timeout sweeper
  -- serialize on the same canonical opportunity and delivery attempt.
  SELECT o.* INTO v_opp
  FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id = v_opportunity_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'opportunity_not_found');
  END IF;

  SELECT a.* INTO v_attempt
  FROM public.lead_routing_delivery_attempts a
  WHERE a.attempt_id = v_attempt_id
  FOR UPDATE;
  IF NOT FOUND OR v_attempt.opportunity_id IS DISTINCT FROM v_opportunity_id
     OR v_opp.current_delivery_attempt_id IS DISTINCT FROM v_attempt_id
     OR v_attempt.delivery_kind IS DISTINCT FROM 'offer'
     OR v_attempt.routing_tier NOT IN ('owner', 'primary_guard')
     OR v_opp.routing_tier IS DISTINCT FROM v_attempt.routing_tier
     OR v_attempt.capture_event_id IS NULL
     OR v_attempt.requested_at IS NULL
     OR v_attempt.target_agent_id IS NULL
     OR v_attempt.provider_message_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'attempt_mismatch');
  END IF;

  SELECT c.* INTO v_capture
  FROM public.i24_capture_events c
  WHERE c.capture_event_id = v_attempt.capture_event_id
    AND c.opportunity_id = v_opportunity_id
    AND c.contactado_status = 'verified'
    AND c.disposition = 'created_new'
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'capture_not_verified');
  END IF;

  SELECT ag.* INTO v_agent
  FROM public.agents ag
  WHERE ag.agent_id = v_attempt.target_agent_id
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'sender_not_found');
  END IF;

  v_target_number := NULLIF(BTRIM(v_attempt.target_number), '');
  v_agent_number := NULLIF(BTRIM(v_agent.whatsapp_number), '');
  IF v_sender_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$'
     OR v_target_number IS NULL
     OR v_target_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$'
     OR v_agent_number IS NULL
     OR v_agent_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$' THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender_number');
  END IF;
  v_sender_number := REGEXP_REPLACE(v_sender_number, '[ +()-]', '', 'g');
  v_target_number := REGEXP_REPLACE(v_target_number, '[ +()-]', '', 'g');
  v_agent_number := REGEXP_REPLACE(v_agent_number, '[ +()-]', '', 'g');
  IF v_sender_number !~ '^[1-9][0-9]{7,14}$'
     OR v_target_number IS DISTINCT FROM v_sender_number
     OR v_agent_number IS DISTINCT FROM v_sender_number THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender_number');
  END IF;

  IF v_context_wamid IS DISTINCT FROM v_attempt.provider_message_id THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_context');
  END IF;
  IF v_opp.expires_at IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'missing_deadline');
  END IF;
  IF v_webhook.created_at < v_attempt.requested_at
     OR v_webhook.created_at >= v_opp.expires_at THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'late');
  END IF;

  -- claim_v3_delivery retains all delivery, conversation, first-wins and state
  -- checks.  Its time input is the immutable DB ingress time for this exact
  -- HMAC-verified webhook, never the worker's eventual processing time.
  v_result := public.claim_v3_delivery(
    v_opportunity_id,
    v_attempt_id,
    v_attempt.capture_event_id,
    v_attempt.target_agent_id,
    v_sender_number,
    v_context_wamid,
    NULL,
    v_webhook.created_at
  );
  IF v_result->>'outcome' IN ('claimed', 'already_assigned') THEN
    -- Business timestamps preserve the authenticated ingress order.  The
    -- maintenance timestamp records when the delayed transaction completed.
    UPDATE public.lead_routing_opportunities
    SET updated_at = clock_timestamp()
    WHERE opportunity_id = v_opportunity_id;
    UPDATE public.lead_routing_events
    SET external_evidence = COALESCE(external_evidence, '{}'::JSONB)
          || jsonb_build_object(
            'webhook_event_id', p_webhook_event_id,
            'inbound_wamid', v_event_wamid,
            'claim_ingress_at', v_webhook.created_at
          ),
        metadata = COALESCE(metadata, '{}'::JSONB)
          || jsonb_build_object('verified_webhook_time', TRUE)
    WHERE opportunity_id = v_opportunity_id
      AND idempotency_key = 'v3-delivery-claim:' || v_attempt_id::TEXT
        || ':' || v_attempt.provider_message_id;
  END IF;
  RETURN v_result || jsonb_build_object(
    'webhook_event_id', p_webhook_event_id,
    'claim_ingress_at', v_webhook.created_at,
    'inbound_wamid', v_event_wamid
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.claim_pending_v3_webhook_for_attempt(
  p_opportunity_id BIGINT,
  p_attempt_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_webhook_event_id BIGINT;
BEGIN
  IF p_opportunity_id IS NULL OR p_attempt_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'invalid_pending_claim_input');
  END IF;

  SELECT o.* INTO v_opp
  FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id = p_opportunity_id
  FOR UPDATE;
  IF NOT FOUND OR v_opp.assigned_agent_id IS NOT NULL
     OR v_opp.current_delivery_attempt_id IS DISTINCT FROM p_attempt_id
     OR v_opp.expires_at IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'claim_not_pending');
  END IF;

  SELECT a.* INTO v_attempt
  FROM public.lead_routing_delivery_attempts a
  WHERE a.attempt_id = p_attempt_id
    AND a.opportunity_id = p_opportunity_id
    AND a.delivery_kind = 'offer'
    AND a.routing_tier IN ('owner', 'primary_guard')
    AND a.capture_event_id IS NOT NULL
    AND a.requested_at IS NOT NULL
    AND a.provider_message_id IS NOT NULL
    AND a.target_number IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'attempt_mismatch');
  END IF;

  SELECT i.webhook_event_id INTO v_webhook_event_id
  FROM public.lead_routing_meta_webhook_inbox i
  WHERE i.event_kind = 'message'
    AND i.hmac_verified
    AND i.created_at >= v_attempt.requested_at
    AND i.created_at < v_opp.expires_at
    AND i.wamid = i.sanitized_payload #>> '{event,id}'
    AND i.sanitized_payload #>> '{event,context,id}' = v_attempt.provider_message_id
    AND i.sanitized_payload->>'context_id' = v_attempt.provider_message_id
    AND REGEXP_REPLACE(i.sanitized_payload #>> '{event,from}', '[ +()-]', '', 'g')
        = REGEXP_REPLACE(v_attempt.target_number, '[ +()-]', '', 'g')
    AND COALESCE(
      CASE i.sanitized_payload #>> '{event,type}'
        WHEN 'button' THEN i.sanitized_payload #>> '{event,button,payload}'
        WHEN 'interactive' THEN i.sanitized_payload #>> '{event,interactive,button_reply,id}'
      END,
      ''
    ) = 'claim:v3:' || p_opportunity_id::TEXT || ':' || p_attempt_id::TEXT
  ORDER BY i.created_at, i.webhook_event_id
  LIMIT 1
  FOR SHARE;

  IF v_webhook_event_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'no_verified_claim_pending');
  END IF;
  RETURN public.claim_v3_delivery_from_webhook(v_webhook_event_id);
END;
$$;


-- Preserve the established transition contract, but consume an already
-- persisted, verified, in-window claim before any timeout fallback.
CREATE OR REPLACE FUNCTION public.v3_advance_routing_tier(
  p_opportunity_id BIGINT,
  p_expected_tier TEXT,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_guard RECORD;
  v_guard_found BOOLEAN := FALSE;
  v_attempt_id BIGINT;
  v_pending_claim JSONB;
BEGIN
  IF p_expected_tier NOT IN ('owner','primary_guard') OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid V3 routing transition';
  END IF;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT v_opp.v3_enabled OR v_opp.assigned_agent_id IS NOT NULL THEN
    RETURN jsonb_build_object('state',COALESCE(v_opp.state,'missing'),'opportunity_id',p_opportunity_id);
  END IF;
  IF v_opp.current_delivery_attempt_id IS NOT NULL THEN
    SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts
    WHERE attempt_id=v_opp.current_delivery_attempt_id FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('state','missing_delivery_attempt','opportunity_id',p_opportunity_id);
    END IF;
  ELSE
    RETURN jsonb_build_object('state','missing_delivery_attempt','opportunity_id',p_opportunity_id);
  END IF;
  IF v_attempt.capture_event_id IS NULL THEN
    RETURN jsonb_build_object('state','missing_capture_context','opportunity_id',p_opportunity_id);
  END IF;
  IF v_attempt.delivered_at IS NOT NULL THEN
    IF v_opp.expires_at IS NULL THEN
      UPDATE public.lead_routing_opportunities
      SET expires_at=v_attempt.delivered_at+INTERVAL '5 minutes', updated_at=p_now
      WHERE opportunity_id=p_opportunity_id AND expires_at IS NULL;
      v_opp.expires_at := v_attempt.delivered_at+INTERVAL '5 minutes';
    END IF;
    IF v_opp.expires_at>p_now THEN
      RETURN jsonb_build_object('state','open','opportunity_id',p_opportunity_id);
    END IF;
  END IF;
  IF v_attempt.delivered_at IS NULL
     AND COALESCE(v_attempt.provider_accepted_at,v_attempt.requested_at)
         +INTERVAL '2 minutes'>p_now THEN
    RETURN jsonb_build_object('state','awaiting_delivery_timeout','opportunity_id',p_opportunity_id);
  END IF;

  v_pending_claim := public.claim_pending_v3_webhook_for_attempt(
    p_opportunity_id,
    v_attempt.attempt_id
  );
  IF v_pending_claim->>'outcome' IN ('claimed', 'already_assigned') THEN
    RETURN jsonb_build_object(
      'state', 'assigned',
      'tier', 'verified_claim',
      'opportunity_id', p_opportunity_id,
      'attempt_id', v_attempt.attempt_id,
      'capture_event_id', v_attempt.capture_event_id,
      'assigned_agent_id', v_pending_claim->>'assigned_agent_id',
      'webhook_event_id', v_pending_claim->>'webhook_event_id'
    );
  END IF;

  IF p_expected_tier='owner' THEN
    SELECT * INTO v_guard FROM public.get_guard_coverage_slots(
      (p_now AT TIME ZONE 'America/Mexico_City')::DATE,
      CASE
        WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '08:00:00'
         AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '14:00:00' THEN 'morning'
        WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '14:00:00'
         AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '20:00:00' THEN 'afternoon'
        ELSE 'night'
      END
    ) WHERE coverage_role='primary' LIMIT 1;
    v_guard_found := FOUND;
    IF NOT v_guard_found OR v_guard.agent_id IS NOT DISTINCT FROM v_attempt.target_agent_id THEN
      PERFORM public.v3_assign_sandy(
        p_opportunity_id,
        CASE WHEN NOT v_guard_found THEN 'guard_unavailable' ELSE 'owner_equals_guard' END,
        v_attempt.capture_event_id,
        p_now
      );
      RETURN jsonb_build_object('state','assigned','tier','sandy','opportunity_id',p_opportunity_id);
    END IF;
    UPDATE public.lead_routing_opportunities
    SET state='guard_delivery_pending',routing_tier='primary_guard',delivery_status=NULL,
        current_delivery_attempt_id=NULL,delivered_at=NULL,expires_at=NULL,updated_at=p_now
    WHERE opportunity_id=p_opportunity_id;
    v_attempt_id := public.v3_request_offer(
      v_attempt.capture_event_id,
      'primary_guard',
      'v3:guard:'||p_opportunity_id::TEXT||':'||v_attempt.capture_event_id::TEXT,
      v_guard.agent_id,
      v_guard.whatsapp_number
    );
    RETURN jsonb_build_object(
      'state','guard_delivery_requested','tier','primary_guard',
      'attempt_id',v_attempt_id,'opportunity_id',p_opportunity_id,
      'capture_event_id',v_attempt.capture_event_id
    );
  END IF;
  PERFORM public.v3_assign_sandy(
    p_opportunity_id,
    'guard_expired',
    v_attempt.capture_event_id,
    p_now
  );
  RETURN jsonb_build_object('state','assigned','tier','sandy','opportunity_id',p_opportunity_id);
END;
$$;

REVOKE ALL ON FUNCTION public.claim_v3_delivery_from_webhook(BIGINT),
  public.claim_pending_v3_webhook_for_attempt(BIGINT,BIGINT)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_v3_delivery_from_webhook(BIGINT),
  public.claim_pending_v3_webhook_for_attempt(BIGINT,BIGINT)
  TO service_role;
