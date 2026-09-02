-- A verified V3 claim must never mutate lead_routing_events: that ledger is
-- append-only by trigger and grant.  Preserve webhook evidence in a separate,
-- idempotent append-only event instead.

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
  WHERE i.webhook_event_id = p_webhook_event_id;
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

  v_claim_parts := regexp_match(
    v_button_payload,
    '^claim:v3:([1-9][0-9]{0,17}):([1-9][0-9]{0,17})$'
  );
  IF v_claim_parts IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'invalid_claim_payload');
  END IF;
  v_opportunity_id := v_claim_parts[1]::BIGINT;
  v_attempt_id := v_claim_parts[2]::BIGINT;

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
    AND c.disposition = 'created_new';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'capture_not_verified');
  END IF;

  SELECT ag.* INTO v_agent
  FROM public.agents ag
  WHERE ag.agent_id = v_attempt.target_agent_id;
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

  IF v_result->>'outcome' = 'claimed' THEN
    -- The canonical business timestamps remain the immutable ingress time;
    -- only this maintenance timestamp records delayed processing.
    UPDATE public.lead_routing_opportunities
    SET updated_at = clock_timestamp()
    WHERE opportunity_id = v_opportunity_id;
  END IF;

  IF v_result->>'outcome' IN ('claimed', 'already_assigned') THEN
    INSERT INTO public.lead_routing_events(
      opportunity_id, event_type, routing_tier, actor_id, occurred_at,
      idempotency_key, external_evidence, metadata
    ) VALUES (
      v_opportunity_id,
      'claim_webhook_verified',
      v_attempt.routing_tier,
      v_attempt.target_agent_id,
      v_webhook.created_at,
      'v3-verified-webhook-claim:' || p_webhook_event_id::TEXT,
      jsonb_build_object(
        'webhook_event_id', p_webhook_event_id,
        'inbound_wamid', v_event_wamid,
        'context_wamid', v_context_wamid,
        'claim_ingress_at', v_webhook.created_at,
        'capture_event_id', v_attempt.capture_event_id
      ),
      jsonb_build_object(
        'verified_webhook_time', TRUE,
        'attempt_id', v_attempt_id,
        'claim_outcome', v_result->>'outcome'
      )
    ) ON CONFLICT (idempotency_key) DO NOTHING;
  END IF;

  RETURN v_result || jsonb_build_object(
    'webhook_event_id', p_webhook_event_id,
    'claim_ingress_at', v_webhook.created_at,
    'inbound_wamid', v_event_wamid
  );
END;
$$;

REVOKE ALL ON FUNCTION public.claim_v3_delivery_from_webhook(BIGINT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_v3_delivery_from_webhook(BIGINT)
  TO service_role;
