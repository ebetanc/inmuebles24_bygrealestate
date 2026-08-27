-- V3-05/V3-06 LOCAL DRAFT ONLY: PROPOSED / NO APLICADO.
--
-- V3-05: Meta webhook is persisted before WF22 returns HTTP 200. HMAC
-- verification and payload sanitization happen outside Postgres; this DB
-- contract accepts only the already-verified, already-sanitized envelope.
-- V3-06: the response claim is one atomic first-wins transition on the
-- canonical opportunity and delivery-attempt tables.

CREATE TABLE IF NOT EXISTS public.lead_routing_meta_webhook_inbox (
  webhook_event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  idempotency_key TEXT NOT NULL CHECK (NULLIF(BTRIM(idempotency_key), '') IS NOT NULL),
  event_kind TEXT NOT NULL CHECK (event_kind IN ('message', 'status')),
  wamid TEXT NOT NULL CHECK (NULLIF(BTRIM(wamid), '') IS NOT NULL),
  status_name TEXT,
  provider_event_at TIMESTAMPTZ,
  sanitized_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
  payload_sha256 TEXT NOT NULL CHECK (payload_sha256 ~ '^[0-9a-f]{64}$'),
  hmac_verified BOOLEAN NOT NULL DEFAULT FALSE,
  processing_state TEXT NOT NULL DEFAULT 'pending'
    CHECK (processing_state IN ('pending', 'leased', 'processed', 'failed', 'exhausted')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  lease_token UUID,
  lease_expires_at TIMESTAMPTZ,
  next_attempt_at TIMESTAMPTZ DEFAULT NOW(),
  last_error_code TEXT,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK ((event_kind = 'message' AND status_name IS NULL)
      OR (event_kind = 'status' AND status_name IN ('sent', 'delivered', 'read', 'failed')))
);

CREATE UNIQUE INDEX IF NOT EXISTS lead_routing_meta_webhook_inbox_key_uniq
  ON public.lead_routing_meta_webhook_inbox(idempotency_key);
CREATE UNIQUE INDEX IF NOT EXISTS lead_routing_meta_webhook_inbox_wamid_kind_status_uniq
  ON public.lead_routing_meta_webhook_inbox(wamid, event_kind, COALESCE(status_name, 'message'));
CREATE INDEX IF NOT EXISTS lead_routing_meta_webhook_inbox_claim_idx
  ON public.lead_routing_meta_webhook_inbox(processing_state, next_attempt_at, received_at, webhook_event_id);

ALTER TABLE public.lead_routing_meta_webhook_inbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lead_routing_meta_webhook_inbox FROM PUBLIC, anon, authenticated;
-- SECURITY INVOKER RPCs execute as service_role, so they need DML rights;
-- keep the boundary column-scoped. No broad direct table write is granted.
REVOKE INSERT, UPDATE ON TABLE public.lead_routing_meta_webhook_inbox FROM service_role;
GRANT SELECT ON TABLE public.lead_routing_meta_webhook_inbox TO service_role;
GRANT INSERT (
  idempotency_key, event_kind, wamid, status_name, provider_event_at,
  sanitized_payload, payload_sha256, hmac_verified, received_at
) ON TABLE public.lead_routing_meta_webhook_inbox TO service_role;
GRANT UPDATE (
  processing_state, attempts, lease_token, lease_expires_at, next_attempt_at,
  last_error_code, processed_at
) ON TABLE public.lead_routing_meta_webhook_inbox TO service_role;
REVOKE ALL ON SEQUENCE public.lead_routing_meta_webhook_inbox_webhook_event_id_seq FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.lead_routing_meta_webhook_inbox_webhook_event_id_seq TO service_role;

-- WF22 must call this RPC before its HTTP response node. The function never
-- calculates HMAC or stores an unsanitized provider payload.
CREATE OR REPLACE FUNCTION public.ingest_v3_meta_webhook_event(
  p_idempotency_key TEXT,
  p_event_kind TEXT,
  p_wamid TEXT,
  p_status_name TEXT DEFAULT NULL,
  p_provider_event_at TIMESTAMPTZ DEFAULT NULL,
  p_sanitized_payload JSONB DEFAULT '{}'::JSONB,
  p_payload_sha256 TEXT DEFAULT NULL,
  p_hmac_verified BOOLEAN DEFAULT FALSE,
  p_received_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_existing public.lead_routing_meta_webhook_inbox;
  v_idempotency TEXT := NULLIF(BTRIM(p_idempotency_key), '');
  v_kind TEXT := NULLIF(LOWER(BTRIM(p_event_kind)), '');
  v_wamid TEXT := NULLIF(BTRIM(p_wamid), '');
  v_status TEXT := NULLIF(LOWER(BTRIM(p_status_name)), '');
  v_hash TEXT := LOWER(NULLIF(BTRIM(p_payload_sha256), ''));
BEGIN
  IF v_idempotency IS NULL OR v_kind NOT IN ('message', 'status')
     OR v_wamid IS NULL OR v_hash IS NULL OR v_hash !~ '^[0-9a-f]{64}$'
     OR p_hmac_verified IS DISTINCT FROM TRUE OR p_received_at IS NULL
     OR p_sanitized_payload IS NULL OR jsonb_typeof(p_sanitized_payload) <> 'object'
     OR (v_kind = 'message' AND v_status IS NOT NULL)
     OR (v_kind = 'status' AND v_status NOT IN ('sent', 'delivered', 'read', 'failed')) THEN
    RAISE EXCEPTION 'invalid verified Meta webhook envelope';
  END IF;

  -- Idempotent replay is a success and returns the durable original row.
  SELECT * INTO v_existing
  FROM public.lead_routing_meta_webhook_inbox
  WHERE idempotency_key = v_idempotency
     OR (wamid = v_wamid AND event_kind = v_kind
         AND COALESCE(status_name, 'message') = COALESCE(v_status, 'message'))
  ORDER BY webhook_event_id
  LIMIT 1
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.idempotency_key <> v_idempotency
       AND v_existing.payload_sha256 <> v_hash THEN
      RAISE EXCEPTION 'Meta webhook idempotency collision';
    END IF;
    IF v_existing.event_kind <> v_kind OR v_existing.wamid <> v_wamid
       OR v_existing.status_name IS DISTINCT FROM v_status
       OR v_existing.payload_sha256 <> v_hash THEN
      RAISE EXCEPTION 'Meta webhook envelope collision';
    END IF;
    RETURN jsonb_build_object('ok', TRUE, 'replay', TRUE,
      'webhook_event_id', v_existing.webhook_event_id,
      'processing_state', v_existing.processing_state);
  END IF;

  INSERT INTO public.lead_routing_meta_webhook_inbox(
    idempotency_key, event_kind, wamid, status_name, provider_event_at,
    sanitized_payload, payload_sha256, hmac_verified, received_at
  ) VALUES (
    v_idempotency, v_kind, v_wamid, v_status, p_provider_event_at,
    p_sanitized_payload, v_hash, TRUE, p_received_at
  ) RETURNING * INTO v_existing;

  RETURN jsonb_build_object('ok', TRUE, 'replay', FALSE,
    'webhook_event_id', v_existing.webhook_event_id,
    'processing_state', v_existing.processing_state);
EXCEPTION WHEN unique_violation THEN
  SELECT * INTO v_existing
  FROM public.lead_routing_meta_webhook_inbox
  WHERE idempotency_key = v_idempotency
     OR (wamid = v_wamid AND event_kind = v_kind
         AND COALESCE(status_name, 'message') = COALESCE(v_status, 'message'))
  ORDER BY webhook_event_id LIMIT 1;
  IF NOT FOUND OR v_existing.payload_sha256 <> v_hash THEN
    RAISE EXCEPTION 'Meta webhook idempotency collision';
  END IF;
  RETURN jsonb_build_object('ok', TRUE, 'replay', TRUE,
    'webhook_event_id', v_existing.webhook_event_id,
    'processing_state', v_existing.processing_state);
END;
$$;

-- Claims are short leases so a crashed WF22 worker can be replayed safely.
CREATE OR REPLACE FUNCTION public.claim_v3_meta_webhook_events(
  p_limit INTEGER DEFAULT 50,
  p_now TIMESTAMPTZ DEFAULT NOW(),
  p_lease INTERVAL DEFAULT INTERVAL '2 minutes'
) RETURNS TABLE(
  webhook_event_id BIGINT, idempotency_key TEXT, event_kind TEXT, wamid TEXT,
  status_name TEXT, sanitized_payload JSONB, attempts INTEGER, lease_token UUID
)
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR p_now IS NULL
     OR p_lease IS NULL OR p_lease <= INTERVAL '0 seconds' OR p_lease > INTERVAL '15 minutes' THEN
    RAISE EXCEPTION 'invalid Meta webhook claim input';
  END IF;
  RETURN QUERY
  WITH candidates AS (
    SELECT i.webhook_event_id
    FROM public.lead_routing_meta_webhook_inbox i
    WHERE i.hmac_verified
      AND (i.processing_state = 'pending'
        OR (i.processing_state IN ('failed', 'leased') AND i.next_attempt_at <= p_now))
      AND (i.lease_expires_at IS NULL OR i.lease_expires_at <= p_now)
    ORDER BY i.next_attempt_at, i.received_at, i.webhook_event_id
    FOR UPDATE SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.lead_routing_meta_webhook_inbox i
    SET processing_state = 'leased', lease_token = gen_random_uuid(),
        lease_expires_at = p_now + p_lease, attempts = i.attempts + 1
    FROM candidates c
    WHERE i.webhook_event_id = c.webhook_event_id
    RETURNING i.webhook_event_id, i.idempotency_key, i.event_kind, i.wamid,
      i.status_name, i.sanitized_payload, i.attempts, i.lease_token
  )
  SELECT * FROM claimed;
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_v3_meta_webhook_event(
  p_webhook_event_id BIGINT,
  p_lease_token UUID,
  p_success BOOLEAN,
  p_error_code TEXT DEFAULT NULL,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.lead_routing_meta_webhook_inbox;
  v_state TEXT;
  v_next TIMESTAMPTZ;
BEGIN
  IF p_webhook_event_id IS NULL OR p_lease_token IS NULL OR p_success IS NULL
     OR p_now IS NULL OR LENGTH(COALESCE(p_error_code, '')) > 120 THEN
    RAISE EXCEPTION 'invalid Meta webhook finish input';
  END IF;
  SELECT * INTO v_row FROM public.lead_routing_meta_webhook_inbox
  WHERE webhook_event_id = p_webhook_event_id FOR UPDATE;
  IF NOT FOUND OR v_row.processing_state <> 'leased'
     OR v_row.lease_token IS DISTINCT FROM p_lease_token
     OR v_row.lease_expires_at <= p_now THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'lease_invalid');
  END IF;
  IF p_success THEN
    UPDATE public.lead_routing_meta_webhook_inbox
    SET processing_state = 'processed', lease_token = NULL, lease_expires_at = NULL,
        next_attempt_at = NULL, last_error_code = NULL, processed_at = p_now
    WHERE webhook_event_id = p_webhook_event_id;
    RETURN jsonb_build_object('ok', TRUE, 'outcome', 'processed');
  END IF;
  v_state := CASE WHEN v_row.attempts >= 5 THEN 'exhausted' ELSE 'failed' END;
  v_next := CASE v_row.attempts
    WHEN 1 THEN p_now + INTERVAL '1 minute'
    WHEN 2 THEN p_now + INTERVAL '5 minutes'
    WHEN 3 THEN p_now + INTERVAL '15 minutes'
    WHEN 4 THEN p_now + INTERVAL '30 minutes'
    ELSE NULL END;
  UPDATE public.lead_routing_meta_webhook_inbox
  SET processing_state = v_state, lease_token = NULL, lease_expires_at = NULL,
      next_attempt_at = v_next, last_error_code = NULLIF(LEFT(BTRIM(p_error_code), 120), '')
  WHERE webhook_event_id = p_webhook_event_id;
  RETURN jsonb_build_object('ok', TRUE, 'outcome', v_state, 'next_attempt_at', v_next);
END;
$$;

CREATE OR REPLACE FUNCTION public.replay_v3_meta_webhook_event(
  p_webhook_event_id BIGINT,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_webhook_event_id IS NULL OR p_now IS NULL THEN RAISE EXCEPTION 'invalid Meta webhook replay input'; END IF;
  UPDATE public.lead_routing_meta_webhook_inbox
  SET processing_state = 'pending', lease_token = NULL, lease_expires_at = NULL,
      next_attempt_at = p_now, last_error_code = NULL
  WHERE webhook_event_id = p_webhook_event_id AND processing_state IN ('failed', 'exhausted');
  RETURN FOUND;
END;
$$;

-- V3-06. The sender must be the exact target of the current attempt, and the
-- inbound context must point to the provider WAMID of that attempt. A
-- delivered/read callback is required; provider acceptance alone is not.
CREATE OR REPLACE FUNCTION public.claim_v3_delivery(
  p_opportunity_id BIGINT,
  p_attempt_id BIGINT,
  p_capture_event_id BIGINT,
  p_sender_agent_id TEXT,
  p_sender_number TEXT,
  p_reply_to_wamid TEXT DEFAULT NULL,
  p_context_wamid TEXT DEFAULT NULL,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_agent public.agents;
  v_capture public.i24_capture_events;
  v_conversation_assigned_agent_id TEXT;
  v_wamid TEXT := NULLIF(BTRIM(COALESCE(p_reply_to_wamid, p_context_wamid)), '');
  v_sender_number TEXT := NULLIF(BTRIM(p_sender_number), '');
  v_target_number TEXT;
  v_agent_number TEXT;
  v_deadline TIMESTAMPTZ;
  v_delivery_proven BOOLEAN := FALSE;
  v_updated_count INTEGER := 0;
  v_assigned_agent_id TEXT;
  v_event_key TEXT;
BEGIN
  IF p_opportunity_id IS NULL OR p_attempt_id IS NULL OR p_capture_event_id IS NULL
     OR NULLIF(BTRIM(p_sender_agent_id), '') IS NULL OR p_now IS NULL
     OR (p_reply_to_wamid IS NULL AND p_context_wamid IS NULL)
     OR (p_reply_to_wamid IS NOT NULL AND p_context_wamid IS NOT NULL
         AND BTRIM(p_reply_to_wamid) <> BTRIM(p_context_wamid)) THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'invalid_input');
  END IF;

  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id = p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', FALSE, 'outcome', 'opportunity_not_found'); END IF;
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts
  WHERE attempt_id = p_attempt_id FOR UPDATE;
  IF NOT FOUND OR v_attempt.opportunity_id <> p_opportunity_id THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'attempt_mismatch');
  END IF;
  IF v_opp.current_delivery_attempt_id IS DISTINCT FROM v_attempt.attempt_id THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'attempt_not_current');
  END IF;
  IF NOT v_opp.v3_enabled OR v_attempt.delivery_kind IS DISTINCT FROM 'offer'
     OR v_attempt.capture_event_id IS DISTINCT FROM p_capture_event_id
     OR v_attempt.routing_tier NOT IN ('owner', 'primary_guard')
     OR v_opp.routing_tier IS DISTINCT FROM v_attempt.routing_tier THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'attempt_not_v3_offer');
  END IF;
  SELECT * INTO v_capture FROM public.i24_capture_events
  WHERE capture_event_id = p_capture_event_id AND opportunity_id = p_opportunity_id
    AND contactado_status = 'verified' AND disposition = 'created_new'
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'capture_not_verified');
  END IF;
  IF v_attempt.target_agent_id IS NULL OR v_attempt.target_agent_id <> BTRIM(p_sender_agent_id) THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender');
  END IF;
  SELECT * INTO v_agent FROM public.agents WHERE agent_id = BTRIM(p_sender_agent_id);
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', FALSE, 'outcome', 'sender_not_found'); END IF;
  v_target_number := NULLIF(BTRIM(v_attempt.target_number), '');
  v_agent_number := NULLIF(BTRIM(v_agent.whatsapp_number), '');
  -- Production stores canonical digits without a leading plus, while Meta may
  -- send either that representation or display punctuation.  Validate the
  -- complete raw value first, then compare one canonical 8-15 digit form.
  IF v_sender_number IS NULL OR v_sender_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$'
     OR v_target_number IS NULL OR v_target_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$'
     OR v_agent_number IS NULL OR v_agent_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$' THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender_number');
  END IF;
  v_sender_number := REGEXP_REPLACE(v_sender_number, '[ +()-]', '', 'g');
  v_target_number := REGEXP_REPLACE(v_target_number, '[ +()-]', '', 'g');
  v_agent_number := REGEXP_REPLACE(v_agent_number, '[ +()-]', '', 'g');
  IF v_sender_number !~ '^[1-9][0-9]{7,14}$'
     OR v_target_number !~ '^[1-9][0-9]{7,14}$'
     OR v_agent_number !~ '^[1-9][0-9]{7,14}$'
     OR v_target_number IS DISTINCT FROM v_sender_number
     OR v_agent_number IS DISTINCT FROM v_target_number THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender_number');
  END IF;
  IF v_attempt.provider_message_id IS NULL OR v_wamid IS DISTINCT FROM v_attempt.provider_message_id THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_context');
  END IF;

  v_delivery_proven := (v_attempt.status = 'delivered' AND v_attempt.delivered_at IS NOT NULL)
    OR EXISTS (SELECT 1 FROM public.lead_routing_delivery_callbacks c
      WHERE c.provider_message_id = v_attempt.provider_message_id
        AND c.delivery_status = 'delivered')
    OR EXISTS (SELECT 1 FROM public.lead_routing_meta_webhook_inbox i
      WHERE i.wamid = v_attempt.provider_message_id AND i.event_kind = 'status'
        AND i.status_name IN ('delivered', 'read') AND i.hmac_verified);
  IF NOT v_delivery_proven THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'delivery_not_confirmed');
  END IF;

  -- The opportunity deadline is the sole authority; WF3b cannot extend it.
  v_deadline := v_opp.expires_at;
  IF v_deadline IS NULL THEN RETURN jsonb_build_object('ok', FALSE, 'outcome', 'missing_deadline'); END IF;
  IF p_now >= v_deadline THEN RETURN jsonb_build_object('ok', FALSE, 'outcome', 'late'); END IF;
  IF v_opp.conversation_id IS NOT NULL THEN
    SELECT assigned_agent_id INTO v_conversation_assigned_agent_id
    FROM public.conversations WHERE conversation_id = v_opp.conversation_id FOR UPDATE;
    IF v_conversation_assigned_agent_id IS NOT NULL
       AND v_conversation_assigned_agent_id <> BTRIM(p_sender_agent_id) THEN
      RETURN jsonb_build_object('ok', FALSE, 'outcome', 'conversation_already_assigned_other',
        'opportunity_id', p_opportunity_id,
        'assigned_agent_id', v_conversation_assigned_agent_id);
    END IF;
  END IF;
  IF v_opp.assigned_agent_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', TRUE,
      'outcome', CASE WHEN v_opp.assigned_agent_id = BTRIM(p_sender_agent_id)
                      THEN 'already_assigned' ELSE 'already_assigned_other' END,
      'opportunity_id', p_opportunity_id, 'assigned_agent_id', v_opp.assigned_agent_id);
  END IF;
  IF v_opp.routing_tier NOT IN ('owner', 'primary_guard')
     OR v_opp.state NOT IN ('owner_open', 'primary_guard_open', 'delivered') THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'state_not_claimable');
  END IF;

  -- First-wins: the opportunity row lock plus this NULL predicate makes the
  -- assignment and its event one durable transaction.
  UPDATE public.lead_routing_opportunities
  SET assigned_agent_id = BTRIM(p_sender_agent_id), assigned_at = p_now,
      accepted_at = COALESCE(accepted_at, p_now), state = 'assigned',
      updated_at = p_now
  WHERE opportunity_id = p_opportunity_id AND assigned_agent_id IS NULL;
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count = 0 THEN
    SELECT assigned_agent_id INTO v_assigned_agent_id
    FROM public.lead_routing_opportunities WHERE opportunity_id = p_opportunity_id;
    RETURN jsonb_build_object('ok', TRUE, 'outcome', 'already_assigned_other',
      'opportunity_id', p_opportunity_id, 'assigned_agent_id', v_assigned_agent_id);
  END IF;
  UPDATE public.lead_routing_delivery_attempts
  SET claimed_at = COALESCE(claimed_at, p_now)
  WHERE attempt_id = p_attempt_id;
  IF v_opp.conversation_id IS NOT NULL THEN
    UPDATE public.conversations SET assigned_agent_id = BTRIM(p_sender_agent_id),
      assigned_at = COALESCE(assigned_at, p_now), assignment_method = 'v3_response_claim',
      claimed_via = 'v3_meta_webhook', mode = 'ai'
    WHERE conversation_id = v_opp.conversation_id AND assigned_agent_id IS NULL;
  END IF;
  v_event_key := 'v3-delivery-claim:' || p_attempt_id::TEXT || ':' || v_wamid;
  INSERT INTO public.lead_routing_events(
    opportunity_id, event_type, routing_tier, actor_id, idempotency_key,
    external_evidence, metadata
  ) VALUES (
    p_opportunity_id, 'accepted', v_attempt.routing_tier, BTRIM(p_sender_agent_id), v_event_key,
    jsonb_build_object('provider_message_id', v_wamid, 'sender_number', v_sender_number),
    jsonb_build_object('first_wins', TRUE, 'attempt_id', p_attempt_id)
  ) ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN jsonb_build_object('ok', TRUE, 'outcome', 'claimed',
    'opportunity_id', p_opportunity_id, 'assigned_agent_id', BTRIM(p_sender_agent_id),
    'attempt_id', p_attempt_id, 'provider_message_id', v_wamid);
END;
$$;

REVOKE ALL ON FUNCTION public.ingest_v3_meta_webhook_event(TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,JSONB,TEXT,BOOLEAN,TIMESTAMPTZ),
  public.claim_v3_meta_webhook_events(INTEGER,TIMESTAMPTZ,INTERVAL),
  public.finish_v3_meta_webhook_event(BIGINT,UUID,BOOLEAN,TEXT,TIMESTAMPTZ),
  public.replay_v3_meta_webhook_event(BIGINT,TIMESTAMPTZ),
  public.claim_v3_delivery(BIGINT,BIGINT,BIGINT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_v3_meta_webhook_event(TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,JSONB,TEXT,BOOLEAN,TIMESTAMPTZ),
  public.claim_v3_meta_webhook_events(INTEGER,TIMESTAMPTZ,INTERVAL),
  public.finish_v3_meta_webhook_event(BIGINT,UUID,BOOLEAN,TEXT,TIMESTAMPTZ),
  public.replay_v3_meta_webhook_event(BIGINT,TIMESTAMPTZ),
  public.claim_v3_delivery(BIGINT,BIGINT,BIGINT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ)
  TO service_role;
