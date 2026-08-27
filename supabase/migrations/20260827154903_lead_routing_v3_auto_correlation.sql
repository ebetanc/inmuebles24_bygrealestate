-- V3-02b LOCAL DRAFT ONLY: PROPOSED / NO APLICADO.
-- Depends on V3-03/04 adding i24_capture_events.opportunity_id and on the
-- V3-07 request-level effect ledger. No portal, WhatsApp, or live mutation.
--
-- The worker never guesses: property must match exactly (case-insensitive),
-- at least one identity (email or e164 phone) must match exactly, and every
-- identity present on both sides must agree. Zero candidates remain awaiting
-- until the EasyBroker checkpoint covers the capture horizon; after that they
-- become manual_review:no_eb_request. Ambiguity and contradiction are
-- manual-review outcomes immediately.

-- V3 opportunities carry the EasyBroker property code directly.  The original
-- G1 function validated through conversations, but V3 intake intentionally
-- does not create a conversation, so validate the opportunity itself.
CREATE OR REPLACE FUNCTION public.correlate_easybroker_request(
  p_exact_request_id BIGINT,
  p_i24_capture_event_id BIGINT,
  p_opportunity_id BIGINT,
  p_idempotency_key TEXT,
  p_evidence JSONB,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  e public.i24_capture_events;
  q public.easybroker_contact_request_inbox;
  candidate BIGINT;
  candidates INTEGER;
  state TEXT;
  basis TEXT;
BEGIN
  IF p_i24_capture_event_id IS NULL
     OR NULLIF(BTRIM(p_idempotency_key), '') IS NULL OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid capture correlation input';
  END IF;
  PERFORM pg_advisory_xact_lock(p_i24_capture_event_id);
  SELECT * INTO e FROM public.i24_capture_events
  WHERE capture_event_id = p_i24_capture_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'capture event not found'; END IF;

  IF p_opportunity_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.lead_routing_opportunities o
    WHERE o.opportunity_id = p_opportunity_id
      AND o.v3_enabled
      AND UPPER(NULLIF(BTRIM(o.property_id), '')) =
          UPPER(NULLIF(BTRIM(e.property_public_id), ''))
  ) THEN
    RAISE EXCEPTION 'contextual opportunity property mismatch';
  END IF;

  IF p_exact_request_id IS NULL THEN
    state := CASE WHEN NOT EXISTS (
      SELECT 1 FROM public.easybroker_ingestion_checkpoints cp
      WHERE cp.account_key = e.account_key AND cp.source = 'easybroker'
        AND cp.watermark_at >= e.correlation_horizon_at
    ) THEN 'awaiting_eb_request' ELSE 'manual_review:no_eb_request' END;
    UPDATE public.i24_capture_events
    SET correlation_state = state, correlation_reason = state, correlated_at = p_now
    WHERE capture_event_id = p_i24_capture_event_id;
    RETURN jsonb_build_object('ok', FALSE, 'state', state, 'correlated_at', p_now);
  END IF;

  SELECT * INTO q FROM public.easybroker_contact_request_inbox
  WHERE eb_request_id = p_exact_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'exact request not found'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.easybroker_i24_request_links l
    WHERE l.eb_request_id = p_exact_request_id
  ) THEN
    IF EXISTS (
      SELECT 1 FROM public.easybroker_i24_request_links l
      WHERE l.eb_request_id = p_exact_request_id
        AND l.i24_capture_event_id = p_i24_capture_event_id
        AND (p_opportunity_id IS NULL OR l.opportunity_id = p_opportunity_id)
    ) THEN
      UPDATE public.easybroker_contact_request_inbox
      SET correlation_state = 'already_linked', correlation_reason = 'already_linked',
          correlated_at = p_now
      WHERE eb_request_id = p_exact_request_id;
      UPDATE public.i24_capture_events
      SET correlation_state = 'already_linked', correlation_reason = 'already_linked',
          correlated_at = p_now
      WHERE capture_event_id = p_i24_capture_event_id;
      RETURN jsonb_build_object('ok', TRUE, 'state', 'already_linked',
        'correlated_at', p_now);
    END IF;
    UPDATE public.easybroker_contact_request_inbox
    SET correlation_state = 'conflict', correlation_reason = 'conflict', correlated_at = p_now
    WHERE eb_request_id = p_exact_request_id;
    UPDATE public.i24_capture_events
    SET correlation_state = 'conflict', correlation_reason = 'conflict', correlated_at = p_now
    WHERE capture_event_id = p_i24_capture_event_id;
    RETURN jsonb_build_object('ok', FALSE, 'state', 'conflict', 'correlated_at', p_now);
  END IF;

  SELECT COUNT(DISTINCT i.eb_request_id)::INTEGER, MIN(i.eb_request_id)
  INTO candidates, candidate
  FROM public.easybroker_contact_request_inbox i
  WHERE i.account_key = e.account_key
    AND UPPER(NULLIF(BTRIM(i.property_public_id), '')) =
        UPPER(NULLIF(BTRIM(e.property_public_id), ''))
    AND i.happened_at BETWEEN e.correlation_window_start_at AND e.correlation_horizon_at
    AND (
      (e.normalized_email IS NOT NULL AND i.normalized_email IS NOT NULL
       AND LOWER(BTRIM(e.normalized_email)) = LOWER(BTRIM(i.normalized_email)))
      OR
      (e.e164_phone IS NOT NULL AND i.e164_phone IS NOT NULL
       AND BTRIM(e.e164_phone) = BTRIM(i.e164_phone))
    )
    AND NOT (
      (e.normalized_email IS NOT NULL AND i.normalized_email IS NOT NULL
       AND LOWER(BTRIM(e.normalized_email)) <> LOWER(BTRIM(i.normalized_email)))
      OR
      (e.e164_phone IS NOT NULL AND i.e164_phone IS NOT NULL
       AND BTRIM(e.e164_phone) <> BTRIM(i.e164_phone))
    );

  IF candidates = 1 AND candidate = p_exact_request_id THEN
    basis := CASE
      WHEN e.normalized_email IS NOT NULL AND q.normalized_email IS NOT NULL
       AND e.e164_phone IS NOT NULL AND q.e164_phone IS NOT NULL THEN 'email+phone'
      WHEN e.normalized_email IS NOT NULL AND q.normalized_email IS NOT NULL THEN 'email'
      ELSE 'phone' END;
    INSERT INTO public.easybroker_i24_request_links(
      eb_request_id, i24_capture_event_id, opportunity_id, idempotency_key,
      evidence, match_basis, delta, linked_at
    ) VALUES (
      p_exact_request_id, p_i24_capture_event_id, p_opportunity_id,
      p_idempotency_key, COALESCE(p_evidence, '{}'::JSONB), basis, '{}'::JSONB, p_now
    );
    state := 'linked';
  ELSIF candidates > 1 THEN
    state := 'manual_review:ambiguous';
  ELSE
    state := 'manual_review:identity_contradiction';
  END IF;
  UPDATE public.easybroker_contact_request_inbox
  SET correlation_state = state, correlation_reason = state, correlated_at = p_now
  WHERE eb_request_id = p_exact_request_id;
  UPDATE public.i24_capture_events
  SET correlation_state = state, correlation_reason = state, correlated_at = p_now
  WHERE capture_event_id = p_i24_capture_event_id;
  RETURN jsonb_build_object('ok', state = 'linked', 'state', state,
    'eb_request_id', p_exact_request_id, 'opportunity_id', p_opportunity_id,
    'match_basis', basis, 'candidate_count', candidates, 'correlated_at', p_now);
EXCEPTION WHEN unique_violation THEN
  UPDATE public.easybroker_contact_request_inbox
  SET correlation_state = 'conflict', correlation_reason = 'unique_link_conflict',
      correlated_at = p_now
  WHERE eb_request_id = p_exact_request_id;
  UPDATE public.i24_capture_events
  SET correlation_state = 'conflict', correlation_reason = 'unique_link_conflict',
      correlated_at = p_now
  WHERE capture_event_id = p_i24_capture_event_id;
  RETURN jsonb_build_object('ok', FALSE, 'state', 'conflict',
    'eb_request_id', p_exact_request_id, 'candidate_count', candidates,
    'correlated_at', p_now);
END;
$$;

CREATE OR REPLACE FUNCTION public.correlate_pending_easybroker_requests(
  p_limit INTEGER DEFAULT 100,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS TABLE(
  capture_event_id BIGINT,
  correlation_state TEXT,
  eb_request_id BIGINT,
  opportunity_id BIGINT,
  candidate_count INTEGER,
  effect_state TEXT,
  reason TEXT
)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  e public.i24_capture_events;
  v_candidate BIGINT;
  v_candidates INTEGER;
  v_contradictions INTEGER;
  v_horizon_covered BOOLEAN;
  v_state TEXT;
  v_reason TEXT;
  v_effect JSONB;
  v_exact_result JSONB;
  v_idempotency TEXT;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid pending correlation input';
  END IF;

  FOR e IN
    SELECT x.*
    FROM public.i24_capture_events x
    WHERE x.correlation_state IN ('pending', 'awaiting_eb_request')
    ORDER BY x.capture_event_id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_candidate := NULL;
    v_candidates := 0;
    v_contradictions := 0;
    v_effect := NULL;
    v_reason := NULL;

    -- A missing property is never eligible for an exact EasyBroker link.
    IF NULLIF(BTRIM(e.property_public_id), '') IS NOT NULL THEN
      SELECT COUNT(*)::INTEGER, MIN(i.eb_request_id)
      INTO v_candidates, v_candidate
      FROM public.easybroker_contact_request_inbox i
      WHERE i.account_key = e.account_key
        AND UPPER(NULLIF(BTRIM(i.property_public_id), '')) =
            UPPER(NULLIF(BTRIM(e.property_public_id), ''))
        AND i.happened_at BETWEEN e.correlation_window_start_at
                              AND e.correlation_horizon_at
        AND (
          (e.normalized_email IS NOT NULL AND i.normalized_email IS NOT NULL
           AND LOWER(BTRIM(e.normalized_email)) = LOWER(BTRIM(i.normalized_email)))
          OR
          (e.e164_phone IS NOT NULL AND i.e164_phone IS NOT NULL
           AND BTRIM(e.e164_phone) = BTRIM(i.e164_phone))
        )
        AND NOT (
          (e.normalized_email IS NOT NULL AND i.normalized_email IS NOT NULL
           AND LOWER(BTRIM(e.normalized_email)) <> LOWER(BTRIM(i.normalized_email)))
          OR
          (e.e164_phone IS NOT NULL AND i.e164_phone IS NOT NULL
           AND BTRIM(e.e164_phone) <> BTRIM(i.e164_phone))
        );

      -- Count property/time rows that carry an explicit contradictory identity
      -- separately. They must not be silently treated as a missing request.
      SELECT COUNT(*)::INTEGER
      INTO v_contradictions
      FROM public.easybroker_contact_request_inbox i
      WHERE i.account_key = e.account_key
        AND UPPER(NULLIF(BTRIM(i.property_public_id), '')) =
            UPPER(NULLIF(BTRIM(e.property_public_id), ''))
        AND i.happened_at BETWEEN e.correlation_window_start_at
                              AND e.correlation_horizon_at
        AND (
          (e.normalized_email IS NOT NULL AND i.normalized_email IS NOT NULL
           AND LOWER(BTRIM(e.normalized_email)) <> LOWER(BTRIM(i.normalized_email)))
          OR
          (e.e164_phone IS NOT NULL AND i.e164_phone IS NOT NULL
           AND BTRIM(e.e164_phone) <> BTRIM(i.e164_phone))
        );
    ELSE
      v_reason := 'missing_property_identity';
    END IF;

    IF v_candidates > 1 THEN
      v_state := 'manual_review:ambiguous';
      v_reason := 'multiple_exact_candidates';
    ELSIF v_contradictions > 0 THEN
      v_state := 'manual_review:identity_contradiction';
      v_reason := 'identity_contradiction';
    ELSIF v_candidates = 1 THEN
      -- Reuse the exact-link RPC so the one-to-one immutable link and its
      -- evidence remain governed by one database authority.
      v_idempotency := 'v3:correlation:' || e.capture_event_id::TEXT || ':'
                       || v_candidate::TEXT;
      SELECT public.correlate_easybroker_request(
        v_candidate, e.capture_event_id, e.opportunity_id,
        v_idempotency,
        jsonb_build_object(
          'source', 'automatic_pending_correlation',
          'candidate_count', v_candidates,
          'property_exact', TRUE,
          'identity_contradiction', FALSE
        ), p_now
      ) INTO v_exact_result;
      v_state := COALESCE(v_exact_result->>'state', 'conflict');
      v_reason := COALESCE(v_exact_result->>'state', 'correlation_rpc_no_state');

      -- Enqueue only after the exact link is durable. The V3-07 function may
      -- return awaiting_responsible; that is a valid durable outcome and is
      -- retried by this worker after assignment. Dynamic invocation keeps this
      -- draft apply-order safe if V3-07 is installed immediately afterward.
      IF v_state IN ('linked', 'already_linked') THEN
        BEGIN
          EXECUTE 'SELECT public.enqueue_v3_easybroker_effect($1, $2)'
          INTO v_effect
          USING v_candidate, p_now;
        EXCEPTION WHEN undefined_function THEN
          v_effect := jsonb_build_object('ok', FALSE, 'state', 'awaiting_responsible');
        END;
      END IF;
    ELSE
      SELECT EXISTS (
        SELECT 1
        FROM public.easybroker_ingestion_checkpoints cp
        WHERE cp.account_key = e.account_key
          AND cp.source = 'easybroker'
          AND cp.watermark_at >= e.correlation_horizon_at
      ) INTO v_horizon_covered;
      IF v_reason = 'missing_property_identity' THEN
        v_state := 'manual_review:identity_contradiction';
      ELSIF COALESCE(v_horizon_covered, FALSE) THEN
        v_state := 'manual_review:no_eb_request';
        v_reason := 'checkpoint_covers_horizon';
      ELSE
        v_state := 'awaiting_eb_request';
        v_reason := 'checkpoint_before_horizon';
      END IF;
    END IF;

    UPDATE public.i24_capture_events x
    SET correlation_state = v_state,
        correlation_reason = v_reason,
        correlated_at = p_now
    WHERE x.capture_event_id = e.capture_event_id;

    capture_event_id := e.capture_event_id;
    correlation_state := v_state;
    eb_request_id := CASE WHEN v_state IN ('linked', 'already_linked') THEN v_candidate END;
    opportunity_id := e.opportunity_id;
    candidate_count := v_candidates;
    effect_state := v_effect->>'state';
    reason := v_reason;
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.correlate_pending_easybroker_requests(INTEGER, TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.correlate_pending_easybroker_requests(INTEGER, TIMESTAMPTZ)
  TO service_role;
